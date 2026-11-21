#!/usr/bin/env python3
"""Unit tests for verification/scripts/rvv_hyp_fuzz.py."""

import tempfile
import unittest
from pathlib import Path

import rvv_hyp_fuzz


class RvvHypFuzzTest(unittest.TestCase):
    def test_generate_rvv_suite(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "rvv"
            rc = rvv_hyp_fuzz.main(
                ["--mode", "rvv", "--seed", "7", "--num", "5", "--blocks", "4", "--outdir", str(out)]
            )
            self.assertEqual(rc, 0)
            names = (out / "manifest.txt").read_text().strip().splitlines()
            self.assertEqual(len(names), 5)
            asm = (out / f"{names[0]}.S").read_text()
            self.assertIn("vsetivli", asm)
            self.assertIn("ebreak", asm)

    def test_generate_hypervisor_suite(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "hyp"
            rc = rvv_hyp_fuzz.main(
                [
                    "--mode",
                    "hypervisor",
                    "--seed",
                    "9",
                    "--num",
                    "4",
                    "--blocks",
                    "3",
                    "--outdir",
                    str(out),
                ]
            )
            self.assertEqual(rc, 0)
            names = (out / "manifest.txt").read_text().strip().splitlines()
            self.assertEqual(len(names), 4)
            asm = (out / f"{names[0]}.S").read_text()
            self.assertIn("hs_trap:", asm)
            self.assertIn("vs_guest:", asm)
            self.assertIn("sret", asm)
            self.assertIn("ebreak", asm)


if __name__ == "__main__":
    unittest.main()
