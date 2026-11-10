#!/usr/bin/env python3
"""Prove actual address bindings and address-FF retiming; check a watched-row invariant."""
import argparse
import collections
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def design(name, cells, inputs, outputs):
    ports = {n: {"direction": "input", "bits": b} for n,b in inputs.items()}
    ports.update({n: {"direction": "output", "bits": b} for n,b in outputs.items()})
    module = {"attributes": {"top": "1"}, "ports": ports, "cells": cells,
              "netnames": {n: {"hide_name": 0, "bits": v["bits"], "attributes": {}}
                           for n,v in ports.items()}}
    return {"modules": {name: module}}


def run(out, name, script, expected=0):
    path = out / (name + ".ys")
    path.write_text(script)
    cpus = sorted(os.sched_getaffinity(0))[:4]
    if not cpus:
        raise RuntimeError("no available CPUs")
    cpu_list = ",".join(map(str, cpus))
    command = ["timeout", "--signal=TERM", "--kill-after=2", "30s", "taskset", "-c", cpu_list,
               "nice", "-n", "5", "yosys", "-Q", "-T", "-s", str(path)]
    started = time.monotonic()
    with (out / (name + ".log")).open("w") as log:
        child = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    text = (out / (name + ".log")).read_text()
    passed = child.returncode == expected
    if expected:
        passed = passed and "proof did fail" in text and "model found" in text
    else:
        passed = passed and ("SUCCESS" in text or "Induction step proven" in text)
    record = {"command": command, "exit": child.returncode, "expected_exit": expected,
              "elapsed_seconds": time.monotonic() - started, "pass": passed}
    print(name, json.dumps(record))
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", type=Path, required=True)
    parser.add_argument("--normalized", type=Path, required=True)
    parser.add_argument("--scope-result", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    original = json.loads(args.original.read_text())["modules"]["rapt_arty_native_top"]
    normalized = json.loads(args.normalized.read_text())["modules"]["rapt_arty_native_top"]
    memory = "u_chip.u_chip.u_backend.u_flash.ram"
    old = original["cells"][memory]; new = normalized["cells"][memory]
    p = new["parameters"]; c = new["connections"]
    assert int(p["WIDTH"], 2) == 32 and int(p["SIZE"], 2) == 2048
    assert p["RD_CLK_ENABLE"] == "1" and p["RD_TRANSPARENCY_MASK"] == "1"
    assert c["RD_CLK"] == c["WR_CLK"] and c["RD_EN"] == ["1"]
    assert c["RD_ARST"] == ["0"] and c["RD_SRST"] == ["0"]
    assert set(p["INIT"]) == {"x"} and len(p["INIT"]) == 65536
    assert old["parameters"]["RD_CLK_ENABLE"] == "0000"
    assert old["parameters"]["WR_CLK_ENABLE"] == "1111"
    assert old["parameters"]["WR_CLK_POLARITY"] == "1111"
    assert old["connections"]["RD_EN"] == ["1"] * 4
    assert old["connections"]["RD_ARST"] == ["0"] * 4
    assert old["connections"]["RD_SRST"] == ["0"] * 4
    assert set(old["parameters"]["INIT"]) == {"x"}
    assert p["WR_CLK_ENABLE"] == "1" and p["WR_CLK_POLARITY"] == "1"
    assert p["RD_CLK_POLARITY"] == "1"
    for lane in range(4):
        assert len(set(c["WR_EN"][lane*8:lane*8+8])) == 1
    addresses = set(old["connections"]["RD_ADDR"] + old["connections"]["WR_ADDR"])
    adds = {}
    for name, cell in original["cells"].items():
        if cell["type"] == "$add" and addresses.intersection(cell["connections"]["Y"]):
            adds[name] = cell
    assert len(adds) == 3
    row_wire = original["netnames"]["u_chip.u_chip.u_backend.u_flash.addr_q"]["bits"][2:13]
    for cell in adds.values():
        assert cell["connections"]["A"] == ["0", "0"] + row_wire
    model = design("actual_addresses", adds, {"row": row_wire},
                   {"rd": old["connections"]["RD_ADDR"],
                    "wr": old["connections"]["WR_ADDR"]})
    (out / "addresses.json").write_text(json.dumps(model) + "\n")
    prop = """module address_check(input wire [10:0] row);
  wire [51:0] rd, wr;
  actual_addresses u_actual(.row(row), .rd(rd), .wr(wr));
  always_comb begin
"""
    for port in range(4):
        # These bindings are asserted against the actual port expressions, not
        # assumed from equal RD/WR port ordinals (their orders are opposite).
        prop += f"    assert(rd[{port*13}+:13] == {{row, 2'd{3-port}}});\n"
        prop += f"    assert(wr[{port*13}+:13] == {{row, 2'd{port}}});\n"
    prop += "  end\nendmodule\n"
    (out / "addresses.sv").write_text(prop)
    address_script = f"read_json {out}/addresses.json\n"
    address_script += f"read_verilog -formal -sv {out}/addresses.sv\n"
    address_script += "prep -top address_check -flatten\nchformal -lower\nsat -verify -prove-asserts -show row\n"
    results = {"actual_addresses": run(out, "addresses", address_script)}

    # Check data/byte-enable identities through retained wire aliases, even if
    # JSON numeric bit identifiers were reassigned by the writer.
    def aliases(module):
        lookup = collections.defaultdict(set)
        for name, net in module["netnames"].items():
            for index, bit in enumerate(net["bits"]):
                if isinstance(bit, int): lookup[bit].add((name, index))
        return lookup
    a_alias = aliases(original); b_alias = aliases(normalized)
    def equal_bit(a, b):
        return (a == b if isinstance(a, str) or isinstance(b, str)
                else bool(a_alias[a] & b_alias[b]))
    for lane in range(4):
        for bit in range(8):
            assert equal_bit(old["connections"]["WR_DATA"][lane*8+bit], c["WR_DATA"][lane*8+bit])
            assert equal_bit(old["connections"]["WR_EN"][lane*8+bit], c["WR_EN"][lane*8+bit])
            assert equal_bit(old["connections"]["RD_DATA"][(3-lane)*8+bit], c["RD_DATA"][lane*8+bit])
    ff = [(n, x) for n,x in normalized["cells"].items()
          if x["type"].startswith("$") and set(c["WR_ADDR"]) <= set(x["connections"].get("Q", []))]
    assert len(ff) == 1
    ff_name, ff_cell = ff[0]
    assert ff_cell["type"] == "$sdffe" and c["WR_ADDR"] == ff_cell["connections"]["Q"][2:13]
    assert ff_cell["connections"]["CLK"] == c["RD_CLK"]
    scope = json.loads(args.scope_result.read_text())
    helpers = {n: normalized["cells"][n] for n in scope["added_cells"]}
    assert len(helpers) == 2 and all(x["type"] == "$mux" for x in helpers.values())
    cells = copy.deepcopy(helpers); cells[ff_name] = copy.deepcopy(ff_cell)
    driven = {b for x in cells.values() for n,v in x["connections"].items()
              if x["port_directions"].get(n) == "output" for b in v if isinstance(b, int)}
    boundary = {b for x in cells.values() for n,v in x["connections"].items()
                if x["port_directions"].get(n) == "input" for b in v
                if isinstance(b, int) and b not in driven}
    inputs = {"p" + str(b): [b] for b in sorted(boundary)}
    circuit = design("actual_address_ff", cells, inputs,
                     {"current_row": c["WR_ADDR"], "next_row": c["RD_ADDR"]})
    (out / "address-ff.json").write_text(json.dumps(circuit) + "\n")
    wrapper = "module address_clock_check(\n"
    wrapper += ",\n".join("  input wire " + n for n in inputs) + "\n);\n"
    wrapper += "  wire [10:0] current_row, next_row;\n  reg [10:0] captured;\n"
    wrapper += "  reg valid = 0;\n  actual_address_ff u_actual(\n"
    wrapper += ",\n".join("    ." + n + "(" + n + ")" for n in inputs)
    wrapper += ",\n    .current_row(current_row), .next_row(next_row)\n  );\n"
    clock = "p" + str(c["RD_CLK"][0])
    wrapper += f"  always @(posedge {clock}) begin captured <= next_row; valid <= 1; end\n"
    wrapper += "  always_comb if (valid) assert(captured == current_row);\nendmodule\n"
    (out / "address-ff.sv").write_text(wrapper)
    script = f"read_json {out}/address-ff.json\nread_verilog -formal -sv {out}/address-ff.sv\n"
    script += "prep -top address_clock_check -flatten\ndffunmap\nopt_clean\n"
    script += "chformal -lower\nsat -verify -seq 2 -tempinduct -maxsteps 8 -prove-asserts\n"
    results["actual_address_ff_retime"] = run(out, "address-ff", script)

    # Symbolic watched-row abstraction: the selected row is any of the2048
    # actual rows; initial contents are arbitrary but related, never forced0.
    # Address/data/WE identities above justify the abstraction. This is not an
    # LEC of the entire CPU, physical RAM primitive, or other external logic.
    state = """module watched_row_check #(
    parameter BadLane = 0, parameter NoForward = 0
) (
    input wire clock,
    input wire [10:0] read_next_row,
    input wire [10:0] write_row,
    input wire [3:0] byte_we,
    input wire [31:0] write_data
);
  (* anyconst *) reg [10:0] watched_row;
  reg [31:0] gold_word, gate_word, gate_read;
  reg [10:0] sampled_row;
  reg valid = 0;
  always_comb if ($initstate) assume(gold_word == gate_word);
  always @(posedge clock) begin
    valid <= 1;
    sampled_row <= read_next_row;
    for (integer port = 0; port < 4; port = port + 1) begin
      if (write_row == watched_row && byte_we[port])
        gold_word[8*port+:8] <= write_data[8*port+:8];
    end
    for (integer lane = 0; lane < 4; lane = lane + 1) begin
      if (write_row == watched_row && byte_we[BadLane ? (lane ^ 1) : lane])
        gate_word[8*lane+:8] <= write_data[8*lane+:8];
    end
    gate_read <= gate_word;
    if (!NoForward && write_row == read_next_row) begin
      for (integer lane = 0; lane < 4; lane = lane + 1)
        if (byte_we[lane]) gate_read[8*lane+:8] <= write_data[8*lane+:8];
    end
  end
  always_comb begin
    assert(gold_word == gate_word);
    if (valid && sampled_row == watched_row) assert(gate_read == gold_word);
  end
endmodule
"""
    (out / "watched-row.sv").write_text(state)
    for name, parameter in [("watched-row", ""), ("bad-lane", "BadLane"),
                            ("missing-forward", "NoForward")]:
        script = f"read_verilog -formal -sv {out}/watched-row.sv\n"
        if parameter: script += f"chparam -set {parameter} 1 watched_row_check\n"
        script += "prep -top watched_row_check -flatten\nopt_clean\n"
        script += "chformal -lower\nsat -verify -seq 2 -tempinduct -maxsteps 8 -set-assumes -prove-asserts\n"
        results[name] = run(out, name, script, 1 if parameter else 0)
    result = {"all_pass": all(r["pass"] for r in results.values()), "proofs": results,
              "input_sha256": {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in [args.original, args.normalized, args.scope_result]},
              "scope": ("Actual13-bit lane addresses and actual clock/CE/SRST address cone; "
                        "arbitrary related watched-row state transition under verified bijective "
                        "mapping. Not full-chip or physical-primitive LEC."),
              "production_memory_init_or_clear_added": False}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["all_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
