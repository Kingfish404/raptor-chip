#!/usr/bin/env python3
"""
Constrained-random RVV 1.0 and Hypervisor (H-extension) fuzz generator.

Generates self-checking bare-metal RV64 assembly programs designed to stress:
1. `--mode rvv`: Dynamic vsetvli/vsetivli across SEW (8/16/32/64) x LMUL
   (m1/m2/m4) x ta/tu x ma/mu, masked ops (v0.t), multiply-accumulate,
   saturating fixed-point, slides/gathers, reductions, widening, and
   unit-stride / strided / fault-only-first vector loads & stores.
2. `--mode hypervisor`: M -> HS -> VS -> HS -> M privilege transitions,
   randomized H/VS CSR mutations, guest VS-mode scalar + RVV execution,
   hypercall (`ecall`) trap-and-emulate loops, `hfence.vvma`/`hfence.gvma`,
   and `hlv.d`/`hsv.d` hypervisor memory accesses.

All generated programs terminate cleanly via `fence; li a0, 0; ebreak` for
NEMU / Spike lockstep differential verification.
"""

import argparse
import os
import random
from pathlib import Path
from typing import List

SCALAR_REGS = [f"x{i}" for i in range(5, 10)] + [f"x{i}" for i in range(12, 18)]

RVV_ALU_VV = [
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
    "vsadd.vv",
    "vsaddu.vv",
    "vssub.vv",
    "vssubu.vv",
]

RVV_MAC_VV = ["vmacc.vv", "vnmsac.vv", "vmadd.vv", "vnmsub.vv"]

RVV_ALU_VX = [
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
    "vsadd.vx",
]

RVV_CMP_VV = ["vmseq.vv", "vmsne.vv", "vmslt.vv", "vmsltu.vv", "vmsle.vv"]
RVV_RED_VS = [
    "vredsum.vs",
    "vredand.vs",
    "vredor.vs",
    "vredxor.vs",
    "vredmin.vs",
    "vredmax.vs",
]
RVV_FP_VV = ["vfadd.vv", "vfsub.vv", "vfmul.vv", "vfsgnj.vv", "vfsgnjn.vv", "vfsgnjx.vv"]
RVV_MASK_MM = ["vmand.mm", "vmnand.mm", "vmor.mm", "vmxor.mm", "vmxnor.mm"]

# Raw 32-bit encodings for H-extension instructions so older binutils compile
# them without needing `-march=..._h`.
ENC_HFENCE_VVMA_ZERO = ".word 0x22000073  # hfence.vvma zero, zero"
ENC_HFENCE_GVMA_ZERO = ".word 0x62000073  # hfence.gvma zero, zero"
# hlv.d t1 (x6), 0(t2=x7): funct7=0110110, rs2=00000, rs1=00111, f3=100, rd=00110, op=1110011
ENC_HLV_D_T1_T2 = ".word 0x6c03c373  # hlv.d t1, (t2)"
# hsv.d t1 (x6), 0(t2=x7): funct7=0110111, rs2=00110, rs1=00111, f3=100, rd=00000, op=1110011
ENC_HSV_D_T1_T2 = ".word 0x6e63c073  # hsv.d t1, (t2)"


def _gen_rvv_sequence(rng: random.Random, blocks: int, vscratch_reg: str = "s2") -> List[str]:
    lines: List[str] = []
    for _ in range(blocks):
        sew = rng.choice(["e8", "e16", "e32", "e64"])
        ew = int(sew[1:])
        lmul = rng.choice(["m1", "m2", "m4"])
        step = {"m1": 1, "m2": 2, "m4": 4}[lmul]
        tail = rng.choice(["ta", "tu"])
        mask_pol = rng.choice(["ma", "mu"])
        avl = rng.choice([0, 1, 2, 3, 4, 7, 8, 15, 16, 31])
        rd_vl = rng.choice(SCALAR_REGS)
        lines.append(f"  vsetivli {rd_vl}, {avl}, {sew}, {lmul}, {tail}, {mask_pol}")

        # Keep v0 as mask register when using masked ops; pick aligned vregs >= step
        vregs = [f"v{i}" for i in range(step, 32, step)]
        all_vregs = [f"v{i}" for i in range(0, 32, step)]

        # Occasionally refresh v0 mask via vector compare
        if rng.random() < 0.45:
            cmp_op = rng.choice(RVV_CMP_VV)
            vs2 = rng.choice(vregs)
            vs1 = rng.choice(vregs)
            lines.append(f"  {cmp_op} v0, {vs2}, {vs1}")

        ops_in_block = rng.randint(5, 9)
        for _ in range(ops_in_block):
            kind = rng.choice(
                [
                    "alu_vv",
                    "alu_vx",
                    "mac_vv",
                    "masked_vv",
                    "slide",
                    "gather",
                    "red",
                    "vfp",
                    "vmask",
                    "vload",
                    "vstore",
                    "vload_strided",
                    "vload_ff",
                ]
            )
            vd = rng.choice(vregs)
            vs2 = rng.choice(vregs)
            vs1 = rng.choice(vregs)
            rs1 = rng.choice(SCALAR_REGS)

            if kind == "alu_vv":
                lines.append(f"  {rng.choice(RVV_ALU_VV)} {vd}, {vs2}, {vs1}")
            elif kind == "alu_vx":
                lines.append(f"  {rng.choice(RVV_ALU_VX)} {vd}, {vs2}, {rs1}")
            elif kind == "mac_vv":
                lines.append(f"  {rng.choice(RVV_MAC_VV)} {vd}, {vs1}, {vs2}")
            elif kind == "masked_vv":
                # Masked op: vd must not overlap v0 (guaranteed since vd in vregs >= step)
                lines.append(f"  {rng.choice(RVV_ALU_VV)} {vd}, {vs2}, {vs1}, v0.t")
            elif kind == "vfp" and ew in (32, 64):
                lines.append(f"  {rng.choice(RVV_FP_VV)} {vd}, {vs2}, {vs1}")
            elif kind == "vmask":
                if rng.random() < 0.5:
                    lines.append(f"  {rng.choice(RVV_MASK_MM)} v0, v0, {vs1}")
                else:
                    lines.append(f"  vcpop.m {rs1}, v0")
                    lines.append(f"  vfirst.m {rs1}, v0")
            elif kind == "slide":
                if vd != vs2:
                    sh = rng.choice([0, 1, 2, 3])
                    op = rng.choice(["vslideup.vi", "vslidedown.vi"])
                    lines.append(f"  {op} {vd}, {vs2}, {sh}")
                else:
                    lines.append(f"  vadd.vv {vd}, {vs2}, {vs1}")
            elif kind == "gather":
                if vd != vs2 and vd != vs1:
                    lines.append(f"  vrgather.vv {vd}, {vs2}, {vs1}")
                else:
                    lines.append(f"  vxor.vv {vd}, {vs2}, {vs1}")
            elif kind == "red" and lmul == "m1":
                lines.append(f"  {rng.choice(RVV_RED_VS)} {vd}, {vs2}, {vs1}")
            elif kind == "vload":
                lines.append(f"  vle{ew}.v {rng.choice(all_vregs)}, ({vscratch_reg})")
            elif kind == "vstore":
                lines.append(f"  vse{ew}.v {rng.choice(all_vregs)}, ({vscratch_reg})")
            elif kind == "vload_strided":
                # Small positive stride fitting inside 1024-byte _vscratch
                stride_reg = rng.choice(SCALAR_REGS)
                stride = rng.choice([ew // 8, (ew // 8) * 2])
                lines.append(f"  li {stride_reg}, {stride}")
                lines.append(f"  vlse{ew}.v {vd}, ({vscratch_reg}), {stride_reg}")
            elif kind == "vload_ff":
                lines.append(f"  vle{ew}ff.v {vd}, ({vscratch_reg})")
    return lines


def generate_rvv_program(rng: random.Random, blocks: int) -> str:
    lines = [
        "# Auto-generated RVV 1.0 constrained-random stress program",
        ".section .text",
        ".globl _start",
        "_start:",
        "  # Enable mstatus.VS = Initial (0x200) and mstatus.FS = Initial (0x2000)",
        "  li t0, 0x2200",
        "  csrs mstatus, t0",
        "  csrw fcsr, zero",
        "  la s2, _vscratch",
        "  # Initialize scalar registers with boundary & random values",
    ]
    bvals = [0, 1, -1, 7, 15, 31, 0x7FFF, -0x8000, 0x7FFFFFFF, -0x80000000, 0x55555555]
    for r in SCALAR_REGS:
        val = rng.choice(bvals) if rng.random() < 0.5 else rng.randint(-100000, 100000)
        lines.append(f"  li {r}, {val}")

    # Deterministically seed all 32 vector registers
    lines.append("  vsetivli x0, 4, e32, m1, ta, ma")
    for vr in range(32):
        lines.append(f"  vle32.v v{vr}, (s2)")

    lines.extend(_gen_rvv_sequence(rng, blocks, vscratch_reg="s2"))
    lines.extend(
        [
            "  fence rw, rw",
            "  li a0, 0",
            "  ebreak",
            "  j .",
            "",
            ".section .data",
            ".balign 64",
            "_vscratch:",
            "  .fill 1024, 1, 0x3c",
            "",
        ]
    )
    return "\n".join(lines)


def generate_hypervisor_program(rng: random.Random, rounds: int) -> str:
    """Generate an RV64 H-extension M -> HS -> VS -> HS -> M constrained-random test."""
    lines = [
        "# Auto-generated RV64 Hypervisor (H-extension) constrained-random stress test",
        ".option norelax",
        ".section .text",
        ".globl _start",
        "_start:",
        "  la t0, m_trap",
        "  csrw mtvec, t0",
        "  # Open full PMP window for HS/VS execution",
        "  li t0, -1",
        "  csrw pmpaddr0, t0",
        "  li t0, 0x0f",
        "  csrw pmpcfg0, t0",
        "  # Enable stateen & counteren & VS/FS for HS and VS",
        "  li t0, -1",
        "  csrw 0x30c, t0  # mstateen0",
        "  csrw 0x60c, t0  # hstateen0",
        "  li t0, 7",
        "  csrw mcounteren, t0",
        "  csrw 0x606, t0  # hcounteren",
        "  csrw scounteren, t0",
        "  # Delegate VS-mode ecall (cause 10) to HS-mode",
        "  li t0, (1 << 10)",
        "  csrw medeleg, t0",
        "  csrw 0x602, zero  # hedeleg",
        "  csrw 0x603, zero  # hideleg",
        "  csrw 0x680, zero  # hgatp = Bare",
        "  csrw 0x280, zero  # vsatp = Bare",
        "  la t0, hs_trap",
        "  csrw stvec, t0",
        "  la t0, vs_trap",
        "  csrw 0x205, t0    # vstvec",
        "  la s2, _vscratch",
        "  la s3, _hscratch",
        f"  li s4, {rounds}",
        "  # Enter HS-mode via mret (MPP=01, FS=Initial, VS=Initial)",
        "  la t0, hs_loop",
        "  csrw mepc, t0",
        "  li t0, (1 << 11) | (1 << 13) | (1 << 9)",
        "  csrw mstatus, t0",
        "  mret",
        "",
        "hs_loop:",
        "  beq s4, zero, hs_done",
        "  # Mutate HS/VS scratch & architectural CSRs",
        f"  li t0, {rng.randint(1, 0xFFFF)}",
        "  xor t0, t0, s4",
        "  csrw 0x240, t0    # vsscratch",
        "  csrw sscratch, t0",
        "  # Exercise hlv.d / hsv.d on guest memory (Bare G-stage)",
        "  mv t2, s3",
        "  mv t1, t0",
        f"  {ENC_HSV_D_T1_T2}",
        "  li t1, 0",
        f"  {ENC_HLV_D_T1_T2}",
        "  bne t1, t0, hs_fail",
        f"  {ENC_HFENCE_VVMA_ZERO}",
        f"  {ENC_HFENCE_GVMA_ZERO}",
        "  # Configure hstatus: SPV=1 (bit 7), SPVP=1 (bit 8) -> enter VS-mode",
        "  li t0, (1 << 7) | (1 << 8)",
        "  csrs 0x600, t0    # hstatus",
        "  # sstatus: SPP=1 (bit 8), VS=Initial (bit 9), FS=Initial (bit 13); vsstatus: VS+FS",
        "  li t0, (1 << 8) | (1 << 9) | (1 << 13)",
        "  csrs sstatus, t0",
        "  li t0, (1 << 9) | (1 << 13)",
        "  csrs 0x200, t0    # vsstatus",
        "  la t0, vs_guest",
        "  csrw sepc, t0",
        "  sret",
        "",
        "vs_guest:",
        "  # Guest VS-mode scalar + RVV execution",
        "  csrr t3, sscratch  # accesses vsscratch in V=1!",
        "  addi t3, t3, 17",
        "  csrw sscratch, t3",
    ]
    # Add randomized guest scalar & RVV instructions inside VS-mode
    for _ in range(rng.randint(4, 8)):
        r1 = rng.choice(SCALAR_REGS)
        r2 = rng.choice(SCALAR_REGS)
        op = rng.choice(["add", "sub", "xor", "or", "and", "mul"])
        lines.append(f"  {op} {r1}, {r1}, {r2}")
    lines.extend(_gen_rvv_sequence(rng, blocks=2, vscratch_reg="s2"))
    lines.extend(
        [
            "  # Hypercall from VS-mode -> trapped by HS-mode (scause = 10)",
            "  ecall",
            "  # Should never fall through; hs_trap resumes at hs_after_vs",
            "  j hs_fail",
            "",
            ".balign 4",
            "hs_trap:",
            "  csrr t0, scause",
            "  li t1, 10",
            "  bne t0, t1, hs_fail",
            "  addi s4, s4, -1",
            "  j hs_loop",
            "",
            ".balign 4",
            "vs_trap:",
            "  j hs_fail",
            "",
            "hs_done:",
            "  # Return to M-mode via ecall (cause 9 -> m_trap)",
            "  li a7, 0",
            "  ecall",
            "hs_fail:",
            "  li a7, 1",
            "  ecall",
            "",
            ".balign 4",
            "m_trap:",
            "  csrr t0, mcause",
            "  li t1, 9",
            "  bne t0, t1, m_bad",
            "  bne a7, zero, m_bad",
            "  fence rw, rw",
            "  li a0, 0",
            "  ebreak",
            "  j .",
            "m_bad:",
            "  li a0, 1",
            "  ebreak",
            "  j .",
            "",
            ".section .data",
            ".balign 64",
            "_vscratch:",
            "  .fill 1024, 1, 0x5a",
            ".balign 64",
            "_hscratch:",
            "  .fill 128, 1, 0",
            "",
        ]
    )
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Constrained-random RVV 1.0 and Hypervisor (H) fuzz generator"
    )
    parser.add_argument("--mode", choices=["rvv", "hypervisor"], required=True)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--num", type=int, default=50)
    parser.add_argument("--blocks", type=int, default=12, help="RVV blocks or Hypervisor rounds")
    parser.add_argument("--outdir", type=Path, required=True)
    args = parser.parse_args(argv)

    args.outdir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    names: List[str] = []
    for idx in range(args.num):
        name = f"{args.mode}_{idx:04d}"
        if args.mode == "rvv":
            asm = generate_rvv_program(rng, blocks=args.blocks)
        else:
            asm = generate_hypervisor_program(rng, rounds=args.blocks)
        (args.outdir / f"{name}.S").write_text(asm)
        names.append(name)
    (args.outdir / "manifest.txt").write_text("\n".join(names) + "\n")
    print(f"[rvv-hyp-fuzz] Generated {len(names)} {args.mode} tests in {args.outdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
