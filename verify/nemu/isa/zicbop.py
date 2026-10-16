"""Check all Zicbop hint offsets and neighboring OP-IMM instructions."""

import argparse
import hashlib
import json
from pathlib import Path

from lib.reference import Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    reference = Reference(args.reference, args.xlen)
    state = reference.state
    rows = []

    def check(name, instruction, privilege, destination=None, value=None):
        reference.reset()
        state.gpr[5] = 0x90000000
        state.gpr[31] = 0x90001000
        before = list(state.gpr[:32])
        retired = state.minstret[0]
        state.priv[0] = bytes([privilege])
        pc = reference.run([instruction])
        expected = before.copy()
        if destination is not None:
            expected[destination] = value & reference.mask
        changes = [(index, state.gpr[index]) for index in range(32)
                   if state.gpr[index] != before[index]]
        expected_changes = [(index, expected[index]) for index in range(32)
                            if expected[index] != before[index]]
        actual = [state.pc[0], int.from_bytes(state.priv[0]), state.mcause[0],
                  state.mtval[0], state.minstret[0], changes]
        wanted = [pc + 4, privilege, 0, 0, retired + 1, expected_changes]
        rows.append(dict(name=name, actual=actual, expected=wanted,
                         passed=actual == wanted))

    for privilege in (0, 1, 3):
        for kind, low_immediate, funct3 in (
                ('i', 0, 6), ('r', 0, 4), ('w', 3, 6)):
            for high_immediate in range(128):
                for base_register in ((0, 5, 31) if high_immediate in (0, 1, 63, 64, 127)
                                      else (5,)):
                    instruction = ((high_immediate << 25) | (low_immediate << 20) |
                                   (base_register << 15) | (funct3 << 12) | 0x13)
                    check(f'prefetch-{kind}-hi{high_immediate}-rs{base_register}-p{privilege}',
                          instruction, privilege)
            for high_immediate in (0, 1, 64, 127):
                immediate = (high_immediate << 5) | low_immediate
                instruction = (immediate << 20) | (5 << 15) | (funct3 << 12) | (7 << 7) | 0x13
                signed_immediate = immediate if immediate < 0x800 else immediate - 0x1000
                value = ((0x90000000 ^ signed_immediate) if kind == 'r'
                         else (0x90000000 | signed_immediate))
                check(f'op-imm-neighbor-{kind}-hi{high_immediate}-p{privilege}',
                      instruction, privilege, 7, value)

    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        xlen=args.xlen,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_ZICBOP xlen={args.xlen} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
