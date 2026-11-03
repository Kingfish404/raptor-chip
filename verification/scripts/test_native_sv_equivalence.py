"""Check that the whole-top equivalence runner accepts and rejects real circuits."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from native_sv_equivalence import audit

SCRIPT = Path(__file__).with_name("native_sv_equivalence.py")


class ProofAuditTest(unittest.TestCase):
    def test_reject_missing_empty_and_partial_status(self):
        for text in ("", "Equivalence successfully proven!",
                     "Executing EQUIV_STATUS pass.\nFound 0 $equiv cells in equiv:\n"
                     "Of those cells 0 are proven and 0 are unproven.\n"
                     "Equivalence successfully proven!",
                     "Executing EQUIV_STATUS pass.\nFound 4 $equiv cells in equiv:\n"
                     "Of those cells 3 are proven and 1 are unproven.\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                audit(text)


@unittest.skipUnless(shutil.which("yosys"), "Yosys with Slang required")
class ProofCircuitTest(unittest.TestCase):
    def run_case(self, changed, asynchronous=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gold, gate = root / "gold", root / "gate"
            for path in (gold, gate):
                (path / "configs/chip32-small").mkdir(parents=True)
                for name in ("include/npc", "include/dpic_mock"):
                    (path / name).mkdir(parents=True)
                (path / "rapt_pkg.sv").write_text("package rapt_pkg; endpackage\n")
            gold_source = """
module child(input logic clock, a, input logic enable = 1'b1, output logic q);
  always_ff @(posedge clock) if (enable) q <= a;
endmodule
module rapt_chip(input logic clock, a, output logic q);
  child dut(.clock, .a, .q);
endmodule
"""
            gate_source = gold_source.replace("enable = 1'b1", "enable")
            gate_source = gate_source.replace(".clock, .a, .q", ".clock, .a, .enable(1'b1), .q")
            if asynchronous:
                for name in ("gold_source", "gate_source"):
                    source = gold_source if name == "gold_source" else gate_source
                    source = source.replace("clock, a", "clock, reset, a")
                    source = source.replace(".clock, .a", ".clock, .reset, .a")
                    source = source.replace("@(posedge clock) if (enable)",
                                            "@(posedge clock or posedge reset) "
                                            "if (reset) q <= 1'b0; else if (enable)")
                    if name == "gold_source":
                        gold_source = source
                    else:
                        gate_source = source
            if changed:
                gate_source = (gate_source.replace("if (reset) q <= 1'b0;",
                                                   "if (reset) q <= 1'b1;")
                               if asynchronous else gate_source.replace("q <= a;", "q <= !a;"))
            (gold / "design.sv").write_text(gold_source)
            (gate / "design.sv").write_text(gate_source)
            run = subprocess.run([sys.executable, str(SCRIPT), "--baseline-rtl", str(gold),
                                  "--candidate-rtl", str(gate), "--output", str(root / "proof"),
                                  "--presets", "chip32-small", "--timeout", "60"],
                                 capture_output=True, text=True, timeout=90)
            result = json.loads((root / "proof/results.json").read_text())
            return run, result

    def test_explicit_default_is_proven(self):
        run, result = self.run_case(False)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue(result["complete"])
        self.assertTrue(result["cases"][0]["proven"])
        self.assertGreater(result["cases"][0]["audit"]["points"], 0)

    def test_changed_data_is_rejected(self):
        run, result = self.run_case(True)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(result["complete"])
        self.assertFalse(result["cases"][0]["proven"])
        self.assertIn("failed", result["cases"][0]["error"])

    def test_asynchronous_reset_is_proven(self):
        run, result = self.run_case(False, asynchronous=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue(result["complete"])

    def test_changed_asynchronous_reset_is_rejected(self):
        run, result = self.run_case(True, asynchronous=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(result["complete"])


if __name__ == "__main__":
    unittest.main()
