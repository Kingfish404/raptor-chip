"""Check RVA23 Zicond results against an independent integer oracle."""

import argparse
import itertools
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
    values = (0, 1, 1 << (args.xlen - 1), reference.mask)
    registers = (0, 1, 2, 3)
    rows = []
    for predicate, source1, source2, destination, left, right, privilege in itertools.product(
            (5, 7), (0, 1, 2), (0, 1, 2), registers, values, values, (0, 1, 3)):
        reference.reset()
        state.gpr[1] = left
        state.gpr[2] = right
        state.gpr[3] = 0x12345678
        state.priv[0] = bytes([privilege])
        before = [state.gpr[register] for register in registers]
        first = before[source1]
        second = before[source2]
        instruction = (7 << 25) | (source2 << 20) | (source1 << 15) | (
            predicate << 12) | (destination << 7) | 0x33
        pc = reference.run([instruction])
        expected = before.copy()
        if destination:
            expected[destination] = 0 if (second == 0) == (predicate == 5) else first
        actual = [state.gpr[register] for register in registers]
        passed = (actual == expected and state.pc[0] == pc + 4 and
                  state.mcause[0] == 0 and state.minstret[0] == 101)
        rows.append(dict(instruction=f'{instruction:08x}', privilege=privilege,
                         left=left, right=right, actual=actual, expected=expected,
                         passed=passed))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'xlen': args.xlen, 'results': rows}, indent=2) + '\n')
    failures = [row for row in rows if not row['passed']]
    print(f'RV{args.xlen} Zicond: {len(rows) - len(failures)}/{len(rows)} pass')
    for row in failures[:8]:
        print(f"FAIL {row['instruction']} privilege={row['privilege']} "
              f"actual={row['actual']} expected={row['expected']}")
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
