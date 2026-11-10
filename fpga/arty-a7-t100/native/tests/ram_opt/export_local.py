#!/usr/bin/env python3
"""Export the frozen complete AXI Flash module before/after RAM normalization."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    helper = repo / "fpga/common/scripts/rtl_pack.py"
    spec = importlib.util.spec_from_file_location("ram_rtl_pack", helper)
    pack = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pack)
    inputs = pack.rtl_sources(repo, io25=True)
    flags = ["--single-unit", "--unroll-limit=100000", "--allow-toplevel-iface-ports",
             "-DSYNTHESIS", "-DRAPT_FPGA_DSP=1", "-DRAPT_FPGA_LUTRAM=1"]
    flags += ["-I" + str(p) for p in pack.include_dirs(repo, repo / "rtl/configs/chip32-small")]
    parameters = {"CoreClockHz": 1000, "HalfPeriod": 8, "PowerupCycles": 2,
                  "ResetCycles": 2, "RecoveryCycles": 2, "PollCycles": 64}
    options = " ".join("-G " + k + "=" + str(v) for k,v in parameters.items())
    script = "read_slang " + " ".join(flags) + " --top rapt_axi_flash " + options
    script += " " + " ".join(map(str, inputs)) + "\n"
    script += "hierarchy -check -top rapt_axi_flash\nproc\nflatten\nmemory_collect\nopt\n"
    script += "bwmuxmap\ntechmap t:$shiftx\nopt\ncheck -assert\n"
    script += "rename -top ram_gold\nwrite_rtlil gold.il\nwrite_json gold.json\n"
    script += "write_verilog gold.v\nrename -top ram_gate\n"
    script += "select -assert-count 1 ram_gate/c:ram\n"
    script += "select -assert-count 3 ram_gate/c:ram %ci2 t:$add %i\n"
    script += "opt_expr -fine ram_gate/c:ram %ci2 t:$add %i\nopt_clean\n"
    script += "memory_share -nosat ram_gate/c:ram\nopt_mem_widen ram_gate/c:ram\n"
    script += "memory_dff ram_gate/c:ram\ncheck -assert\n"
    script += "write_rtlil gate.il\nwrite_json gate.json\nwrite_verilog gate.v\n"
    (out / "export.ys").write_text(script)
    cpus = sorted(os.sched_getaffinity(0))[:4]
    if not cpus:
        raise RuntimeError("no available CPUs")
    cpu_list = ",".join(map(str, cpus))
    command = ["timeout", "--signal=TERM", "--kill-after=3", "60s", "taskset", "-c", cpu_list,
               "nice", "-n", "5", "yosys", "-Q", "-T", "-m", "slang", "-s", "export.ys"]
    record = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "command": command, "cwd": str(out), "parameters": parameters,
              "scope": "complete actual peripheral only; no CPU or FPGA implementation",
              "sources": {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in inputs}}
    source = repo / "synth/configs/pin-limited/rtl/rapt_axi_flash.sv"
    if record["sources"][str(source.relative_to(repo))] != (
        "2cfb7b6ad95b7314a76b12d829d04d5cba5576c0e7647ba39e89a5cd40f02ccf"
    ):
        raise RuntimeError("frozen peripheral source hash differs")
    (out / "control.json").write_text(json.dumps(record, indent=2) + "\n")
    started = time.monotonic()
    with (out / "console.log").open("w") as log:
        child = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT)
    result = {"exit": child.returncode, "elapsed_seconds": time.monotonic() - started,
              "no_vivado_or_hardware": True}
    if child.returncode == 0:
        mod = json.loads((out / "gate.json").read_text())["modules"]["ram_gate"]
        params = mod["cells"]["ram"]["parameters"]
        result["memory"] = {k: params[k] for k in ("WIDTH", "SIZE", "RD_PORTS", "WR_PORTS",
                                                     "RD_CLK_ENABLE", "RD_TRANSPARENCY_MASK")}
    (out / "finish.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return child.returncode


if __name__ == "__main__":
    raise SystemExit(main())
