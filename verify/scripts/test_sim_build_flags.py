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
            for source in ("Makefile", "sim/Makefile", "sim/Kconfig",
                           "sim/scripts/config.mk", "sim/scripts/build_cache.py",
                           "sim/scripts/configure.py"):
                shutil.copy2(ROOT / source, root / source)
            for source in ("sim/.config", "hdl/configs/default/rapt_config.svh",
                           "hdl/chisel/Makefile"):
                (root / source).write_text("\n")
            (root / "sim/include/config/auto.conf").write_text('# CONFIG_wrapBus is not set\n')
            # configure.py owns build-local Kconfig output.  A tiny conf stub is
            # sufficient here because this test inspects the generated command,
            # rather than Kconfig semantics (covered by build-isolation tests).
            kconfig_build = root / "sim/tools/kconfig/build"
            kconfig_build.mkdir(parents=True)
            conf = kconfig_build / "conf"
            conf.write_text(
                "#!/bin/sh\n"
                "mkdir -p \"$(dirname \"$KCONFIG_CONFIG\")\" "
                "\"$(dirname \"$KCONFIG_AUTOCONFIG\")\" "
                "\"$(dirname \"$KCONFIG_AUTOHEADER\")\"\n"
                ": > \"$KCONFIG_CONFIG\"\n"
                ": > \"$KCONFIG_AUTOCONFIG\"\n"
                ": > \"$KCONFIG_AUTOHEADER\"\n")
            conf.chmod(0o755)
            for source in ("rapt_idu_decoder.sv", "rapt_idu_decoder_c.sv"):
                (root / "hdl/generated" / source).write_text("// dry-run fixture\n")
            (root / "sim/rtl").mkdir()
            verilator = root / "verilator-stub"
            verilator.write_text(
                "#!/bin/sh\n"
                "printf 'verilator'\n"
                "printf ' %s' \"$@\"\n"
                "printf '\\n'\n"
                "while [ $# -gt 0 ]; do\n"
                "  if [ \"$1\" = -o ]; then\n"
                "    mkdir -p \"$(dirname \"$2\")\"\n"
                "    : > \"$2\"\n"
                "    chmod +x \"$2\"\n"
                "    exit 0\n"
                "  fi\n"
                "  shift\n"
                "done\n")
            verilator.chmod(0o755)
            # The '+' compiler recipe executes even with make -n. Substitute
            # a harmless command printer, and exercise the actual recipe.
            run = subprocess.run(
                ["make", "-s", "-C", str(root / "sim"), "all",
                 f"VERILATOR={verilator}", "LZ4_PREFIX=", *options],
                capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            # Join recipe continuations so option tests examine whole tokens,
            # not the '--assert' substring inside a signature or macro name.
            command = next(line for line in run.stdout.replace("\\\n", " ").splitlines()
                           if line.startswith("verilator --trace-fst"))
            parsed = shlex.split(command)
            return parsed, parsed[parsed.index("--Mdir") + 1]

    def test_default_executes_properties(self):
        command, object_dir = self.command()
        self.assertIn("-DRAPT_ASSERT_EN", command)
        self.assertIn("--assert", command)
        self.assertIn("obj_dir-riscv32-", object_dir)

    def test_disabled_omits_both_controls(self):
        command, object_dir = self.command("RAPT_SIM_ASSERT=0")
        self.assertNotIn("-DRAPT_ASSERT_EN", command)
        self.assertNotIn("--assert", command)
        self.assertIn("obj_dir-riscv32-", object_dir)

    def test_explicit_macro_also_executes_properties(self):
        command, _ = self.command("RAPT_SIM_ASSERT=0", "VFLAGS=-DRAPT_ASSERT_EN")
        self.assertIn("-DRAPT_ASSERT_EN", command)
        self.assertIn("--assert", command)

    def test_compiler_specific_warnings(self):
        for compiler, clang in (("g++", False), ("clang++", True)):
            if not shutil.which(compiler):
                continue
            with self.subTest(compiler=compiler):
                command, _ = self.command(f"CXX={compiler}")
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
