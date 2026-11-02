import json
from pathlib import Path
import tempfile
import unittest

from simpoints import cluster_rows, make_plan, read_profile, summarize


class SamplingTests(unittest.TestCase):
    def test_distinct_phases_and_partial_tail_keep_instruction_weights(self):
        rows = [dict(start=i * 100, instructions=100, blocks={"loop": 100}) for i in range(20)]
        rows.append(dict(start=2000, instructions=10, blocks={"cleanup": 10}))
        representatives = cluster_rows(rows)
        self.assertEqual(len(representatives), 2)
        self.assertEqual(sorted(n for _, n in representatives), [10, 2000])
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "profile"
            source.write_text("input identity")
            plan = make_plan(source, rows, {"complete": True},
                             [{"name": "test", "start": 0, "end": 2010}], 50)
        self.assertAlmostEqual(sum(p["weight"] for p in plan["regions"][0]["points"]), 1)
        self.assertEqual(sum(p["represented_instructions"]
                             for p in plan["regions"][0]["points"]), 2010)

    def test_profile_refuses_truncation_bad_totals_and_noncontiguous_intervals(self):
        row = {"schema": "raptor-bbv-v1", "start": 0,
               "instructions": 100, "blocks": {"1": 100}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile"
            path.write_text(json.dumps(row) + "\n")
            with self.assertRaisesRegex(ValueError, "not complete"):
                read_profile(path)
            self.assertEqual(len(read_profile(path, allow_prefix=True)[0]), 1)
            for update in ({"instructions": 99}, {"start": 1}):
                path.write_text(json.dumps({**row, **update}) + "\n")
                with self.assertRaises(ValueError):
                    read_profile(path, allow_prefix=True)

    def test_qemu_vectors_require_explicit_prefix_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile"
            path.write_text("T:1:80 :2:20\nT:2:10\n")
            rows, footer = read_profile(path, allow_prefix=True)
        self.assertIsNone(footer)
        self.assertEqual([r["instructions"] for r in rows], [100, 10])
        self.assertEqual(rows[1]["start"], 100)

    def test_subtest_boundary_cannot_silently_drop_crossing_interval(self):
        rows = [dict(start=0, instructions=100, blocks={"loop": 100})]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile"
            path.write_text("input")
            with self.assertRaisesRegex(ValueError, "boundaries"):
                make_plan(path, rows, None, [{"name": "test", "start": 1, "end": 100}], 0)

    def test_warmup_starts_on_a_fingerprinted_profile_boundary(self):
        rows = [dict(start=i * 100, instructions=100, blocks={str(i): 100},
                     start_signature=f"{i:016x}", guest_start=1000 + i * 100)
                for i in range(3)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile"
            path.write_text("input")
            plan = make_plan(path, rows, {"complete": True},
                             [{"name": "test", "start": 0, "end": 300}], 50, kmax=3)
        for point in plan["regions"][0]["points"]:
            self.assertEqual(point["checkpoint_start"] % 100, 0)
            self.assertEqual(point["checkpoint_guest_start"], 1000 + point["checkpoint_start"])
            self.assertEqual(point["checkpoint_signature"], f"{point['checkpoint_start'] // 100:016x}")

    def test_cpi_aggregation_does_not_average_ipc(self):
        points = [dict(id="a", start=0, instructions=100, weight=0.25),
                  dict(id="b", start=100, instructions=100, weight=0.75)]
        plan = {"schema": "raptor-sample-plan-v1", "regions": [
            {"name": "test", "instructions": 1000, "points": points}]}
        runs = [dict(profile="base", id=p["id"], start=p["start"], instructions=100,
                     cycles=cycles, passed=True) for p, cycles in zip(points, (100, 400))]
        result = summarize(plan, runs)
        self.assertTrue(result["complete"])
        self.assertEqual(result["regions"][0]["profiles"]["base"]["cycles"], 3250)
        result = summarize(plan, runs[:1])
        self.assertFalse(result["complete"])
        self.assertEqual(result["regions"][0]["profiles"], {})

    def test_duplicate_measurements_and_wrong_instruction_start_are_rejected(self):
        plan = {"schema": "raptor-sample-plan-v1", "regions": [
            {"name": "test", "instructions": 100, "points": [
                dict(id="a", start=0, instructions=100, weight=1)]}]}
        row = dict(profile="base", id="a", start=1, instructions=100, cycles=100, passed=True)
        with self.assertRaisesRegex(ValueError, "start"):
            summarize(plan, [row])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            summarize(plan, [row, row])


if __name__ == "__main__":
    unittest.main()
