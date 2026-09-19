#!/usr/bin/env python3
"""Fast runner contract checks; no synthesis tools or PDKs required."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[2] / "sim/scripts/sta.py"
FAKE_MAKE = """.PHONY: sta sta-detail show
sta sta-detail show:
	@echo 'goal=$@ platform=$(PLATFORM) frequency=$(CLK_FREQ_MHZ) design=$(DESIGN) libs=[$(EXTRA_LIB_FILES)] blackboxes=[$(EXTRA_BLACKBOX_V_FILES)]'
	@mkdir -p result/$(PLATFORM)-rapt-$(CLK_FREQ_MHZ)MHz
	@echo "$$FAKE_STA_MESSAGE" > result/$(PLATFORM)-rapt-$(CLK_FREQ_MHZ)MHz/sta.log
	@echo fixture > result/$(PLATFORM)-rapt-$(CLK_FREQ_MHZ)MHz/sta_detail.log
"""


class DffFlowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="raptor-chip-dff-test-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.backend = self.root / "backend"
        for directory in ("scripts", "third_party", "platforms/nangate45", "platforms/custom22"):
            (self.backend / directory).mkdir(parents=True, exist_ok=True)
        for platform in ("nangate45", "custom22"):
            (self.backend / "platforms" / platform / "platform.mk").touch()
        (self.backend / "Makefile").write_text(FAKE_MAKE)
        self.rtl = self.root / "rapt.sv"
        self.rtl.write_text("module rapt; endmodule\n")
        self.work = self.root / "work"

    def run_flow(self, *extra, **environment):
        return subprocess.run(
            [sys.executable, str(RUNNER), "--backend", str(self.backend),
             "--work-dir", str(self.work), "--rtl", str(self.rtl),
             "--platform", "nangate45", "--frequency", "50", *extra],
            env={**os.environ, **environment}, text=True, capture_output=True)

    def test_macro_inputs_and_outer_make_flags_are_not_inherited(self):
        result = self.run_flow(EXTRA_LIB_FILES="bad.lib", EXTRA_BLACKBOX_V_FILES="bad.v",
                               MAKEFLAGS="--invalid-outer-option")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("libs=[] blackboxes=[]", result.stdout)
        self.assertFalse((self.backend / "result").exists())
        self.assertTrue((self.work / "result/nangate45-rapt-50MHz/sta.log").is_file())
        self.assertEqual(self.run_flow().returncode, 0)  # reusable workspace

    def test_custom_platform_frequency_and_detail(self):
        result = self.run_flow("--platform", "custom22", "--frequency", "80", "--detail")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("goal=sta platform=custom22 frequency=80", result.stdout)
        self.assertIn("goal=sta-detail", result.stdout)
        self.assertLess(result.stdout.index("goal=sta "), result.stdout.index("goal=sta-detail"))

    def test_sram_requires_and_passes_explicit_libraries(self):
        self.assertNotEqual(self.run_flow("--memory", "sram").returncode, 0)
        lib = self.root / "macro.lib"
        lib.write_text("library(macro) {}\n")
        result = self.run_flow("--memory", "sram", "--lib", str(lib))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"libs=[{lib}] blackboxes=[]", result.stdout)
        self.assertNotEqual(self.run_flow("--memory", "dff", "--lib", str(lib)).returncode, 0)

    def test_unknown_platform_rejected_without_creating_workspace(self):
        result = self.run_flow("--platform", "missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.work.exists())

    def test_existing_workspace_files_preserved(self):
        self.work.mkdir()
        target = self.work / "Makefile"
        target.write_text("user content")
        self.assertNotEqual(self.run_flow().returncode, 0)
        self.assertEqual(target.read_text(), "user content")

    def test_opensta_error_with_zero_exit_is_failure(self):
        result = self.run_flow(FAKE_STA_MESSAGE="Error: deliberately failed timing setup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STA failed", result.stderr)

    def test_invalid_frequency_rejected(self):
        for frequency in ("0", "-1", "nan", "inf"):
            with self.subTest(frequency=frequency):
                self.assertNotEqual(self.run_flow("--frequency", frequency).returncode, 0)


if __name__ == "__main__":
    unittest.main()
