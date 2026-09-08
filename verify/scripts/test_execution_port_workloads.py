#!/usr/bin/env python3
import unittest

from execution_port_workloads import comparison, parse_metrics, validate_output


class OutputValidationTest(unittest.TestCase):
    def test_microbench_pass(self):
        result = validate_output("Running MicroBench\nMicroBench PASS\nHIT GOOD TRAP\n")
        self.assertEqual(result["self_check"], "passed")

    def test_coremark_simulated_duration_is_explicit_caveat(self):
        output = ("CoreMark Size    : 666\n"
                  "ERROR! Must execute for at least 10 secs for a valid result!\n"
                  "Errors detected\nHIT GOOD TRAP\n")
        result = validate_output(output)
        self.assertEqual(result["self_check"], "crc_checks_passed")
        self.assertFalse(result["official_coremark_score_valid"])

    def test_coremark_crc_error_is_rejected(self):
        output = ("CoreMark Size    : 666\n[0]ERROR! matrix crc 0x4x\n"
                  "ERROR! Must execute for at least 10 secs for a valid result!\n"
                  "Errors detected\nHIT GOOD TRAP\n")
        with self.assertRaises(ValueError):
            validate_output(output)

    def test_failures_are_rejected(self):
        for output in ["MicroBench FAIL\nHIT GOOD TRAP", "HIT BAD TRAP",
                       "ERROR! bad port\nHIT GOOD TRAP", "clean exit"]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                validate_output(output)


class MetricsTest(unittest.TestCase):
    REPORT = """#inst: 8, cycle: 6, IPC: 1.333
ALQ selection: ready-entry cycles 4, issued 8, rebalance extra issues 0
ALQ issue histogram 0: cycles 1
ALQ issue histogram 1: cycles 3
ALQ issue histogram 2: cycles 1
ALQ issue histogram 3: cycles 1
ALQ extra physical ports (index >= 2): issues 1
"""

    def test_metrics_and_cycle_conservation(self):
        result = parse_metrics(self.REPORT)
        self.assertEqual(result["physical_integer_ports"], 3)
        self.assertEqual(result["max_issue_cycles"], 1)
        self.assertAlmostEqual(result["extra_port_issue_fraction"], 0.125)
        with self.assertRaises(ValueError):
            parse_metrics(self.REPORT.replace("cycle: 6", "cycle: 7"))

    def test_comparison_requires_same_stream(self):
        def profile(label, cycles, digest="same"):
            return {"label": label, "workloads": [{
                "workload": "w", "image_sha256": digest, "instructions": 8,
                "cycles": cycles, "alq_selection": {"extra_port_issues": 2},
            }]}
        result = comparison(profile("p2", 10), profile("p3", 8))
        self.assertEqual(result["aggregate"]["cycle_delta"], -2)
        self.assertEqual(result["workloads"][0]["speedup"], 1.25)
        with self.assertRaises(ValueError):
            comparison(profile("p2", 10), profile("p3", 8, "different"))


if __name__ == "__main__":
    unittest.main()
