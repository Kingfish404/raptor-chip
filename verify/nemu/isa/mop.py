"""Check RVA23 Zimop, Zcmop and Zihintntl architectural behavior."""
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

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected,
                         passed=actual == expected))

    def execute(name, instruction, privilege, destination=None, length=4):
        reference.reset()
        for register in range(1, 32):
            state.gpr[register] = register * 0x10101 & reference.mask
        before = list(state.gpr[:32])
        expected = before.copy()
        if destination is not None and destination != 0:
            expected[destination] = 0
        retired = state.minstret[0]
        state.priv[0] = bytes([privilege])
        pc = reference.run([instruction])
        check(name, [state.pc[0], int.from_bytes(state.priv[0]), state.mcause[0], state.mtval[0],
                     state.minstret[0]],
              [pc + length, privilege, 0, 0, retired + 1])
        check(name + '-gpr', list(state.gpr[:32]), expected)

    for privilege in (0, 1, 3):
        for number in range(32):
            base = (0x81c04073 | ((number & 3) << 20) |
                    ((number & 12) << 24) | ((number & 16) << 26))
            for destination, source in ((0, 31), (5, 0), (31, 5)):
                instruction = base | (source << 15) | (destination << 7)
                execute(f'mop-r-{number}-rd{destination}-rs{source}-p{privilege}',
                        instruction, privilege, destination)
        for number in range(8):
            base = (0x82004073 | ((number & 3) << 26) |
                    ((number & 4) << 28))
            for destination, source1, source2 in ((0, 31, 5), (5, 0, 31),
                                                   (31, 5, 0)):
                instruction = (base | (source2 << 20) | (source1 << 15) |
                               (destination << 7))
                execute(f'mop-rr-{number}-rd{destination}-p{privilege}',
                        instruction, privilege, destination)
        for number in range(1, 16, 2):
            instruction = 0x6081 | ((number - 1) << 7)
            execute(f'c-mop-{number}-p{privilege}', instruction, privilege,
                    length=2)
        for source in range(2, 6):
            execute(f'ntl-rs{source}-p{privilege}',
                    (source << 20) | 0x33, privilege)
            execute(f'c-ntl-rs{source}-p{privilege}',
                    0x9002 | (source << 2), privilege, length=2)

    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        xlen=args.xlen,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_MOP xlen={args.xlen} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
