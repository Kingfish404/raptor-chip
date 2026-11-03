#!/usr/bin/env python3
"""Prove flattened native RTL against an independently preserved RTL tree.

Both sides use the same preset, synthesis defines and behavioral memory models.
No matched point is waived. All memories are mapped before equivalence checking.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "chip32-middle-16k": (32, "rapt_chip"),
    "chip32-small": (32, "rapt_chip"),
    "chip32-dff": (32, "rapt_chip"),
    "small": (64, "rapt_chip"),
    "default": (64, "rapt_chip"),
}
ASYNC_CELLS = "t:$adff t:$adffe t:$aldff t:$aldffe t:$dffsr t:$dffsre"


def manifest(root):
    return {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(root.rglob("*"))
        if p.is_file() and p.suffix in (".sv", ".svh", ".v", ".vh")
    }


def checked_path(path):
    path = path.resolve()
    if any(c.isspace() or c in ';"\\' for c in str(path)):
        raise ValueError("Yosys paths must not contain whitespace, quotes or command separators")
    return path


def elaboration(root, preset, xlen, top, destination):
    sources = [root / "rapt_pkg.sv"]
    sources += sorted(p for p in root.rglob("*.sv") if p.name != "rapt_pkg.sv")
    includes = " ".join(f"-I{root / directory}" for directory in (
        f"configs/{preset}", "include", "include/npc", "include/dpic_mock"))
    defines = "-DSYNTHESIS" + (" -DRAPT_RV64" if xlen == 64 else "")
    return [
        f"read_slang --threads 1 --single-unit {defines} {includes} --top {top} "
        + " ".join(map(str, sources)),
        f"hierarchy -check -top {top}",
        "select -assert-none t:$check t:$assert t:$assume t:$cover",
        "proc", "flatten", "opt -purge", "memory_map", "opt -full", "check -assert",
        f"write_rtlil {destination}",
    ]


def audit(log):
    final = log.rsplit("Executing EQUIV_STATUS pass.", 1)
    if len(final) != 2 or "ERROR:" in log:
        raise ValueError("missing final equivalence status or tool error")
    match = re.search(r"Found (\d+) \$equiv cells in equiv:\s*"
                      r"Of those cells (\d+) are proven and (\d+) are unproven\.", final[1])
    if not match or "Equivalence successfully proven!" not in final[1]:
        raise ValueError("incomplete equivalence proof")
    total, proven, remaining = map(int, match.groups())
    if total == 0 or total != proven or remaining:
        raise ValueError("vacuous or unproven equivalence points")
    return {"points": total, "proven": proven, "unproven": remaining}


def run_script(commands, directory, name, yosys, timeout):
    script, log = directory / (name + ".ys"), directory / (name + ".log")
    script.write_text(";\n".join(commands) + "\n")
    start = time.monotonic()
    with log.open("w") as stream:
        result = subprocess.run([yosys, "-Q", "-T", "-m", "slang", "-s", str(script)],
                                cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{name} failed; see {log}")
    return {"seconds": round(time.monotonic() - start, 3),
            "script_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
            "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-rtl", required=True, type=Path)
    parser.add_argument("--candidate-rtl", type=Path, default=ROOT / "rtl")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--presets", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--top", choices=("rapt_chip", "rapt"),
                        help="override the top for a preset that cannot use rapt_chip")
    parser.add_argument("--timeout", type=int, default=7200,
                        help="timeout in seconds for each elaboration or proof")
    parser.add_argument("--yosys", default=os.environ.get("RAPTOR_YOSYS_REAL", "yosys"))
    args = parser.parse_args()
    roots = [checked_path(args.baseline_rtl), checked_path(args.candidate_rtl)]
    output = checked_path(args.output)
    if roots[0] == roots[1] or not all((r / "rapt_pkg.sv").is_file() for r in roots):
        parser.error("two distinct, complete RTL trees are required")
    if args.timeout < 1:
        parser.error("timeout must be positive")
    output.mkdir(parents=True, exist_ok=True)
    hashes = list(map(manifest, roots))
    result = {"complete": False, "rtl_roots": list(map(str, roots)), "source_sha256": hashes,
              "memory_model": "behavioral, flattened and mapped", "cases": [],
              "yosys": subprocess.check_output([args.yosys, "-V"], text=True).strip()}
    report = output / "results.json"

    def save():
        report.write_text(json.dumps(result, indent=2) + "\n")

    save()
    for preset in args.presets:
        xlen, default_top = CASES[preset]
        top = args.top or default_top
        directory = output / preset
        directory.mkdir(exist_ok=True)
        row = {"preset": preset, "xlen": xlen, "top": top, "proven": False}
        result["cases"].append(row)
        save()
        try:
            for label, root in zip(("gold", "gate"), roots):
                row[label] = run_script(
                    elaboration(root, preset, xlen, top, directory / (label + ".il")),
                    directory, label, args.yosys, args.timeout)
                save()
                print(f"{preset} RV{xlen}: {label} elaborated", flush=True)
            commands = [
                f"read_rtlil {directory / 'gold.il'}", f"rename {top} gold", "design -stash gold",
                f"read_rtlil {directory / 'gate.il'}", f"rename {top} gate", "design -stash gate",
                "design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                "equiv_make gold gate equiv", "hierarchy -top equiv", "opt_merge", "opt_clean",
                # Merge identical flops before expanding asynchronous controls.
                # This keeps common history shared instead of inventing two
                # independently initialized copies of the sampling state.
                f"clk2fflogic {ASYNC_CELLS}", "opt_clean",
                "equiv_simple -undef -short", "equiv_induct -undef -seq 4", "equiv_status -assert",
            ]
            row["proof"] = run_script(commands, directory, "prove", args.yosys, args.timeout)
            row["audit"] = audit((directory / "prove.log").read_text())
            if hashes != list(map(manifest, roots)):
                raise RuntimeError("RTL changed during equivalence checking")
            row["proven"] = True
            save()
            print(f"PASS: {preset} RV{xlen} {top}: {row['audit']['proven']} points", flush=True)
        except Exception as error:
            row["error"] = str(error)
            save()
            raise
    if hashes != list(map(manifest, roots)):
        raise RuntimeError("RTL changed before completion")
    result["complete"] = True
    save()


if __name__ == "__main__":
    main()
