#!/usr/bin/env python3
"""Exercise real Make/Kconfig isolation; use a fake compiler for cache tests."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SIM = REPO / "sim"


class BuildIsolationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="raptor-chip-build-test-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.compiler = self.root / "verilator-stub"
        self.compiler.write_text("""#!/usr/bin/env python3
import pathlib, sys
args = sys.argv[1:]
if '--dump-defines' in args:
    xlen = 64 if '-DRAPT_RV64' in args else 32
    print(f'`define RAPT_XLEN {xlen}')
    print('`define RAPT_PADDR_BITS 32')
    print(f'`define RAPT_PMPADDR_BITS {30 if xlen == 64 else 32}')
    sys.exit(0)
if '--version' in args:
    print('Verilator build-isolation fixture')
    sys.exit(0)
out = pathlib.Path(args[args.index('-o') + 1])
if not out.is_absolute() and '--Mdir' in args:
    out = pathlib.Path(args[args.index('--Mdir') + 1]) / out
out.parent.mkdir(parents=True, exist_ok=True)
count = out.parent / 'compile-count'
count.write_text(str(int(count.read_text()) + 1 if count.exists() else 1))
out.write_text('#!/bin/sh\\nexit 0\\n')
out.chmod(0o755)
""")
        self.compiler.chmod(0o755)
        self.legacy = {p: (p.read_bytes(), p.stat().st_mtime_ns)
                       for p in (SIM / ".config", SIM / "include/generated/autoconf.h",
                                 SIM / "include/config/auto.conf") if p.exists()}

    def tearDown(self):
        for path, state in self.legacy.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), state, str(path))

    def make(self, *arguments, profile="test", root=False, verify=False):
        env = os.environ.copy()
        for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "BUILD_DIR", "BUILD_PROFILE",
                    "BUILD_ROOT", "VFLAGS", "SIM_CONFIG_ROOT"):
            env.pop(key, None)
        directory = REPO / "verification" if verify else REPO if root else SIM
        result = subprocess.run(["make", "--no-print-directory", "-C", str(directory),
                                 f"BUILD_ROOT={self.build}", f"BUILD_PROFILE={profile}",
                                 f"VERILATOR={self.compiler}", *arguments],
                                env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def config(self, profile="test", xlen=32):
        return self.build / profile / f"config-riscv{xlen}"

    def test_root_parallel_builds_and_configure_only(self):
        self.make("-j2", "configure-rv32", "configure-rv64", "DIFFTEST=0", root=True)
        self.assertFalse(list(self.build.rglob("compile-count")))
        for xlen in (32, 64):
            self.assertNotIn("CONFIG_DIFFTEST=y", (self.config(xlen=xlen) / ".config").read_text())
        self.make("-j2", "build-rv32", "build-rv64", "DIFFTEST=1", root=True)
        for xlen in (32, 64):
            self.assertIn("CONFIG_DIFFTEST=y", (self.config(xlen=xlen) / ".config").read_text())
            self.assertTrue((self.build / f"test/riscv{xlen}-npc-sim").exists())

    def test_parallel_xlen_configurations(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(self.make, "o2_defconfig", "VFLAGS=", profile="parallel")
            b = pool.submit(self.make, "o2_difftest_defconfig", "VFLAGS=-DRAPT_RV64", profile="parallel")
            a.result()
            b.result()
        plain = self.config("parallel", 32) / ".config"
        diff = self.config("parallel", 64) / ".config"
        self.assertNotIn("CONFIG_DIFFTEST=y", plain.read_text())
        self.assertIn("CONFIG_DIFFTEST=y", diff.read_text())
        for xlen in (32, 64):
            self.assertTrue((self.config("parallel", xlen) / "include/generated/autoconf.h").exists())

    def test_configure_is_idempotent_and_profiles_independent(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(self.make, "o2_defconfig", profile="plain")
            b = pool.submit(self.make, "o2linux_difftest_defconfig", profile="linux")
            a.result()
            b.result()
        paths = [self.config("plain") / name for name in (".config", "include/config/auto.conf",
                                                         "include/generated/autoconf.h")]
        before = [(p.read_bytes(), p.stat().st_mtime_ns) for p in paths]
        self.make("o2_defconfig", profile="plain")
        self.assertEqual(before, [(p.read_bytes(), p.stat().st_mtime_ns) for p in paths])
        self.assertNotEqual((self.config("plain") / ".config").read_bytes(),
                            (self.config("linux") / ".config").read_bytes())

    def test_cache_switch_back_does_not_delete_or_recompile(self):
        self.make("o2_difftest_defconfig")
        self.make("all")
        link = self.build / "test/riscv32-npc-sim"
        original = link.resolve(strict=True)
        sentinel = original.parent / "preserve-me"
        sentinel.write_text("old cache stays usable")
        for option in ("VERILATOR_EXTRA=--coverage-line", "VERILATOR_CODEGEN_JOBS=2"):
            with self.subTest(option=option):
                self.make("all", option)
                other = link.resolve(strict=True)
                self.assertNotEqual(original, other)
                self.assertTrue(original.exists())
                self.make("all")
                self.assertEqual(link.resolve(), original)
                self.assertEqual((original.parent / "compile-count").read_text(), "1")
                self.assertTrue(sentinel.exists())
                self.assertTrue(other.exists())

    def test_root_forwards_rv64_config_selection(self):
        self.make("build-rv32", "VFLAGS=-DRAPT_RV64", root=True)
        self.assertTrue((self.config(xlen=64) / ".config").exists())
        self.assertFalse(self.config(xlen=32).exists())
        self.assertTrue((self.build / "test/riscv64-npc-sim").exists())

    def test_verify_refreshes_existing_binary_and_selects_only_requested_xlen(self):
        reference = self.root / "reference.so"
        reference.touch()
        rom = self.root / "mrom.bin"
        rom.touch()
        link = self.build / "test/riscv64-npc-sim"
        link.parent.mkdir(parents=True)
        link.write_text("stale simulator")

        def prerequisites(preset):
            return self.make("check-prereqs", "ISA=rv64", f"RAPT_CONFIG={preset}",
                             f"NPC_BIN={link}", f"NEMU_SO={reference}", f"MROM_IMG={rom}",
                             verify=True)

        prerequisites("default")
        original = link.resolve(strict=True)
        self.assertTrue(link.is_symlink())
        self.assertTrue(self.config(xlen=64).exists())
        self.assertFalse(self.config(xlen=32).exists())
        prerequisites("small")
        selected = link.resolve(strict=True)
        self.assertNotEqual(original, selected)
        self.assertTrue(original.exists())
        prerequisites("small")
        self.assertEqual(link.resolve(strict=True), selected)
        self.assertEqual((selected.parent / "compile-count").read_text(), "1")

    def test_pin_level_cache_separates_tool_versions_and_wave_options(self):
        env = os.environ.copy()
        for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            env.pop(key, None)
        for version, wave in (("old-version", 0), ("new-version", 0), ("new-version", 1)):
            result = subprocess.run([
                "make", "--no-print-directory", "-C", str(SIM / "tb"), "verilator-build",
                f"VL_BUILD_ROOT={self.build}", f"VERILATOR={self.compiler}",
                f"VL_TOOL_VERSION={version}", f"WAVE={wave}", "RAPT_CONFIG=middle"],
                env=env, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout)
        outputs = list(self.build.glob("vl-middle-*/rapt_tb_top"))
        self.assertEqual(len(outputs), 3)

    def test_help_is_read_only_and_clean_is_profile_local(self):
        self.make("help")
        self.assertFalse(self.build.exists())
        self.make("all", profile="keep")
        self.make("all", profile="remove")
        self.make("clean", profile="remove")
        self.assertFalse((self.build / "remove").exists())
        self.assertTrue((self.build / "keep/riscv32-npc-sim").exists())

    def test_coverage_uses_only_current_invocation(self):
        coverage = self.root / "coverage"
        legacy = self.root / "legacy"
        legacy.mkdir()
        sentinel = legacy / "coverage.dat"
        sentinel.write_text("unrelated old coverage")
        merger = self.root / "verilator_coverage"
        merger.write_text("#!/usr/bin/env python3\n"
                          "import pathlib, sys\n"
                          "pathlib.Path(sys.argv[2]).write_text('\\n'.join(sys.argv[3:]))\n")
        merger.chmod(0o755)
        workload = self.root / "workload.py"
        workload.write_text("import os, pathlib\n"
                            "(pathlib.Path(os.environ['RAPT_COVERAGE_DIR']) / "
                            "'coverage-test.dat').write_text('test')\n")
        extra = self.root / "coverage.mk"
        extra.write_text(".PHONY: isolation-coverage\n"
                         "isolation-coverage:\n"
                         "\t$(call RUN_AND_SAVE_COVERAGE,isolation,$(TEST_WORKLOAD))\n")
        env = os.environ.copy()
        for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            env.pop(key, None)
        env["PATH"] = str(self.root) + os.pathsep + env["PATH"]

        def run(command):
            return subprocess.run([
                "make", "--no-print-directory", "-C", str(REPO / "verification"),
                "-f", "Makefile", "-f", str(extra), "isolation-coverage",
                f"COV_DIR={coverage}", f"BUILD_DIR={self.build}",
                f"NSIM_HOME={legacy}", f"TEST_WORKLOAD={command}"],
                env=env, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, timeout=30)

        previous = None
        for _ in range(2):
            result = run(f"python3 {workload}")
            self.assertEqual(result.returncode, 0, result.stdout)
            selected = Path((coverage / "coverage_isolation.dat").read_text())
            self.assertTrue(selected.exists())
            self.assertNotEqual(selected, previous)
            if previous:
                self.assertTrue(previous.exists())
            previous = selected
        result = run("true")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("did not produce coverage data", result.stdout)
        self.assertEqual(sentinel.read_text(), "unrelated old coverage")


if __name__ == "__main__":
    unittest.main()
