#!/usr/bin/env python3
"""Check Sv39 gigapage VPN[1] placement using standalone RV64 NEMU stores.

Run in a separate process: NEMU exports global state. The five addresses
exercise nonzero VPN[1]; a sixth completion marker proves execution finished.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--reference', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--cc', default='riscv64-elf-gcc')
    ap.add_argument('--objcopy', default='riscv64-elf-objcopy')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = root / 'app/tests/baremetal/nemu_sv39_superpage.S'
    linker = root / 'verify/scripts/fuzz_link.ld'
    ref = args.reference.resolve()
    commands = [
        [args.cc, '-march=rv64imac_zicsr', '-mabi=lp64', '-nostdlib',
         '-nostartfiles', '-static', '-Wl,--no-relax', '-T', str(linker),
         str(source), '-o', str(out / 'probe.elf')],
        [args.objcopy, '-O', 'binary', str(out / 'probe.elf'), str(out / 'probe.bin')],
    ]
    for command in commands:
        subprocess.run(command, check=True)
    lib = ctypes.CDLL(str(ref))
    lib.difftest_init.argtypes = [ctypes.c_int]
    lib.difftest_memcpy.argtypes = [ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_bool]
    lib.difftest_exec.argtypes = [ctypes.c_uint64]
    lib.difftest_init(0)
    data = (out / 'probe.bin').read_bytes()
    buf = ctypes.create_string_buffer(data)
    lib.difftest_memcpy(0x80000000, buf, len(data), True)
    lib.difftest_exec(200)
    values = {}
    for address in [0x80200008, 0x80400008, 0x82000008, 0x83e00008, 0x87e00008, 0x80080000]:
        value = ctypes.create_string_buffer(8)
        lib.difftest_memcpy(address, value, 8, False)
        values[hex(address)] = int.from_bytes(value.raw, 'little')
    passed = all(value == 0x12345678 for value in values.values())
    report = {'passed': passed, 'values': values, 'commands': commands,
              'sha256': {str(f): hashlib.sha256(f.read_bytes()).hexdigest()
                         for f in [source, linker, ref, out / 'probe.bin']}}
    (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS' if passed else 'FAIL', 'Sv39 gigapage physical address placement')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
