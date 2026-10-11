#!/usr/bin/env python3
"""Exercise the classic Sail plugin's timeout and failure paths without RTL."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "verify/riscof/classic/plugins/sail_cSim/riscof_sail_cSim.py"
spec = importlib.util.spec_from_file_location("classic_sail", PLUGIN)
module = importlib.util.module_from_spec(spec)
riscof = types.ModuleType("riscof")
riscof.__path__ = []
utils = types.ModuleType("riscof.utils")
template = types.ModuleType("riscof.pluginTemplate")
template.pluginTemplate = type("pluginTemplate", (), {})
riscof.utils = utils
with patch.dict(sys.modules, {"riscof": riscof, "riscof.utils": utils,
                              "riscof.pluginTemplate": template}):
    spec.loader.exec_module(module)


class Make:
    """Run real recipes, scaling the framework's implicit batch timeout down."""

    def __init__(self, makefilePath):
        self.path = Path(makefilePath)
        self.targets = []

    def add_target(self, command):
        name = "TEST" + str(len(self.targets))
        self.targets.append(name)
        with self.path.open("a") as stream:
            stream.write(f".PHONY: {name}\n{name}:\n\t{command}\n")

    def execute_all(self, cwd, timeout=0.05):
        return subprocess.run(
            [*self.makeCommand.split(), "-f", str(self.path), *self.targets],
            cwd=cwd, timeout=timeout, capture_output=True,
        ).returncode


class SailRunnerTest(unittest.TestCase):
    def exercise(self, *, count=1, delay=0, returncode=0, timeout=1,
                 compiler="true rv{0}", succeeds=True):
        with tempfile.TemporaryDirectory(prefix="riscof-sail-") as directory:
            root = Path(directory)
            sail = root / "fake-sail"
            sail.write_text(
                f"#!{sys.executable}\n"
                "from pathlib import Path\nimport sys\nimport time\n"
                f"time.sleep({delay})\n"
                f"if {returncode}: sys.exit({returncode})\n"
                "sig = next(a.split('=', 1)[1] for a in sys.argv "
                "if a.startswith('--test-signature='))\n"
                "Path(sig).write_text('12345678\\n')\n"
            )
            sail.chmod(0o755)
            runner = object.__new__(module.sail_cSim)
            runner.work_dir = directory
            runner.pluginpath = str(PLUGIN.parent)
            runner.name = "Reference-sail_c_simulator_"
            runner.make = "make"
            runner.num_jobs = "2"
            runner.xlen = "32"
            runner.timeout = timeout
            runner.sail_exe = str(sail)
            runner.compile_cmd = compiler
            runner.objdump_cmd = "true &&"
            tests = {}
            for index in range(count):
                work = root / str(index)
                work.mkdir()
                tests[str(index)] = {"test_path": "/suite/test.S", "work_dir": str(work),
                                     "isa": "RV32I", "macros": ["XLEN=32"]}
            with patch.object(module.utils, "makeUtil", Make, create=True):
                if succeeds:
                    runner.runTests(tests)
                else:
                    with self.assertRaisesRegex(RuntimeError, "Sail build/run failed"):
                        runner.runTests(tests)
            signatures = list(root.glob("*/Reference-*.signature"))
            self.assertEqual(len(signatures), count if succeeds else 0)
            for signature in signatures:
                self.assertEqual(signature.read_text(), "12345678\n")
            logs = {p.name: p.read_text() for p in (root / "0").glob("*.log")}
            return logs

    def test_parallel_batch_outlives_implicit_framework_timeout(self):
        self.exercise(count=3, delay=0.1)

    def test_reference_failure_stops_flow(self):
        self.exercise(returncode=7, succeeds=False)

    def test_per_reference_timeout_stops_flow(self):
        self.exercise(delay=0.5, timeout=0.05, succeeds=False)

    def test_compiler_failure_preserves_build_log(self):
        logs = self.exercise(compiler="echo compiler-failed; false", succeeds=False)
        self.assertIn("compiler-failed", logs["build.log"])
        self.assertNotIn("test.log", logs)


if __name__ == "__main__":
    unittest.main()
