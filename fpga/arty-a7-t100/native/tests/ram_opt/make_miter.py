#!/usr/bin/env python3
"""Connect both real generated peripherals and compare every output every cycle."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    out = args.directory.resolve()
    gold = json.loads((out / "gold.json").read_text())["modules"]["ram_gold"]
    gate = json.loads((out / "gate.json").read_text())["modules"]["ram_gate"]
    assert gold["ports"].keys() == gate["ports"].keys()
    ports = []; wires = []; mappings = {"gold": [], "gate": []}; checks = []; initial = []
    for name, value in gold["ports"].items():
        assert value["direction"] == gate["ports"][name]["direction"]
        assert len(value["bits"]) == len(gate["ports"][name]["bits"])
        safe = name.replace(".", "_")
        width = len(value["bits"])
        declaration = "wire " + ("[" + str(width - 1) + ":0] " if width > 1 else "")
        if value["direction"] == "input":
            signal = "i_" + safe
            ports.append("  input " + declaration + signal)
            initial.append("    dut." + signal + " = 0;")
            for side in mappings:
                mappings[side].append("    .\\" + name + " (" + signal + ")")
        else:
            assert value["direction"] == "output"
            ports.append("  output " + declaration + "o_" + safe)
            for side in mappings:
                signal = side + "_" + safe
                wires.append("  " + declaration + signal + ";")
                mappings[side].append("    .\\" + name + " (" + signal + ")")
            checks.append("(gold_" + safe + " !== gate_" + safe + ")")
            wires.append("  assign o_" + safe + " = gold_" + safe + ";")
    ports.append("  output wire mismatch")
    source = "module ram_opt_miter (\n" + ",\n".join(ports) + "\n);\n"
    source += "\n".join(wires) + "\n"
    for side in mappings:
        source += "  ram_" + side + " u_" + side + " (\n"
        source += ",\n".join(mappings[side]) + "\n  );\n"
    source += "  assign mismatch =\n      " + "\n      || ".join(checks) + ";\n"
    source += """  // Simulation-only related, nonzero initial memory state. Production INIT
  // remains unspecified. Warm resets below never repeat this initialization.
  function automatic logic [7:0] initial_byte(input int index);
    return 8'((index * 73) ^ (index >> 4) ^ 8'h5a);
  endfunction
  initial begin
    for (int index = 0; index < 8192; index++) u_gold.ram[index] = initial_byte(index);
    for (int row = 0; row < 2048; row++) begin
      for (int lane = 0; lane < 4; lane++)
        u_gate.ram[row][lane*8+:8] = initial_byte(row*4+lane);
    end
  end
endmodule
"""
    (out / "miter.sv").write_text(source)
    (out / "initial_inputs.inc").write_text("\n".join(initial) + "\n")
    (out / "miter-scope.json").write_text(json.dumps({
        "actual_peripheral_before_after_documented_scoped_passes": True,
        "compare_all_outputs_including_invalid_data_cycles": True,
        "simulation_initial_relation": "gold.ram[4*row+lane] == gate.ram[row][8*lane+:8]",
        "production_ram_reset_or_init_added": False,
        "universal_memory_initial_state_proof": False,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
