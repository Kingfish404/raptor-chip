import copy
import unittest

from fpga_cost import evaluate
import test_fpga_validation as fixtures


class FpgaCostTests(unittest.TestCase):
    def source(self):
        source = fixtures.FpgaValidationTests().source("candidate", 1000)
        source["setup"] = [{"wall_seconds": 1000}]
        full, sample = source["cases"][:2]
        for case, costs in ((full, [10, 100, 100]), (sample, [20, 30, 30])):
            for run, cost in zip(case["runs"], costs):
                run.update(wall_seconds=cost, execution_wall_seconds=cost / 2)
        return source

    def test_first_repeat_and_setup_cannot_hide_total_cost(self):
        result = evaluate(self.source(), "trace", 0)
        self.assertAlmostEqual(result["median_replay_wall_speedup"], 100 / 30)
        self.assertAlmostEqual(result["repeat_total_wall_speedup"], 210 / 80)
        self.assertEqual(result["first_observed_repetition_wall_speedup"], .5)
        self.assertAlmostEqual(result["setup_plus_repeats_component_ratio"], 1210 / 1080)
        self.assertEqual(result["full"]["repetitions"][0]["wall_seconds"], 10)

    def test_incomplete_mismatched_or_ambiguous_studies_are_rejected(self):
        source = self.source()
        source["complete"] = False
        with self.assertRaisesRegex(ValueError, "complete"):
            evaluate(source, "trace", 0)
        source = self.source()
        source["cases"][1]["retirement_domain"] = {"mode": "user"}
        with self.assertRaisesRegex(ValueError, "retirement_domain"):
            evaluate(source, "trace", 0)
        source = self.source()
        source["cases"].append(copy.deepcopy(source["cases"][0]))
        with self.assertRaisesRegex(ValueError, "one full"):
            evaluate(source, "trace", 0)

    def test_unverified_windows_and_invalid_costs_are_rejected(self):
        source = self.source()
        source["cases"][1]["runs"][0]["delta_transfer"]["readback_verified"] = False
        with self.assertRaisesRegex(ValueError, "not verified"):
            evaluate(source, "trace", 0)
        source = self.source()
        source["setup"][0]["wall_seconds"] = float("nan")
        with self.assertRaisesRegex(ValueError, "setup cost"):
            evaluate(source, "trace", 0)
        source = self.source()
        source["cases"][0]["runs"][0]["execution_wall_seconds"] = 11
        with self.assertRaisesRegex(ValueError, "execution cost"):
            evaluate(source, "trace", 0)


if __name__ == "__main__":
    unittest.main()
