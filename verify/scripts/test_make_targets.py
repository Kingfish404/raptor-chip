#!/usr/bin/env python3
"""Check consolidated public Make interfaces without running workloads."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MakeTargetsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="raptor-chip-target-test-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def make(self, *args, cwd=ROOT):
        env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE") and k != "MFLAGS"}
        return subprocess.run(["make", "--no-print-directory", *args], cwd=cwd, env=env,
                              text=True, capture_output=True, timeout=30)

    def test_removed_aliases_are_not_callable(self):
        for target in ("config-nemu32", "config-rv32", "sim-rv32", "coremark-rv32-difftest",
                       "coremark-rv64-optim", "hdl-format", "all-sv-format", "sta-sram",
                       "sta-dff", "sta-flops", "sta-rv64", "verify-all", "ide-setup"):
            with self.subTest(target=target):
                result = self.make(target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No rule to make target", result.stderr)

    def test_format_check_and_scope(self):
        formatter = self.work / "formatter"
        formatter.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        formatter.chmod(0o755)
        check = self.make("format-check", "FORMAT_SCOPE=hdl", f"VERIBLE_FORMAT={formatter}")
        full = self.make("format", "FORMAT_SCOPE=all", f"VERIBLE_FORMAT={formatter}")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertIn("--verify", check.stdout)
        self.assertNotIn("--inplace", check.stdout)
        self.assertIn("--inplace", full.stdout)
        hdl = {line for line in check.stdout.splitlines() if line.startswith(str(ROOT))}
        all_sv = {line for line in full.stdout.splitlines() if line.startswith(str(ROOT))}
        self.assertTrue(hdl < all_sv)
        self.assertTrue(all(path.startswith(str(ROOT / "hdl")) for path in hdl))

    def test_invalid_selectors_fail(self):
        for setting in ("DIFFTEST=invalid", "FORMAT_SCOPE=invalid", "BENCH_OPT=invalid"):
            result = self.make("help", setting)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be", result.stderr)

    def test_benchmark_flag_changes_rebuild_objects(self):
        (self.work / "Makefile").write_text(f'''NAME := coremark
PLATFORM := npc
ARCH := riscv32-npc
DST_DIR := .
OBJS := object
CFLAGS = -O2 -DITERATIONS=$(ITERATIONS)
include {ROOT}/verify/benchmark-options.mk
all: object
object:
\t@echo '$(CFLAGS)' > $@
\t@echo compiled >> count
include {ROOT}/verify/benchmark-build.mk
''')
        for mode, count in (("baseline", 1), ("baseline", 1), ("optimized", 2), ("baseline", 3)):
            result = self.make("all", f"BENCH_OPT={mode}", cwd=self.work)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len((self.work / "count").read_text().splitlines()), count)
            flags = (self.work / "object").read_text()
            self.assertEqual("-O3" in flags, mode == "optimized")
            self.assertIn("-DITERATIONS=2", flags)
        result = self.make("all", "ITERATIONS=10", cwd=self.work)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-DITERATIONS=10", (self.work / "object").read_text())


if __name__ == "__main__":
    unittest.main()
