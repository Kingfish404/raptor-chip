#!/usr/bin/env python3
"""Check full-state one-step inductive PRF equivalence with identical inputs.

All data/valid/transient state must correspond before a step; every matching
state and output must be proven. This is not equality between independently
chosen power-up data values. No cells are ignored. Snapshot roots need headers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

# Prevent intermediate combinational names becoming artificial cutpoints.
# This does not remove their logic: it is proved through state/output cones.
COMBINATIONAL_MATCHES = ["wr_mux_data", "wr_any_oh", "wr_oh", "settle_prd_oh",
                         "dealloc_prs_oh", "wr_data", "wr_addr", "wr_en"]
PROOF_PASSES = [
    "opt_merge",
    "select -set state_points equiv/w:prf_arr* equiv/w:prf_valid %u "
    "equiv/w:prf_transient %u %a %ci1 equiv/t:$equiv %i",
    "select -assert-any @state_points",
    # Selecting just the $equiv cells omits their drivers from SAT import.
    "select -set state_cone @state_points %ci*",
    "equiv_induct -undef -seq 1 @state_cone",
    "equiv_simple -undef -short", "equiv_simple -undef",
    "equiv_status -assert",
]


def manifest(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.suffix in (".sv", ".svh")}


def audit_proof(log):
    """Reject vacuous/truncated proof reports and missing PRF observation points."""
    final = log.rsplit("Executing EQUIV_STATUS pass.", 1)
    if len(final) != 2 or "ERROR:" in log:
        raise ValueError("missing final equivalence status or tool error")
    summary = re.search(
        r"Found (\d+) \$equiv cells in equiv:\s*"
        r"Of those cells (\d+) are proven and (\d+) are unproven\.", final[1])
    if not summary or "Equivalence successfully proven!" not in final[1]:
        raise ValueError("incomplete equivalence summary")
    total, proven, unproven = map(int, summary.groups())
    if total == 0 or proven != total or unproven:
        raise ValueError("vacuous or incomplete equivalence proof")
    points = set(re.findall(r"^Presumably equivalent wires:.* -> (\S+)$", log, re.M))
    required = {"prf_valid", "prf_transient", "rf", "rf_map",
                "prf_rd.pv1", "prf_rd.pv2", "prf_rd.pv1_valid", "prf_rd.pv2_valid"}
    if not required <= points:
        raise ValueError(f"missing PRF state/output matches: {sorted(required - points)}")
    entries = sorted(int(match.group(1)) for point in points
                     if (match := re.fullmatch(r"prf_arr\[(\d+)\]", point)))
    if not entries or entries != list(range(entries[-1] + 1)):
        raise ValueError("missing or non-contiguous PRF data-state matches")
    return {"equivalence_cells": total, "proven_cells": proven,
            "unproven_cells": unproven, "matched_data_entries": len(entries),
            "matched_state_outputs": sorted(required)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-hdl", type=Path, required=True)
    parser.add_argument("--candidate-hdl", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=900,
                        help="per-XLEN proof timeout in seconds")
    args = parser.parse_args()
    roots = [args.baseline_hdl.resolve(), args.candidate_hdl.resolve()]
    # Paths are embedded into Yosys command language, not a shell.
    if any(any(c.isspace() or c in ';"' for c in str(root))
           for root in [*roots, args.output.resolve()]):
        raise ValueError("HDL/output paths must not contain whitespace, quotes or semicolons")
    args.output.mkdir(parents=True, exist_ok=True)
    hashes = [manifest(root) for root in roots]
    result = {"complete": False, "hdl_roots": list(map(str, roots)),
              "source_sha256": hashes, "cases": []}
    report = args.output / "results.json"
    report.write_text(json.dumps(result, indent=2) + "\n")
    blacklist = args.output.resolve() / "combinational_matches.txt"
    blacklist.write_text("\n".join(COMBINATIONAL_MATCHES) + "\n")
    for xlen in (32, 64):
        commands = []
        for label, root in zip(("gold", "gate"), roots):
            includes = " ".join(f"-I{root / path}" for path in
                                ("configs/default", "include", "include/npc", "include/dpic_mock"))
            defines = "-DSYNTHESIS" + (" -DRAPT_RV64" if xlen == 64 else "")
            commands.extend([
                f"read_slang --single-unit --allow-toplevel-iface-ports {defines} {includes} "
                f"--top rapt_prf {root / 'rapt_pkg.sv'} {root / 'backend/rapt_prf.sv'}",
                "hierarchy -check -top rapt_prf",
                "select -assert-none t:$check t:$assert t:$assume t:$cover",
                "proc", "memory_map", "opt -full", f"design -stash {label}"])
        commands.extend([
            "design -copy-from gold -as gold rapt_prf",
            "design -copy-from gate -as gate rapt_prf",
            f"equiv_make -blacklist {blacklist} gold gate equiv", "hierarchy -top equiv",
            # Establish the stated corresponding-state precondition explicitly.
            # Plain equiv_simple cannot prove independently arbitrary initial
            # Q values of non-reset data flops. All state/output points remain
            # obligations; final status rejects any unproven point.
            # Only register-state points may be induction hypotheses. Using
            # every common combinational name as a hypothesis can make a bad
            # implementation's precondition impossible (a vacuous proof).
            *PROOF_PASSES])
        script = args.output / f"rv{xlen}.ys"
        script.write_text(";\n".join(commands) + "\n")
        command = ["yosys", "-Q", "-T", "-m", "slang", "-s", str(script)]
        with (args.output / f"rv{xlen}.log").open("w") as log:
            run = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        if run.returncode:
            raise RuntimeError(f"RV{xlen} equivalence failed: {args.output / f'rv{xlen}.log'}")
        audit = audit_proof((args.output / f"rv{xlen}.log").read_text())
        if hashes != [manifest(root) for root in roots]:
            raise RuntimeError("source changed before recording a completed proof case")
        result["cases"].append({"xlen": xlen, "command": command, "proven": True,
                                "audit": audit,
                                "script_sha256": hashlib.sha256(script.read_bytes()).hexdigest()})
        report.write_text(json.dumps(result, indent=2) + "\n")
        print(f"PASS: RV{xlen} PRF corresponding-state equivalence", flush=True)
    if hashes != [manifest(root) for root in roots]:
        raise RuntimeError("source changed during equivalence checks")
    result["complete"] = True
    report.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
