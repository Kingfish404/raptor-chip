#!/usr/bin/env python3
"""Run a CPU MMIO diagnostic from DDR, then return to the native ROM monitor.

Use a matching native build with CM005 enabled. The ROM must be waiting for
commands; this tool uploads a small payload at 0x80000000 and uses a stack below
0x80020000. It does not reset the FPGA or write PHY configuration registers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import termios
import time

BOARD = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BOARD.parent / 'common/scripts'))
from upload import Serial, ack, load, packet


def build_payload(build, output, cross):
    config = json.loads((build / 'manifest.json').read_text())['configuration']
    if not config.get('cm005_bridge'):
        raise ValueError('Build does not enable CM005 forwarding')
    if config['memory'] != 'ddr' and config['ram_bytes'] < 0x20000:
        raise ValueError('Diagnostic needs at least 128 KiB of RAM')
    xlen = config['xlen']
    output.mkdir(parents=True, exist_ok=True)
    linker = output / 'cm005_diag.ld'
    linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; '
                      '.text : { *(.text.start) *(.text*) } '
                      '.rodata : { *(.rodata*) } .data : { *(.data*) } '
                      '.bss : { *(.bss*) *(COMMON) } '
                      'ASSERT(SIZEOF(.bss) == 0, "unexpected BSS") }\n')
    sources = [BOARD / 'firmware/cm005_diag.S', BOARD / 'firmware/cm005_diag.c']
    elf, binary = output / 'cm005_diag.elf', output / 'cm005_diag.bin'
    subprocess.run([cross + 'gcc', f'-march=rv{xlen}imac_zicsr_zifencei',
                    '-mabi=' + ('lp64' if xlen == 64 else 'ilp32'), '-mcmodel=medany',
                    '-Os', '-ffreestanding', '-fno-builtin', '-fno-stack-protector',
                    '-msmall-data-limit=0', '-nostdlib', '-Wall', '-Wextra', '-Werror',
                    '-Wl,--build-id=none', '-Wl,--no-relax', '-T', str(linker),
                    '-I', str(build / 'cm005-generated'), *map(str, sources),
                    '-o', str(elf)], check=True)
    subprocess.run([cross + 'objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
    if binary.stat().st_size >= 0x10000:
        raise ValueError('Diagnostic payload overlaps its reserved stack region')
    return binary


def parse_report(raw, build):
    registers = json.loads((build / 'cm005-generated/cm005_registers.json').read_text())
    names = {r['offset']: r['name'] for r in registers['registers']}
    result = {'unix_time': time.time(), 'registers': {}, 'phys': {}}
    for line in raw.decode('ascii').splitlines():
        fields = line.split()
        if fields and fields[0] == 'CSR' and len(fields) == 3:
            offset, value = (int(f, 16) for f in fields[1:])
            result['registers'][names[offset]] = value
        elif fields and fields[0] == 'PHY' and len(fields) == 4:
            port, reg, value = (int(f, 16) for f in fields[1:])
            result['phys'].setdefault('ab'[port], {})[str(reg)] = value
    if result['registers'].get('bridge_id') != 0x434d3035:
        raise RuntimeError('CPU MMIO bridge identity check failed')
    if len(result['registers']) != len(names):
        raise RuntimeError('Incomplete bridge register snapshot')
    for phy in result['phys'].values():
        phy['valid_id'] = phy.get('2') not in (None, 0, 0xffff)
        phy['link_up'] = phy['valid_id'] and bool(phy.get('1', 0) & 4)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--port')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--cross', default='riscv64-unknown-elf-')
    args = parser.parse_args()
    if not args.build_only and not args.port:
        parser.error('--port is required unless --build-only is selected')
    binary = build_payload(args.build.resolve(), args.output.resolve(), args.cross)
    if args.build_only:
        print(binary)
        return
    serial = Serial(args.port)
    raw = bytearray()
    try:
        termios.tcflush(serial.fd, termios.TCIFLUSH)
        load(serial, 0x80000000, binary.read_bytes())
        serial.write(packet(2, 0x80000000, 0))
        ack(serial)
        deadline = time.monotonic() + 30
        while not raw.endswith(b'RAPT ready\r\n'):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Native diagnostic did not return to the ROM monitor')
            raw.extend(serial.read(timeout=remaining))
            if len(raw) > 16384:
                raise RuntimeError('Unexpected diagnostic output length')
    finally:
        serial.close()
        (args.output / 'uart.log').write_bytes(raw)
    if b'CM005_NATIVE_END\r\n' not in raw:
        raise RuntimeError('Native diagnostic did not complete')
    report = parse_report(raw, args.build)
    report['payload_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    report['build_sha256'] = json.loads((args.build / 'manifest.json').read_text())['sha256']
    (args.output / 'status.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
