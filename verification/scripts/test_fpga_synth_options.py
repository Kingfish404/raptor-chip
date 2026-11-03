#!/usr/bin/env python3
"""Check the Vivado OOC command and constraints without starting Vivado."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "synth/yosys/scripts/fpga_synth.tcl"


class FpgaSynthOptionsTests(unittest.TestCase):
    def run_tcl(self, value):
        if not shutil.which("tclsh"):
            self.skipTest("tclsh required")
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, FPGA_OUT=directory, FPGA_PERIOD="20", FPGA_IO_FRAC="0.2",
                       FPGA_THREADS="4", FPGA_PART="xcku15p-ffva1156-2-e", FPGA_CLOCK="clock",
                       FPGA_TOP="test_top", FPGA_SYNTH_DIRECTIVE="default", SYNTH_SCRIPT=str(SCRIPT))
            env.pop("FPGA_NO_TIMING_DRIVEN", None)
            if value is not None:
                env["FPGA_NO_TIMING_DRIVEN"] = value
            bootstrap = '''
proc unknown {args} { return {} }
proc synth_design {args} {
    puts [join $args "\\n"]
    exit 0
}
if {[catch {source $::env(SYNTH_SCRIPT)} message]} {
    puts stderr $message
    exit 1
}
'''
            result = subprocess.run(["tclsh"], input=bootstrap, text=True, env=env,
                                    capture_output=True, check=False)
            constraints = (Path(directory) / "module.xdc").read_text()
            return result, constraints

    def test_board_option_preserves_constraints_and_area_options(self):
        original_constraints = None
        for value in (None, "0", "1"):
            with self.subTest(value=value):
                result, constraints = self.run_tcl(value)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = result.stdout.splitlines()
                self.assertEqual(args.count("-no_timing_driven"), int(value == "1"))
                self.assertEqual(args[args.index("-directive") + 1], "default")
                self.assertEqual(args[args.index("-resource_sharing") + 1], "off")
                self.assertIn("-no_lc", args)
                self.assertIn("-mode", args)
                self.assertIn("create_clock -name module_clock -period 20", constraints)
                self.assertIn("set_input_delay 4.0 -clock module_clock", constraints)
                self.assertIn("set_output_delay 4.0 -clock module_clock", constraints)
                if original_constraints is None:
                    original_constraints = constraints
                self.assertEqual(constraints, original_constraints)

    def test_tcl_rejects_invalid_option(self):
        result, _ = self.run_tcl("2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FPGA_NO_TIMING_DRIVEN must be 0 or 1", result.stderr)
        self.assertNotIn("out_of_context", result.stdout)

    def test_make_records_and_forwards_option(self):
        if not shutil.which("make"):
            self.skipTest("make required")
        for value in ("0", "1", "2"):
            with self.subTest(value=value):
                result = subprocess.run([
                    "make", "--no-print-directory", "-n", "-C", str(ROOT / "synth/yosys"),
                    "fpga-syn-locked", "SRAM_MODE=flops", "MODULE=lsu",
                    "RAPT_CONFIG=default-w4", "FPGA_NO_TIMING_DRIVEN=" + value,
                ], text=True, capture_output=True, check=False)
                if value == "2":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("FPGA_NO_TIMING_DRIVEN must be 0 or 1", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("'no_timing_driven=" + value + "'", result.stdout)
                    self.assertIn("FPGA_NO_TIMING_DRIVEN='" + value + "'", result.stdout)


if __name__ == "__main__":
    unittest.main()
