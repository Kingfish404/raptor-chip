"""Check Svinval privilege rules and translation-cache invalidation."""

import argparse
import hashlib
import json
from pathlib import Path

from lib.reference import Reference


def instruction(funct7, rs1=0, rs2=0):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | 0x73


SINVAL_VMA = instruction(0b0001011, 1, 2)
SFENCE_W_INVAL = instruction(0b0001100)
SFENCE_INVAL_IR = instruction(0b0001100, rs2=1)
LOAD_DOUBLE = 0x0000B183
LOAD_WORD = 0x0000A183


def check_privilege(reference, rows):
    state = reference.state
    instructions = (
        ("sinval.vma", SINVAL_VMA),
        ("sfence.w.inval", SFENCE_W_INVAL),
        ("sfence.inval.ir", SFENCE_INVAL_IR),
    )
    for privilege in (0, 1, 3):
        for tvm in (0, 1):
            for name, opcode in instructions:
                reference.reset()
                state.priv[0] = bytes([privilege])
                state.mstatus[0] |= tvm << 20
                pc = reference.run([opcode])
                denied = privilege == 0 or (privilege == 1 and tvm and name == "sinval.vma")
                actual = [state.pc[0], state.mcause[0], state.mtval[0], state.minstret[0]]
                expected = [0x80FF0000, 2, opcode, 100] if denied else [pc + 4, 0, 0, 101]
                rows.append(dict(name=f"{name}-priv{privilege}-tvm{tvm}", actual=actual,
                                 expected=expected, passed=actual == expected))


def check_invalidation(reference, rows):
    state = reference.state
    root, middle, leaf = 0x82000000, 0x82001000, 0x82002000
    virtual, first, second = 0x41000000, 0x81000000, 0x81001000
    reference.reset()
    for table in (root, middle, leaf) if reference.xlen == 64 else (root, leaf):
        reference.write(table, bytes(4096))

    def write_pte(address, value):
        reference.write(address, value.to_bytes(reference.xlen // 8, "little"))

    def load():
        pc = reference.run([LOAD_DOUBLE if reference.xlen == 64 else LOAD_WORD])
        return [state.pc[0], state.mcause[0], state.gpr[3], state.minstret[0]], pc

    if reference.xlen == 64:
        write_pte(root + 8, (middle >> 12) << 10 | 1)
        write_pte(middle + 8 * 8, (leaf >> 12) << 10 | 1)
        state.satp[0] = (8 << 60) | (root >> 12)
    else:
        write_pte(root + ((virtual >> 22) & 0x3FF) * 4, (leaf >> 12) << 10 | 1)
        state.satp[0] = (1 << 31) | (root >> 12)
    write_pte(leaf, (first >> 12) << 10 | 0xCF)
    reference.write(first, (0x1234).to_bytes(8, "little"))
    reference.write(second, (0x5678).to_bytes(8, "little"))
    state.mstatus[0] |= (1 << 17) | (1 << 11)
    state.gpr[1] = virtual
    actual, pc = load()
    expected = [pc + 4, 0, 0x1234, 101]
    rows.append(dict(name="initial-translation", actual=actual, expected=expected,
                     passed=actual == expected))

    write_pte(leaf, (second >> 12) << 10 | 0xCF)
    actual, pc = load()
    expected = [pc + 4, 0, 0x1234, 102]
    rows.append(dict(name="stale-before-invalidation", actual=actual, expected=expected,
                     passed=actual == expected))

    reference.run([SFENCE_W_INVAL, SINVAL_VMA, SFENCE_INVAL_IR])
    actual, pc = load()
    expected = [pc + 4, 0, 0x5678, 106]
    rows.append(dict(name="remapped-after-invalidation", actual=actual, expected=expected,
                     passed=actual == expected))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=64)
    args = parser.parse_args()
    reference = Reference(args.reference, args.xlen)
    rows = []
    check_privilege(reference, rows)
    check_invalidation(reference, rows)
    failures = [row for row in rows if not row["passed"]]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        xlen=args.xlen,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows,
        failures=len(failures),
    ), indent=2) + "\n")
    for failure in failures:
        print("FAIL", failure)
    print(f"NEMU_SVINVAL cases={len(rows)} failures={len(failures)} xlen={args.xlen}")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
