import copy
import json
from pathlib import Path
import tempfile
import unittest

from prepare import checkpoint_union, full_plan
from run_model import validate_full_plan
from simpoints import make_plan
from validate import evaluate


GATES = {"cycle_error_percent": 5, "speedup_error_percent": 5,
         "warmup_change_percent": 1, "minimum_wall_speedup": 2,
         "minimum_models": 2, "ranking_tie_percent": 1}


class ValidationTests(unittest.TestCase):
    def result(self, name, kind, warmup, cycles):
        identifier = "kernel:full" if kind == "full" else "kernel:0"
        length = 1000 if kind == "full" else 100
        window = {"schema": "raptor-window-v1", "complete": True,
                  "warmup": warmup, "instructions": length, "start_pc": "0x80000000",
                  "boundaries": [{"instructions": warmup, "cycle": 100,
                                  "signature": "1", "last_pc": "0x80000004"},
                                 {"instructions": warmup + length,
                                  "cycle": 100 + cycles * length / 1000,
                                  "signature": "2", "last_pc": "0x80000008"}]}
        return {"schema": "raptor-model-evaluation-v1", "complete": True,
                "kind": kind, "name": name, "profile_sha256": "trace", "profile_inputs": {},
                "inputs": {"model": name, "reference": "ref", "mrom": "rom"},
                "settings": {"warmup": warmup}, "read_latency": 20, "write_latency": 30,
                "difftest": True, "jobs": 1, "wall_seconds": 100 if kind == "full" else 10,
                "execution_wall_seconds": 99 if kind == "full" else 9,
                "runs": [{"id": identifier, "passed": True, "returncode": 0, "window": window}],
                "measurements": [{"id": identifier, "instructions": length,
                                  "start": 100, "boundary_shift": 0}],
                "regions": [{"name": "kernel", "start": 100, "end": 1100, "instructions": 1000}],
                "estimates": {"complete": True, "regions": [
                    {"name": "kernel", "profiles": {name: {"cycles": cycles}}}]}}

    def run_study(self, mutate=None, selected=100):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = []
            for name, cycles in (("baseline", 2000), ("candidate", 1000)):
                full = self.result(name, "full", 300, cycles)
                full_path = root / (name + "-full.json")
                full_path.write_text(json.dumps(full))
                for warmup in (0, 100, 300):
                    sample = self.result(name, "sample", warmup,
                                         cycles * (1.1 if warmup == 0 else 1.002))
                    if mutate:
                        mutate(sample)
                    sample_path = root / f"{name}-{warmup}.json"
                    sample_path.write_text(json.dumps(sample))
                    cases.append((full_path, sample_path))
            return evaluate(cases, GATES, selected)

    def test_full_cycle_error_cost_and_architecture_ranking(self):
        result = self.run_study()
        self.assertTrue(result["complete"])
        self.assertEqual(len(result["comparisons"]), 6)
        self.assertTrue(result["rankings"][0]["ranking_preserved"])
        self.assertEqual(result["rankings"][0]["full_speedup"], 2)
        self.assertAlmostEqual(result["comparisons"][1]["cycle_error_percent"], .2)

    def test_memory_or_roi_mismatch_is_not_an_accuracy_result(self):
        with self.assertRaisesRegex(ValueError, "read_latency"):
            self.run_study(lambda sample: sample.update(read_latency=0))
        def change(sample):
            sample["regions"][0]["end"] += 1
        with self.assertRaisesRegex(ValueError, "regions"):
            self.run_study(change)

    def test_failed_difftest_cannot_be_a_complete_study(self):
        def change(sample):
            sample["runs"][0]["passed"] = False
        with self.assertRaisesRegex(ValueError, "failed"):
            self.run_study(change)

    def test_different_user_instruction_stream_cannot_establish_model_ranking(self):
        def change(sample):
            if sample["name"] == "candidate":
                sample["runs"][0]["window"]["boundaries"][-1]["signature"] = "different"
        with self.assertRaisesRegex(ValueError, "diverged"):
            self.run_study(change)

    def test_selecting_largest_warmup_does_not_fake_convergence(self):
        def change(sample):
            if sample["settings"]["warmup"] == 100:
                sample["estimates"]["regions"][0]["profiles"][sample["name"]]["cycles"] *= 1.02
        result = self.run_study(change, selected=300)
        self.assertFalse(result["complete"])
        self.assertTrue(any("warmup change" in error for error in result["errors"]))

    def test_short_samples_cannot_be_labeled_as_full_references(self):
        plan = {"regions": [{"start": 100, "instructions": 1000, "points": [
            {"start": 100, "instructions": 100, "weight": 1}]}]}
        with self.assertRaisesRegex(ValueError, "entire ROI"):
            validate_full_plan(plan)

    def test_prelude_warmup_and_capture_union_keep_exact_native_offsets(self):
        rows = [{"start": i * 100, "instructions": 100, "blocks": {str(i): 100},
                 "guest_start": 10000 + i * 100, "start_pc": hex(0x80000000 + i * 4),
                 "start_signature": f"{i:016x}"} for i in range(5)]
        regions = [{"name": "test", "start": 200, "end": 500, "warmup_start": 0}]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "trace"
            source.write_text("identity")
            plan = make_plan(source, rows, {"complete": True}, regions, 200, kmax=3)
        reference = full_plan(plan, rows, regions, 200)
        validate_full_plan(reference)
        point = reference["regions"][0]["points"][0]
        self.assertEqual((point["checkpoint_guest_start"], point["warmup"]), (10000, 200))
        union = checkpoint_union([plan, copy.deepcopy(plan), reference])
        offsets = [point["checkpoint_guest_start"] for region in union["regions"]
                   for point in region["points"]]
        self.assertEqual(len(offsets), len(set(offsets)))


if __name__ == "__main__":
    unittest.main()
