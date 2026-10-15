#!/usr/bin/env python3
"""Exercise the classic Sail plugin's timeout and failure paths without RTL."""

import importlib.util
import configparser
import os
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
template.pluginTemplate = type("pluginTemplate", (), {"__init__": lambda self, **kwargs: None})
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
    suite = "classic"

    def make_runner(self):
        directory = ROOT / "verify/riscof" / self.suite
        config = configparser.ConfigParser()
        config.read(directory / "config.ini")
        self.assertEqual((directory / config["RISCOF"]["ReferencePluginPath"]).resolve(),
                         PLUGIN.parent)
        settings = dict(config["sail_cSim"])
        for name in ("pluginpath", "sail_config"):
            if name in settings:
                settings[name] = str((directory / settings[name]).resolve())
        return module.sail_cSim(config=settings)

    def test_profile_defaults_and_environment_override(self):
        with patch.dict(os.environ, {}, clear=True):
            runner = self.make_runner()
            self.assertEqual(runner.num_jobs, "4")
            self.assertEqual(runner.timeout, 40 if self.suite == "classic-nemu" else 630)
        with patch.dict(os.environ, {"RAPT_JOBS": "2", "RAPT_TIMEOUT": "15"}):
            runner = self.make_runner()
            self.assertEqual((runner.num_jobs, runner.timeout), ("2", 45))
        self.assertEqual(Path(runner.sail_config).name,
                         "nemu.json" if self.suite == "classic-nemu" else "raptor.json")
        self.assertTrue(Path(runner.sail_config).is_file())

    def exercise(self, *, count=1, delay=0, returncode=0, timeout=1,
                 compiler="true rv{0}", succeeds=True, xlen="32"):
        with tempfile.TemporaryDirectory(prefix="riscof-sail-") as directory:
            root = Path(directory)
            runner = self.make_runner()
            sail = root / "fake-sail"
            sail.write_text(
                f"#!{sys.executable}\n"
                "from pathlib import Path\nimport sys\nimport time\n"
                f"assert '--config-override={runner.sail_config}' in sys.argv\n"
                f"assert ('--rv32' in sys.argv) == {xlen == '32'}\n"
                f"time.sleep({delay})\n"
                f"if {returncode}: sys.exit({returncode})\n"
                "sig = next(a.split('=', 1)[1] for a in sys.argv "
                "if a.startswith('--test-signature='))\n"
                "Path(sig).write_text('12345678\\n')\n"
            )
            sail.chmod(0o755)
            runner.work_dir = directory
            runner.name = "Reference-sail_c_simulator_"
            runner.make = "make"
            runner.num_jobs = "2"
            runner.xlen = xlen
            runner.timeout = timeout
            runner.sail_exe = str(sail)
            runner.compile_cmd = compiler
            runner.objdump_cmd = "true &&"
            tests = {}
            for index in range(count):
                work = root / str(index)
                work.mkdir()
                tests[str(index)] = {"test_path": "/suite/test.S", "work_dir": str(work),
                                     "isa": f"RV{xlen}I", "macros": [f"XLEN={xlen}"]}
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

    def test_rv64_reference(self):
        self.exercise(xlen="64")

    def test_reference_failure_stops_flow(self):
        self.exercise(returncode=7, succeeds=False)

    def test_per_reference_timeout_stops_flow(self):
        self.exercise(delay=0.5, timeout=0.05, succeeds=False)

    def test_compiler_failure_preserves_build_log(self):
        logs = self.exercise(compiler="echo compiler-failed; false", succeeds=False)
        self.assertIn("compiler-failed", logs["build.log"])
        self.assertNotIn("test.log", logs)


class NemuSailRunnerTest(SailRunnerTest):
    suite = "classic-nemu"


if __name__ == "__main__":
    unittest.main()
