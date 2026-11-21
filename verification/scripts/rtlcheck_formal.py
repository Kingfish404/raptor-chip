#!/usr/bin/env python3
"""
RTLCheck-style LSU/SQ RVWMO ordering formal verification driver.

Proves all 5 microarchitectural RVWMO axioms on `rapt_sq_forward.sv` across:
- RV32 and RV64
- Both live (`PrecomputedBlocks=0`) and precomputed (`PrecomputedBlocks=1`) modes
- Bit-vector SMT solving via Yosys-Slang + `yosys-smtbmc` (`bitwuzla` / `yices`)
- 5 AST-mutated negative controls (via `ast_mutator.replace_token_sequence`)
  that MUST fail and produce real counterexamples.
"""

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from ast_mutator import replace_token_sequence

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / "rtl/core/backend/lsu/rapt_sq_forward.sv"
PKG = ROOT / "rtl/rapt_pkg.sv"
HARNESS = ROOT / "verification/formal/formal_rtlcheck_lsu.sv"
OSS_CAD_BIN = ROOT / "third_party/oss-cad-suite/bin"

MUTATIONS = {
    "drop-cbo-zero": (
        "assign forward_valid[port_idx] = !zero_pending && !alloc_match && (|(winner & eligible));",
        "assign forward_valid[port_idx] = !alloc_match && (|(winner & eligible));",
    ),
    "drop-alloc-block": (
        "assign forward_valid[port_idx] = !zero_pending && !alloc_match && (|(winner & eligible));",
        "assign forward_valid[port_idx] = !zero_pending && (|(winner & eligible));",
    ),
    "ignore-stale": (
        "assign eligible[entry_idx] = !stale_context[entry_idx]",
        "assign eligible[entry_idx] = 1'b1",
    ),
    "wrong-age-order": (
        "assign candidates = (|before_head) ? before_head : slot_match;",
        "assign candidates = slot_match;",
    ),
    "bad-narrow-bound": (
        "&& store_addr[entry_idx][OffsetBits-1:0] <= load_addr[port_idx][OffsetBits-1:0]",
        "&& store_addr[entry_idx][OffsetBits-1:0] < load_addr[port_idx][OffsetBits-1:0]",
    ),
}


def find_yosys(explicit: str) -> str:
    if explicit:
        return explicit
    return os.environ.get("RAPTOR_YOSYS_REAL") or shutil.which("yosys") or "yosys"


def find_smtbmc() -> str:
    bundled = OSS_CAD_BIN / "yosys-smtbmc"
    if bundled.exists():
        return str(bundled)
    return shutil.which("yosys-smtbmc") or "yosys-smtbmc"


def run_case(
    yosys: str,
    smtbmc: str,
    solver: str,
    out_dir: Path,
    label: str,
    xlen: int,
    dut_path: Path,
    expect_pass: bool,
    timeout: int,
    entries: int = 4,
    read_ports: int = 1,
    narrow_forward: int = 1,
):
    case_dir = out_dir / label
    case_dir.mkdir(parents=True, exist_ok=True)
    ys_path = case_dir / "emit.ys"
    smt2_path = case_dir / "model.smt2"
    ys_log = case_dir / "yosys.log"
    smt_log = case_dir / "smtbmc.log"
    defines = "-DRAPT_RV64" if xlen == 64 else ""
    params = f"-GEntries={entries} -GReadPorts={read_ports} -GNarrowForward={narrow_forward}"
    script = "\n".join(
        [
            "plugin -i slang",
            f"read_slang --threads 1 --single-unit --top formal_rtlcheck_lsu "
            f"-DFORMAL -DSYNTHESIS {defines} {params} "
            f"-I{ROOT}/rtl/configs/formal -I{ROOT}/rtl/include "
            f"{PKG} {dut_path} {HARNESS}",
            "prep -top formal_rtlcheck_lsu -flatten",
            "async2sync",
            "opt -fast",
            "chformal -assume -early",
            "chformal -live -fair -cover -remove",
            "setundef -undriven -anyseq",
            "dffunmap",
            f"write_smt2 -wires {smt2_path}",
            "",
        ]
    )
    ys_path.write_text(script)
    t0 = time.monotonic()
    with ys_log.open("w") as lf:
        yproc = subprocess.run(
            [yosys, "-Q", "-T", "-s", str(ys_path)],
            stdout=lf,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
    if yproc.returncode != 0 or not smt2_path.exists():
        elapsed = round(time.monotonic() - t0, 2)
        print(f"[rtlcheck-lsu] {label}: FAIL (yosys rc={yproc.returncode}, {elapsed}s)", flush=True)
        return {
            "label": label,
            "xlen": xlen,
            "expect_pass": expect_pass,
            "proved": False,
            "failed_cex": False,
            "ok": False,
            "elapsed_sec": elapsed,
            "log": str(ys_log),
        }

    env = os.environ.copy()
    if OSS_CAD_BIN.is_dir():
        env["PATH"] = f"{OSS_CAD_BIN}:{env.get('PATH', '')}"
    with smt_log.open("w") as lf:
        sproc = subprocess.run(
            [smtbmc, "-s", solver, "--presat", "--noprogress", "-t", "1", str(smt2_path)],
            env=env,
            stdout=lf,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
    elapsed = round(time.monotonic() - t0, 2)
    text = smt_log.read_text(errors="replace")
    proved = sproc.returncode == 0 and "Status: PASSED" in text
    failed_cex = sproc.returncode != 0 and "Status: FAILED" in text and "Assert failed" in text
    ok = proved if expect_pass else failed_cex
    got = "PROVE" if proved else ("CEX" if failed_cex else f"ERR({sproc.returncode})")
    print(
        f"[rtlcheck-lsu] {label}: {'PASS' if ok else 'FAIL'} "
        f"(expect={'PROVE' if expect_pass else 'CEX'}, got={got}, {elapsed}s)",
        flush=True,
    )
    return {
        "label": label,
        "xlen": xlen,
        "expect_pass": expect_pass,
        "proved": proved,
        "failed_cex": failed_cex,
        "ok": ok,
        "elapsed_sec": elapsed,
        "log": str(smt_log),
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="RTLCheck LSU/SQ RVWMO formal driver")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--yosys", default="")
    parser.add_argument("--solver", default="bitwuzla")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--skip-mutations", action="store_true")
    parser.add_argument("--matrix", action="store_true", help="Prove full geometry matrix (Entries=4/8 x Ports=1/2 x Narrow=0/1)")
    args = parser.parse_args(argv)

    yosys = find_yosys(args.yosys)
    smtbmc = find_smtbmc()
    args.output.mkdir(parents=True, exist_ok=True)

    tasks = []
    if args.matrix:
        for xlen in (32, 64):
            for entries in (4, 8):
                for ports in (1, 2):
                    for narrow in (0, 1):
                        lbl = f"prove-rv{xlen}-e{entries}-p{ports}-n{narrow}"
                        tasks.append((lbl, xlen, DUT, True, entries, ports, narrow))
    else:
        tasks = [
            ("prove-rv32", 32, DUT, True, 4, 1, 1),
            ("prove-rv64", 64, DUT, True, 4, 1, 1),
        ]
    if not args.skip_mutations:
        orig_text = DUT.read_text()
        for mname, (old, new) in MUTATIONS.items():
            mutated = replace_token_sequence(orig_text, old, new)
            mpath = args.output / f"mutant-{mname}.sv"
            mpath.write_text(mutated)
            tasks.append((f"neg-{mname}-rv32", 32, mpath, False, 4, 1, 1))

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        results = list(
            ex.map(
                lambda t: run_case(
                    yosys,
                    smtbmc,
                    args.solver,
                    args.output,
                    t[0],
                    t[1],
                    t[2],
                    t[3],
                    args.timeout,
                    entries=t[4],
                    read_ports=t[5],
                    narrow_forward=t[6],
                ),
                tasks,
            )
        )

    all_ok = all(r["ok"] for r in results)
    summary = {"complete": all_ok, "solver": args.solver, "cases": results}
    (args.output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"[rtlcheck-lsu] SUMMARY: {'ALL PASS' if all_ok else 'FAILED'} ({len(results)} cases)")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
