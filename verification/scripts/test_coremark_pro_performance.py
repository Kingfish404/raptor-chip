import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from coremark_pro_performance import summarize


class MatchedWindowTests(unittest.TestCase):
    def evaluate(self, before, after, passed=True):
        result = {
            "samples": [{"workload": "kernel", "sample": 0, "fraction": 0.5}],
            "runs": [
                {"workload": "kernel", "sample": 0, "profile": "baseline",
                 "passed": True, "boundaries": before},
                {"workload": "kernel", "sample": 0, "profile": "candidate",
                 "passed": passed, "boundaries": after},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            summarize(SimpleNamespace(output=Path(directory), warmup=4096, window=16384), result)
        return result

    def test_dual_retirement_uses_identical_instruction_boundaries(self):
        result = self.evaluate(
            {4096: 100, 4097: 110, 20480: 300, 20481: 310},
            {4095: 20, 4097: 25, 20479: 120, 20481: 125})
        self.assertTrue(result["complete"])
        row = result["comparisons"][0]
        self.assertEqual((row["start_instruction"], row["end_instruction"]), (4097, 20481))
        self.assertEqual(row["speedup"], 2)

    def test_nonmatching_boundaries_are_not_interpolated(self):
        result = self.evaluate({4096: 100, 20480: 300}, {4097: 20, 20481: 120})
        self.assertFalse(result["complete"])
        self.assertEqual(result["comparisons"], [])

    def test_failed_differential_run_is_excluded(self):
        result = self.evaluate({4096: 100, 20480: 300}, {4096: 20, 20480: 120}, passed=False)
        self.assertFalse(result["complete"])
        self.assertEqual(result["comparisons"], [])

    def test_counter_regression_is_rejected(self):
        result = self.evaluate({4096: 100, 20480: 300}, {4096: 120, 20480: 20})
        self.assertFalse(result["complete"])
        self.assertEqual(result["comparisons"], [])


if __name__ == "__main__":
    unittest.main()
