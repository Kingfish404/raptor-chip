"""Check opt-in Sscofpmf with the WARL-zero HPM banks used by Raptor."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path

from lib.reference import ISAAPI, Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--enable', action='store_true')
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    check('supported', api.supported, 2047 if args.xlen == 64 else 998)
    check('configure', api.configure(32 if args.enable else 0), 0)
    reference = Reference(args.reference, args.xlen)
    state = reference.state

    def write(csr, value):
        state.gpr[4] = value & reference.mask
        return reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def read(csr):
        pc = reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return state.gpr[3], pc

    for csr in (0xda0, 0x723 if args.xlen == 32 else 0x323):
        reference.reset()
        value, pc = read(csr)
        if args.enable:
            check(f'csr-{csr:x}', [value, state.pc[0]], [0, pc + 4])
        elif csr in (0xda0, 0x723):
            check(f'csr-{csr:x}-illegal', [state.mcause[0], state.mtval[0], state.pc[0]],
                  [2, (csr << 20) | (2 << 12) | (3 << 7) | 0x73, 0x80ff0000])

    reference.reset()
    state.priv[0] = b'\x01'
    value, pc = read(0xda0)
    if args.enable:
        check('scountovf-supervisor', [value, state.pc[0]], [0, pc + 4])
    else:
        check('scountovf-supervisor-illegal', [state.mcause[0], state.pc[0]],
              [2, 0x80ff0000])

    reference.reset()
    pc = write(0xda0, 1)
    check('scountovf-write-illegal', [state.mcause[0], state.mepc[0], state.pc[0]],
          [2, pc, 0x80ff0000])

    reference.reset()
    write(0x303, 0x2000)
    value, _ = read(0x303)
    check('mideleg-lcofi', value, 0x2000 if args.enable else 0)
    write(0x304, 0x2000)
    value, _ = read(0x104)
    check('sie-lcofie', value, 0x2000 if args.enable else 0)
    write(0x344, 0x2000)
    value, _ = read(0x144)
    check('sip-lcofip', value, 0x2000 if args.enable else 0)
    value, _ = read(0x344)
    check('mip-lcofip', value & 0x2000, 0x2000 if args.enable else 0)
    write(0x106, 0xffffffff)
    value, _ = read(0x106)
    check('scounteren-unimplemented-hpm', value & ~0x7, 0)
    if args.xlen == 32 and args.enable:
        write(0x723, 0xffffffff)
        value, _ = read(0x723)
        check('mhpmevent3h-warl-zero', value, 0)
    state.priv[0] = b'\x01'
    state.stvec[0] = 0x80fe0000
    library.difftest_raise_intr.argtypes = [reference.word]
    library.difftest_raise_intr((1 << (args.xlen - 1)) | 13)
    check('lcofi-delegation', [state.pc[0], state.scause[0], state.mcause[0]],
          [0x80fe0000, (1 << (args.xlen - 1)) | 13, 0] if args.enable else
          [0x80ff0000, 0, (1 << (args.xlen - 1)) | 13])

    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, enabled=args.enable,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_SSCOFPMF xlen={args.xlen} enabled={args.enable} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
