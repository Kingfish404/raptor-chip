"""Reject lost stages, wrong clocks, early detection and wrong-lane capture after mapping."""

import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("receiver_map", Path(__file__).parents[1]
                                             / "receiver_map.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture():
    cells = {"u_clocks": {"type": "native_clock", "port_directions": {"core_clock_o": "output"},
                           "connections": {"core_clock_o": [1]}}}
    nets = {}

    def flop(name, data, output):
        cells[name] = {"type": "FDRE", "parameters": {}, "attributes": {},
                       "port_directions": {"C": "input", "D": "input", "CE": "input",
                                           "Q": "output"},
                       "connections": {"C": [1], "D": [data], "CE": [101], "Q": [output]}}

    def lut(name, inputs, output, init):
        connections = {f"I{i}": [bit] for i, bit in enumerate(inputs)} | {"O": [output]}
        directions = {f"I{i}": "input" for i in range(len(inputs))} | {"O": "output"}
        cells[name] = {"type": f"LUT{len(inputs)}", "connections": connections,
                       "port_directions": directions, "parameters": {"INIT": init}}

    for name, bits in (("ds_sync_q", list(range(10, 14))), ("dq_meta_q", list(range(20, 28))),
                       ("dq_sync_q", list(range(30, 38))), ("ds_edge", [100]),
                       ("sample_ds", [101]), ("data_o", list(range(400, 528)))):
        nets["chip.u_frame." + name] = {"bits": bits}
    for i in range(4):
        flop(f"ds{i}", 2 if i == 0 else 9 + i, 10 + i)
    for lane in range(8):
        flop(f"meta{lane}", 50 + lane, 20 + lane)
        flop(f"sync{lane}", 20 + lane, 30 + lane)
    lut("edge", [12, 13], 100, "0110")
    lut("select", [100, 3], 101, "1000")
    for index in range(128):
        lut(f"data_mux{index}", [30 + index % 8, 101], 200 + index, "1000")
        flop(f"data{index}", 200 + index, 400 + index)
    return {"modules": {MODULE.TOP: {"cells": cells, "netnames": nets}}}


class ReceiverMapTests(unittest.TestCase):
    def setUp(self):
        self.design = fixture()
        self.module = self.design["modules"][MODULE.TOP]

    def test_distinct_common_clock_direct_stages_and_sample_data(self):
        receipt = MODULE.audit(self.design)
        self.assertEqual(receipt["capture_ff_count"], 20)
        self.assertEqual(receipt["sampled_data_ff_count"], 128)
        self.assertTrue(all(receipt["checks"].values()))
        self.assertIn("native_rx_ds_3", self.module["cells"])

    def test_three_ds_stages_are_rejected(self):
        self.module["netnames"]["chip.u_frame.ds_sync_q"]["bits"].pop()
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)

    def test_srl_replacement_is_rejected(self):
        self.module["cells"]["ds0"]["type"] = "SRL16E"
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)

    def test_unrelated_capture_clock_is_rejected(self):
        self.module["cells"]["meta3"]["connections"]["C"] = [99]
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)

    def test_swapped_dq_lane_is_rejected(self):
        self.module["cells"]["sync3"]["connections"]["D"] = [24]
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)

    def test_early_ds_detection_is_rejected(self):
        self.module["cells"]["edge"]["connections"]["I0"] = [11]
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)

    def test_wrong_detector_truth_table_is_rejected(self):
        self.module["cells"]["edge"]["parameters"]["INIT"] = "1000"
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)

    def test_wrong_data_lane_is_rejected(self):
        self.module["cells"]["data_mux0"]["connections"]["I0"] = [31]
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)

    def test_missing_sample_selector_is_rejected(self):
        self.module["cells"]["select"]["connections"]["I0"] = [3]
        with self.assertRaises(ValueError):
            MODULE.audit(self.design)


if __name__ == "__main__":
    unittest.main()
