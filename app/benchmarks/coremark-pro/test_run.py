import unittest
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

from run import compare, parse_output, progress, run_one


def good_output(verify=1):
    return f"""Raptor benchmark run: iterations=1 verify={verify} timebase=10000000 Hz
RAPTOR ROI cycles=200000 instructions=100000 ticks=2000
-- Workload:linear_alg-mid-100x100-sp=1046644201
-- linear_alg-mid:fails=0
HIT GOOD TRAP
"""


class ResultChecks(unittest.TestCase):
    def test_reference_validation(self):
        result = parse_output(good_output(), "linear_alg-mid-100x100-sp")
        self.assertTrue(result["verify"])
        self.assertTrue(result["timer_resolution_pass"])

    def test_good_exit_does_not_hide_wrong_answer(self):
        with self.assertRaisesRegex(ValueError, "failure"):
            parse_output(good_output().replace("fails=0", "fails=1"),
                         "linear_alg-mid-100x100-sp")

    def test_missing_validation_is_not_a_pass(self):
        with self.assertRaisesRegex(ValueError, "reference validation"):
            parse_output(good_output().replace("-- linear_alg-mid:fails=0", ""),
                         "linear_alg-mid-100x100-sp")

    def test_performance_run_does_not_claim_validation(self):
        result = parse_output(good_output(0).replace("-- linear_alg-mid:fails=0", ""),
                              "linear_alg-mid-100x100-sp")
        self.assertFalse(result["verify"])

    def test_wrong_workload_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "mismatched"):
            parse_output(good_output(), "nnet_test")

    def test_unmatched_execution_is_rejected(self):
        row = {"workload": "linear_alg-mid-100x100-sp", "passed": True,
               "image_sha256": "same", **parse_output(good_output(), "linear_alg-mid-100x100-sp")}
        before = {**row, "profile": "baseline"}
        after = {**row, "profile": "candidate", "instructions": row["instructions"] + 1}
        with self.assertRaisesRegex(ValueError, "instructions"):
            compare([before, after])

    def test_progress_distinguishes_initialization_from_timed_work(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            log = directory / "run.log"
            self.assertEqual(progress(log, directory), {"phase": "initialization"})
            log.write_text("-  Info: Starting Run...\n")
            (directory / "nemu-uarch_state.json").write_text(json.dumps(
                {"inst_cnt": 300000000, "pc": "0x8000837a"}))
            snapshot = progress(log, directory)
            self.assertEqual(snapshot["phase"], "timed workload")
            self.assertEqual(snapshot["guest_instructions"], 300000000)
            (directory / "nemu-uarch_state.json").write_text('{"inst_cnt":')
            self.assertEqual(progress(log, directory), {"phase": "timed workload"})

    def test_timeout_keeps_last_progress_and_cannot_pass(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            (directory / "zip-test.bin").write_bytes(b"payload")
            status = directory / "candidate-zip-test-status"
            status.mkdir()
            (status / "nemu-uarch_state.json").write_text('{"inst_cnt":999,"pc":"stale"}')
            simulator = directory / "simulator.py"
            simulator.write_text('''import json, os, pathlib, time
directory = pathlib.Path(os.environ["NEMU_STATUS_DIR"])
assert not (directory / "nemu-uarch_state.json").exists()
(directory / "nemu-uarch_state.json").write_text(json.dumps({"inst_cnt":100000000,"pc":"0x8000837a"}))
time.sleep(30)
''')
            args = SimpleNamespace(image_dir=directory, log_dir=directory, cwd=directory,
                                   timeout=1, progress_interval=1, nemu_status=True)
            with redirect_stdout(io.StringIO()):
                result = run_one(args, "candidate", [sys.executable, str(simulator)], "zip-test")
            self.assertFalse(result["passed"])
            self.assertIn("timed out after 1s during initialization", result["error"])
            self.assertEqual(result["last_progress"]["guest_instructions"], 100000000)


if __name__ == "__main__":
    unittest.main()
