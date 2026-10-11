#!/usr/bin/env python3
"""Elaborate every direction predictor and reject a missing selection."""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MISSING = "rapt_bpu_requires_TAGE_GSHARE_BIMODAL_or_STATIC"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "verify/build/bpu-config-check")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    preset = (ROOT / "hdl/configs/default/rapt_config.svh").read_text()
    selection = r"^`define RAPT_BPU_DIRP_(?:TAGE|GSHARE|BIMODAL|STATIC)\b[^\n]*"
    if len(re.findall(selection, preset, re.M)) != 1:
        raise ValueError("default preset must select exactly one predictor")
    sources = [ROOT / "hdl/rapt_pkg.sv",
               *sorted((ROOT / "hdl/frontend/branch_predictor").glob("*.sv")),
               *sorted((ROOT / "hdl/common").glob("*.sv"))]
    results = {"complete": False, "cases": []}
    summary = output / "results.json"
    summary.write_text(json.dumps(results, indent=2) + "\n")
    for xlen in (32, 64):
        for predictor in ("TAGE", "GSHARE", "BIMODAL", "STATIC", "missing"):
            case = output / f"rv{xlen}-{predictor.lower()}"
            case.mkdir(exist_ok=True)
            define = "" if predictor == "missing" else f"`define RAPT_BPU_DIRP_{predictor}"
            (case / "rapt_config.svh").write_text(re.sub(selection, define, preset, flags=re.M))
            flags = ["-DSYNTHESIS"] + (["-DRAPT_RV64"] if xlen == 64 else [])
            flags += ["-I" + str(path) for path in
                      (case, ROOT / "hdl", ROOT / "hdl/include", ROOT / "hdl/include/npc",
                       ROOT / "hdl/frontend/branch_predictor")]
            inputs = flags + [str(path) for path in sources]
            commands = {
                "verilator": ["verilator", "--lint-only", "--top-module", "rapt_bpu",
                              "-Wno-fatal", *inputs],
                "slang": ["yosys", "-Q", "-T", "-m", "slang", "-p",
                          "read_slang --top rapt_bpu --single-unit "
                          "--allow-toplevel-iface-ports " + shlex.join(inputs)],
            }
            for tool, command in commands.items():
                run = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, timeout=120)
                log = case / f"{tool}.log"
                log.write_text(run.stdout)
                if predictor == "missing":
                    rejected = (rf"error: unknown module '{MISSING}'" if tool == "slang"
                                else rf"%Error[^\n]*{MISSING}")
                    passed = run.returncode > 0 and re.search(rejected, run.stdout) is not None
                else:
                    passed = run.returncode == 0
                results["cases"].append({"xlen": xlen, "predictor": predictor, "tool": tool,
                                         "passed": passed, "returncode": run.returncode,
                                         "command": command, "log": str(log)})
                summary.write_text(json.dumps(results, indent=2) + "\n")
                print(f"{'PASS' if passed else 'FAIL'}: rv{xlen} {predictor} {tool}", flush=True)
    results["complete"] = all(case["passed"] for case in results["cases"])
    summary.write_text(json.dumps(results, indent=2) + "\n")
    return int(not results["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
