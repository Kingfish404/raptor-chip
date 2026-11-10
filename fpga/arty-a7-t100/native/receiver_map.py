#!/usr/bin/env python3
"""Retain and audit the actual mapped oversampling receiver; fail on topology changes."""

import argparse
import json
from pathlib import Path

TOP = "rapt_arty_native_top"
FLOPS = {"FDRE", "FDCE", "FDSE", "FDPE"}


def audit(design):
    module = design["modules"][TOP]
    cells, nets = module["cells"], module["netnames"]

    def net(suffix, width):
        matches = [(name, data["bits"]) for name, data in nets.items()
                   if name.endswith("u_frame." + suffix)]
        if len(matches) != 1 or len(matches[0][1]) != width:
            raise ValueError(f"expected one {width}-bit frame net {suffix}, got {matches}")
        return matches[0]

    drivers = {}
    for name, cell in cells.items():
        for port, direction in cell["port_directions"].items():
            if direction == "output":
                for bit in cell["connections"][port]:
                    if isinstance(bit, int):
                        if bit in drivers:
                            raise ValueError(f"multiple drivers on mapped bit {bit}")
                        drivers[bit] = (name, port)

    def capture(bit):
        name, port = drivers[bit]
        cell = cells[name]
        if cell["type"] not in FLOPS or port != "Q":
            raise ValueError(f"capture bit {bit} is {cell['type']}.{port}, not an actual FF")
        if cell.get("parameters", {}).get("IS_C_INVERTED", "0").strip("0"):
            raise ValueError(f"capture FF {name} has inverted clock")
        return name, cell

    names = {}
    for signal, width in (("ds_sync_q", 4), ("dq_meta_q", 8), ("dq_sync_q", 8),
                          ("ds_edge", 1), ("sample_ds", 1), ("data_o", 128)):
        names[signal] = net(signal, width)
    ds, meta, sync = [names[s][1] for s in ("ds_sync_q", "dq_meta_q", "dq_sync_q")]
    all_bits = ds + meta + sync
    if len(set(all_bits)) != 20:
        raise ValueError("receiver sampling stages were merged")
    captures = [capture(bit) for bit in all_bits]
    if len({name for name, _ in captures}) != 20:
        raise ValueError("receiver does not contain twenty distinct FF cells")
    clock_cells = [c for name, c in cells.items() if name == "u_clocks"]
    if len(clock_cells) != 1:
        raise ValueError("native clock boundary must be one explicit u_clocks cell")
    clock = clock_cells[0]["connections"]["core_clock_o"]
    for name, cell in captures:
        if cell["connections"]["C"] != clock:
            raise ValueError(f"{name} does not use the exact common core clock")
    for stage in range(1, 4):
        if capture(ds[stage])[1]["connections"]["D"] != [ds[stage - 1]]:
            raise ValueError(f"DS stage {stage} lost its direct previous-stage connection")
    for lane in range(8):
        if capture(sync[lane])[1]["connections"]["D"] != [meta[lane]]:
            raise ValueError(f"DQ lane {lane} lost its direct two-stage connection")

    def evaluate(bit, values, seen):
        if bit in values:
            return values[bit]
        if bit in {"0", "1"}:
            return int(bit)
        if bit in seen or bit not in drivers:
            raise ValueError("detector depends on an unexpected input or sequential path")
        name, port = drivers[bit]
        cell = cells[name]
        kind, connections = cell["type"], cell["connections"]
        if kind.startswith("LUT") and kind[3:].isdigit() and port == "O":
            index = 0
            for lane in range(int(kind[3:])):
                index |= evaluate(connections[f"I{lane}"][0], values, seen | {bit}) << lane
            return (int(cell["parameters"]["INIT"], 2) >> index) & 1
        if kind in {"BUF", "IBUF"} and port == "O":
            return evaluate(connections["I"][0], values, seen | {bit})
        if kind == "INV" and port == "O":
            return 1 ^ evaluate(connections["I"][0], values, seen | {bit})
        raise ValueError(f"unsupported late-DS detector cell {name}: {kind}.{port}")

    for older in range(2):
        for newer in range(2):
            actual = evaluate(names["ds_edge"][1][0], {ds[3]: older, ds[2]: newer}, set())
            if actual != older ^ newer:
                raise ValueError("late DS detector is not DS[3] XOR DS[2]")

    def reaches(bit, wanted, seen):
        if bit == wanted:
            return True
        if bit in seen or bit not in drivers:
            return False
        name, _ = drivers[bit]
        cell = cells[name]
        if cell["type"] in FLOPS:
            return False
        inputs = [b for p, d in cell["port_directions"].items() if d == "input"
                  for b in cell["connections"][p]]
        return any(reaches(b, wanted, seen | {bit}) for b in inputs)

    sample = names["sample_ds"][1][0]
    if not reaches(sample, names["ds_edge"][1][0], set()):
        raise ValueError("sample selector no longer depends on the late DS detector")
    data_cells = []
    for index, bit in enumerate(names["data_o"][1]):
        name, cell = capture(bit)
        if not reaches(cell["connections"]["D"][0], sync[index % 8], set()):
            raise ValueError(f"sampled data bit {index} does not select matching DQ lane")
        inputs = cell["connections"]["D"] + cell["connections"].get("CE", [])
        if not any(reaches(b, sample, set()) for b in inputs):
            raise ValueError(f"sampled data bit {index} lost its DS selector")
        data_cells.append(name)

    logic_cells = {}
    for signal in ("ds_edge", "sample_ds"):
        old_name, _ = drivers[names[signal][1][0]]
        cell = cells.pop(old_name)
        new_name = "native_rx_" + signal
        cell.setdefault("attributes", {}).update({"KEEP": "TRUE", "DONT_TOUCH": "TRUE"})
        cells[new_name] = cell
        logic_cells[signal] = {"name": new_name, "type": cell["type"],
                               "connections": cell["connections"],
                               "parameters": cell.get("parameters", {})}
    for index, old_name in enumerate(data_cells):
        cell = cells.pop(old_name)
        new_name = f"native_rx_data_{index}"
        cell.setdefault("attributes", {}).update({"KEEP": "TRUE", "DONT_TOUCH": "TRUE"})
        cells[new_name] = cell
        data_cells[index] = new_name
    rows = []
    groups = (("ds", ds), ("dq_meta", meta), ("dq_sync", sync))
    for group, bits in groups:
        for index, bit in enumerate(bits):
            old_name, cell = capture(bit)
            new_name = f"native_rx_{group}_{index}"
            if new_name in cells:
                raise ValueError(f"mapped cell name collision: {new_name}")
            cell.setdefault("attributes", {}).update(
                {"KEEP": "TRUE", "DONT_TOUCH": "TRUE", "ASYNC_REG": "TRUE"})
            cells[new_name] = cells.pop(old_name)
            rows.append({"name": new_name, "original_name": old_name, "type": cell["type"],
                         "group": group, "index": index, "D": cell["connections"]["D"],
                         "Q": [bit], "C": clock, "attributes": cell["attributes"]})
    return {"capture_ff_count": len(rows), "clock_bits": clock, "captures": rows,
            "late_ds_detector": "ds_sync_q[3] XOR ds_sync_q[2]", "netnames": names,
            "logic_cells": logic_cells, "sampled_data_ff_count": len(data_cells),
            "sampled_data_cells": data_cells,
            "checks": {"distinct_flops": True, "common_clock": True, "direct_stages": True,
                       "late_ds_truth_table": True, "matching_lane_data_selection": True,
                       "sample_selector_connectivity": True}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    design = json.loads(args.input.read_text())
    receipt = audit(design)
    args.output.write_text(json.dumps(design, separators=(",", ":")) + "\n")
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print("NATIVE_RECEIVER_MAP_PASS: 20 capture FFs, DS4/DQ2, common clock and sampled data")


if __name__ == "__main__":
    main()
