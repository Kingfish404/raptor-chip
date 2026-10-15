import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from report import BENCHMARKS, render_markdown


class ReportTests(unittest.TestCase):
    def test_benchmark_workflow_avoids_login_shell_logout_failure(self):
        workflow = (Path(__file__).resolve().parents[3] /
                    ".github/workflows/benchmark.yaml").read_text()
        self.assertIn(
            "defaults:\n  run:\n    shell: bash --noprofile --norc -eo pipefail {0}",
            workflow,
        )
        self.assertIn(
            "- name: Embench full-suite summary\n"
            "        if: always()\n"
            "        shell: bash --noprofile --norc -eo pipefail {0}",
            workflow,
        )

        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / ".bash_logout").write_text("exit 1\n")
            environment = dict(os.environ, HOME=directory)
            result = subprocess.run(
                ["bash", "-leo", "pipefail", "-c", "exit 0"],
                env=environment, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 1)
            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", "exit 0"],
                env=environment, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0)

    def test_complete_suite_make_targets_exit_successfully(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "embench-baremetal-rv32"
            logs.mkdir()
            reference = root / "reference.json"
            reference.write_text(json.dumps({name: 1 for name in BENCHMARKS}))
            for name in BENCHMARKS:
                (logs / f"{name}.log").write_text(
                    "Cycles: 1000\n[PASS]\nHIT GOOD TRAP\n"
                )

            result = subprocess.run(
                ["make", "-C", str(Path(__file__).resolve().parents[2]),
                 "embench-baremetal-report-sim", "ISA64=0",
                 f"APP_LOG_DIR={root}", f"EMBENCH_REF_JSON={reference}"],
                capture_output=True, text=True, check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("19/19 pass", (root / "embench-baremetal-rv32.md").read_text())

            summary = root / "summary.md"
            script = (
                "report_rc=0\n"
                "make app-embench-baremetal-report-rv32 "
                "APP_LOG_DIR=\"$APP_LOG_DIR\" "
                "EMBENCH_REF_JSON=\"$EMBENCH_REF_JSON\" || report_rc=$?\n"
                "cat \"$APP_LOG_DIR/embench-baremetal-rv32.md\" "
                ">> \"$GITHUB_STEP_SUMMARY\" || true\n"
                "exit \"$report_rc\"\n"
            )
            environment = dict(os.environ, APP_LOG_DIR=str(root),
                               EMBENCH_REF_JSON=str(reference),
                               GITHUB_STEP_SUMMARY=str(summary))
            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                cwd=Path(__file__).resolve().parents[3], env=environment,
                capture_output=True, text=True, check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("19/19 pass", result.stdout)
            self.assertIn("19/19 pass", summary.read_text())

    def test_complete_suite_cli_exits_successfully(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir()
            reference = root / "reference.json"
            output = root / "report.md"
            reference.write_text(json.dumps({name: 1 for name in BENCHMARKS}))
            for name in BENCHMARKS:
                (logs / f"{name}.log").write_text(
                    "Cycles: 1000\n[PASS]\nHIT GOOD TRAP\n"
                )

            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("report.py")),
                 "--log-dir", str(logs), "--reference", str(reference),
                 "--output", str(output)],
                capture_output=True, text=True, check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("19/19 pass", output.read_text())
            self.assertIn("Score=**1.000**", output.read_text())

    def test_ci_summary_step_preserves_report_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "embench-baremetal-rv64"
            logs.mkdir()
            reference = root / "reference.json"
            summary = root / "summary.md"
            reference.write_text(json.dumps({name: 1 for name in BENCHMARKS}))
            for name in BENCHMARKS:
                (logs / f"{name}.log").write_text(
                    "Cycles: 1000\n[PASS]\nHIT GOOD TRAP\n"
                )

            script = (
                "report_rc=0\n"
                "make --no-print-directory -C app embench-baremetal-report-sim "
                "ISA64=1 APP_LOG_DIR=\"$APP_LOG_DIR\" "
                "EMBENCH_REF_JSON=\"$EMBENCH_REF_JSON\" || report_rc=$?\n"
                "cat \"$APP_LOG_DIR/embench-baremetal-rv64.md\" "
                ">> \"$GITHUB_STEP_SUMMARY\" || true\n"
                "echo \"Embench report exit status: $report_rc\"\n"
                "exit \"$report_rc\"\n"
            )
            environment = dict(os.environ, APP_LOG_DIR=str(root),
                               EMBENCH_REF_JSON=str(reference),
                               GITHUB_STEP_SUMMARY=str(summary))

            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                cwd=Path(__file__).resolve().parents[3], env=environment,
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Embench report exit status: 0", result.stdout)
            self.assertIn("19/19 pass", summary.read_text())

            (logs / f"{BENCHMARKS[0]}.log").unlink()
            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                cwd=Path(__file__).resolve().parents[3], env=environment,
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("Embench report exit status: 2", result.stdout)

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
