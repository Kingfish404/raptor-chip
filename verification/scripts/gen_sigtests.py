#!/usr/bin/env python3
"""
Generate lightweight signature-based ISA correctness tests.

These are self-contained assembly tests that:
1. Execute a specific instruction pattern
2. Store results to a known "signature" memory region
3. Compare the signature between DUT (NPC) and reference (NEMU)

This approach is similar to RISCOF but without the Python framework dependency.
"""

import argparse
import os


def gen_alu_tests(xlen):
    """Generate ALU operation tests with known inputs/outputs."""
    tests = []

    # --- R-type tests ---
    r_ops = [
        ("add", "add"),
        ("sub", "sub"),
        ("and", "and"),
        ("or", "or"),
        ("xor", "xor"),
        ("sll", "sll"),
        ("srl", "srl"),
        ("sra", "sra"),
        ("slt", "slt"),
        ("sltu", "sltu"),
    ]

    asm = []
    asm.append("# ALU R-type correctness test")
    asm.append(".section .text")
    asm.append(".globl _start")
    asm.append("_start:")
    asm.append("  la sp, _signature")
    asm.append("")

    # Test each R-type op with corner case values
    test_vals = [
        (0, 0),
        (1, 1),
        (-1, -1),
        (0x7FFFFFFF, 1),
        (0x80000000, 1),
        (0xDEADBEEF, 0xCAFEBABE),
        (1, 0),
        (0, 1),
        (-1, 0),
        (0, -1),
    ]

    sig_offset = 0
    for op_name, op_asm in r_ops:
        for a, b in test_vals:
            a_hex = a & 0xFFFFFFFF
            b_hex = b & 0xFFFFFFFF
            asm.append(f"  # {op_name} with a=0x{a_hex:08x}, b=0x{b_hex:08x}")
            asm.append(f"  li t0, 0x{a_hex:08x}")
            asm.append(f"  li t1, 0x{b_hex:08x}")
            asm.append(f"  {op_asm} t2, t0, t1")
            asm.append(f"  sw t2, {sig_offset}(sp)")
            sig_offset += 4

    asm.append("")
    asm.append("  li a0, 0")
    asm.append("  ebreak")
    asm.append("")
    asm.append(".section .data")
    asm.append(".balign 4")
    asm.append("_signature:")
    asm.append(f"  .fill {sig_offset // 4}, 4, 0")
    asm.append("")

    tests.append(("alu_r_type", "\n".join(asm)))

    # --- I-type tests ---
    i_ops = [
        ("addi", "addi"),
        ("slti", "slti"),
        ("sltiu", "sltiu"),
        ("xori", "xori"),
        ("ori", "ori"),
        ("andi", "andi"),
    ]

    asm2 = []
    asm2.append("# ALU I-type correctness test")
    asm2.append(".section .text")
    asm2.append(".globl _start")
    asm2.append("_start:")
    asm2.append("  la sp, _signature")
    asm2.append("")

    sig_offset = 0
    for op_name, op_asm in i_ops:
        for a, _ in test_vals:
            a_hex = a & 0xFFFFFFFF
            for imm in [0, 1, -1, 0x7FF, -0x800, 42, -42]:
                asm2.append(f"  li t0, 0x{a_hex:08x}")
                asm2.append(f"  {op_asm} t2, t0, {imm}")
                asm2.append(f"  sw t2, {sig_offset}(sp)")
                sig_offset += 4

    asm2.append("")
    asm2.append("  li a0, 0")
    asm2.append("  ebreak")
    asm2.append("")
    asm2.append(".section .data")
    asm2.append(".balign 4")
    asm2.append("_signature:")
    asm2.append(f"  .fill {sig_offset // 4}, 4, 0")
    asm2.append("")

    tests.append(("alu_i_type", "\n".join(asm2)))

    return tests


def gen_mul_div_tests(xlen):
    """Generate M-extension tests."""
    m_ops = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]

    test_vals = [
        (0, 0),
        (1, 1),
        (-1, -1),
        (0x7FFFFFFF, 2),
        (0x80000000, 2),
        (0xDEADBEEF, 0xCAFEBABE),
        (-1, 1),
        (1, -1),
        (0x80000000, -1),
        (7, 3),
        (-7, 3),
        (7, -3),
        (-7, -3),  # div/rem corner cases
        (0, 1),
        (1, 0),
        (-1, 0),  # div by zero
    ]

    asm = []
    asm.append("# M-extension correctness test")
    asm.append(".section .text")
    asm.append(".globl _start")
    asm.append("_start:")
    asm.append("  la sp, _signature")
    asm.append("")

    sig_offset = 0
    for op in m_ops:
        for a, b in test_vals:
            a_hex = a & 0xFFFFFFFF
            b_hex = b & 0xFFFFFFFF
            asm.append(f"  # {op} 0x{a_hex:08x}, 0x{b_hex:08x}")
            asm.append(f"  li t0, 0x{a_hex:08x}")
            asm.append(f"  li t1, 0x{b_hex:08x}")
            asm.append(f"  {op} t2, t0, t1")
            asm.append(f"  sw t2, {sig_offset}(sp)")
            sig_offset += 4

    asm.append("")
    asm.append("  li a0, 0")
    asm.append("  ebreak")
    asm.append("")
    asm.append(".section .data")
    asm.append(".balign 4")
    asm.append("_signature:")
    asm.append(f"  .fill {sig_offset // 4}, 4, 0")
    asm.append("")

    return [("mul_div", "\n".join(asm))]


def gen_branch_tests(xlen):
    """Generate branch instruction tests."""
    asm = []
    asm.append("# Branch correctness test")
    asm.append(".section .text")
    asm.append(".globl _start")
    asm.append("_start:")
    asm.append("  la sp, _signature")
    asm.append("")

    sig_offset = 0
    branches = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
    pairs = [
        (0, 0),
        (1, 0),
        (0, 1),
        (-1, 0),
        (0, -1),
        (-1, -1),
        (0x7FFFFFFF, 0x80000000),
        (0x80000000, 0x7FFFFFFF),
    ]

    for br in branches:
        for a, b in pairs:
            a_hex = a & 0xFFFFFFFF
            b_hex = b & 0xFFFFFFFF
            asm.append(f"  li t0, 0x{a_hex:08x}")
            asm.append(f"  li t1, 0x{b_hex:08x}")
            asm.append(f"  li t2, 0          # not taken")
            asm.append(f"  {br} t0, t1, .Ltaken_{br}_{sig_offset}")
            asm.append(f"  j .Ldone_{br}_{sig_offset}")
            asm.append(f".Ltaken_{br}_{sig_offset}:")
            asm.append(f"  li t2, 1          # taken")
            asm.append(f".Ldone_{br}_{sig_offset}:")
            asm.append(f"  sw t2, {sig_offset}(sp)")
            sig_offset += 4

    asm.append("")
    asm.append("  li a0, 0")
    asm.append("  ebreak")
    asm.append("")
    asm.append(".section .data")
    asm.append(".balign 4")
    asm.append("_signature:")
    asm.append(f"  .fill {sig_offset // 4}, 4, 0")
    asm.append("")

    return [("branch", "\n".join(asm))]


def gen_mem_tests(xlen):
    """Generate load/store tests with various sizes and alignments."""
    asm = []
    asm.append("# Memory load/store correctness test")
    asm.append(".section .text")
    asm.append(".globl _start")
    asm.append("_start:")
    asm.append("  la sp, _signature")
    asm.append("  la s0, _scratch")
    asm.append("")

    sig_offset = 0

    # Store then load, check round-trip
    # SW/LW
    patterns = [0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0x00000000, 0xFFFFFFFF]
    for pat in patterns:
        asm.append(f"  li t0, 0x{pat:08x}")
        asm.append(f"  sw t0, 0(s0)")
        asm.append(f"  lw t1, 0(s0)")
        asm.append(f"  sw t1, {sig_offset}(sp)")
        sig_offset += 4

    # SH/LH/LHU at different offsets
    for offset in [0, 2]:
        asm.append(f"  li t0, 0x{0xBEEF:04x}")
        asm.append(f"  sh t0, {offset}(s0)")
        asm.append(f"  lh t1, {offset}(s0)")
        asm.append(f"  sw t1, {sig_offset}(sp)")
        sig_offset += 4
        asm.append(f"  lhu t1, {offset}(s0)")
        asm.append(f"  sw t1, {sig_offset}(sp)")
        sig_offset += 4

    # SB/LB/LBU
    for offset in [0, 1, 2, 3]:
        asm.append(f"  li t0, 0x{0xFF:02x}")
        asm.append(f"  sb t0, {offset}(s0)")
        asm.append(f"  lb t1, {offset}(s0)")
        asm.append(f"  sw t1, {sig_offset}(sp)")
        sig_offset += 4
        asm.append(f"  lbu t1, {offset}(s0)")
        asm.append(f"  sw t1, {sig_offset}(sp)")
        sig_offset += 4

    asm.append("")
    asm.append("  li a0, 0")
    asm.append("  ebreak")
    asm.append("")
    asm.append(".section .data")
    asm.append(".balign 8")
    asm.append("_signature:")
    asm.append(f"  .fill {sig_offset // 4}, 4, 0")
    asm.append("_scratch:")
    asm.append("  .fill 32, 1, 0")
    asm.append("")

    return [("mem_ops", "\n".join(asm))]


def main():
    parser = argparse.ArgumentParser(description="Generate signature-based ISA tests")
    parser.add_argument("--xlen", type=int, choices=[32, 64], default=32)
    parser.add_argument("--outdir", type=str, default="build/sigtest")
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    all_tests = []
    all_tests.extend(gen_alu_tests(args.xlen))
    all_tests.extend(gen_mul_div_tests(args.xlen))
    all_tests.extend(gen_branch_tests(args.xlen))
    all_tests.extend(gen_mem_tests(args.xlen))

    manifest = []
    for name, src in all_tests:
        fname = os.path.join(args.outdir, f"{name}.S")
        with open(fname, "w") as f:
            f.write(src)
        manifest.append(name)

    mf = os.path.join(args.outdir, "manifest.txt")
    with open(mf, "w") as f:
        for name in manifest:
            f.write(name + "\n")

    print(f"[sigtest-gen] {len(all_tests)} tests written to {args.outdir}/")


if __name__ == "__main__":
    main()
