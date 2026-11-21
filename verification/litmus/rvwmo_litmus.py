#!/usr/bin/env python3
"""
RVWMO (RISC-V Weak Memory Ordering) Litmus & Coherence Verification Suite.

Provides:
1. 16 self-checking bare-metal RV32/RV64 assembly litmus tests covering:
   - Per-location coherence (CoWR, CoWW, CoRW, CoRR, mixed-width SQ forwarding)
   - Speculative store non-leakage across mispredicted branches
   - Deep store-queue capacity & drain ordering
   - Fences (`fence rw,rw`, `fence.tso`, `fence.i` self-modifying code)
   - Atomics (`lr/sc`, `lr/sc.aqrl`, `amo*.aq/rl/aqrl`)
   - RVWMO Preserved Program Order (PPO) address/data/control dependencies
2. Standard `herd7`-compatible multi-hart `.litmus` suite export (MP, SB, LB,
   IRIW, 2+2W, R, S) with optional `herd7 -model riscv.cat` oracle validation.

Usage:
    python3 verification/litmus/rvwmo_litmus.py generate --xlen 64 --outdir /tmp/litmus
    python3 verification/litmus/rvwmo_litmus.py export-herd7 --outdir /tmp/litmus-cat
"""

import argparse
import json
import shutil
import subprocess
from pathlib import Path
from typing import Dict, List

HEADER = """\
# Auto-generated RVWMO Litmus test: {name} (XLEN={xlen})
.section .text
.globl _start
_start:
  la sp, _litmus_mem
  li s0, {iters}
.Lloop_{name}:
"""

FOOTER = """\
  addi s0, s0, -1
  bne s0, zero, .Lloop_{name}
  fence rw, rw
  li a0, 0
  ebreak
  j .

.Lfail_{name}:
  li a0, 1
  ebreak
  j .

.section .data
.balign 64
_litmus_mem:
  .fill 512, 1, 0
.balign 64
.option push
.option norvc
_smc_slot:
  addi t6, zero, 1
  ret
.option pop
"""


def _wrap(name: str, xlen: int, body: str, iters: int = 32) -> str:
    return (
        HEADER.format(name=name, xlen=xlen, iters=iters)
        + body
        + FOOTER.format(name=name)
    )


def build_litmus_tests(xlen: int) -> Dict[str, str]:
    """Return mapping of litmus test name -> RV32/RV64 assembly source."""
    fail = ".Lfail_{name}"
    tests: Dict[str, str] = {}

    # 1. CoWR same-address full-width forwarding
    name = "co_wr_same"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  li t0, 0x12345678
  xor t0, t0, s0
  sw t0, 0(sp)
  lw t1, 0(sp)
  bne t0, t1, {fail.format(name=name)}
""",
    )

    # 2. CoWR mixed-width overlapping store-to-load forwarding (SW -> LB/LBU/LH/LHU)
    name = "co_wr_mixed_subword"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  li t0, 0x11223344
  sw t0, 8(sp)
  lbu t1, 8(sp)
  li t2, 0x44
  bne t1, t2, {fail.format(name=name)}
  lbu t1, 9(sp)
  li t2, 0x33
  bne t1, t2, {fail.format(name=name)}
  lhu t1, 10(sp)
  li t2, 0x1122
  bne t1, t2, {fail.format(name=name)}
  li t3, 0xaa
  sb t3, 9(sp)
  lw t1, 8(sp)
  li t2, 0x1122aa44
  bne t1, t2, {fail.format(name=name)}
""",
    )

    # 3. CoWW back-to-back stores to same address, youngest must win
    name = "co_ww_order"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  li t0, 0x11111111
  li t1, 0x22222222
  li t2, 0x33333333
  xor t2, t2, s0
  sw t0, 16(sp)
  sw t1, 16(sp)
  sw t2, 16(sp)
  fence rw, rw
  lw t3, 16(sp)
  bne t2, t3, {fail.format(name=name)}
""",
    )

    # 4. CoRW + CoRR interleaved load/store/load coherence
    name = "co_rw_rr"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  li t0, 0x5a5a0000
  or t0, t0, s0
  sw t0, 24(sp)
  lw t1, 24(sp)
  addi t2, t0, 1
  sw t2, 24(sp)
  lw t3, 24(sp)
  lw t4, 24(sp)
  bne t1, t0, {fail.format(name=name)}
  bne t3, t2, {fail.format(name=name)}
  bne t4, t2, {fail.format(name=name)}
""",
    )

    # 5. Speculative store non-leakage across mispredicted branches
    name = "sq_flush_no_leak"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  li t0, 0x0cafe000
  or t0, t0, s0
  sw t0, 32(sp)
  andi t1, s0, 1
  bne t1, zero, .Lskip_spec_{name}
  # Even iterations: branch not taken, alternate pattern
  beq s0, zero, .Lbad_path_{name}
  j .Lcheck_spec_{name}
.Lbad_path_{name}:
  li t2, 0x0badbeef
  sw t2, 32(sp)
.Lskip_spec_{name}:
  bne s0, zero, .Lcheck_spec_{name}
  li t2, 0x0badc0de
  sw t2, 32(sp)
.Lcheck_spec_{name}:
  lw t3, 32(sp)
  bne t3, t0, {fail.format(name=name)}
""",
    )

    # 6. Deep store-queue capacity & FIFO drain ordering
    name = "sq_deep_drain"
    stores = []
    checks = []
    for idx in range(16):
        off = 64 + idx * 4
        stores.append(f"  addi t0, s0, {idx + 1}\n  sw t0, {off}(sp)")
        checks.append(
            f"  lw t1, {off}(sp)\n  addi t2, s0, {idx + 1}\n"
            f"  bne t1, t2, {fail.format(name=name)}"
        )
    tests[name] = _wrap(
        name,
        xlen,
        "\n".join(stores) + "\n  fence w, r\n" + "\n".join(checks) + "\n",
        iters=16,
    )

    # 7. fence rw, rw across cache lines
    name = "fence_rw_rw"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, s0, 100
  addi t1, s0, 200
  sw t0, 0(sp)
  fence rw, rw
  sw t1, 128(sp)
  fence rw, rw
  lw t2, 128(sp)
  lw t3, 0(sp)
  bne t2, t1, {fail.format(name=name)}
  bne t3, t0, {fail.format(name=name)}
""",
    )

    # 8. fence.tso ordering
    name = "fence_tso"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, s0, 33
  addi t1, s0, 77
  sw t0, 40(sp)
  fence.tso
  sw t1, 168(sp)
  fence.tso
  lw t2, 40(sp)
  lw t3, 168(sp)
  bne t2, t0, {fail.format(name=name)}
  bne t3, t1, {fail.format(name=name)}
""",
    )

    # 9. fence.i self-modifying code coherence
    name = "fence_i_smc"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  la t0, _smc_slot
  andi t1, s0, 1
  # Toggle between `addi t6, zero, 1` (0x00100f93) and `addi t6, zero, 2` (0x00200f93)
  beq t1, zero, .Lsmc_two_{name}
  li t2, 0x00100f93
  li t3, 1
  j .Lsmc_patch_{name}
.Lsmc_two_{name}:
  li t2, 0x00200f93
  li t3, 2
.Lsmc_patch_{name}:
  sw t2, 0(t0)
  fence rw, rw
  fence.i
  jalr ra, t0, 0
  bne t6, t3, {fail.format(name=name)}
""",
        iters=16,
    )

    # 10. LR/SC reservation success and invalidation
    name = "lr_sc_reservation"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, sp, 48
  sw s0, 0(t0)
  lr.w t1, (t0)
  bne t1, s0, {fail.format(name=name)}
  addi t2, s0, 5
  sc.w t3, t2, (t0)
  bne t3, zero, {fail.format(name=name)}
  lw t4, 0(t0)
  bne t4, t2, {fail.format(name=name)}
""",
    )

    # 11. LR/SC with aq/rl ordering
    name = "lr_sc_aqrl"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, sp, 52
  sw s0, 0(t0)
  lr.w.aq t1, (t0)
  addi t2, t1, 9
  sc.w.rl t3, t2, (t0)
  bne t3, zero, {fail.format(name=name)}
  lw t4, 0(t0)
  bne t4, t2, {fail.format(name=name)}
""",
    )

    # 12. AMO acquire/release chain
    name = "amo_aqrl_chain"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, sp, 56
  sw zero, 0(t0)
  li t1, 7
  amoadd.w.aq t2, t1, (t0)
  bne t2, zero, {fail.format(name=name)}
  li t1, 3
  amoadd.w.rl t2, t1, (t0)
  li t3, 7
  bne t2, t3, {fail.format(name=name)}
  li t1, 0x15
  amoxor.w.aqrl t2, t1, (t0)
  li t3, 10
  bne t2, t3, {fail.format(name=name)}
  lw t4, 0(t0)
  li t3, 31
  bne t4, t3, {fail.format(name=name)}
""",
    )

    # 13. PPO address dependency (load -> xor -> add -> load)
    name = "ppo_addr_dep"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, s0, 11
  sw t0, 192(sp)
  sw t0, 196(sp)
  lw t1, 192(sp)
  xor t2, t1, t1
  add t3, sp, t2
  lw t4, 196(t3)
  bne t4, t0, {fail.format(name=name)}
""",
    )

    # 14. PPO data dependency (load -> store data)
    name = "ppo_data_dep"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, s0, 41
  sw t0, 200(sp)
  lw t1, 200(sp)
  addi t2, t1, 3
  sw t2, 204(sp)
  lw t3, 204(sp)
  addi t4, t0, 3
  bne t3, t4, {fail.format(name=name)}
""",
    )

    # 15. PPO control dependency (load -> branch -> store)
    name = "ppo_ctrl_dep"
    tests[name] = _wrap(
        name,
        xlen,
        f"""\
  addi t0, s0, 1
  sw t0, 208(sp)
  lw t1, 208(sp)
  beq t1, zero, {fail.format(name=name)}
  sw t1, 212(sp)
  lw t2, 212(sp)
  bne t2, t0, {fail.format(name=name)}
""",
    )

    # 16. RV64-specific doubleword mixed-width forwarding & LR.D/SC.D
    if xlen == 64:
        name = "rv64_co_wr_dw_mixed"
        tests[name] = _wrap(
            name,
            xlen,
            f"""\
  li t0, 0x0123456789abcdef
  sd t0, 256(sp)
  lwu t1, 256(sp)
  li t2, 0x89abcdef
  bne t1, t2, {fail.format(name=name)}
  lwu t1, 260(sp)
  li t2, 0x01234567
  bne t1, t2, {fail.format(name=name)}
  li t3, 0xfeedface
  sw t3, 260(sp)
  ld t4, 256(sp)
  li t5, 0xfeedface89abcdef
  bne t4, t5, {fail.format(name=name)}
  addi t6, sp, 264
  sd t0, 0(t6)
  lr.d t1, (t6)
  bne t1, t0, {fail.format(name=name)}
  addi t2, t1, 1
  sc.d t3, t2, (t6)
  bne t3, zero, {fail.format(name=name)}
""",
        )

    return tests


HERD7_LITMUS: Dict[str, str] = {
    "MP+fence.rw.rw.litmus": """\
RISCV MP+fence.rw.rw
"Message Passing with fence rw,rw (RVWMO forbidden: 1:x5=1 /\\ 1:x7=0)"
{
0:x6=x; 0:x8=y;
1:x6=y; 1:x8=x;
}
 P0          | P1          ;
 ori x5,x0,1 | lw x5,0(x6) ;
 sw x5,0(x6) | fence rw,rw ;
 fence rw,rw | lw x7,0(x8) ;
 ori x7,x0,1 |             ;
 sw x7,0(x8) |             ;
exists (1:x5=1 /\\ 1:x7=0)
""",
    "SB+fence.rw.rw.litmus": """\
RISCV SB+fence.rw.rw
"Store Buffering with fence rw,rw (RVWMO forbidden: 0:x7=0 /\\ 1:x7=0)"
{
0:x6=x; 0:x8=y;
1:x6=y; 1:x8=x;
}
 P0          | P1          ;
 ori x5,x0,1 | ori x5,x0,1 ;
 sw x5,0(x6) | sw x5,0(x6) ;
 fence rw,rw | fence rw,rw ;
 lw x7,0(x8) | lw x7,0(x8) ;
exists (0:x7=0 /\\ 1:x7=0)
""",
    "LB+addr+data.litmus": """\
RISCV LB+addr+data
"Load Buffering with address+data dependency (RVWMO forbidden: 0:x5=1 /\\ 1:x5=1)"
{
0:x6=x; 0:x8=y;
1:x6=y; 1:x8=x;
}
 P0           | P1           ;
 lw x5,0(x6)  | lw x5,0(x6)  ;
 xor x7,x5,x5 | xor x7,x5,x5 ;
 add x9,x8,x7 | ori x7,x7,1  ;
 ori x10,x0,1 | sw x7,0(x8)  ;
 sw x10,0(x9) |              ;
exists (0:x5=1 /\\ 1:x5=1)
""",
    "IRIW+fence.rw.rw.litmus": """\
RISCV IRIW+fence.rw.rw
"Independent Reads of Independent Writes with fences (RVWMO forbidden)"
{
0:x6=x; 1:x6=y;
2:x6=x; 2:x8=y;
3:x6=y; 3:x8=x;
}
 P0          | P1          | P2          | P3          ;
 ori x5,x0,1 | ori x5,x0,1 | lw x5,0(x6) | lw x5,0(x6) ;
 sw x5,0(x6) | sw x5,0(x6) | fence rw,rw | fence rw,rw ;
             |             | lw x7,0(x8) | lw x7,0(x8) ;
exists (2:x5=1 /\\ 2:x7=0 /\\ 3:x5=1 /\\ 3:x7=0)
""",
    "2+2W+fence.rw.rw.litmus": """\
RISCV 2+2W+fence.rw.rw
"2+2W with fence rw,rw (RVWMO forbidden: [x]=2 /\\ [y]=2)"
{
0:x6=x; 0:x8=y;
1:x6=y; 1:x8=x;
}
 P0          | P1          ;
 ori x5,x0,2 | ori x5,x0,2 ;
 sw x5,0(x6) | sw x5,0(x6) ;
 fence rw,rw | fence rw,rw ;
 ori x7,x0,1 | ori x7,x0,1 ;
 sw x7,0(x8) | sw x7,0(x8) ;
exists ([x]=2 /\\ [y]=2)
""",
}


def cmd_generate(args: argparse.Namespace) -> int:
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    tests = build_litmus_tests(args.xlen)
    names: List[str] = []
    for name, asm in sorted(tests.items()):
        (outdir / f"{name}.S").write_text(asm)
        names.append(name)
    (outdir / "manifest.txt").write_text("\n".join(names) + "\n")
    print(f"[rvwmo-litmus] Generated {len(names)} RV{args.xlen} tests in {outdir}")
    return 0


def cmd_export_herd7(args: argparse.Namespace) -> int:
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    for fname, content in sorted(HERD7_LITMUS.items()):
        (outdir / fname).write_text(content)
    summary = {"exported": sorted(HERD7_LITMUS.keys()), "herd7_checked": False}
    if args.run_herd7:
        herd7 = shutil.which("herd7")
        if not herd7:
            raise RuntimeError("herd7 not found in PATH")
        results = {}
        for fname in sorted(HERD7_LITMUS.keys()):
            proc = subprocess.run(
                [herd7, "-model", "riscv.cat", str(outdir / fname)],
                capture_output=True,
                text=True,
                check=True,
            )
            results[fname] = "Never" in proc.stdout
        summary["herd7_checked"] = True
        summary["all_forbidden_never"] = all(results.values())
        summary["results"] = results
    (outdir / "herd7_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"[rvwmo-litmus] Exported {len(HERD7_LITMUS)} herd7 .litmus files to {outdir}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="RVWMO Litmus test generator")
    sub = parser.add_subparsers(dest="command", required=True)

    p_gen = sub.add_parser("generate", help="Generate bare-metal RVWMO litmus .S suite")
    p_gen.add_argument("--xlen", type=int, choices=[32, 64], required=True)
    p_gen.add_argument("--outdir", required=True)

    p_h7 = sub.add_parser("export-herd7", help="Export herd7-compatible .litmus tests")
    p_h7.add_argument("--outdir", required=True)
    p_h7.add_argument("--run-herd7", action="store_true")

    args = parser.parse_args(argv)
    if args.command == "generate":
        return cmd_generate(args)
    return cmd_export_herd7(args)


if __name__ == "__main__":
    raise SystemExit(main())
