#!/usr/bin/env python3
"""Build both Kconfig frontends in isolation and detect duplicate Bison writers."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class KconfigParallelTest(unittest.TestCase):
    def check_frontend(self, frontend):
        with tempfile.TemporaryDirectory(prefix="raptor-kconfig-parallel-") as tmp:
            root = Path(tmp)
            source = root / "kconfig"
            shutil.copytree(ROOT / frontend / "tools/kconfig", source,
                            ignore=shutil.ignore_patterns("build", ".git"))
            tools = root / "bin"
            tools.mkdir()
            calls = root / "bison-calls"
            bison = shutil.which("bison")
            self.assertIsNotNone(bison, "Bison is required for this regression")
            wrapper = tools / "bison"
            wrapper.write_text(f"#!{sys.executable}\n" + '''
import fcntl, os, subprocess, sys, time
from pathlib import Path
with Path(os.environ["BISON_CALLS"]).open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    lock.write("bison\\n")
    lock.flush()
    # Widen the race window so two independent output recipes overlap.
    time.sleep(0.2)
    sys.exit(subprocess.call([os.environ["REAL_BISON"], *sys.argv[1:]]))
''')
            wrapper.chmod(0o755)
            env = os.environ.copy()
            for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "BUILD_DIR",
                        "KCONFIG_CONFIG", "KCONFIG_AUTOCONFIG", "KCONFIG_AUTOHEADER"):
                env.pop(key, None)
            env.update(NEMU_HOME=str(ROOT / "nemu"), BISON_CALLS=str(calls),
                       REAL_BISON=bison, PATH=f"{tools}:{env['PATH']}")

            def build(expected_calls):
                result = subprocess.run(
                    ["make", "--no-print-directory", "-j4", "NAME=conf",
                     "build/parser.tab.c", "build/parser.tab.h", "app"],
                    cwd=source, env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls.read_text().splitlines()), expected_calls)
                self.assertTrue(os.access(source / "build/conf", os.X_OK))

            build(1)
            build(1)  # An unchanged tree must reuse both generated outputs.
            for expected, output in enumerate(("parser.tab.h", "parser.tab.c"), 2):
                (source / "build" / output).unlink()
                build(expected)

            # Verify that the resulting executable can actually parse configs.
            presets = ("riscv32_ref_defconfig", "riscv64_ref_defconfig") \
                if frontend == "nemu" else ("o2_defconfig", "o2_difftest_defconfig")
            for preset in presets:
                config = root / preset
                config_env = dict(env, srctree=str(ROOT / frontend), KCONFIG_CONFIG=str(config))
                result = subprocess.run(
                    [str(source / "build/conf"), "-s",
                     f"--defconfig={ROOT / frontend / 'configs' / preset}",
                     str(ROOT / frontend / "Kconfig")],
                    cwd=root, env=config_env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(config.is_file())
                if frontend == "nemu":
                    self.assertEqual("CONFIG_RV64=y" in config.read_text(),
                                     preset.startswith("riscv64"))

    def test_nemu(self):
        self.check_frontend("nemu")

    def test_sim(self):
        self.check_frontend("sim")


if __name__ == "__main__":
    unittest.main()
