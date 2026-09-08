#!/usr/bin/env python3
"""Unit tests for dispatch_steer_ppa report parsing and comparison."""

import hashlib
import tempfile
from pathlib import Path
import unittest

import dispatch_steer_ppa as report


class DispatchSteerPpaTest(unittest.TestCase):
    def make_case(self, root: Path, module="dpu", k=4):
        source = root / "source.sv"
        source.write_text("module source; endmodule\n")
        netlist = root / "top.netlist.v"
        netlist.write_text("module top; endmodule\n")
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        netlist_hash = hashlib.sha256(netlist.read_bytes()).hexdigest()
        (root / "source_manifest.sha256").write_text(f"{source_hash}  {source}\n")
        (root / "netlist.sha256").write_text(f"{netlist_hash}  {netlist}\n")
        (root / "run_config.txt").write_text(
            f"module={module}\ntop=top\npdk=nangate45\nconfig=default\n"
            f"clock_mhz=100\nperiod_ns=10\nio_delay_frac=0\noutput_load_ff=5.0\n"
            f"extra_defines=-DRAPT_STEER_SCAN_ENTRIES={k}\nsram_mode=flops\n"
            "sram_platform=sky130\n")
        (root / "top.stat.rpt").write_text(
            "  123  456.75 cells\nChip area for module '\\top': 456.750000\n")
        (root / "top.sta_summary.rpt").write_text(
            "top top\nperiod_ns 10\nio_delay_frac 0\nio_delay_ns 0\n"
            "output_load_ff 5\nwns_ns 8.75\ntns_ns 0\nperiod_min_ns 1.25\nfmax_mhz 800\n")
        (root / "sta.log").write_text(
            "Startpoint: stimulus[0] (input port clocked by core_clk)\n"
            "Endpoint: response[0] (output port clocked by core_clk)\n"
            "Total 1e-6 2e-6 3e-6 6e-6 100.0%\n")
        profile = "status=0\nelapsed_sec=1.2\nuser_sec=1\nsystem_sec=0.1\nmax_rss_kb=42\n"
        (root / "synth.profile").write_text(profile)
        (root / "sta.profile").write_text(profile)
        return netlist

    def test_parse_case_and_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            netlist = self.make_case(root)
            row = report.parse_case("dpu-k4", root, "dpu", 4)
            self.assertEqual(row["cell_count"], 123)
            self.assertEqual(row["area"], 456.75)
            self.assertEqual(row["timing"]["period_min_ns"], 1.25)
            self.assertEqual(row["power_w"]["total"], 6e-6)
            netlist.write_text("changed\n")
            with self.assertRaisesRegex(ValueError, "netlist hash mismatch"):
                report.parse_case("dpu-k4", root, "dpu", 4)

    def test_comparison(self):
        old = {"area": 10.0, "cell_count": 100,
               "timing": {"period_min_ns": 2.0, "fmax_mhz": 500.0},
               "power_w": {"total": 4.0}}
        new = {"area": 15.0, "cell_count": 180,
               "timing": {"period_min_ns": 2.5, "fmax_mhz": 400.0},
               "power_w": {"total": 6.0}}
        delta = report.compare(old, new)
        self.assertAlmostEqual(delta["area_delta_percent"], 50.0)
        self.assertAlmostEqual(delta["delay_delta_percent"], 25.0)
        self.assertAlmostEqual(delta["fmax_delta_percent"], -20.0)
        self.assertAlmostEqual(delta["power_delta_percent"], 50.0)


if __name__ == "__main__":
    unittest.main()
