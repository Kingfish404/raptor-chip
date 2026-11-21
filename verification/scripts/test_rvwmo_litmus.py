#!/usr/bin/env python3
"""Unit tests for verification/litmus/rvwmo_litmus.py."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

LITMUS_DIR = Path(__file__).resolve().parents[1] / "litmus"
sys.path.insert(0, str(LITMUS_DIR))
import rvwmo_litmus  # noqa: E402


class RvwmoLitmusTest(unittest.TestCase):
    def test_generate_rv32_and_rv64(self):
        with tempfile.TemporaryDirectory() as tmp:
            for xlen, expected_min in ((32, 15), (64, 16)):
                out = Path(tmp) / f"rv{xlen}"
                rc = rvwmo_litmus.main(["generate", "--xlen", str(xlen), "--outdir", str(out)])
                self.assertEqual(rc, 0)
                names = (out / "manifest.txt").read_text().strip().splitlines()
                self.assertGreaterEqual(len(names), expected_min)
                for name in names:
                    asm = (out / f"{name}.S").read_text()
                    self.assertIn("ebreak", asm)
                    self.assertIn("_litmus_mem:", asm)

    def test_export_herd7(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "herd7"
            rc = rvwmo_litmus.main(["export-herd7", "--outdir", str(out)])
            self.assertEqual(rc, 0)
            summary = json.loads((out / "herd7_summary.json").read_text())
            self.assertGreaterEqual(len(summary["exported"]), 5)
            for fname in summary["exported"]:
                text = (out / fname).read_text()
                self.assertTrue(text.startswith("RISCV "))
                self.assertIn("exists (", text)


if __name__ == "__main__":
    unittest.main()
