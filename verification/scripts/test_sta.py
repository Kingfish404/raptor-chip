#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import shutil
import importlib.util


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


ROOT = Path(__file__).resolve().parents[2]


class StaEntrypointsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rapt-sta-entry-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("Makefile", "sim/Makefile", "sim/Kconfig", "sim/scripts/config.mk", "sim/scripts/build_cache.py", "sim/scripts/sta.py",
                     "synth/yosys/Makefile", "synth/yosys/fpga_eval.mk", "synth/modules.mk"):
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, dest)
        for name in ("sim/.config", "sim/include/config/auto.conf",
                     "rtl/configs/default/rapt_config.svh", "tools/decodegen/Makefile"):
            self.file(name)
        (self.root / "tools/decodegen/src").mkdir()
        (self.root / "rtl/include").mkdir()
        for name in ("sim/csrc", "sim/rtl"):
            (self.root / name).mkdir()
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
        self.file(f"{self.flow}/Makefile", FAKE_MAKE)
        self.file(f"{self.flow}/platforms/sky130hd/platform.mk")
        self.file(f"{self.flow}/scripts/.fixture")
        self.file("work/rtl/rapt_pack.sv", "module rapt; endmodule\n")
        # Skip elaboration only; exercise preflight, alias normalization and runner.
        run = self.run_check("STA_PLATFORM=sky130", "MEMORY=dff", "-o", "sta-check",
                             f"STA_WORK_DIR={self.root}/work", target="sta")
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("goal=sta platform=sky130hd", run.stdout)

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
        self.assertIn("cannot load its slang frontend", run.stdout)


spec = importlib.util.spec_from_file_location('ppa_summary', ROOT / 'synth/yosys/scripts/summarize_ppa.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SummaryStatusTest(unittest.TestCase):
    def test_current_and_legacy_cell_count_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            stat=Path(tmp)/'top.stat.rpt'
            for line in ('123 cells\n','123 total cells\n'):
                stat.write_text(line)
                self.assertEqual(module.parse_stat(stat)[0],123)

    def test_no_fmax_inference_from_global_slack_or_legacy_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'top.stat.rpt').write_text('10 cells\n')
            (root/'sta.log').write_text('')
            summary=root/'top.sta_summary.rpt'
            summary.write_text('period_ns 10\nwns_ns 9\nperiod_min_ns 1\nfmax_mhz 1000\n')
            result=module.collect_module(root)
            self.assertIsNone(result['reg_setup_budget'])
            self.assertNotIn('fmax',result)
            summary.write_text('status ok\ntiming_schema 2\nreg_setup_budget_ns 1.25\n')
            self.assertEqual(module.collect_module(root)['reg_setup_budget'],'1.25')

    def test_incomplete_summary_rejects_existing_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'top.stat.rpt').write_text('10 cells\n')
            (root/'sta.log').write_text('old successful log\n')
            summary=root/'top.sta_summary.rpt'
            summary.write_text('status incomplete\nwns_ns 9.0\n')
            self.assertEqual(module.collect_module(root),{'status':'invalid'})
            summary.write_text('status ok\nwns_ns 1.0\nperiod_ns 10\n')
            self.assertEqual(module.collect_module(root)['status'],'ok')


if __name__ == "__main__":
    unittest.main()
