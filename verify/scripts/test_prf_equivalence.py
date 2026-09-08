#!/usr/bin/env python3
"""Negative tests for PRF proof acceptance; these do not replace RTL proof."""
import unittest
from pathlib import Path
import shutil
import subprocess
import tempfile

from prf_equivalence import audit_proof, PROOF_PASSES, COMBINATIONAL_MATCHES


def report(total=10, proven=10, unproven=0):
    points = ["prf_valid", "prf_transient", "rf", "rf_map", "prf_rd.pv1",
              "prf_rd.pv2", "prf_rd.pv1_valid", "prf_rd.pv2_valid",
              "prf_arr[0]", "prf_arr[1]", "prf_arr[2]"]
    return "\n".join(f"Presumably equivalent wires: gold, gate -> {p}" for p in points) + (
        "\n15. Executing EQUIV_STATUS pass.\n"
        f"Found {total} $equiv cells in equiv:\n"
        f"  Of those cells {proven} are proven and {unproven} are unproven.\n"
        "  Equivalence successfully proven!\n")


class ProofAuditTest(unittest.TestCase):
    def test_complete(self):
        result = audit_proof(report())
        self.assertEqual(result["matched_data_entries"], 3)
        self.assertEqual(result["proven_cells"], 10)

    def test_zero_cells(self):
        with self.assertRaises(ValueError):
            audit_proof(report(0, 0))

    def test_unproven_cells(self):
        with self.assertRaises(ValueError):
            audit_proof(report(10, 9, 1))

    def test_inconsistent_totals(self):
        with self.assertRaises(ValueError):
            audit_proof(report(10, 9))

    def test_missing_final_status(self):
        with self.assertRaises(ValueError):
            audit_proof(report().split("15. Executing")[0])

    def test_missing_output(self):
        with self.assertRaises(ValueError):
            audit_proof(report().replace("-> prf_rd.pv2\n", "-> unrelated\n"))

    def test_missing_data_entry(self):
        with self.assertRaises(ValueError):
            audit_proof(report().replace("-> prf_arr[1]\n", "-> unrelated\n"))

    def test_error_despite_success_text(self):
        with self.assertRaises(ValueError):
            audit_proof(report() + "ERROR: later failure\n")


@unittest.skipUnless(shutil.which("yosys"), "Yosys is required for proof-model tests")
class StateInductionTest(unittest.TestCase):
    def prove(self, gate_expression, hold=False):
        with tempfile.TemporaryDirectory(prefix="prf-proof-model-") as tmp:
            source = Path(tmp) / "fixture.v"
            modules = []
            for name, expression in (("gold", "a"), ("gate", gate_expression)):
                modules.append(f"""
module {name}(input clock, input [3:0] a, output [3:0] y);
  reg [3:0] prf_valid;
  (* keep *) wire [3:0] wr_mux_data = {expression};
  always @(posedge clock) {"if (a[0])" if hold else ""} prf_valid <= wr_mux_data;
  assign y = prf_valid;
endmodule
""")
            source.write_text("\n".join(modules))
            blacklist = Path(tmp) / "matches.txt"
            blacklist.write_text("\n".join(COMBINATIONAL_MATCHES) + "\n")
            commands = [f"read_verilog {source}", "proc", "opt",
                        f"equiv_make -blacklist {blacklist} gold gate equiv",
                        "hierarchy -top equiv", *PROOF_PASSES]
            return subprocess.run(["yosys", "-Q", "-T", "-p", "; ".join(commands)],
                                  capture_output=True, text=True, timeout=30)

    def test_corresponding_uninitialized_state(self):
        run = self.prove("a")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("Equivalence successfully proven!", run.stdout)

    def test_impossible_combinational_match_cannot_hide_mutation(self):
        # next_data_gold == next_data_gate is impossible for a vs ~a.
        # It must NOT become an induction hypothesis that proves everything.
        run = self.prove("~a")
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("unproven $equiv cells", run.stdout + run.stderr)

    def test_held_state_really_uses_induction(self):
        run = self.prove("a", hold=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        induction = run.stdout.split("Executing EQUIV_INDUCT pass.", 1)[1].split(
            "Executing EQUIV_SIMPLE pass.", 1)[0]
        self.assertIn("Proved 4 previously unproven", induction)


if __name__ == "__main__":
    unittest.main()
