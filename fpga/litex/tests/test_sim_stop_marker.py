"""Exercise the real simulation recipe's completion and exit-status handling."""

from pathlib import Path
import subprocess
import tempfile
import unittest


class SimStopMarkerTest(unittest.TestCase):
    def run_sim(self, body):
        recipes = (Path(__file__).resolve().parents[1] / "mk/recipes.mk").read_text()
        start = recipes.index("define _run_vsim\n")
        end = recipes.index("endef", start) + len("endef")
        with tempfile.TemporaryDirectory(prefix="sim-stop-marker-") as tmp:
            root = Path(tmp)
            (root / "obj_dir").mkdir()
            simulator = root / "obj_dir/Vsim"
            simulator.write_text("#!/bin/bash\n" + body + "\n")
            simulator.chmod(0o755)
            makefile = root / "Makefile"
            makefile.write_text(
                "SHELL := /bin/bash\nSIM_STOP_MARKER := finished\nSIM_TIMEOUT := 2\n"
                + recipes[start:end] + f"\nrun:\n\t$(call _run_vsim,{root})\n")
            return subprocess.run(["make", "--no-print-directory", "-f", str(makefile), "run"],
                                  capture_output=True, text=True, timeout=15)

    def test_marker_and_normal_exit(self):
        result = self.run_sim("echo finished")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_marker_and_intentional_termination(self):
        result = self.run_sim("echo finished; exec sleep 30")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_marker(self):
        self.assertNotEqual(self.run_sim("exit 0").returncode, 0)

    def test_timeout(self):
        self.assertNotEqual(self.run_sim("exec sleep 30").returncode, 0)

    def test_abnormal_exit_after_marker(self):
        self.assertNotEqual(self.run_sim("echo finished; exit 7").returncode, 0)

    def test_abnormal_exit_without_marker(self):
        self.assertNotEqual(self.run_sim("exit 7").returncode, 0)


if __name__ == "__main__":
    unittest.main()
