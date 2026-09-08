#!/usr/bin/env python3
"""Prove dispatch admission and first-stop classification for arbitrary inputs."""
import hashlib
import json
from pathlib import Path
import subprocess
from rank_select_check import run_yosys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "verify/build/dispatch-admit"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / "hdl/rapt_pkg.sv", ROOT / "hdl/backend/rapt_dispatch_admit.sv",
               ROOT / "verify/formal/formal_dispatch_admit.sv"]
    results = {"yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
               "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
               "proofs": []}
    includes = f"-I{ROOT}/hdl/configs/default -I{ROOT}/hdl/include -I{ROOT}/hdl/include/npc"
    for width in [1, 2, 3, 4, 8]:
        command = (f"read_slang --single-unit --top formal_dispatch_admit "
                   f"-GWidth={width} {includes} {' '.join(map(str, sources))}; "
                   "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                   "prep -top formal_dispatch_admit; flatten; memory_map; opt; "
                   "sat -verify -prove correct 1 -set-def-inputs")
        output = run_yosys(command, OUTPUT / f"prove-{width}.log", 300)
        if "SAT proof finished - no model found: SUCCESS!" not in output:
            raise RuntimeError(f"missing proof success for width {width}")
        results["proofs"].append({"width": width, "contracts_proven": True})
        (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"PASS: dispatch admission width {width}", flush=True)


if __name__ == "__main__":
    main()
