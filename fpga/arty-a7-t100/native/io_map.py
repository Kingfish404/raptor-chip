#!/usr/bin/env python3
"""Verify that the actual full-chip mapping retains the physical DS/DIAG pad driver."""

import argparse
import json
from pathlib import Path


def audit(design):
    module = design["modules"]["rapt_arty_native_top"]
    port = module["ports"]["flash_dqs"]
    if port["direction"] != "inout" or len(port["bits"]) != 1:
        raise ValueError("DS/DIAG must retain one real bidirectional top-level port")
    pad = port["bits"][0]
    nets, cells = module["netnames"], module["cells"]
    data = nets["u_chip.diag"]["bits"][0]
    enable = nets["u_chip.diag_oe"]["bits"][0]
    if not isinstance(data, int) or not isinstance(enable, int):
        raise ValueError("real DIAG data/OE was replaced by a constant")
    drivers = {}
    for name, cell in cells.items():
        for pin, direction in cell["port_directions"].items():
            if direction == "output":
                for bit in cell["connections"][pin]:
                    if isinstance(bit, int):
                        drivers.setdefault(bit, []).append((name, pin))
    pad_drivers = drivers.get(pad, [])
    if len(pad_drivers) != 1:
        raise ValueError(f"DS/DIAG pad must retain exactly one chip driver: {pad_drivers}")
    name, output = pad_drivers[0]
    cell = cells[name]
    pins = cell["connections"]
    if cell["type"] in {"$tribuf", "$_TBUF_"} and output == "Y":
        data_pin, enable_pin, active = "A", "EN" if cell["type"] == "$tribuf" else "E", 1
    elif cell["type"] == "IOBUF" and output == "IO":
        data_pin, enable_pin, active = "I", "T", 0
    else:
        raise ValueError(f"DS/DIAG drive is not a faithful tri-state boundary: {cell['type']}")
    if pins[data_pin] != [data]:
        raise ValueError("DS/DIAG pad data no longer comes from the real chip DIAG signal")

    def evaluate(bit, level, seen):
        if bit == enable:
            return level
        if bit in {"0", "1"}:
            return int(bit)
        if bit in seen or len(drivers.get(bit, [])) != 1:
            raise ValueError("OE path is not a single combinational function of actual pad OE")
        driver, _ = drivers[bit][0]
        logic = cells[driver]
        connections = logic["connections"]
        if logic["type"].startswith("LUT"):
            width = int(logic["type"][3:])
            index = sum(evaluate(connections[f"I{i}"][0], level, seen | {bit}) << i
                        for i in range(width))
            return (int(logic["parameters"]["INIT"], 2) >> index) & 1
        if logic["type"] in {"BUF", "INV"}:
            value = evaluate(connections["I"][0], level, seen | {bit})
            return value ^ int(logic["type"] == "INV")
        raise ValueError("unsupported mapped pad-OE logic: " + logic["type"])

    for level in (0, 1):
        output_enable = int(evaluate(pins[enable_pin][0], level, set()) == active)
        if output_enable != level:
            raise ValueError("mapped physical enable does not follow the real chip pad OE")
    first = cells["native_rx_ds_0"]["connections"]["D"][0]

    def reaches(bit, seen):
        if bit == pad:
            return True
        if bit in seen or len(drivers.get(bit, [])) != 1:
            return False
        driver, _ = drivers[bit][0]
        logic = cells[driver]
        if logic["type"].startswith("FD"):
            return False
        inputs = [b for pin, direction in logic["port_directions"].items()
                  if direction == "input" for b in logic["connections"][pin]]
        return any(reaches(b, seen | {bit}) for b in inputs)

    if not reaches(first, set()):
        raise ValueError("DS/DIAG input no longer reaches the first real DS capture FF")
    return {"pass": True, "port": "flash_dqs", "direction": "inout", "port_bit": pad,
            "driver": name, "driver_type": cell["type"], "connections": pins,
            "actual_diag_data_bit": data, "actual_diag_oe_bit": enable,
            "driver_deleted_or_forced": False, "enable_truth_table": [0, 1],
            "receiver_first_D_bit": first, "receiver_input_connectivity": True,
            "physical_oe_inactive_qualification": "separate formal/simulation and routed review"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    receipt = audit(json.loads(args.input.read_text()))
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print("NATIVE_IO_MAP_PASS: real DIAG data/OE retained and DS capture path connected")


if __name__ == "__main__":
    main()
