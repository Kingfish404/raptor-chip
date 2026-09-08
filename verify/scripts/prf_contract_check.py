#!/usr/bin/env python3
"""Native elaboration of legal PRF shapes and rejection of invalid contracts."""
import argparse
import json
from pathlib import Path
import subprocess

from prf_equivalence import manifest

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hdl-root", type=Path, default=ROOT / "hdl")
    parser.add_argument("--output", type=Path, default=ROOT / "verify/build/prf-contracts")
    args = parser.parse_args()
    hdl, out = args.hdl_root.resolve(), args.output.resolve()
    if any(any(c.isspace() or c in ';"' for c in str(p)) for p in (hdl, out)):
        raise ValueError("HDL/output paths must not contain whitespace, quotes or semicolons")
    out.mkdir(parents=True, exist_ok=True)
    hashes = manifest(hdl)
    result = {"complete": False, "hdl_root": str(hdl), "source_sha256": hashes, "cases": []}
    report = out / "results.json"
    report.write_text(json.dumps(result, indent=2) + "\n")
    fixture = out / "prf_type_contract.sv"
    fixture.write_text('''`include "rapt.svh"
`include "rapt_if.svh"
module prf_type_contract #(
    parameter int ResultBits = `RAPT_XLEN,
    parameter int DestBits = `RAPT_PHY_LEN,
    parameter int ValidBits = 1
);
  typedef struct packed {
    logic [ValidBits-1:0] valid;
    logic [4:0] rd;
    logic [DestBits-1:0] prd;
    logic [ResultBits-1:0] result;
  } completion_t;
  completion_t completion[rapt_pkg::CoreConfig.completion_ports];
  exu_prf_if reads();
  rou_cmu_if commits();
  cmu_bcast_if bcast();
  rapt_prf #(.CompletionT(completion_t)) dut (
      .clock(1'b0), .reset(1'b0), .completion, .prf_rd(reads),
      .rou_cmu(commits), .cmu_bcast(bcast),
      .map_snapshot('{default:'0}), .rat_snapshot('{default:'0}),
      .rf(), .rf_map(), .dbg_we_i(1'b0), .dbg_addr_i('0), .dbg_wdata_i('0), .dbg_rdata_o()
  );
endmodule
''')
    cases = [("rv32", "rapt_prf", "", None),
             ("rv64", "rapt_prf", "-DRAPT_RV64", None),
             ("non-power-of-two", "rapt_prf", "-GPNUM=96", None),
             ("completion32", "rapt_prf", "-GNumCompletions=32", None),
             ("typed-legal", "prf_type_contract", "", None)]
    for name, parameter in (("no-completions", "NumCompletions=0"),
                            ("no-read-slots", "RenameWidth=0"),
                            ("no-commit-slots", "CommitWidth=0"),
                            ("too-few-physical", "PNUM=16"),
                            ("short-address", "PLEN=6"),
                            ("no-arch-regs", "RNUM=0"),
                            ("oversized-arch-view", "RNUM=33")):
        cases.append((name, "rapt_prf", f"-G{parameter}", "storage/port shape"))
    for name, parameter in (("read-interface", "RenameWidth=1"),
                            ("commit-interface", "CommitWidth=1")):
        cases.append((name, "rapt_prf", f"-G{parameter}", "interface dimensions"))
    for name, parameter in (("result-type", "ResultBits=33"),
                            ("dest-type", "DestBits=8"),
                            ("valid-type", "ValidBits=2")):
        cases.append((name, "prf_type_contract", f"-G{parameter}", "completion field widths"))
    includes = " ".join(f"-I{hdl / p}" for p in
                        ("configs/default", "include", "include/npc", "include/dpic_mock"))
    for name, top, options, reason in cases:
        source = f"{hdl / 'rapt_pkg.sv'} {hdl / 'backend/rapt_prf.sv'}"
        if top == "prf_type_contract":
            source += f" {fixture}"
        command = ["yosys", "-Q", "-T", "-m", "slang", "-p",
                   f"read_slang --single-unit --allow-toplevel-iface-ports -DSYNTHESIS "
                   f"{includes} {options} --top {top} {source}; hierarchy -check -top {top}; "
                   "select -assert-none t:$check t:$assert t:$assume t:$cover"]
        run = subprocess.run(command, capture_output=True, text=True, timeout=60)
        log = run.stdout + run.stderr
        (out / f"{name}.log").write_text(log)
        if reason:
            if run.returncode == 0 or f"Invalid rapt_prf configuration: {reason}" not in log:
                raise RuntimeError(f"{name}: expected contract rejection; inspect {out / f'{name}.log'}")
        elif run.returncode:
            raise RuntimeError(f"{name}: legal configuration failed; inspect {out / f'{name}.log'}")
        result["cases"].append({"name": name, "command": command,
                                "rejected": bool(reason), "reason": reason})
        print(f"PASS: {name}" + (f" rejected ({reason})" if reason else " elaborates"), flush=True)
    if hashes != manifest(hdl):
        raise RuntimeError("HDL changed during contract checks")
    result["complete"] = True
    report.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
