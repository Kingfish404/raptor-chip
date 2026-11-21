#!/usr/bin/env python3
"""
Random RISC-V instruction generator for differential fuzz testing.

Supports three profiles:
- `basic`:      RV32/RV64 IMAC random instructions
- `sota`:       Adds DRVFuzz boundary dictionary, ProcessorFuzz safe M-mode
                CSR transitions, MorFuzz SQ forwarding hazards & BPU loops
- `industrial`: Full Cascade/MorFuzz/ProcessorFuzz-grade mix adding IEEE-754
                F+D floating-point (arithmetic, FMA, div/sqrt, fcvt, dynamic
                frm), A-extension atomics (AMO + LR/SC), jal/jalr call/return
                (RAS/BTB stress), and recoverable M-mode ecall trap-and-return
                exception handlers.
"""

import argparse
import os
import random

R_TYPE_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_TYPE_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai"]
M_TYPE_OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
LOAD_OPS_32 = ["lw", "lh", "lhu", "lb", "lbu"]
STORE_OPS_32 = ["sw", "sh", "sb"]
BRANCH_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]

R_TYPE_OPS_64 = ["addw", "subw", "sllw", "srlw", "sraw"]
I_TYPE_OPS_64 = ["addiw", "slliw", "srliw", "sraiw"]
M_TYPE_OPS_64 = ["mulw", "divw", "divuw", "remw", "remuw"]
LOAD_OPS_64 = ["ld", "lwu"]
STORE_OPS_64 = ["sd"]

AMO_OPS_32 = [
    "amoswap.w",
    "amoadd.w",
    "amoxor.w",
    "amoand.w",
    "amoor.w",
    "amomin.w",
    "amomax.w",
    "amominu.w",
    "amomaxu.w",
]
AMO_OPS_64 = [op.replace(".w", ".d") for op in AMO_OPS_32]

FP_BIN_S = ["fadd.s", "fsub.s", "fmul.s", "fdiv.s", "fmin.s", "fmax.s", "fsgnj.s", "fsgnjn.s", "fsgnjx.s"]
FP_BIN_D = [op.replace(".s", ".d") for op in FP_BIN_S]
FP_FMA_S = ["fmadd.s", "fmsub.s", "fnmadd.s", "fnmsub.s"]
FP_FMA_D = [op.replace(".s", ".d") for op in FP_FMA_S]
FP_CMP_S = ["feq.s", "flt.s", "fle.s"]
FP_CMP_D = [op.replace(".s", ".d") for op in FP_CMP_S]
FP_REGS = [f"f{i}" for i in range(0, 16)]

SAFE_CSRS = [
    "mscratch",
    "sscratch",
    "mepc",
    "sepc",
    "mtval",
    "stval",
    "mcause",
    "scause",
    "mcounteren",
    "scounteren",
]
CSR_OPS = ["csrrw", "csrrs", "csrrc"]
CSRI_OPS = ["csrrwi", "csrrsi", "csrrci"]

RVV_VV_OPS = [
    "vadd.vv",
    "vsub.vv",
    "vxor.vv",
    "vand.vv",
    "vor.vv",
    "vsll.vv",
    "vsrl.vv",
    "vsra.vv",
    "vmin.vv",
    "vminu.vv",
    "vmax.vv",
    "vmaxu.vv",
    "vmul.vv",
    "vmulh.vv",
    "vmulhu.vv",
]
RVV_VX_OPS = [
    "vadd.vx",
    "vsub.vx",
    "vrsub.vx",
    "vxor.vx",
    "vand.vx",
    "vor.vx",
    "vsll.vx",
    "vsrl.vx",
    "vsra.vx",
    "vmul.vx",
]
RVV_VI_OPS = ["vadd.vi", "vrsub.vi", "vxor.vi", "vand.vi", "vor.vi", "vsll.vi", "vsrl.vi", "vsra.vi"]
RVV_RED_OPS = ["vredsum.vs", "vredand.vs", "vredor.vs", "vredxor.vs", "vredmin.vs", "vredmax.vs"]

# Registers:
#   x0  = zero
#   x1  = ra   (control / loop counter / jalr return)
#   x2  = sp   (scalar scratch pointer)
#   x10 = a0   (exit code for ebreak)
#   x11 = a1   (vector scratch pointer when --rvv)
#   x31 = t6   (reserved for trap handler scratch when --traps)
USABLE_REGS_BASE = [f"x{i}" for i in range(3, 31) if i not in (10,)]
USABLE_REGS_RVV = [f"x{i}" for i in range(3, 31) if i not in (10, 11)]
SP_REG = "x2"
VSP_REG = "x11"


def boundary_values(xlen):
    """DRVFuzz-style data-sensitive boundary dictionary for XLEN."""
    if xlen == 32:
        vals = [
            0, 1, -1, 2, -2, 3, 7, 8, 15, 16, 31, 32,
            0x7FFF, -0x8000, 0xFFFF, 0x7FFFFFFF, -0x80000000,
            0x55555555, -0x55555556, 0x00FF00FF, 0xFF00FF00 - (1 << 32),
        ]
        for bit in (0, 1, 7, 8, 15, 16, 23, 24, 30):
            vals.append(1 << bit)
            vals.append(~(1 << bit))
        return vals
    vals = [
        0, 1, -1, 2, -2, 7, 8, 15, 16, 31, 32, 63, 64,
        0x7FFFFFFF, -0x80000000, 0xFFFFFFFF, 0x100000000,
        (1 << 63) - 1, -(1 << 63), 0x5555555555555555, -0x5555555555555556,
        0x0000000080000000, 0x000000004FFFFFFE,
    ]
    for bit in (0, 1, 15, 31, 32, 47, 48, 62):
        vals.append(1 << bit)
        vals.append(~(1 << bit))
    return vals


def rand_reg(rng, regs):
    return rng.choice(regs)


def rand_imm(rng, bits=12, boundary=False):
    half = 1 << (bits - 1)
    if boundary and rng.random() < 0.35:
        return rng.choice([-half, -half + 1, -2, -1, 0, 1, 2, half - 2, half - 1])
    return rng.randint(-half, half - 1)


def rand_uimm(rng, bits=5, boundary=False):
    hi = (1 << bits) - 1
    if boundary and rng.random() < 0.35:
        return rng.choice([0, 1, 2, hi - 1, hi])
    return rng.randint(0, hi)


def gen_r_type(rng, ops, regs):
    op = rng.choice(ops)
    return f"  {op} {rand_reg(rng, regs)}, {rand_reg(rng, regs)}, {rand_reg(rng, regs)}"


def gen_i_type(rng, ops, xlen, regs, boundary=False):
    op = rng.choice(ops)
    rd, rs1 = rand_reg(rng, regs), rand_reg(rng, regs)
    if op in ("slli", "srli", "srai", "slliw", "srliw", "sraiw"):
        shamt_bits = 6 if (xlen == 64 and op in ("slli", "srli", "srai")) else 5
        imm = rand_uimm(rng, shamt_bits, boundary=boundary)
    else:
        imm = rand_imm(rng, 12, boundary=boundary)
    return f"  {op} {rd}, {rs1}, {imm}"


def _aligned_offset(rng, op, max_bytes=64):
    if "d" in op:
        return rng.choice(range(0, max_bytes, 8))
    if "w" in op:
        return rng.choice(range(0, max_bytes, 4))
    if "h" in op:
        return rng.choice(range(0, max_bytes, 2))
    return rng.choice(range(0, max_bytes, 1))


def gen_load(rng, ops, regs):
    op = rng.choice(ops)
    return f"  {op} {rand_reg(rng, regs)}, {_aligned_offset(rng, op)}({SP_REG})"


def gen_store(rng, ops, regs):
    op = rng.choice(ops)
    return f"  {op} {rand_reg(rng, regs)}, {_aligned_offset(rng, op)}({SP_REG})"


def gen_store_load_hazard(rng, ops_store, ops_load, regs):
    base_off = rng.choice(range(0, 56, 8))
    s_op = rng.choice(ops_store)
    l_op = rng.choice(ops_load)
    rs, rd = rand_reg(rng, regs), rand_reg(rng, regs)
    sub_off = base_off
    if "b" in l_op:
        sub_off = base_off + rng.randint(0, 7)
    elif "h" in l_op:
        sub_off = base_off + rng.choice([0, 2, 4, 6])
    elif "w" in l_op:
        sub_off = base_off + rng.choice([0, 4])
    return [f"  {s_op} {rs}, {base_off}({SP_REG})", f"  {l_op} {rd}, {sub_off}({SP_REG})"]


def gen_atomic_op(rng, xlen, regs):
    ops = AMO_OPS_32 + (AMO_OPS_64 if xlen == 64 else [])
    addr_reg = rand_reg(rng, regs)
    off = rng.choice(range(64, 120, 8))
    if rng.random() < 0.7:
        op = rng.choice(ops)
        aqrl = rng.choice(["", ".aq", ".rl", ".aqrl"])
        rd, rs2 = rand_reg(rng, regs), rand_reg(rng, regs)
        return [
            f"  addi {addr_reg}, {SP_REG}, {off}",
            f"  {op}{aqrl} {rd}, {rs2}, ({addr_reg})",
        ]
    suf = "d" if (xlen == 64 and rng.random() < 0.5) else "w"
    rd1, rd2, rs2 = rand_reg(rng, regs), rand_reg(rng, regs), rand_reg(rng, regs)
    return [
        f"  addi {addr_reg}, {SP_REG}, {off}",
        f"  lr.{suf} {rd1}, ({addr_reg})",
        f"  sc.{suf} {rd2}, {rs2}, ({addr_reg})",
    ]


def gen_fp_block(rng, xlen, regs):
    """Generate IEEE-754 F+D instructions with rounding mode & int/fp conversions."""
    seq = []
    if rng.random() < 0.25:
        frm = rng.randint(0, 4)
        seq.append(f"  fsrmi x0, {frm}")
    kind = rng.choice(["bin_s", "bin_d", "fma_s", "fma_d", "sqrt", "cmp", "cvt", "fload_fstore"])
    fd, fs1, fs2, fs3 = (rng.choice(FP_REGS) for _ in range(4))
    rd, rs1 = rand_reg(rng, regs), rand_reg(rng, regs)
    if kind == "bin_s":
        seq.append(f"  {rng.choice(FP_BIN_S)} {fd}, {fs1}, {fs2}")
    elif kind == "bin_d":
        seq.append(f"  {rng.choice(FP_BIN_D)} {fd}, {fs1}, {fs2}")
    elif kind == "fma_s":
        seq.append(f"  {rng.choice(FP_FMA_S)} {fd}, {fs1}, {fs2}, {fs3}")
    elif kind == "fma_d":
        seq.append(f"  {rng.choice(FP_FMA_D)} {fd}, {fs1}, {fs2}, {fs3}")
    elif kind == "sqrt":
        op = rng.choice(["fsqrt.s", "fsqrt.d"])
        seq.append(f"  {op} {fd}, {fs1}")
    elif kind == "cmp":
        op = rng.choice(FP_CMP_S + FP_CMP_D)
        seq.append(f"  {op} {rd}, {fs1}, {fs2}")
    elif kind == "cvt":
        cvt_ops = [
            f"fcvt.s.w {fd}, {rs1}",
            f"fcvt.d.w {fd}, {rs1}",
            f"fcvt.w.s {rd}, {fs1}, rtz",
            f"fcvt.w.d {rd}, {fs1}, rtz",
            f"fcvt.s.d {fd}, {fs1}",
            f"fcvt.d.s {fd}, {fs1}",
            f"fclass.s {rd}, {fs1}",
            f"fclass.d {rd}, {fs1}",
        ]
        if xlen == 64:
            cvt_ops += [f"fcvt.d.l {fd}, {rs1}", f"fcvt.l.d {rd}, {fs1}, rtz"]
        seq.append("  " + rng.choice(cvt_ops))
    else:
        off = rng.choice(range(0, 64, 8))
        if rng.random() < 0.5:
            seq.append(f"  {rng.choice(['fsw', 'fsd'])} {fs1}, {off}({SP_REG})")
        else:
            seq.append(f"  {rng.choice(['flw', 'fld'])} {fd}, {off}({SP_REG})")
    return seq


def gen_csr_transition(rng, regs):
    csr = rng.choice(SAFE_CSRS)
    rd = rand_reg(rng, regs)
    if rng.random() < 0.5:
        return [f"  {rng.choice(CSR_OPS)} {rd}, {csr}, {rand_reg(rng, regs)}"]
    return [f"  {rng.choice(CSRI_OPS)} {rd}, {csr}, {rng.randint(0, 31)}"]


def gen_rvv_block(rng, regs, xlen):
    sew_choices = ["e8", "e16", "e32"] + (["e64"] if xlen == 64 else [])
    sew = rng.choice(sew_choices)
    lmul = rng.choice(["m1", "m2"])
    tail = rng.choice(["ta", "tu"])
    mask = rng.choice(["ma", "mu"])
    avl = rng.choice([1, 2, 3, 4, 7, 8, 16])
    rd_vl = rand_reg(rng, regs)
    step = 2 if lmul == "m2" else 1
    vregs = [f"v{i}" for i in range(0, 32, step)]
    seq = [f"  vsetivli {rd_vl}, {avl}, {sew}, {lmul}, {tail}, {mask}"]
    for _ in range(rng.randint(3, 5)):
        kind = rng.choice(["vv", "vx", "vi", "red", "vload", "vstore"])
        vd, vs2, vs1 = rng.choice(vregs), rng.choice(vregs), rng.choice(vregs)
        if kind == "vv":
            seq.append(f"  {rng.choice(RVV_VV_OPS)} {vd}, {vs2}, {vs1}")
        elif kind == "vx":
            seq.append(f"  {rng.choice(RVV_VX_OPS)} {vd}, {vs2}, {rand_reg(rng, regs)}")
        elif kind == "vi":
            op = rng.choice(RVV_VI_OPS)
            signed_vi = ("vadd.vi", "vrsub.vi", "vxor.vi", "vand.vi", "vor.vi")
            imm = rng.randint(-16, 15) if op in signed_vi else rng.randint(0, 31)
            seq.append(f"  {op} {vd}, {vs2}, {imm}")
        elif kind == "red" and lmul == "m1":
            seq.append(f"  {rng.choice(RVV_RED_OPS)} {vd}, {vs2}, {vs1}")
        elif kind == "vload":
            seq.append(f"  vle{sew[1:]}.v {vd}, ({VSP_REG})")
        else:
            seq.append(f"  vse{sew[1:]}.v {vd}, ({VSP_REG})")
    return seq


def gen_branch(rng, regs):
    return rng.choice(BRANCH_OPS), rand_reg(rng, regs), rand_reg(rng, regs)


def gen_lui_auipc(rng, regs):
    return f"  {rng.choice(['lui', 'auipc'])} {rand_reg(rng, regs)}, {rng.randint(0, 0xFFFFF)}"


def generate_program(
    rng,
    length,
    xlen,
    boundary_dict=False,
    csr_fuzz=False,
    enable_rvv=False,
    morph=False,
    enable_fp=False,
    enable_amo=False,
    enable_traps=False,
):
    """Generate one random test program as assembly text."""
    lines = []
    regs = USABLE_REGS_RVV if enable_rvv else USABLE_REGS_BASE
    bvals = boundary_values(xlen) if boundary_dict else []

    lines.append("# Auto-generated RISC-V fuzz test")
    lines.append(
        f"# XLEN={xlen}, length={length}, boundary={boundary_dict}, "
        f"csr={csr_fuzz}, rvv={enable_rvv}, morph={morph}, "
        f"fp={enable_fp}, amo={enable_amo}, traps={enable_traps}"
    )
    lines.append("")
    lines.append(".section .text")
    lines.append(".globl _start")
    lines.append("_start:")
    lines.append("  la sp, _scratch")

    if enable_traps:
        lines.append("  la t6, _fuzz_trap_handler")
        lines.append("  csrw mtvec, t6")

    if enable_fp:
        # Enable mstatus.FS = Initial (bits [14:13] = 01 -> 0x2000)
        lines.append("  li t6, 0x2000")
        lines.append("  csrs mstatus, t6")
        lines.append("  csrw fcsr, zero")
        lines.append("  la t6, _fscratch")
        for fi in range(16):
            lines.append(f"  fld f{fi}, {fi * 8}(t6)")

    if enable_rvv:
        lines.append("  li t6, 0x200")
        lines.append("  csrs mstatus, t6")
        lines.append(f"  la {VSP_REG}, _vscratch")
        lines.append("  vsetivli x0, 4, e32, m1, ta, ma")
        for vr in range(0, 32, 4):
            lines.append(f"  vle32.v v{vr}, ({VSP_REG})")

    for i in range(3, 16):
        if i == 10 or (enable_rvv and i == 11):
            continue
        if boundary_dict and rng.random() < 0.5:
            val = rng.choice(bvals)
        else:
            val = rng.randint(-(1 << (xlen - 1)), (1 << (xlen - 1)) - 1)
        lines.append(f"  li x{i}, {val}")

    ops_r = R_TYPE_OPS + (R_TYPE_OPS_64 if xlen == 64 else [])
    ops_i = I_TYPE_OPS + (I_TYPE_OPS_64 if xlen == 64 else [])
    ops_m = M_TYPE_OPS + (M_TYPE_OPS_64 if xlen == 64 else [])
    ops_load = LOAD_OPS_32 + (LOAD_OPS_64 if xlen == 64 else [])
    ops_store = STORE_OPS_32 + (STORE_OPS_64 if xlen == 64 else [])

    categories = [
        ("r", 22),
        ("i", 12),
        ("m", 12),
        ("load", 10),
        ("store", 8),
        ("branch", 8),
        ("lui", 4),
    ]
    if morph:
        categories.extend([("sq_hazard", 8), ("loop", 3), ("call_ret", 3)])
    if csr_fuzz:
        categories.append(("csr", 6))
    if enable_amo:
        categories.append(("amo", 8))
    if enable_fp:
        categories.append(("fp", 12))
    if enable_traps:
        categories.append(("trap_ecall", 3))
    if enable_rvv:
        categories.append(("rvv", 12))

    pool = []
    for cat, weight in categories:
        pool.extend([cat] * weight)

    branch_counter = 0
    loop_counter = 0
    call_counter = 0
    i = 0
    while i < length:
        cat = rng.choice(pool)
        if cat == "r":
            lines.append(gen_r_type(rng, ops_r, regs))
        elif cat == "i":
            lines.append(gen_i_type(rng, ops_i, xlen, regs, boundary=boundary_dict))
        elif cat == "m":
            lines.append(gen_r_type(rng, ops_m, regs))
        elif cat == "load":
            lines.append(gen_load(rng, ops_load, regs))
        elif cat == "store":
            lines.append(gen_store(rng, ops_store, regs))
        elif cat == "sq_hazard":
            seq = gen_store_load_hazard(rng, ops_store, ops_load, regs)
            lines.extend(seq)
            i += len(seq) - 1
        elif cat == "amo":
            seq = gen_atomic_op(rng, xlen, regs)
            lines.extend(seq)
            i += len(seq) - 1
        elif cat == "fp":
            seq = gen_fp_block(rng, xlen, regs)
            lines.extend(seq)
            i += len(seq) - 1
        elif cat == "csr":
            seq = gen_csr_transition(rng, regs)
            lines.extend(seq)
            i += len(seq) - 1
        elif cat == "trap_ecall":
            lines.append("  ecall")
        elif cat == "rvv":
            seq = gen_rvv_block(rng, regs, xlen)
            lines.extend(seq)
            i += len(seq) - 1
        elif cat == "call_ret":
            # Forward call + return to stress RAS and indirect jump prediction
            lbl_fn = f".Lfn{call_counter}"
            lbl_after = f".Lafter_fn{call_counter}"
            call_counter += 1
            lines.append(f"  jal ra, {lbl_fn}")
            lines.append(f"  j {lbl_after}")
            lines.append(f"{lbl_fn}:")
            lines.append(gen_r_type(rng, ops_r, regs))
            lines.append("  jalr x0, ra, 0")
            lines.append(f"{lbl_after}:")
            i += 3
        elif cat == "loop":
            iters = rng.randint(2, 5)
            lbl = f".Llp{loop_counter}"
            loop_counter += 1
            lines.append(f"  li ra, {iters}")
            lines.append(f"{lbl}:")
            for _ in range(rng.randint(2, 4)):
                lines.append(gen_r_type(rng, ops_r, regs))
                i += 1
            lines.append("  addi ra, ra, -1")
            lines.append(f"  bne ra, zero, {lbl}")
            i += 2
        elif cat == "branch":
            op, rs1, rs2 = gen_branch(rng, regs)
            skip = rng.randint(1, 3)
            label = f".Lbr{branch_counter}"
            branch_counter += 1
            lines.append(f"  {op} {rs1}, {rs2}, {label}")
            for _ in range(skip):
                lines.append(gen_r_type(rng, ops_r, regs))
                i += 1
            lines.append(f"{label}:")
        elif cat == "lui":
            lines.append(gen_lui_auipc(rng, regs))
        i += 1

    lines.extend(
        [
            "",
            "  # --- Test complete ---",
            "  fence rw, rw",
            "  li a0, 0",
            "  ebreak",
            "  j .",
            "",
        ]
    )

    if enable_traps:
        lines.extend(
            [
                ".balign 4",
                "_fuzz_trap_handler:",
                "  csrr t6, mepc",
                "  addi t6, t6, 4",
                "  csrw mepc, t6",
                "  mret",
                "",
            ]
        )

    lines.extend([".section .data", ".balign 16", "_scratch:", "  .fill 128, 1, 0"])
    if enable_fp:
        # Diverse IEEE-754 doubles: +0, -0, +1.0, -1.0, 1.5, -2.5, subnormal,
        # inf, -inf, qNaN, sNaN, boxed float32 1.0, boxed float32 -0.0, huge, tiny
        fp_vals = [
            "0x0000000000000000", "0x8000000000000000", "0x3ff0000000000000",
            "0xbff0000000000000", "0x3ff8000000000000", "0xc004000000000000",
            "0x0000000000000001", "0x7ff0000000000000", "0xfff0000000000000",
            "0x7ff8000000000000", "0x7ff0000000000001", "0xffffffff3f800000",
            "0xffffffff80000000", "0xffffffff7f800000", "0x7fefffffffffffff",
            "0x0010000000000000",
        ]
        lines.append(".balign 16")
        lines.append("_fscratch:")
        for v in fp_vals:
            lines.append(f"  .dword {v}")
    if enable_rvv:
        lines.extend([".balign 32", "_vscratch:", "  .fill 256, 1, 0x5a"])
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="RISC-V random instruction fuzz generator")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--num", type=int, default=20)
    parser.add_argument("--length", type=int, default=200)
    parser.add_argument("--xlen", type=int, choices=[32, 64], default=32)
    parser.add_argument("--outdir", type=str, default="build/fuzz")
    parser.add_argument(
        "--profile",
        choices=["basic", "sota", "industrial"],
        default="basic",
        help="basic: IMAC; sota: +boundary/CSR/morph; industrial: +F+D/AMO/RAS/ecall traps",
    )
    parser.add_argument("--boundary-dict", action="store_true")
    parser.add_argument("--csr-fuzz", action="store_true")
    parser.add_argument("--rvv", action="store_true")
    parser.add_argument("--morph", action="store_true")
    parser.add_argument("--fp", action="store_true")
    parser.add_argument("--amo", action="store_true")
    parser.add_argument("--traps", action="store_true")
    args = parser.parse_args()

    is_sota = args.profile in ("sota", "industrial")
    is_ind = args.profile == "industrial"
    boundary = args.boundary_dict or is_sota
    csr_fuzz = args.csr_fuzz or is_sota
    morph = args.morph or is_sota
    enable_fp = args.fp or is_ind
    enable_amo = args.amo or is_ind
    enable_traps = args.traps or is_ind

    os.makedirs(args.outdir, exist_ok=True)
    rng = random.Random(args.seed)
    for i in range(args.num):
        prog = generate_program(
            rng,
            args.length,
            args.xlen,
            boundary_dict=boundary,
            csr_fuzz=csr_fuzz,
            enable_rvv=args.rvv,
            morph=morph,
            enable_fp=enable_fp,
            enable_amo=enable_amo,
            enable_traps=enable_traps,
        )
        with open(os.path.join(args.outdir, f"fuzz_{i:04d}.S"), "w") as f:
            f.write(prog)

    print(
        f"[fuzz-gen] {args.num} programs written to {args.outdir}/ "
        f"(profile={args.profile}, fp={enable_fp}, amo={enable_amo}, "
        f"traps={enable_traps}, rvv={args.rvv})"
    )
    manifest = os.path.join(args.outdir, "manifest.txt")
    with open(manifest, "w") as f:
        for i in range(args.num):
            f.write(f"fuzz_{i:04d}\n")
    print(f"[fuzz-gen] Manifest: {manifest}")


if __name__ == "__main__":
    main()
