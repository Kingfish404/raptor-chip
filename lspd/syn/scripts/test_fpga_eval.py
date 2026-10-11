"""Regression checks for cache safety and conservative FPGA aggregation."""

import copy
import json
from pathlib import Path
import os
import sys
import tempfile
import time
import unittest

import fpga_eval as flow


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fpga-eval-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "input.sv"
        self.source.write_text("module sample; endmodule\n")
        self.inputs = flow.hashes([str(self.source), self.source])
        self.calls = 0

    def action(self, directory):
        self.calls += 1
        (directory / "artifact").write_text("result")

    def evaluate(self, spec=None, action=None):
        return flow.cached_phase(self.root / "cache", "fixture", spec or {"version": 1},
                                 action or self.action, self.inputs)

    def test_identical_inputs_reuse_and_corrupt_artifact_rebuilds(self):
        directory, reused = self.evaluate()
        self.assertFalse(reused)
        self.assertTrue(self.evaluate()[1])
        self.assertEqual(self.calls, 1)
        (directory / "artifact").write_text("damaged")
        self.assertFalse(self.evaluate()[1])
        self.assertEqual(self.calls, 2)

    def test_changed_constraints_have_separate_entries(self):
        first, _ = self.evaluate({"period": 20, "context": "a"})
        second, reused = self.evaluate({"period": 20, "context": "b"})
        self.assertNotEqual(first, second)
        self.assertFalse(reused)
        self.assertTrue(flow.valid_entry(first, first.name))

    def test_failed_action_is_not_reusable(self):
        def failure(directory):
            self.action(directory)
            raise RuntimeError("tool failed")

        with self.assertRaisesRegex(RuntimeError, "tool failed"):
            self.evaluate(action=failure)
        self.assertFalse(self.evaluate()[1])

    def test_zero_exit_without_required_artifact_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Missing required export artifact"):
            flow.cached_phase(self.root / "cache", "export", {}, self.action, self.inputs)
        self.assertEqual(list((self.root / "cache").rglob("complete.json")), [])

    def test_timeout_stops_tool_and_keeps_phase_incomplete(self):
        started = time.monotonic()

        def action(directory):
            flow.execute([sys.executable, "-c", "import time; time.sleep(30)"],
                         directory, dict(os.environ), 0.05, "/usr/bin/time")

        with self.assertRaisesRegex(RuntimeError, "timed out"):
            self.evaluate(action=action)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(list((self.root / "cache").rglob("complete.json")), [])

    def test_changed_sources_during_run_are_rejected(self):
        def source_change(directory):
            self.action(directory)
            self.source.write_text("changed while running")

        with self.assertRaisesRegex(RuntimeError, "Sources changed"):
            self.evaluate(action=source_change)
        self.assertEqual(list((self.root / "cache").rglob("complete.json")), [])

    def test_missing_artifact_is_not_reusable(self):
        directory, _ = self.evaluate()
        (directory / "artifact").unlink()
        self.assertFalse(flow.valid_entry(directory, directory.name))

    def test_incomplete_result_rejects_old_json(self):
        (self.root / "status.txt").write_text("status incomplete\n")
        (self.root / "result.json").write_text('{"schema": 1}')
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            flow.load_result(self.root)

    def test_completed_result_checks_cache_integrity(self):
        directory, _ = self.evaluate()
        (self.root / "status.txt").write_text("status ok\n")
        (self.root / "result.json").write_text(json.dumps({
            "schema": 1, "stages": {"synth": {"directory": str(directory), "key": directory.name}}
        }))
        flow.load_result(self.root)
        (directory / "artifact").unlink()
        with self.assertRaisesRegex(ValueError, "Missing or modified"):
            flow.load_result(self.root)

    def compositions(self):
        return [{"config": {"module": module, "top": "top_" + module,
                            "part": "ku15p", "xlen": "64", "period": "20"},
                 "stage": "route", "mode": "screen", "rtl_sha256": "same-source",
                 "resources": dict.fromkeys(flow.RESOURCE_COLUMNS, 7)}
                for module in ("frontend", "backend", "memory")]

    def test_sum_only_known_disjoint_scopes(self):
        rows = self.compositions()
        self.assertEqual(flow.sum_compositions(rows)["Total LUTs"], 21)
        child = copy.deepcopy(rows[0])
        child["config"]["module"] = "bpu"
        self.assertIsNone(flow.sum_compositions([*rows, child]))
        self.assertIsNone(flow.sum_compositions([rows[0], rows[0], rows[2]]))

    def test_mixed_sources_stages_or_configurations_do_not_sum(self):
        for key, value in (("stage", "place"), ("mode", "closure"),
                           ("rtl_sha256", "other"), ("flow_sha256", "other-flow")):
            rows = self.compositions()
            rows[0][key] = value
            self.assertIsNone(flow.sum_compositions(rows))
        rows = self.compositions()
        rows[0]["config"]["xlen"] = "32"
        self.assertIsNone(flow.sum_compositions(rows))

    def test_context_comments_can_describe_clock_source(self):
        path = self.root / "context.xdc"
        path.write_text("# Clock source from board\nset_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clock]\n")
        flow.validate_context(path)

    def test_nested_context_inputs_are_rejected(self):
        path = self.root / "context.xdc"
        for command in ("source", "read_xdc", "read_checkpoint"):
            path.write_text(f"{command} another-file\n")
            with self.assertRaisesRegex(ValueError, "self-contained"):
                flow.validate_context(path)

    def test_route_errors_are_not_hidden_by_positive_slack(self):
        row = {"stage": "route", "timing": {"wns_ns": 12.0},
               "context": {"route_errors": "1", "routed_fully": "0"}}
        self.assertIn("ERRORS", flow.routing_result(row))
        row["context"] = {"route_errors": "0", "routed_fully": "1",
                          "partpin_ports": "0", "interface_ports": "100"}
        self.assertEqual(flow.routing_result(row), "internal only")
        row["context"]["partpin_ports"] = "100"
        self.assertIn("complete OOC", flow.routing_result(row))
        row["stage"] = "place"
        self.assertEqual(flow.routing_result(row), "not routed")

    def test_timing_reports_negative_slack_and_preserves_missing(self):
        report = self.root / "timing.rpt"
        report.write_text("WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WHS(ns) THS(ns)\n"
                          "------- ------- ------ ----- ------- ------- ------ ----\n"
                          "-0.123 -5.000 4 100 -0.100 -0.200 2 100\n")
        self.assertEqual(flow.timing(report), {"wns_ns": -0.123, "tns_ns": -5.0,
                                              "whs_ns": -0.1, "ths_ns": -0.2})
        report.write_text("No timing paths\n")
        self.assertTrue(all(value is None for value in flow.timing(report).values()))

    def test_hierarchy_resources_use_top_not_child(self):
        report = self.root / "utilization.rpt"
        report.write_text("| Instance | Module | Total LUTs | FFs | RAMB36 | RAMB18 | URAM | DSP Blocks |\n"
                          "+----------+\n"
                          "| top | (top) | 1,200 | 50 | 2 | 1 | 0 | 4 |\n"
                          "| child | leaf | 200 | 5 | 0 | 0 | 0 | 0 |\n")
        self.assertEqual(flow.resources(report, "top")["Total LUTs"], 1200)
        with self.assertRaisesRegex(ValueError, "Missing resource row"):
            flow.resources(report, "absent")


if __name__ == "__main__":
    unittest.main()
