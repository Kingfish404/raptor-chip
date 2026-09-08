#!/usr/bin/env python3
"""Exercise STA preflight in disposable trees, without network or installation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class StaEntrypointsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rapt-sta-entry-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("Makefile", "sim/Makefile", "sim/Kconfig", "sim/scripts/config.mk",
                     "lspd/syn/Makefile", "lspd/modules.mk"):
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, dest)
        for name in ("sim/.config", "sim/include/config/auto.conf",
                     "hdl/configs/default/rapt_config.svh", "hdl/chisel/Makefile"):
            self.file(name)
        (self.root / "hdl/chisel/src").mkdir()
        (self.root / "bin").mkdir()
        self.file("bin/yosys", "#!/bin/sh\nexit 0\n", executable=True)
        # Any accidental network/tool setup is a test failure, even if a caller
        # swallows that command's exit status and continues.
        for name in ("git", "cmake"):
            self.file(f"bin/{name}",
                      '#!/bin/sh\necho FORBIDDEN_TOOL_SETUP >&2\nexit 91\n', executable=True)
        self.flow = "third_party/yosys-opensta"
        self.sta = self.file(f"{self.flow}/third_party/OpenSTA/build/sta",
                             "#!/bin/sh\nexit 0\n", executable=True)
        for platform in ("nangate45", "sky130hd"):
            for name in ("config.tcl", "yosys_config.tcl"):
                self.file(f"{self.flow}/platforms/{platform}/{name}")
        for name in ("merged.lib", "NangateOpenCellLibrary_typical.lib"):
            self.file(f"{self.flow}/third_party/lib/nangate45/lib/{name}")
        self.file(f"{self.flow}/third_party/lib/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib")

    def file(self, name, contents="\n", executable=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        if executable:
            path.chmod(0o755)
        return path

    def run_check(self, *options, target="sta-deps"):
        env = os.environ.copy()
        for name in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "RAPTOR_HOME", "RAPT_CONFIG"):
            env.pop(name, None)
        env["PATH"] = str(self.root / "bin") + os.pathsep + env["PATH"]
        run = subprocess.run(["make", "-s", "-C", str(self.root / "sim"), target,
                              "LZ4_PREFIX=", *options], env=env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        self.assertNotIn("FORBIDDEN_TOOL_SETUP", run.stdout)
        return run

    def test_ready_is_offline_and_strips_default_platform(self):
        run = self.run_check()
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("tools and nangate45 libraries are ready", run.stdout)

    def test_sky130_name_translation(self):
        for platform in ("sky130hd", "sky130", " sky130 "):
            with self.subTest(platform=platform):
                run = self.run_check(f"STA_PLATFORM={platform}")
                self.assertEqual(run.returncode, 0, run.stdout)
                self.assertIn("tools and sky130 libraries are ready", run.stdout)

    def test_sky130_alias_reaches_sta_flow(self):
        self.file(f"{self.flow}/Makefile",
                  '.PHONY: sta show\nsta show:\n\t@test "$(PLATFORM)" = sky130hd\n')
        # Skip RTL packing only: exercise the real preflight and flow recipe.
        run = self.run_check("STA_PLATFORM=sky130", "-o", "pack-synth-check",
                             target="sta-flops")
        self.assertEqual(run.returncode, 0, run.stdout)

    def test_missing_sky130_config_is_not_masked_by_alias(self):
        (self.root / self.flow / "platforms/sky130hd/config.tcl").unlink()
        run = self.run_check("STA_PLATFORM=sky130")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("missing STA platform config for sky130hd", run.stdout)

    def test_missing_opensta_fails_with_setup_guidance(self):
        self.sta.unlink()
        run = self.run_check()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("missing OpenSTA", run.stdout)
        self.assertIn("sta-setup", run.stdout)

    def test_missing_sta_lib_is_not_masked_by_synthesis_lib(self):
        (self.root / self.flow / "third_party/lib/nangate45/lib/NangateOpenCellLibrary_typical.lib").unlink()
        run = self.run_check()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("missing NanGate45 STA Liberty", run.stdout)

    def test_missing_slang_fails_without_installing(self):
        self.file("bin/yosys", "#!/bin/sh\nexit 1\n", executable=True)
        run = self.run_check()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("slang plugin is unavailable", run.stdout)


if __name__ == "__main__":
    unittest.main()
