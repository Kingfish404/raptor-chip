#!/usr/bin/env python3
"""Check RV64 satp WARL behavior for the declared platform ASID width."""

import argparse
import json
from pathlib import Path
import random

from nemu_reference import Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--asid-bits", type=int, choices=range(17), default=9)
    args = parser.parse_args()
    asid_mask = (1 << args.asid_bits) - 1
    ref = Reference(args.reference, 64)
    state = ref.state
    rows = []
    randomizer = random.Random(220064)
    values = [0, 0xffff, *(1 << i for i in range(16)),
              *(randomizer.randrange(65536) for _ in range(256))]
    for asid in values:
        ref.reset()
        value = (8 << 60) | (asid << 44) | 0xabcde
        state.gpr[1] = value
        ref.run([0x18009073, 0x18002173])  # csrw satp,x1; csrr x2,satp
        expected = (8 << 60) | ((asid & asid_mask) << 44) | 0xabcde
        rows.append(dict(asid=asid, actual=state.gpr[2], expected=expected))
    for mode in range(16):
        ref.reset()
        old = (8 << 60) | ((0x123 & asid_mask) << 44) | 0xabcde
        state.gpr[1] = old
        ref.run([0x18009073])
        value = (mode << 60) | ((0x77 & asid_mask) << 44) | 0x12345 if mode else 0
        state.gpr[1] = value
        ref.run([0x18009073, 0x18002173])
        rows.append(dict(mode=mode, actual=state.gpr[2], expected=value if mode in (0, 8) else old))
    passed = all(row["actual"] == row["expected"] for row in rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(passed=passed, asid_bits=args.asid_bits, cases=rows), indent=2) + "\n")
    print(f"{'PASS' if passed else 'FAIL'}: {len(rows)} satp ASIDLEN={args.asid_bits}/MODE/PPN WARL cases")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
