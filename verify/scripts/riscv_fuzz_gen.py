#!/usr/bin/env python3
"""
Random RISC-V instruction generator for fuzz testing.

Generates self-checking assembly programs that:
1. Execute random legal RV32/RV64 IMAC instructions
2. End with a known sequence (write to tohost / ebreak) so the simulator halts
3. Are compiled and run with difftest to catch ISA implementation differences

Usage:
    python3 riscv_fuzz_gen.py --seed 42 --num 20 --length 200 --xlen 32 --outdir build/fuzz/
"""

import argparse
import os
import random
import sys

# ---------------------------------------------------------------------------
# Instruction templates
# ---------------------------------------------------------------------------

# R-type ALU instructions (RV32I base)
R_TYPE_OPS = [
    "add",
    "sub",
    "sll",
    "slt",
    "sltu",
    "xor",
    "srl",
    "sra",
    "or",
    "and",
]

# I-type ALU instructions
I_TYPE_OPS = [
    "addi",
    "slti",
    "sltiu",
    "xori",
    "ori",
    "andi",
    "slli",
    "srli",
    "srai",
]

# M extension
M_TYPE_OPS = [
    "mul",
    "mulh",
    "mulhsu",
    "mulhu",
    "div",
    "divu",
    "rem",
    "remu",
]

# Load/Store (only aligned to avoid misalignment exceptions in simple tests)
LOAD_OPS_32 = ["lw", "lh", "lhu", "lb", "lbu"]
STORE_OPS_32 = ["sw", "sh", "sb"]

# Branch ops
BRANCH_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]

# RV64-only
R_TYPE_OPS_64 = ["addw", "subw", "sllw", "srlw", "sraw"]
I_TYPE_OPS_64 = ["addiw", "slliw", "srliw", "sraiw"]
M_TYPE_OPS_64 = ["mulw", "divw", "divuw", "remw", "remuw"]
LOAD_OPS_64 = ["ld", "lwu"]
STORE_OPS_64 = ["sd"]

# Registers:
#   x0  = zero (hardwired)
#   x1  = ra  (reserved for control)
#   x2  = sp  (scratch memory pointer, don't clobber)
#   x10 = a0  (return value for ebreak, don't clobber)
USABLE_REGS = [f"x{i}" for i in range(3, 32) if i not in (10,)]
SP_REG = "x2"


def rand_reg(rng):
    return rng.choice(USABLE_REGS)


def rand_imm(rng, bits=12):
    """Random sign-extended immediate fitting in `bits` bits."""
    half = 1 << (bits - 1)
    return rng.randint(-half, half - 1)


def rand_uimm(rng, bits=5):
    return rng.randint(0, (1 << bits) - 1)


def gen_r_type(rng, ops):
    op = rng.choice(ops)
    rd, rs1, rs2 = rand_reg(rng), rand_reg(rng), rand_reg(rng)
    return f"  {op} {rd}, {rs1}, {rs2}"


def gen_i_type(rng, ops, xlen):
    op = rng.choice(ops)
    rd, rs1 = rand_reg(rng), rand_reg(rng)
    if op in ("slli", "srli", "srai", "slliw", "srliw", "sraiw"):
        shamt_bits = 6 if (xlen == 64 and op in ("slli", "srli", "srai")) else 5
        imm = rand_uimm(rng, shamt_bits)
    else:
        imm = rand_imm(rng, 12)
    return f"  {op} {rd}, {rs1}, {imm}"


def gen_load(rng, ops):
    """Generate load from scratch memory area (SP-based)."""
    op = rng.choice(ops)
    rd = rand_reg(rng)
    # Use small positive offsets aligned to access size
    if "d" in op:
        offset = rng.choice(range(0, 64, 8))
    elif "w" in op:
        offset = rng.choice(range(0, 64, 4))
    elif "h" in op:
        offset = rng.choice(range(0, 64, 2))
    else:
        offset = rng.choice(range(0, 64, 1))
    return f"  {op} {rd}, {offset}({SP_REG})"


def gen_store(rng, ops):
    """Generate store to scratch memory area (SP-based)."""
    op = rng.choice(ops)
    rs2 = rand_reg(rng)
    if "d" in op:
        offset = rng.choice(range(0, 64, 8))
    elif "w" in op:
        offset = rng.choice(range(0, 64, 4))
    elif "h" in op:
        offset = rng.choice(range(0, 64, 2))
    else:
        offset = rng.choice(range(0, 64, 1))
    return f"  {op} {rs2}, {offset}({SP_REG})"


def gen_branch(rng):
    """Generate a short forward branch (skip 1-3 instructions)."""
    op = rng.choice(BRANCH_OPS)
    rs1, rs2 = rand_reg(rng), rand_reg(rng)
    # Generate a label name: we'll resolve it later with a local label
    return op, rs1, rs2


def gen_lui_auipc(rng):
    op = rng.choice(["lui", "auipc"])
    rd = rand_reg(rng)
    imm = rng.randint(0, 0xFFFFF)  # 20-bit
    return f"  {op} {rd}, {imm}"


def generate_program(rng, length, xlen):
    """Generate one random test program as a list of assembly lines."""
    lines = []

    # Header
    lines.append("# Auto-generated RISC-V fuzz test")
    lines.append(f"# XLEN={xlen}, length={length}, seed={rng.getstate()[1][0]}")
    lines.append("")
    lines.append(".section .text")
    lines.append(".globl _start")
    lines.append("_start:")

    # Set up scratch memory pointer (SP -> _scratch)
    lines.append("  la sp, _scratch")

    # Initialize some registers with diverse values (skip x10/a0: reserved for exit)
    for i in range(3, 16):
        if i == 10:
            continue  # a0 is reserved for ebreak exit code
        val = rng.randint(-(1 << (xlen - 1)), (1 << (xlen - 1)) - 1)
        # Use 'li' pseudo-instruction (assembler handles expansion)
        lines.append(f"  li x{i}, {val}")

    # Build instruction weights
    ops_r = R_TYPE_OPS + (R_TYPE_OPS_64 if xlen == 64 else [])
    ops_i = I_TYPE_OPS + (I_TYPE_OPS_64 if xlen == 64 else [])
    ops_m = M_TYPE_OPS + (M_TYPE_OPS_64 if xlen == 64 else [])
    ops_load = LOAD_OPS_32 + (LOAD_OPS_64 if xlen == 64 else [])
    ops_store = STORE_OPS_32 + (STORE_OPS_64 if xlen == 64 else [])

    # Weighted instruction mix
    #   ALU: 45%, M-ext: 15%, Load: 15%, Store: 10%, Branch: 10%, LUI/AUIPC: 5%
    #   CSR reads removed: they can trap depending on privilege config
    categories = (
        [("r", 30)]
        + [("i", 15)]
        + [("m", 15)]
        + [("load", 15)]
        + [("store", 10)]
        + [("branch", 10)]
        + [("lui", 5)]
    )
    pool = []
    for cat, weight in categories:
        pool.extend([cat] * weight)

    branch_counter = 0
    i = 0
    while i < length:
        cat = rng.choice(pool)

        if cat == "r":
            lines.append(gen_r_type(rng, ops_r))
        elif cat == "i":
            lines.append(gen_i_type(rng, ops_i, xlen))
        elif cat == "m":
            lines.append(gen_r_type(rng, ops_m))
        elif cat == "load":
            lines.append(gen_load(rng, ops_load))
        elif cat == "store":
            lines.append(gen_store(rng, ops_store))
        elif cat == "branch":
            # Short forward branch with local labels
            op, rs1, rs2 = gen_branch(rng)
            skip = rng.randint(1, 3)
            label = f".Lbr{branch_counter}"
            branch_counter += 1
            lines.append(f"  {op} {rs1}, {rs2}, {label}")
            # Generate `skip` NOP-like instructions (simple ALU)
            for _ in range(skip):
                lines.append(gen_r_type(rng, ops_r))
                i += 1
            lines.append(f"{label}:")
        elif cat == "lui":
            lines.append(gen_lui_auipc(rng))

        i += 1

    # Termination: ensure a0=0 (GOOD TRAP) then halt via ebreak.
    # Use a fence to ensure all prior stores are visible.
    lines.append("")
    lines.append("  # --- Test complete ---")
    lines.append("  fence")
    lines.append("  li a0, 0       # exit code 0 = GOOD TRAP")
    lines.append("  ebreak")
    lines.append("  # Infinite loop as safety net if ebreak is not handled")
    lines.append("  j .            # spin forever")
    lines.append("")

    # Scratch data area
    lines.append(".section .data")
    lines.append(".balign 8")
    lines.append("_scratch:")
    lines.append("  .fill 128, 1, 0  # 128 bytes scratch area")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="RISC-V random instruction fuzz generator"
    )
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--num", type=int, default=20, help="Number of test programs")
    parser.add_argument(
        "--length", type=int, default=200, help="Instructions per program"
    )
    parser.add_argument("--xlen", type=int, choices=[32, 64], default=32, help="XLEN")
    parser.add_argument(
        "--outdir", type=str, default="build/fuzz", help="Output directory"
    )
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    rng = random.Random(args.seed)

    for i in range(args.num):
        prog = generate_program(rng, args.length, args.xlen)
        fname = os.path.join(args.outdir, f"fuzz_{i:04d}.S")
        with open(fname, "w") as f:
            f.write(prog)

    print(f"[fuzz-gen] {args.num} programs written to {args.outdir}/")
    # Also write a manifest
    manifest = os.path.join(args.outdir, "manifest.txt")
    with open(manifest, "w") as f:
        for i in range(args.num):
            f.write(f"fuzz_{i:04d}\n")
    print(f"[fuzz-gen] Manifest: {manifest}")


if __name__ == "__main__":
    main()
