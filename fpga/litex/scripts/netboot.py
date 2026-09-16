#!/usr/bin/env python3
"""Prepare LiteX TFTP Linux bundles without running Make or touching hardware.

Only pack writes persistent files, exclusively to a new output directory.
check uses temporary scratch space for ELF/DTB validation. serve-plan only prints.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile

from patch_litex_sdcard_linux_override import find_opensbi_fdt_sequence, encode_lui_a1


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.PIPE)


def overlap(a, size_a, b, size_b):
    return a < b + size_b and b < a + size_a


def patch_payload(payload, destination, base):
    offset, old, _ = find_opensbi_fdt_sequence(payload)
    new = encode_lui_a1(destination - base)
    patched = bytearray(payload)
    struct.pack_into('<I', patched, offset, new)
    return bytes(patched), {'offset': offset, 'old_lui': hex(old), 'new_lui': hex(new)}


def validate_layout(symbols, stage, payload, dtb, ram_size, kernel_end):
    base = symbols['MAIN_RAM']
    require(base == 0x80000000 and symbols['_start'] == base, 'unsupported stage0 entry/RAM base')
    require(0 < ram_size <= 0x40000000, 'RAM must fit the current 1 GiB PMA window')
    require(symbols['PAYLOAD_SIZE'] == len(payload), 'stage0 PAYLOAD_SIZE differs from release')
    require(symbols['DTB_SIZE'] == len(dtb), 'stage0 DTB_SIZE differs from seeded DTB')
    require(symbols['STAGE0_SRAM'] == 0x0f000000, 'unsupported stage0 SRAM address')
    require(symbols['UART_RXTX'] == 0xf0001800, 'unsupported stage0 UART address')
    require(0 < symbols['_reloc_end'] - symbols['_reloc_start'] <= 0x1000,
            'relocation routine exceeds conservative 4 KiB SRAM budget')
    require(base <= symbols['_reloc_start'] < symbols['_reloc_end'] <= base + len(stage),
            'relocation routine lies outside stage0 binary')
    regions = [(base, len(stage)), (symbols['PAYLOAD_SRC'], len(payload)),
               (symbols['DTB_SRC'], len(dtb))]
    for i, (address, size) in enumerate(regions):
        require(size > 0 and address % 4 == 0 and base <= address < address + size <= base + ram_size,
                'upload region outside RAM, empty, or misaligned')
        for other, other_size in regions[:i]:
            require(not overlap(address, size, other, other_size), 'upload regions overlap')
    require(symbols['PAYLOAD_SRC'] > base, 'stage0 requires downward payload copy')
    dest = symbols['DTB_DEST']
    require(base < kernel_end <= dest and dest + len(dtb) <= base + ram_size,
            'runtime DTB overlaps kernel or exceeds RAM')
    require(not overlap(base, len(payload), dest, len(dtb)), 'runtime payload overlaps runtime DTB')
    require(not overlap(base, len(payload), symbols['DTB_SRC'], len(dtb)),
            'payload relocation overwrites DTB before its copy')
    require(dest <= symbols['DTB_SRC'] or not overlap(dest, len(dtb), symbols['DTB_SRC'], len(dtb)),
            'stage0 cannot copy DTB upward over itself')


def prepare(firmware, package, xlen, cross):
    """Snapshot inputs, validate snapshots, return files and provenance."""
    inputs = {name: (firmware / name).read_bytes() for name in
              ('stage0.elf', 'stage0.bin', 'litex-soc-seeded.dtb')}
    manifest_data = (package / 'manifest.json').read_bytes()
    manifest = json.loads(manifest_data)
    payload = (package / 'fw_payload.bin').read_bytes()
    require(manifest['bits'] == xlen, 'release XLEN mismatch')
    require(manifest['files']['fw_payload.bin'] == digest(payload), 'release payload SHA256 mismatch')
    elf = inputs['stage0.elf']
    require(elf[:4] == b'\x7fELF' and len(elf) >= 24 and elf[4] == {32: 1, 64: 2}[xlen]
            and elf[5] == 1 and struct.unpack_from('<H', elf, 18)[0] == 243,
            'stage0 must be a matching little-endian RISC-V ELF')
    stage, dtb = inputs['stage0.bin'], inputs['litex-soc-seeded.dtb']
    require(len(dtb) >= 40 and struct.unpack_from('>II', dtb) == (0xd00dfeed, len(dtb)),
            'invalid or truncated DTB')
    with tempfile.TemporaryDirectory(prefix='raptor-netboot-check-') as scratch:
        root = Path(scratch)
        (root / 'stage0.elf').write_bytes(elf)
        (root / 'soc.dtb').write_bytes(dtb)
        symbols = {}
        for line in run(cross + 'nm', '-P', root / 'stage0.elf').decode().splitlines():
            fields = line.split()
            if len(fields) >= 3:
                symbols[fields[0]] = int(fields[2], 16)
        run(cross + 'objcopy', '-O', 'binary', root / 'stage0.elf', root / 'stage0.bin')
        require((root / 'stage0.bin').read_bytes() == stage, 'stage0.bin does not match stage0.elf')

        def prop(node, name, kind='s'):
            return run('fdtget', '-t', kind, root / 'soc.dtb', node, name).decode().strip()

        require(prop('/cpus/cpu@0', 'riscv,isa-base') == f'rv{xlen}i', 'DTB XLEN mismatch')
        require(prop('/cpus/cpu@0', 'mmu-type') == f'riscv,sv{39 if xlen == 64 else 32}',
                'DTB MMU mismatch')
        require(prop('/', '#address-cells', 'x') == '1' and prop('/', '#size-cells', 'x') == '1',
                'only current single-cell Raptor DT memory format is supported')
        ram = [int(v, 16) for v in prop('/memory@80000000', 'reg', 'x').split()]
        require(len(ram) == 2 and ram[0] == 0x80000000, 'unsupported DTB memory map')
        seed = [int(v, 16) for v in prop('/chosen', 'rng-seed', 'bx').split()]
        require(len(seed) == 32 and any(seed), 'DTB lacks a populated 32-byte development RNG seed')
        timebase = int(prop('/cpus', 'timebase-frequency', 'u'))
        require(timebase > 0, 'invalid DTB timebase')
        bootargs = prop('/chosen', 'bootargs')
        isa = prop('/cpus/cpu@0', 'riscv,isa')
        if manifest.get('abi') in ('lp64d', 'ilp32d'):
            letters = isa.split('_')[0][4:]
            require('f' in letters and 'd' in letters, 'hard-float release requires F/D in DTB')
    validate_layout(symbols, stage, payload, dtb, ram[1], int(manifest['kernel_memory_end'], 0))
    require(int(manifest['fdt_address'], 0) == symbols['DTB_DEST'], 'release/stage0 FDT destination mismatch')
    patched, patch = patch_payload(payload, symbols['DTB_DEST'], symbols['MAIN_RAM'])
    boot = {'fw_payload.bin': hex(symbols['PAYLOAD_SRC']), 'soc.dtb': hex(symbols['DTB_SRC']),
            'stage0.bin': hex(symbols['MAIN_RAM']), 'addr': hex(symbols['_start'])}
    files = {'fw_payload.bin': patched, 'soc.dtb': dtb, 'stage0.bin': stage,
             'boot.json': (json.dumps(boot, indent=2) + '\n').encode()}
    record = {'schema': 1, 'xlen': xlen, 'board_validated': False,
              'firmware_source': str(firmware.resolve()), 'package_source': str(package.resolve()),
              'source_sha256': {**{k: digest(v) for k, v in inputs.items()},
                                'fw_payload.bin': digest(payload), 'manifest.json': digest(manifest_data)},
              'symbols': symbols, 'ram_size': ram[1], 'timebase': timebase, 'bootargs': bootargs,
              'opensbi_patch': patch, 'files': {k: digest(v) for k, v in files.items()}}
    return files, record


def write_bundle(out, files, record):
    # Exclusive creation: never overwrite another session's bundle or a symlink.
    out.mkdir(mode=0o755, parents=False, exist_ok=False)
    for name, data in {**files, 'bundle.json': (json.dumps(record, indent=2) + '\n').encode()}.items():
        with (out / name).open('xb') as stream:
            stream.write(data)
        (out / name).chmod(0o444)
    out.chmod(0o755)


def verify_bundle(out):
    record = json.loads((out / 'bundle.json').read_bytes())
    names = {'boot.json', 'fw_payload.bin', 'soc.dtb', 'stage0.bin'}
    require(record['schema'] == 1 and set(record['files']) == names, 'invalid bundle file list/schema')
    for name, expected in record['files'].items():
        require(not (out / name).is_symlink(), 'bundle symlinks are not supported')
        require(digest((out / name).read_bytes()) == expected, f'bundle SHA256 mismatch: {name}')
    boot = json.loads((out / 'boot.json').read_bytes())
    s = record['symbols']
    require(boot == {'fw_payload.bin': hex(s['PAYLOAD_SRC']), 'soc.dtb': hex(s['DTB_SRC']),
                     'stage0.bin': hex(s['MAIN_RAM']), 'addr': hex(s['_start'])},
            'boot manifest differs from recorded layout')
    return record


def serve_plan(out, address, port):
    record = verify_bundle(out)
    require(record.get('xlen') in (32, 64), 'invalid bundle XLEN')
    relative = Path('raptor-netboot') / f'rv{record["xlen"]}' / digest((out / 'bundle.json').read_bytes())
    ip = ipaddress.IPv4Address(address)
    require(not (ip.is_unspecified or ip.is_multicast or ip.is_reserved or int(ip) == 0xffffffff),
            'specify the host board-facing unicast IPv4 address, not a wildcard')
    require(1 <= port <= 65535, 'invalid server port')
    daemon = shutil.which('in.tftpd') or '/usr/sbin/in.tftpd'
    print('PLAN ONLY: no server, sudo, network or firewall changes are performed.')
    if not Path(daemon).is_file():
        print('MISSING: tftpd-hpa (install separately; do not alter an active network session).')
    # A dedicated export tree keeps root boot.json out of the boot protocol.
    # These are printed instructions only; serve-plan remains read-only.
    staging = (
        'import json,pathlib,shutil,sys; '
        'source=pathlib.Path(sys.argv[1]); root=pathlib.Path(sys.argv[2]); '
        f'relative=pathlib.Path({str(relative)!r}); '
        'dest=root/relative; dest.mkdir(parents=True); '
        '[shutil.copyfile(source/name,dest/name) for name in '
        '("fw_payload.bin","soc.dtb","stage0.bin")]; '
        'boot=json.loads((source/"boot.json").read_text()); '
        '(dest/"boot.json").write_text(json.dumps('
        '{str(relative/name) if name!="addr" else name:value for name,value in boot.items()})); '
        '[p.chmod(0o444) for p in dest.iterdir()]; root.chmod(0o755)'
    )
    print('netboot_export=$(mktemp -d /tmp/raptor-netboot-export.XXXXXX)')
    print(shlex.join([sys.executable, '-c', staging, str(out.resolve())]) + ' "$netboot_export"')
    print(shlex.join([daemon, '--listen', '--foreground', '--ipv4', '--address', f'{ip}:{port}',
                     '--secure', '--blocksize', '512']) + ' "$netboot_export"')
    print('Review privileges for chroot/port binding; allow only the board on the lab interface.')
    print(f'BIOS must use this server IP/port. At litex>: netboot {relative}/boot.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'pack', 'verify', 'serve-plan'))
    for name in ('firmware', 'package', 'out'):
        parser.add_argument('--' + name, default=os.environ.get('NETBOOT_' + name.upper()))
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=os.environ.get('NETBOOT_XLEN', '64'))
    parser.add_argument('--cross', default=os.environ.get('NETBOOT_CROSS', 'riscv64-linux-gnu-'))
    parser.add_argument('--server-ip', default=os.environ.get('NETBOOT_SERVER_IP', ''))
    parser.add_argument('--server-port', type=int, default=os.environ.get('NETBOOT_SERVER_PORT', '69'))
    args = parser.parse_args()
    try:
        if args.action in ('check', 'pack'):
            require(args.firmware and args.package, 'set NETBOOT_FIRMWARE and NETBOOT_PACKAGE (finished inputs only)')
            files, record = prepare(Path(args.firmware), Path(args.package), args.xlen, args.cross)
            if args.action == 'pack':
                require(args.out, 'set NETBOOT_OUT to a new directory with an existing parent')
                write_bundle(Path(args.out), files, record)
            print(f"PASS: RV{args.xlen} software layout, ELF/bin, release hash, seeded DTB and OpenSBI patch")
            print('Not validated: matching bitstream/CSR/timebase, BIOS networking, TFTP transfer, Linux boot.')
        else:
            require(args.out, 'set NETBOOT_OUT to an existing bundle')
            if args.action == 'verify':
                verify_bundle(Path(args.out))
                print('PASS: bundle hashes and boot manifest')
            else:
                serve_plan(Path(args.out), args.server_ip, args.server_port)
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
