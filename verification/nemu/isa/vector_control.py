"""Check opt-in V128 advertisement, control instructions and CSRs."""
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
    check('configure', api.configure(64 if args.enable else 0), 0)
    reference = Reference(args.reference, args.xlen)
    state = reference.state
    villain = 1 << (args.xlen - 1)

    def csr_read(csr):
        pc = reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return state.gpr[3], pc

    def csr_write(csr, value):
        state.gpr[4] = value & reference.mask
        return reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def vsetvli(vtype, rs1=1, rd=3):
        return reference.run([((vtype & 0x7ff) << 20) | (rs1 << 15) | (7 << 12) | (rd << 7) | 0x57])

    def vsetivli(vtype, avl, rd=3):
        return reference.run([0xc0000000 | ((vtype & 0x3ff) << 20) |
                              (avl << 15) | (7 << 12) | (rd << 7) | 0x57])

    def vsetvl(vtype, rs1=1, rd=3):
        state.gpr[2] = vtype & reference.mask
        return reference.run([(0x40 << 25) | (2 << 20) | (rs1 << 15) |
                              (7 << 12) | (rd << 7) | 0x57])

    reference.reset()
    if args.enable:
        value, pc = csr_read(0xc21)
        check('vs-off-csr-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    else:
        value, pc = csr_read(0xc22)
        check('disabled-csr-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    state.gpr[1] = 0x80071000
    state.gpr[2] = 2
    pc = reference.run([(2 << 26) | (1 << 25) | (2 << 20) | (1 << 15) | (8 << 7) | 0x07])
    check('vs-off-strided-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([(1 << 26) | (1 << 25) | (16 << 20) | (1 << 15) | (8 << 7) | 0x07])
    check('vs-off-indexed-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    state.gpr[1] = 100
    pc = vsetvli(0xc0)
    check('vs-off-vset-illegal', [state.mcause[0], state.mepc[0], state.minstret[0]],
          [2, pc, 100])
    csr_write(0x300, (state.mstatus[0] & ~0x6000) | 0x200)
    check('vs-warl', state.mstatus[0] & 0x600, 0x200 if args.enable else 0)
    check('misa-v', bool(state.misa[0] & (1 << 21)), args.enable)
    value, _ = csr_read(0x301)
    check('misa-read-v', bool(value & (1 << 21)), args.enable)
    csr_write(0x301, 0)
    value, _ = csr_read(0x301)
    check('misa-write-zero-preserves-v', bool(value & (1 << 21)), args.enable)
    csr_write(0x301, 1 << 21)
    value, _ = csr_read(0x301)
    check('misa-write-v-preserves-mode', bool(value & (1 << 21)), args.enable)

    if args.enable:
        check('vs-initial-sd-clear', bool(state.mstatus[0] & villain), False)
        value, _ = csr_read(0xc21)
        check('reset-vill', value, villain)
        value, _ = csr_read(0xc20)
        check('reset-vl', value, 0)
        value, _ = csr_read(0xc22)
        check('vlenb', value, 16)
        state.gpr[1] = 100
        pc = vsetvli(0xc0)
        check('e8-m1', [state.gpr[3], state.pc[0], state.mstatus[0] & 0x600],
              [16, pc + 4, 0x600])
        check('vs-dirty-sd-set', bool(state.mstatus[0] & villain), True)
        value, _ = csr_read(0x100)
        check('sstatus-vs-dirty', value & 0x600, 0x600)
        csr_write(0x008, 255)
        value, _ = csr_read(0x008)
        check('vstart-warl', value, 127)
        vsetivli(0xc9, 5)
        check('e16-m2-immediate', state.gpr[3], 5)
        value, _ = csr_read(0x008)
        check('vset-clears-vstart', value, 0)
        csr_write(0x00a, 3)
        csr_write(0x009, 1)
        value, _ = csr_read(0x00f)
        check('vcsr-alias', value, 7)
        csr_write(0x00f, 2)
        check('vcsr-write', [csr_read(0x00a)[0], csr_read(0x009)[0]], [1, 0])
        vsetvl(0xd0)
        check('e32-m1-register', [state.gpr[3], csr_read(0xc21)[0]], [4, 0xd0])
        vsetvl(0xd9, rs1=0, rd=0)
        check('keep-vl-e64-m2', [csr_read(0xc20)[0], csr_read(0xc21)[0]], [4, 0xd9])
        vsetvli(0xc0, rs1=0, rd=0)
        check('keep-vl-reserved', [csr_read(0xc20)[0], csr_read(0xc21)[0]], [0, villain])
        vsetvl(0xdf)
        check('unsupported-fractional', [csr_read(0xc20)[0], csr_read(0xc21)[0]],
              [0, villain])
        vsetvli(0x100)
        check('reserved-vtype-bits', csr_read(0xc21)[0], villain)
        pc = csr_write(0xc20, 1)
        check('vl-readonly', [state.mcause[0], state.mepc[0]], [2, pc])
        state.gpr[1] = 1
        pc = reference.run([0x00008057])
        check('unimplemented-vector-op-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    else:
        pc = vsetvli(0xc0)
        check('disabled-vset-illegal', [state.mcause[0], state.mepc[0]], [2, pc])

    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, enabled=args.enable,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_CONTROL xlen={args.xlen} enabled={args.enable} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
