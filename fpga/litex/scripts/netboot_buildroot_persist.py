#!/usr/bin/env python3
"""Add an external runtime overlay to a verified RV32/RV64 Buildroot release."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import stat

from add_linux_sdcard_dts import sdcard_node
from netboot_distro import ADDRESSES, LITEX, persistence_bootargs, require, run, sha


def build(package, soc, csr, runtime, output, work, data_selector='LABEL=RAPTOR_DATA', persist_logs=False):
    extra_bootargs = persistence_bootargs(data_selector, persist_logs)
    manifest = json.loads((package / 'manifest.json').read_text())
    bits = manifest['bits']
    require(bits in (32, 64), 'unsupported XLEN')
    addresses = dict(ADDRESSES, Image=0x80400000 if bits == 32 else 0x80200000)
    for name in ('Image', 'fw_dynamic.bin', 'initramfs.cpio.gz', 'kernel.config'):
        require(sha(package / name) == manifest['files'][name], f'source hash mismatch: {name}')
    config = (package / 'kernel.config').read_text()
    for option in ('MMC_LITEX', 'MMC_BLOCK', 'EXT4_FS', 'BLK_DEV_INITRD', 'REGULATOR_FIXED_VOLTAGE'):
        require(f'CONFIG_{option}=y\n' in config, f'kernel lacks {option}')
    require(run('fdtget', '-t', 's', soc, '/cpus/cpu@0', 'riscv,isa-base').strip() == f'rv{bits}i'.encode(),
            'DTB XLEN mismatch')
    require(run('fdtget', '-t', 'x', soc, '/memory@80000000', 'reg').strip() == b'80000000 40000000',
            'requires the 1 GiB RAM map')
    require(not output.exists(), 'output must be new')
    work.mkdir(parents=True, exist_ok=False)
    files = work / 'files'
    files.mkdir()
    for name in ('Image', 'fw_dynamic.bin', 'kernel.config'):
        shutil.copyfile(package / name, files / name)
    # Linux accepts concatenated newc archives. Preserve the release filesystem
    # and overlay only the startup scripts, including regular /sbin entries.
    raw = bytearray(gzip.decompress((package / 'initramfs.cpio.gz').read_bytes()))
    raw.extend(b'\0' * (-len(raw) % 4))
    def entry(name, data, mode):
        encoded = name.encode() + b'\0'
        fields = (0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(encoded), 0)
        header = b'070701' + ''.join(f'{v:08x}' for v in fields).encode() + encoded
        raw.extend(header + b'\0' * (-len(header) % 4))
        raw.extend(data + b'\0' * (-len(data) % 4))
    provenance = {}
    for name in ('raptor-persist', 'raptor-mounts', 'raptor-shell'):
        entry('sbin/' + name, (runtime / name).read_bytes(), stat.S_IFREG | 0o755)
        provenance[name] = sha(runtime / name)
    entry('TRAILER!!!', b'', 0)
    (files / 'rootfs.cpio.gz').write_bytes(gzip.compress(bytes(raw), compresslevel=1, mtime=0))
    size = (files / 'rootfs.cpio.gz').stat().st_size
    require(len(raw) + size < 700 * 1024 * 1024, 'rootfs exceeds RAM budget')
    import struct
    image = (files / 'Image').read_bytes()[:64]
    limit = addresses['soc.dtb'] - addresses['Image']
    require(struct.unpack_from('<Q', image, 8)[0] == addresses['Image'] - 0x80000000,
            'kernel load alignment does not match XLEN')
    require(image[56:60] == b'RSC\x05' and struct.unpack_from('<Q', image, 16)[0] < limit,
            'invalid Image or kernel overlaps DTB')
    require((files / 'Image').stat().st_size < limit and
            (files / 'fw_dynamic.bin').stat().st_size < 0x200000, 'download regions overlap')
    dts = work / 'soc.dts'
    source = run('dtc', '-q', '-I', 'dtb', '-O', 'dts', soc).decode()
    require('"litex,mmc"' not in source, 'use a base DTB without MMC')
    dts.write_text(source + sdcard_node(json.loads(csr.read_text())))
    dtb = files / 'soc.dtb'
    run('dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', dtb, dts)
    for prop, value in [('linux,initrd-start', 0x88000000), ('linux,initrd-end', 0x88000000 + size)]:
        run('fdtput', '-t', 'x', dtb, '/chosen', prop, f'{value:x}')
    bootargs = 'console=liteuart0,115200 earlycon=sbi rdinit=/sbin/raptor-shell random.trust_bootloader=on' + extra_bootargs
    run('fdtput', '-t', 's', dtb, '/chosen', 'bootargs', bootargs)
    run('riscv64-linux-gnu-gcc', f'-march=rv{bits}imac_zicsr_zifencei',
        '-mabi=' + ('ilp32' if bits == 32 else 'lp64'), '-nostdlib', '-nostartfiles', '-static',
        '-fno-pic', '-no-pie', '-Wl,--build-id=none,-Ttext=0x87f00000', '-o', work / 'stage0.elf',
        LITEX / 'firmware/linux-fpga/netboot_dynamic.S')
    run('riscv64-linux-gnu-objcopy', '-O', 'binary', work / 'stage0.elf', files / 'stage0.bin')
    record = {'schema': 'raptor-distro-netboot-v1', 'xlen': bits, 'distro': 'buildroot',
              'startup_cmo_policy': 'menvcfg-cbie3-cbcfe1',
              'source': str(package), 'source_manifest_sha256': sha(package / 'manifest.json'),
              'kernel_config_sha256': sha(package / 'kernel.config'), 'source_dtb_sha256': sha(soc),
              'sd_csr_sha256': sha(csr), 'runtime_sha256': provenance, 'board_validated': False,
              'rootfs_persistent': False, 'persistent_directories': ['/data', '/home', '/root'] + (['/var/log'] if persist_logs else []),
              'data_selector': data_selector, 'bootargs': bootargs,
              'files': {name: sha(files / name) for name in addresses}}
    identity = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()[:20]
    relative = Path(f'raptor-netboot/rv{bits}/buildroot-{identity}')
    record['tftp_path'] = str(relative)
    boot = {str(relative / name): hex(address) for name, address in addresses.items()}
    boot['addr'] = hex(addresses['stage0.bin'])
    (files / 'boot.json').write_text(json.dumps(boot, indent=2) + '\n')
    record['files']['boot.json'] = sha(files / 'boot.json')
    (files / 'bundle.json').write_text(json.dumps(record, indent=2) + '\n')
    shutil.copytree(files, output)
    for path in output.iterdir():
        path.chmod(0o444)
    print(f'BUNDLE={output}\nnetboot {relative}/boot.json')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('package', 'soc', 'csr', 'runtime', 'output', 'work'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--data-selector', default='LABEL=RAPTOR_DATA')
    parser.add_argument('--persist-logs', action='store_true')
    args = parser.parse_args()
    build(*(getattr(args, name).resolve() for name in ('package', 'soc', 'csr', 'runtime', 'output', 'work')),
          data_selector=args.data_selector, persist_logs=args.persist_logs)
