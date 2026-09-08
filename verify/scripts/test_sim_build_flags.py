#!/usr/bin/env python3
"""Check simulator compiler/assertion flags without touching shared build state."""
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SimulatorBuildFlagsTest(unittest.TestCase):
    def command(self, *options):
        # Even make -n executes this project's parse-time build invalidation.
        # Supply a minimal, disposable source tree, never the user's sim tree.
        with tempfile.TemporaryDirectory(prefix="rapt-build-flags-") as tmp:
            root = Path(tmp)
            for directory in ("sim/csrc", "sim/include/config", "sim/scripts",
                              "hdl/configs/default", "hdl/chisel/src", "hdl/generated"):
                (root / directory).mkdir(parents=True, exist_ok=True)
            for source in ("Makefile", "sim/Makefile", "sim/Kconfig", "sim/scripts/config.mk"):
                shutil.copy2(ROOT / source, root / source)
            for source in ("sim/.config", "hdl/configs/default/rapt_config.svh",
                           "hdl/chisel/Makefile"):
                (root / source).write_text("\n")
            (root / "sim/include/config/auto.conf").write_text('# CONFIG_wrapBus is not set\n')
            for source in ("rapt_idu_decoder.sv", "rapt_idu_decoder_c.sv"):
                (root / "hdl/generated" / source).write_text("// dry-run fixture\n")
            (root / "sim/rtl").mkdir()
            # The '+' compiler recipe executes even with make -n. Substitute
            # a harmless command printer, and exercise the actual recipe.
            run = subprocess.run(
                ["make", "-s", "-C", str(root / "sim"), "all",
                 "VERILATOR=echo verilator", "LZ4_PREFIX=", *options],
                capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            # Join recipe continuations so option tests examine whole tokens,
            # not the '--assert' substring inside a signature or macro name.
            command = next(line for line in run.stdout.replace("\\\n", " ").splitlines()
                           if line.startswith("verilator --trace-fst"))
            signature = (root / "sim/build/default/.vflags_stamp-riscv32").read_text()
            return shlex.split(command), signature

    def test_default_executes_properties(self):
        command, signature = self.command()
        self.assertIn("-DRAPT_ASSERT_EN", command)
        self.assertIn("--assert", command)
        self.assertIn("SIM_ASSERT_FLAGS=--assert", signature)

    def test_disabled_omits_both_controls(self):
        command, signature = self.command("RAPT_SIM_ASSERT=0")
        self.assertNotIn("-DRAPT_ASSERT_EN", command)
        self.assertNotIn("--assert", command)
        self.assertNotIn("SIM_ASSERT_FLAGS=--assert", signature)

    def test_explicit_macro_also_executes_properties(self):
        command, _ = self.command("RAPT_SIM_ASSERT=0", "VFLAGS=-DRAPT_ASSERT_EN")
        self.assertIn("-DRAPT_ASSERT_EN", command)
        self.assertIn("--assert", command)

    def test_compiler_specific_warnings(self):
        for compiler, clang in (("g++", False), ("clang++", True)):
            if not shutil.which(compiler):
                continue
            with self.subTest(compiler=compiler):
                command, signature = self.command(f"CXX={compiler}")
                self.assertIn(f"CXX={compiler}", signature)
                self.assertEqual(command[command.index("-MAKEFLAGS") + 1],
                                 f"CXX={compiler}")
                flags = [command[i + 1] for i, arg in enumerate(command)
                         if arg == "-CFLAGS" and command[i + 1].startswith("-W")]
                self.assertIn("-Werror", flags)
                self.assertEqual("-Wno-error=maybe-uninitialized" in flags, not clang)
                self.assertEqual("-Wno-macro-redefined" in flags, clang)
                self.assertEqual("-Wno-parentheses-equality" in flags, clang)
                run = subprocess.run(
                    [compiler, *flags, "-x", "c++", "-fsyntax-only", "-"],
                    input="int main() { return 0; }\n", capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)


if __name__ == "__main__":
    unittest.main()
