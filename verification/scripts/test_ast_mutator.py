#!/usr/bin/env python3
"""Unit tests for verification/scripts/ast_mutator.py."""

import json
import tempfile
import unittest
from pathlib import Path

import ast_mutator

SAMPLE_SV = """\
module demo (
    input  logic       clock,
    input  logic       reset,
    input  logic       valid,
    input  logic [3:0] a,
    input  logic [3:0] b,
    output logic       hit,
    output logic [3:0] out_q
);
  logic match;
  always_comb begin
    match = (a == b) && valid;
    if (match) hit = 1'b1;
    else hit = 1'b0;
  end
  always_ff @(posedge clock) begin
    if (reset) out_q <= 4'd0;
    else if (valid) out_q   <=   a;
  end
endmodule
"""


class AstMutatorTest(unittest.TestCase):
    def test_replace_token_sequence_is_whitespace_invariant(self):
        # Pattern has single spaces, source has aligned multi-space NBA
        mutated = ast_mutator.replace_token_sequence(
            SAMPLE_SV,
            "out_q <= a;",
            "out_q <= b;",
        )
        self.assertIn("out_q <= b;", mutated)
        self.assertNotIn("out_q   <=   a;", mutated)

    def test_replace_token_sequence_rejects_missing_or_duplicate(self):
        with self.assertRaises(ValueError):
            ast_mutator.replace_token_sequence(SAMPLE_SV, "nonexistent <= 0;", "x <= 1;")
        with self.assertRaises(ValueError):
            ast_mutator.replace_token_sequence(SAMPLE_SV, "valid", "1'b0")

    def test_discover_mutations_skips_nba_and_reset(self):
        cands = ast_mutator.discover_mutations(SAMPLE_SV)
        kinds = {c.kind for c in cands}
        self.assertEqual(kinds, {"op_flip", "cond_invert", "const_flip"})
        # Non-blocking assignments `out_q <=` must not be mutated to `<`
        for c in cands:
            if c.kind == "op_flip":
                self.assertNotEqual(c.original, "<=")
            if c.kind == "cond_invert":
                self.assertNotIn("reset", c.original)

    def test_filter_signal_and_batch_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            src = tmp_path / "demo.sv"
            src.write_text(SAMPLE_SV)
            out_dir = tmp_path / "mutants"
            rc = ast_mutator.main(
                [
                    "batch",
                    str(src),
                    "--output",
                    str(out_dir),
                    "--filter-signal",
                    "match",
                    "--limit",
                    "10",
                ]
            )
            self.assertEqual(rc, 0)
            manifest = json.loads((out_dir / "manifest.json").read_text())
            self.assertGreaterEqual(len(manifest["mutants"]), 3)
            for m in manifest["mutants"]:
                self.assertTrue((out_dir / m["file"]).exists())


if __name__ == "__main__":
    unittest.main()
