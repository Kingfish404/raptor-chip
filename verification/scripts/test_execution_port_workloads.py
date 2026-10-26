#!/usr/bin/env python3
import unittest
from execution_port_workloads import comparison, parse_metrics, validate_output
from execution_port_report import aggregate_profile, observed_demand, summarize


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
ALQ issue histogram: [1 3 1 1]
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


def dispatch(cycles, accepted, endpoint, branch):
    width = 2
    unfilled = width * cycles - accepted
    empty = cycles - endpoint - 2
    return {
        "cycles": cycles,
        "width": width,
        "accepted": accepted,
        "unfilled_slots": unfilled,
        "stops": {
            "width": {"cycles": 2, "unfilled_slots": 0, "zero_progress_cycles": 0},
            "empty": {"cycles": empty, "unfilled_slots": unfilled - endpoint,
                      "zero_progress_cycles": empty},
            "endpoint": {"cycles": endpoint, "unfilled_slots": endpoint,
                         "zero_progress_cycles": endpoint},
        },
        "endpoint_domains": {0: endpoint - branch, 1: branch},
    }


class AggregateTest(unittest.TestCase):
    def test_cpu_cases_use_same_accounting(self):
        rows = [{"dispatch": dispatch(10, 7, 3, 2)}]
        expected = aggregate_profile({"label": "cpu", "workloads": rows})
        actual = aggregate_profile({"label": "cpu", "complete": True, "cases": rows})
        self.assertEqual(actual, expected)

    def test_rejects_incomplete_cpu_profile(self):
        for complete in (None, False):
            with self.subTest(complete=complete), self.assertRaisesRegex(ValueError, "not complete"):
                aggregate_profile({"label": "cpu", "complete": complete,
                                   "cases": [{"dispatch": dispatch(10, 7, 3, 2)}]})

    def test_rejects_ambiguous_collections(self):
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            aggregate_profile({"label": "cpu", "complete": True,
                               "cases": [], "workloads": []})

    def test_aggregate_and_fractions(self):
        profile = {"label": "p2", "workloads": [
            {"dispatch": dispatch(10, 7, 3, 2)},
            {"dispatch": dispatch(20, 17, 4, 3)},
        ]}
        result = aggregate_profile(profile)
        self.assertEqual(result["cycles"], 30)
        self.assertEqual(result["accepted"], 24)
        self.assertEqual(result["stops"]["endpoint"]["cycles"], 7)
        self.assertAlmostEqual(result["endpoint_domains"]["branch"]["endpoint_fraction"], 5 / 7)
        self.assertAlmostEqual(result["endpoint_domains"]["integer"]["endpoint_fraction"], 2 / 7)

    def test_rejects_endpoint_conservation_failure(self):
        item = dispatch(10, 7, 3, 2)
        item["endpoint_domains"][1] += 1
        with self.assertRaises(ValueError):
            aggregate_profile({"label": "bad", "workloads": [{"dispatch": item}]})

    def test_rob_dispatch_aggregation(self):
        def steering(cycles, bypass, pending, peak, branch, memory):
            histogram = ({0: cycles // 2, 3: cycles - cycles // 2}
                         if cycles == 10 else {1: cycles // 2, 5: cycles - cycles // 2})
            pending_domains = ({1: {"instruction_cycles": 10, "peak": 2},
                                4: {"instruction_cycles": 5, "peak": 1}}
                               if cycles == 10 else
                               {1: {"instruction_cycles": 20, "peak": 2},
                                4: {"instruction_cycles": 40, "peak": 4}})
            return {"candidates": cycles * 2, "accepted": cycles, "bypass": bypass,
                    "oldest_blocked_cycles": branch + memory,
                    "pending_average": pending, "pending_peak": peak,
                    "blocked_domains": {1: branch, 4: memory},
                    "pending_histogram": histogram, "sample_cycles": cycles,
                    "pending_domains": pending_domains}
        profile = {"label": "buffered", "workloads": [
            {"dispatch": dispatch(10, 7, 3, 2),
             "rob_dispatch": steering(10, 2, 1.5, 3, 2, 3)},
            {"dispatch": dispatch(20, 17, 4, 3),
             "rob_dispatch": steering(20, 4, 3.0, 5, 1, 4)},
        ]}
        result = aggregate_profile(profile)["rob_dispatch"]
        self.assertEqual(result["bypass"], 6)
        self.assertEqual(result["pending_peak"], 5)
        self.assertAlmostEqual(result["pending_average"], 2.5)
        self.assertEqual(result["blocked_domains"]["memory"], 7)
        self.assertEqual(sum(result["pending_histogram"].values()), 30)
        self.assertEqual(result["observed_demand"]["p50"], 1)
        self.assertEqual(result["observed_demand"]["p90"], 5)
        self.assertAlmostEqual(result["pending_domains"]["branch"]["average"], 1.0)
        self.assertAlmostEqual(result["pending_domains"]["memory"]["average"], 1.5)
        for row in profile['workloads']:
            steering = row['rob_dispatch']
            steering['branch_capacity_reasons'] = {
                str(r): steering['blocked_domains'][1] if r == 3 else 0 for r in range(7)}
        result = aggregate_profile(profile)['rob_dispatch']
        self.assertEqual(result['branch_capacity_reasons'][3], 3)
        profile['workloads'][0]['rob_dispatch']['branch_capacity_reasons']['3'] += 1
        with self.assertRaisesRegex(ValueError, 'do not conserve'):
            aggregate_profile(profile)
        del profile['workloads'][0]['rob_dispatch']['branch_capacity_reasons']
        with self.assertRaisesRegex(ValueError, 'schema changed'):
            aggregate_profile(profile)

    def test_requires_complete_results(self):
        with self.assertRaises(ValueError):
            summarize({"complete": False, "profiles": []})

    def test_observed_pending_demand(self):
        result = observed_demand({0: 5, 8: 3, 16: 1, 33: 1})
        self.assertEqual(result["p50"], 0)
        self.assertEqual(result["p90"], 16)
        self.assertEqual(result["p99"], 33)
        self.assertAlmostEqual(result["cycles_over_8_fraction"], 0.2)
        self.assertAlmostEqual(result["cycles_over_32_fraction"], 0.1)
        self.assertEqual(result["cycles_over_48_fraction"], 0.0)


if __name__ == "__main__":
    unittest.main()
