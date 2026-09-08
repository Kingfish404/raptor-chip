"""Runner bookkeeping tests; these do not certify the ACT4 DUT."""
import subprocess
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from run_act4 import run_one


class Act4RunnerTest(unittest.TestCase):
    def test_make_timeout_default_and_overrides(self):
        # Evaluate only this assignment, not the repository Makefile (which
        # has parsing side effects and may interact with concurrent builds).
        makefile = Path(__file__).resolve().parents[1] / "Makefile"
        setting = next(line for line in makefile.read_text().splitlines()
                       if line.startswith("ACT4_TIMEOUT ?="))
        script = "TIMEOUT ?= 10\n" + setting + "\nall:\n\t@echo $(ACT4_TIMEOUT)\n"
        env = dict(os.environ)
        for key in ("TIMEOUT", "ACT4_TIMEOUT", "MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            env.pop(key, None)
        for args, expected in (([], "60"), (["TIMEOUT=90"], "90"),
                               (["ACT4_TIMEOUT=120"], "120"),
                               (["TIMEOUT=90", "ACT4_TIMEOUT=120"], "120")):
            with self.subTest(args=args):
                result = subprocess.run(["make", "--no-print-directory", "-f", "-", *args],
                                        input=script, text=True, capture_output=True,
                                        check=True, env=env)
                self.assertEqual(result.stdout.strip(), expected)

    def test_missing_npc_fails_before_creating_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "logs"
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("run_act4.py")),
                 "--npc-bin", str(root / "absent-npc"), "--log-dir", str(log), str(root)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("NPC binary is missing", result.stderr)
            self.assertFalse(log.exists())

    def invoke(self, outcome, *, conversion=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            elf = root / "D" / "test.elf"
            log = root / "logs" / "D" / "test.log"
            log.parent.mkdir(parents=True)
            log.write_text("stale success")
            results = [conversion or subprocess.CompletedProcess([], 0), outcome]
            with patch("run_act4.subprocess.run", side_effect=results) as run:
                failed = run_one(elf, elf_root=root, npc_bin="npc", objcopy="objcopy",
                                 mrom_img="boot", nemu_so=None, log_dir=root / "logs",
                                 timeout=10, mem_random_delay=0, mem_random_seed=1)
            temporary_bin = Path(run.call_args_list[0].args[0][-1])
            self.assertFalse(temporary_bin.exists())
            return failed, log.read_text()

    def test_timeout_retains_bytes_and_is_not_pass(self):
        failed, log = self.invoke(subprocess.TimeoutExpired(
            ["npc"], 10, output=b"RVCP-SUMMARY: TEST PASSED\npartial\xff", stderr=b"error"))
        self.assertTrue(failed)
        self.assertIn("Exit: TIMEOUT", log)
        self.assertIn("partial\ufffderror", log)
        self.assertIn("Command:", log)
        self.assertNotIn("stale success", log)

    def test_timeout_without_output(self):
        failed, log = self.invoke(subprocess.TimeoutExpired(["npc"], 10))
        self.assertTrue(failed)
        self.assertIn("Wall timeout: 10s", log)

    def test_timeout_string_output(self):
        failed, log = self.invoke(subprocess.TimeoutExpired(["npc"], 10, output="partial"))
        self.assertTrue(failed)
        self.assertIn("partial", log)

    def test_success_requires_zero_exit_and_pass_summary(self):
        for status, output, expected in [
            (0, "RVCP-SUMMARY: TEST PASSED", False),
            (1, "RVCP-SUMMARY: TEST PASSED", True),
            (0, "RVCP-SUMMARY: TEST FAILED", True),
            (0, "RVCP-SUMMARY: TEST SIGRUN", True),
            (0, "no summary", True),
        ]:
            with self.subTest(status=status, output=output):
                failed, log = self.invoke(subprocess.CompletedProcess([], status, output, ""))
                self.assertEqual(failed, expected)
                self.assertIn("Elapsed:", log)

    def test_launch_error_replaces_stale_log(self):
        failed, log = self.invoke(FileNotFoundError("NPC missing"))
        self.assertTrue(failed)
        self.assertIn("NPC launch failed", log)
        self.assertNotIn("stale success", log)

    def test_conversion_error_cleans_temporary_file(self):
        for error in (FileNotFoundError("objcopy missing"),
                      subprocess.CalledProcessError(1, ["objcopy"], stderr=b"bad ELF")):
            with self.subTest(error=error):
                failed, log = self.invoke(None, conversion=error)
                self.assertTrue(failed)
                self.assertIn("objcopy", log)
                self.assertNotIn("stale success", log)


if __name__ == "__main__":
    unittest.main()
