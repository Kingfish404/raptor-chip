import copy
from pathlib import Path
import tempfile
import unittest

from fpga_validate import checked_case, evaluate
from pc_reference import ALGORITHM, PcReference
from run_samples import matched_window
from simpoints import digest
from test_pc_reference import window, write_profile


GATES = {"cycle_error_percent": 5, "speedup_error_percent": 5,
         "warmup_change_percent": 1, "repeat_variation_percent": 1,
         "minimum_wall_speedup": 2, "ranking_tie_percent": 1}


class FpgaValidationTests(unittest.TestCase):
    def source(self, name, cycles):
        result = {"schema": "raptor-fpga-evaluation-v1", "complete": True,
                  "routed": {"timing_pass": True}, "repetitions": 3, "setup": [],
                  "build": {"sha256": name, "configuration": {
                      "memory": "ddr", "clock_mhz": 50, "xlen": 64, "ddr_part": "part"}},
                  "cases": []}
        for warmup in (None, 0, 100, 300):
            full = warmup is None
            identifier = "full" if full else f"sample-{warmup}"
            length = 1000 if full else 128
            estimate = cycles if full else cycles * 1.002
            point = {"id": identifier, "start": 0, "warmup": warmup or 0,
                     "instructions": length, "start_pc": "0x80000000"}
            case = {"id": identifier, "kind": "full" if full else "sample",
                    "profile_sha256": "trace", "profile_inputs": {"firmware": "firmware"},
                    "retirement_domain": {"mode": "all"},
                    "regions": [{"name": "roi", "start": 0, "end": 1000,
                                 "instructions": 1000}],
                    "settings": {"warmup": warmup or 0}, "runs": [], "estimates": []}
            for repeat in range(3):
                window = {"schema": "raptor-window-v1", "complete": True,
                          "warmup": point["warmup"], "instructions": length,
                          "start_pc": point["start_pc"], "boundaries": [
                              {"instructions": point["warmup"], "cycle": 100,
                               "last_pc": "0x80000004", "signature": "1"},
                              {"instructions": point["warmup"] + length,
                               "cycle": 100 + estimate * length / 1000,
                               "last_pc": "0x80000008", "signature": "2"}]}
                case["runs"].append({"id": identifier, "point": point,
                    "repetition": repeat, "window": window,
                    "measurement": matched_window(window, window, point),
                    "delta_transfer": {"readback_verified": True},
                    "sram_transfer": {"readback_verified": True},
                    "wall_seconds": 100 if full else 10,
                    "execution_wall_seconds": 90 if full else 9})
                case["estimates"].append({"complete": True, "regions": [
                    {"name": "roi", "profiles": {identifier: {"cycles": estimate}}}]})
            result["cases"].append(case)
        return result

    def study(self):
        return {"baseline": self.source("baseline", 2000), "candidate": self.source("candidate", 1000)}

    def test_accuracy_cost_convergence_and_cross_bitstream_signatures(self):
        result = evaluate(self.study(), 100, GATES)
        self.assertTrue(result["complete"])
        self.assertTrue(result["rankings"][0]["ranking_preserved"])

    def test_transfer_cost_cannot_be_hidden_by_fast_execution(self):
        sources = self.study()
        for case in sources["candidate"]["cases"][1:]:
            for run in case["runs"]:
                run["wall_seconds"] = 110
        result = evaluate(sources, 100, GATES)
        self.assertFalse(result["complete"])
        self.assertTrue(any("transfers" in error for error in result["errors"]))

    def test_convergence_requires_a_stable_longest_warmup_reference(self):
        sources = self.study()
        case = sources["candidate"]["cases"][-1]
        for run, estimate, scale in zip(case["runs"], case["estimates"], (.97, 1, 1.03)):
            window = run["window"]
            start, end = window["boundaries"]
            end["cycle"] = start["cycle"] + (end["cycle"] - start["cycle"]) * scale
            run["measurement"] = matched_window(window, window, run["point"])
            estimate["regions"][0]["profiles"][case["id"]]["cycles"] *= scale
        result = evaluate(sources, 100, GATES)
        self.assertFalse(result["complete"])
        self.assertTrue(any("unstable" in error for error in result["errors"]))
        witness = next(row for row in result["warmup_convergence"]
                       if row["model"] == "candidate")
        self.assertAlmostEqual(witness["change_percent"], 0)
        self.assertGreater(witness["repeat_variation_percent"]["largest"], 1)

    def test_failed_readback_rejects_hardware_result(self):
        sources = self.study()
        sources["candidate"]["cases"][1]["runs"][0]["delta_transfer"]["readback_verified"] = False
        with self.assertRaisesRegex(ValueError, "not verified"):
            evaluate(sources, 100, GATES)

    def test_missing_point_in_one_repeat_rejects_result(self):
        sources = self.study()
        sources["candidate"]["cases"][1]["runs"].pop()
        with self.assertRaisesRegex(ValueError, "missing points"):
            evaluate(sources, 100, GATES)

    def test_repeated_instruction_stream_divergence_is_rejected(self):
        sources = self.study()
        run = sources["candidate"]["cases"][1]["runs"][1]
        run["window"] = copy.deepcopy(run["window"])
        run["window"]["boundaries"][-1]["signature"] = "3"
        with self.assertRaisesRegex(ValueError, "diverged"):
            evaluate(sources, 100, GATES)

    def test_same_code_with_different_workload_inputs_cannot_establish_a_ranking(self):
        sources = self.study()
        for case in sources["candidate"]["cases"]:
            case["profile_inputs"] = {"firmware": "different"}
        with self.assertRaisesRegex(ValueError, "profile_inputs"):
            evaluate(sources, 100, GATES)

    def test_explicit_profile_selection_keeps_other_studies_visible(self):
        sources = self.study()
        for result in sources.values():
            other = copy.deepcopy(result["cases"])
            for case in other:
                case["profile_sha256"] = "long-trace"
                case["id"] = "long-" + case["id"]
            result["cases"].extend(other)
        with self.assertRaisesRegex(ValueError, "one full reference"):
            evaluate(sources, 100, GATES)
        selected = evaluate(sources, 100, GATES, "trace")
        self.assertTrue(selected["complete"])
        self.assertEqual(len(selected["excluded_cases"]["baseline"]), 4)
        self.assertEqual(selected["profile_sha256"], "trace")
        sources["candidate"]["complete"] = False
        with self.assertRaisesRegex(ValueError, "incomplete"):
            evaluate(sources, 100, GATES, "trace")

    def test_native_reference_rejects_identically_wrong_repeated_streams(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profile.bbv.jsonl"
            pcs = [0x80000000 + 4 * (i % 17) for i in range(1000)]
            write_profile(path, pcs, 1000)
            sha = digest(path)
            reference = PcReference(path, sha, {"mode": "all"})
            case = self.source("baseline", 2000)["cases"][0]
            case["profile_sha256"] = sha
            case["pc_reference"] = {"path": str(path), "sha256": sha, "algorithm": ALGORITHM}
            for run in case["runs"]:
                run["point"]["checkpoint_start"] = 0
                current = window(pcs, 0, [0, 1000])
                for row, old in zip(current["boundaries"], run["window"]["boundaries"]):
                    row["cycle"] = old["cycle"]
                run["window"].update(current)
                run["native_pc_audit"] = reference.verify(run["window"], run["point"])
            checked_case(case, 3)
            for run in case["runs"]:
                run["window"]["boundaries"][-1]["signature"] = "deadbeef"
            with self.assertRaisesRegex(ValueError, "differs from native"):
                checked_case(case, 3)


if __name__ == "__main__":
    unittest.main()
