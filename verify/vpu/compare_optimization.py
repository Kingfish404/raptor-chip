#!/usr/bin/env python3
"""Compare identical, passing VPU workloads with operand read elimination off/on."""
import argparse
import json
from pathlib import Path
import re


def read_run(path):
    lines = (path / "run.log").read_text().splitlines()
    passed = [line for line in lines if line.startswith("PASS top ")]
    assert len(passed) == 1, f"Missing or ambiguous PASS: {path}"
    return dict(re.findall(r"(\w+)=([0-9a-f]+)", passed[0])), json.loads((path / "sources.json").read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("optimized", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    old, om = read_run(args.baseline)
    new, nm = read_run(args.optimized)
    assert om.get("suite", "full") == nm.get("suite", "full") == "full", "Optimization requires full suite"
    assert om["sources"] == nm["sources"], "Different source snapshots"
    assert om["verilator"] == nm["verilator"], "Different simulation tools"
    oc, nc = dict(om["configuration"]), dict(nm["configuration"])
    assert oc.pop("OptimizeOperandReads") == 0 and nc.pop("OptimizeOperandReads") == 1
    assert oc == nc, "Different hardware/reference configuration"
    for key in ("workload_hash", "commands", "arithmetic", "active_elements", "seed", "spike_steps"):
        assert old[key] == new[key], f"Workload/validation differs: {key}"
    if oc["Spike"]:
        assert json.loads((args.baseline / "reference.json").read_text()) == json.loads((args.optimized / "reference.json").read_text())
        assert int(old["spike_steps"]) > 0
    before, after = int(old["command_latency_cycles"]), int(new["command_latency_cycles"])
    assert after < before, "Expected redundant-read optimization did not reduce cycles"
    result = dict(configuration=oc, workload_hash=old["workload_hash"],
                  arithmetic_instructions=int(old["arithmetic"]),
                  baseline_cycles=before, optimized_cycles=after,
                  reduction_percent=100*(before-after)/before,
                  scope="Sum of arithmetic command acceptance-to-response latency, including fixed test authorization delays; not application IPC or physical PPA",
                  source_manifest=om["sources"])
    args.output.write_text(json.dumps(result, indent=2)+"\n")
    print(f"PASS optimization {before} -> {after} cycles ({result['reduction_percent']:.3f}% reduction); workload={old['workload_hash']}")


if __name__ == "__main__":
    main()
