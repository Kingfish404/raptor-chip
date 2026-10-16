"""Check Zawrs decode, privilege checks, retirement and LR/SC preservation."""
import argparse
import ctypes
import hashlib
import itertools
import json
from pathlib import Path

from lib.reference import ISAAPI, Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--enable', action='store_true')
    parser.add_argument('--hypervisor', action='store_true')
    args = parser.parse_args()
    if args.hypervisor and (args.xlen != 64 or not args.enable):
        parser.error('--hypervisor requires RV64 and --enable')
    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    size = ctypes.sizeof(ISAAPI)
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    check('supported', query(1, size).contents.supported, 2047 if args.xlen == 64 else 998)
    extensions = (2 | (1024 if args.hypervisor else 0)) if args.enable else 0
    check('enable', query(1, size).contents.configure(extensions), 0)
    reference = Reference(args.reference, args.xlen)
    state = reference.state
    data = 0x81000000
    for instruction, privilege, tw, reserved, pending in itertools.product(
            (0x00d00073, 0x01d00073), (0, 1, 3), (0, 1), (False, True), (False, True)):
        reference.reset()
        state.gpr[1] = data
        state.gpr[2] = 0x5678
        reference.run([0x1820a1af])
        reference.write(data, (0x1234).to_bytes(4, 'little'))
        if reserved:
            reference.run([0x1000a1af])
        before = list(state.gpr[:32])
        retired = state.minstret[0]
        state.priv[0] = bytes([privilege])
        state.mstatus[0] |= tw << 21
        state.mip[0] = int(pending) << 1
        pc = reference.run([instruction])
        trapped = not args.enable or (instruction == 0x00d00073 and privilege != 3 and tw)
        name = f'{instruction:08x}-priv{privilege}-tw{tw}-lr{reserved}-pending{pending}'
        check(name, [state.pc[0], state.mcause[0], state.mtval[0], state.minstret[0]],
              [0x80ff0000, 2, instruction, retired] if trapped else [pc + 4, 0, 0, retired + 1])
        check(name + '-gprs', list(state.gpr[:32]), before)
        if not trapped:
            state.priv[0] = b'\x03'
            reference.run([0x1820a1af])
            check(name + '-sc', state.gpr[3], int(not reserved))
            check(name + '-memory', int.from_bytes(reference.read(data, 4), 'little'),
                  0x5678 if reserved else 0x1234)
    for instruction, bit in itertools.product((0x00d00073, 0x01d00073), (7, 15)):
        reference.reset()
        encoding = instruction | (1 << bit)
        pc = reference.run([encoding])
        check(f'reserved-{encoding:08x}', [state.mcause[0], state.mtval[0], state.mepc[0]],
              [2, encoding, pc])
    if args.hypervisor:
        for name, instruction, privilege, tw, cause in (
                ('vs-vtw-nto', 0x00d00073, 1, False, 22),
                ('vs-tw-priority', 0x00d00073, 1, True, 2),
                ('vs-vtw-sto', 0x01d00073, 1, False, 0),
                ('vu-vtw-nto', 0x00d00073, 0, False, 22),
                ('vu-tw-priority', 0x00d00073, 0, True, 2),
                ('vu-vtw-sto', 0x01d00073, 0, False, 0)):
            reference.reset()
            state.gpr[4] = 1 << 21
            reference.run([(0x600 << 20) | (4 << 15) | (1 << 12) | 0x73])
            state.mstatus[0] = ((state.mstatus[0] & ~(3 << 11)) |
                                (1 << 39) | (privilege << 11) | (int(tw) << 21))
            state.mepc[0] = 0x80000000
            reference.run([0x30200073])
            check(name + '-entered', state.priv[0][0], privilege)
            pc = reference.run([instruction])
            check(name, [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80ff0000, cause, instruction] if cause else [pc + 4, 0, 0])
    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, enabled=args.enable,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_ZAWRS xlen={args.xlen} cases={len(rows)} failures={len(failures)} enabled={args.enable}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
