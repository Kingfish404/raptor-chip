#!/usr/bin/env python3
"""XC7-map the exact normalized local RAM cell, retaining all original parameters."""
import argparse
import collections
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    source = args.input.resolve(); out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    mod = json.loads(source.read_text())["modules"]["rapt_arty_native_top"]
    cell = copy.deepcopy(mod["cells"]["u_chip.u_chip.u_backend.u_flash.ram"])
    c = cell["connections"]
    assert c["RD_CLK"] == c["WR_CLK"] and c["RD_EN"] == ["1"]
    assert c["RD_ARST"] == c["RD_SRST"] == ["0"]
    ports = {
        "clock": {"direction": "input", "bits": c["RD_CLK"]},
        "read_addr": {"direction": "input", "bits": c["RD_ADDR"]},
        "write_addr": {"direction": "input", "bits": c["WR_ADDR"]},
        "write_data": {"direction": "input", "bits": c["WR_DATA"]},
        "byte_we": {"direction": "input", "bits": list(dict.fromkeys(c["WR_EN"]))},
        "read_data": {"direction": "output", "bits": c["RD_DATA"]},
    }
    assert len(ports["byte_we"]["bits"]) == 4
    module = {"attributes": {"top": "1"}, "ports": ports,
              "cells": {"actual_local_ram": cell}, "netnames": {
                  n: {"hide_name": 0, "bits": v["bits"], "attributes": {}}
                  for n,v in ports.items()}}
    (out / "actual-ram.json").write_text(json.dumps({"modules": {"native_ram_map": module}}) + "\n")
    script = "read_json actual-ram.json\nhierarchy -check -top native_ram_map\n"
    script += "synth_xilinx -family xc7 -top native_ram_map -noiopad -noclkbuf\n"
    script += "check -assert\nstat -tech xilinx\nwrite_json mapped.json\nwrite_verilog mapped.v\n"
    (out / "map.ys").write_text(script)
    cpus = sorted(os.sched_getaffinity(0))[:4]
    if not cpus:
        raise RuntimeError("no available CPUs")
    cpu_list = ",".join(map(str, cpus))
    command = ["timeout", "--signal=TERM", "--kill-after=3", "60s", "taskset", "-c", cpu_list,
               "nice", "-n", "5", "yosys", "-Q", "-T", "-s", "map.ys"]
    (out / "control.json").write_text(json.dumps({"command": command, "cwd": str(out),
        "input_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "all_memory_cell_parameters_preserved": True, "no_no_rw_check": True}, indent=2) + "\n")
    started = time.monotonic()
    with (out / "console.log").open("w") as log:
        child = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT)
    result = {"exit": child.returncode, "elapsed_seconds": time.monotonic() - started,
              "no_vivado_or_hardware": True}
    if child.returncode == 0:
        mapped = json.loads((out / "mapped.json").read_text())["modules"]["native_ram_map"]
        result["cells"] = collections.Counter(c["type"] for c in mapped["cells"].values())
        assert result["cells"]["RAMB36E1"] == 2
        assert not any(n.startswith("$mem") for n in result["cells"])
    (out / "finish.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return child.returncode


if __name__ == "__main__":
    raise SystemExit(main())
