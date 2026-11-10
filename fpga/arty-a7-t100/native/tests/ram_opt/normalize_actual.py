#!/usr/bin/env python3
"""Normalize only the actual local RAM address cone and audit all other cells."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--module", default="rapt_arty_native_top")
    parser.add_argument("--memory", default="u_chip.u_chip.u_backend.u_flash.ram")
    args = parser.parse_args()
    source = args.input.resolve(); out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    memory = args.module + "/c:" + args.memory
    addresses = memory + " %ci2 t:$add %i"
    script = "read_rtlil " + str(source) + "\nwrite_json original.json\n"
    script += "select -assert-count 1 " + memory + "\n"
    script += "select -assert-count 3 " + addresses + "\n"
    script += "opt_expr -fine " + addresses + "\nopt_clean\n"
    for command in ["memory_share -nosat", "opt_mem_widen", "memory_dff"]:
        script += command + " " + memory + "\n"
    script += "write_rtlil normalized.il\nwrite_json normalized.json\n"
    (out / "normalize.ys").write_text(script)
    cpus = sorted(os.sched_getaffinity(0))[:4]
    if not cpus:
        raise RuntimeError("no available CPUs")
    cpu_list = ",".join(map(str, cpus))
    command = ["timeout", "--signal=TERM", "--kill-after=3", "60s", "taskset", "-c", cpu_list,
               "nice", "-n", "5", "yosys", "-Q", "-T", "-s", "normalize.ys"]
    control = {"command": command, "cwd": str(out),
               "input_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
               "opt_expr_scope": "exactly3 direct RAM address adders",
               "opt_clean_scope": "global dead-code and alias cleanup",
               "memory_pass_scope": memory, "no_no_rw_check": True,
               "cell_audit": "Exact RTLIL statements per named cell; ignore statement ordering only"}
    (out / "control.json").write_text(json.dumps(control, indent=2) + "\n")
    started = time.monotonic()
    with (out / "console.log").open("w") as log:
        child = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT)
    result = {"exit": child.returncode, "elapsed_seconds": time.monotonic() - started,
              "no_vivado_or_hardware": True}
    if child.returncode == 0:
        def cells(path):
            return {m.group(1): sorted(m.group(0).splitlines()) for m in re.finditer(
                r"^  cell [^\n]+ (\S+)\n.*?^  end$", path.read_text(), re.M | re.S)}
        old = cells(source); new = cells(out / "normalized.il")
        result["changed_cells"] = [n for n in old if n in new and old[n] != new[n]]
        result["removed_cells"] = sorted(set(old) - set(new))
        result["added_cells"] = sorted(set(new) - set(old))
        if result["changed_cells"] != ["\\" + args.memory]:
            raise RuntimeError("non-memory pre-existing cell changed")
        if len(result["removed_cells"]) != 3 or len(result["added_cells"]) != 2:
            raise RuntimeError("unexpected address cone change count")
        mod = json.loads((out / "normalized.json").read_text())["modules"][args.module]
        params = mod["cells"][args.memory]["parameters"]
        result["memory"] = {k: params[k] for k in ("WIDTH", "SIZE", "RD_PORTS", "WR_PORTS",
                                                   "RD_CLK_ENABLE", "RD_TRANSPARENCY_MASK")}
    (out / "finish.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return child.returncode


if __name__ == "__main__":
    raise SystemExit(main())
