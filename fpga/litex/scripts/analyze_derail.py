#!/usr/bin/env python3
"""Analyze a dual-commit derailment ILA capture (capture_ila.tcl "derail" mode).

The capture triggers on the first committed PC==0 (a jump to null, since the
reset vector is the ROM at 0x20000000). This script locates the trigger sample
and prints the committed instruction stream leading up to it, decoding each
RISC-V instruction word so the derailing jalr/ret and the preceding dual-commit
that corrupted its source register stand out.

Usage:
    analyze_derail.py <capture.csv> [--window N]
"""
import argparse
import csv
import sys


# --- Minimal RV32 disassembly (enough to spot jalr/ret/branch/loads) --------
OPCODES = {
    0x37: "lui",
    0x17: "auipc",
    0x6F: "jal",
    0x67: "jalr",
    0x63: "branch",
    0x03: "load",
    0x23: "store",
    0x13: "op-imm",
    0x33: "op",
    0x0F: "misc-mem",
    0x73: "system",
    0x2F: "amo",
}
ABI = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
]


def reg(n):
    return ABI[n] if 0 <= n < 32 else f"x{n}"


def disasm(word):
    if word is None:
        return ""
    w = word & 0xFFFFFFFF
    if (w & 3) != 3:
        return f".c 0x{w:04x}"  # compressed; not decoded here
    op = w & 0x7F
    rd = (w >> 7) & 0x1F
    rs1 = (w >> 15) & 0x1F
    rs2 = (w >> 20) & 0x1F
    f3 = (w >> 12) & 7
    name = OPCODES.get(op, f"op{op:#04x}")
    if op == 0x67:  # jalr
        # ret == jalr x0, 0(ra); the classic derailment source.
        if rd == 0 and rs1 == 1:
            return f"ret (jalr x0,0({reg(rs1)}))"
        return f"jalr {reg(rd)},{reg(rs1)}"
    if op == 0x6F:
        return f"jal {reg(rd)}"
    if op == 0x63:
        b = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}.get(f3, "b?")
        return f"{b} {reg(rs1)},{reg(rs2)}"
    if op == 0x03:
        return f"load {reg(rd)},{reg(rs1)}"
    if op == 0x23:
        return f"store {reg(rs2)},({reg(rs1)})"
    if op in (0x13, 0x33):
        return f"{name} {reg(rd)},{reg(rs1)}" + ("," + reg(rs2) if op == 0x33 else "")
    if op in (0x37, 0x17):
        return f"{name} {reg(rd)}"
    if op == 0x73:
        return "system"
    return f"{name} rd={reg(rd)} rs1={reg(rs1)}"


def to_int(s):
    s = (s or "").strip()
    if s == "" or s.upper() in ("X", "XXXX"):
        return None
    try:
        if s.lower().startswith("0x"):
            return int(s, 16)
        # ILA CSVs usually emit hex without prefix for buses; try hex then dec.
        return int(s, 16)
    except ValueError:
        try:
            return int(s)
        except ValueError:
            return None


def find_col(fields, *needles):
    for f in fields:
        low = f.lower()
        if all(n in low for n in needles):
            return f
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--window", type=int, default=60,
                    help="rows of committed-instruction history to print before the trigger")
    args = ap.parse_args()

    with open(args.csv, newline="") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        print("empty CSV")
        return 1
    fields = rows[0].keys()

    c_sample = find_col(fields, "sample", "in", "buffer") or find_col(fields, "sample") or list(fields)[0]
    c_fire = find_col(fields, "commit_fire")
    c_pc = find_col(fields, "commit_pc") if not find_col(fields, "commit_pc_b") else \
        next((f for f in fields if "commit_pc" in f.lower() and "_b" not in f.lower()), None)
    c_pcb = find_col(fields, "commit_pc_b")
    c_inst = next((f for f in fields if "commit_inst" in f.lower() and "_b" not in f.lower()), None)
    c_instb = find_col(fields, "commit_inst_b")
    c_dual = find_col(fields, "dual_commit")
    c_flush = find_col(fields, "flush_apply") or find_col(fields, "flush_pipe")
    c_rhead = find_col(fields, "rob_head")
    c_trap = find_col(fields, "recv_trap")

    print(f"columns: sample={c_sample} fire={c_fire} pc={c_pc} pc_b={c_pcb} "
          f"inst={c_inst} inst_b={c_instb} dual={c_dual} flush={c_flush}")

    # Locate the trigger: first row where commit_fire==1 and commit_pc==0.
    trig = None
    for i, r in enumerate(rows):
        fire = to_int(r.get(c_fire)) if c_fire else None
        pc = to_int(r.get(c_pc)) if c_pc else None
        if fire == 1 and pc == 0:
            trig = i
            break
    if trig is None:
        print("!! no (commit_fire==1 && commit_pc==0) row found; dumping all commits")
        trig = len(rows) - 1

    lo = max(0, trig - args.window)
    print(f"\n=== committed-instruction stream, rows {lo}..{trig} (trigger @ {trig}) ===")
    print(f"{'row':>6} {'dual':>4} {'flsh':>4}  {'pc':>10} {'inst':>9}  disasm"
          f"   |  {'pc_b':>10} {'inst_b':>9}  disasm_b")
    last_good_pc = None
    for i in range(lo, min(len(rows), trig + 6)):
        r = rows[i]
        fire = to_int(r.get(c_fire)) if c_fire else None
        if fire != 1:
            continue
        pc = to_int(r.get(c_pc)) if c_pc else None
        inst = to_int(r.get(c_inst)) if c_inst else None
        dual = to_int(r.get(c_dual)) if c_dual else 0
        flush = to_int(r.get(c_flush)) if c_flush else 0
        pcb = to_int(r.get(c_pcb)) if c_pcb else None
        instb = to_int(r.get(c_instb)) if c_instb else None
        mark = " <== TRIGGER (PC=0)" if i == trig else ""
        if pc not in (0, None):
            last_good_pc = pc
        pcs = f"{pc:#010x}" if pc is not None else "    -     "
        insts = f"{inst:08x}" if inst is not None else "   -    "
        d_a = disasm(inst)
        if dual == 1 and pcb is not None:
            pcbs = f"{pcb:#010x}"
            instbs = f"{instb:08x}" if instb is not None else "   -    "
            d_b = disasm(instb)
        else:
            pcbs, instbs, d_b = "", "", ""
        print(f"{i:>6} {dual!s:>4} {flush!s:>4}  {pcs} {insts}  {d_a:<22}"
              f" | {pcbs:>10} {instbs:>9}  {d_b}{mark}")

    print(f"\nlast non-zero committed PC before derail: "
          f"{last_good_pc:#010x}" if last_good_pc is not None else "  (none)")
    print("Interpretation: the last committed instruction before PC=0 is the")
    print("one that jumped to null. If it is 'ret'/jalr, its source register")
    print("(ra/rs1) was corrupted -- scan upward for the dual-commit (dual=1)")
    print("whose committed rd wrote that register.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
