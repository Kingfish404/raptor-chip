#!/usr/bin/env python3
"""Fail-closed tests for full-ROU physical-cost comparison."""
import hashlib
from pathlib import Path
import tempfile
import unittest

import rou_state_evaluate as report
from test_dispatch_steer_ppa import DispatchSteerPpaTest


class RouStateEvaluationTest(unittest.TestCase):
    def fixture(self, root):
        root.mkdir()
        DispatchSteerPpaTest().make_case(root, module="rou", k=4)
        source = root / "hdl/backend/rapt_rou.sv"
        source.parent.mkdir(parents=True)
        source.write_text("module rapt_rou; endmodule\n")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        (root / "source_manifest.sha256").write_text(f"{digest}  {source}\n")

    def test_same_constraints_and_snapshot_normalization(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / "a", Path(tmp) / "b"
            self.fixture(a)
            self.fixture(b)
            result = report.evaluate(a, b)
            self.assertTrue(result["complete"])
            self.assertFalse(result["functional_equivalence_proven"])
            self.assertEqual(result["source_differences"], {})
            self.assertEqual(result["delta"]["area_delta_percent"], 0)

    def test_reject_constraint_and_source_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / "a", Path(tmp) / "b"
            self.fixture(a)
            self.fixture(b)
            sta = b / "top.sta_summary.rpt"
            original = sta.read_text()
            sta.write_text(original.replace("output_load_ff 5", "output_load_ff 6"))
            with self.assertRaisesRegex(ValueError, "constraint mismatch"):
                report.evaluate(a, b)
            sta.write_text(original)
            (b / "hdl/backend/rapt_rou.sv").write_text("changed during mapping\n")
            with self.assertRaisesRegex(ValueError, "source provenance mismatch"):
                report.evaluate(a, b)

    def test_reject_empty_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / "a", Path(tmp) / "b"
            self.fixture(a)
            self.fixture(b)
            (b / "source_manifest.sha256").write_text("")
            with self.assertRaisesRegex(ValueError, "empty source manifest"):
                report.evaluate(a, b)


if __name__ == "__main__":
    unittest.main()
