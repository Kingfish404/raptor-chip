import unittest

from report import BENCHMARKS, render_markdown


class ReportTests(unittest.TestCase):
    def test_complete_suite_has_geometric_mean_score(self):
        rows = [{"name": name, "status": "PASS", "speed": 4.0} for name in BENCHMARKS]

        markdown, passed = render_markdown(rows, "Embench", "cycles")

        self.assertTrue(passed)
        self.assertIn("Score=**4.000**", markdown)
        self.assertIn("19/19 pass", markdown)

    def test_missing_shard_log_cannot_produce_partial_score(self):
        rows = [{"name": name, "status": "PASS", "speed": 4.0} for name in BENCHMARKS]
        rows[-1]["status"] = "FAIL"
        rows[-1]["speed"] = None

        markdown, passed = render_markdown(rows, "Embench", "cycles")

        self.assertFalse(passed)
        self.assertIn("Score=**N/A**", markdown)
        self.assertIn("18/19 pass", markdown)

    def test_missing_reference_cannot_produce_partial_score(self):
        rows = [{"name": name, "status": "PASS", "speed": 4.0} for name in BENCHMARKS]
        rows[-1]["speed"] = None

        markdown, passed = render_markdown(rows, "Embench", "ticks")

        self.assertFalse(passed)
        self.assertIn("Score=**N/A**", markdown)


if __name__ == "__main__":
    unittest.main()
