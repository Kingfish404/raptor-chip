"""Exercise configuration signatures without compiling the guest suite."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class BuildConfigurationChecks(unittest.TestCase):
    def test_locale_change_keeps_build_but_flag_change_invalidates_it(self):
        locales = subprocess.check_output(["locale", "-a"], text=True).splitlines()
        alternate = next((name for name in locales if name.lower() == "en_us.utf8"), None)
        if alternate is None:
            self.skipTest("en_US.utf8 locale is required to exercise alternate glob ordering")
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            compiler = directory / "compiler"
            compiler.write_text('#!/bin/sh\nprintf "test compiler\\n"\n')
            compiler.chmod(0o755)
            stamp = directory / "build/.build-config"
            command = ["make", "--no-print-directory", "-C", str(HERE), str(stamp),
                       f"BUILD_DIR={stamp.parent}", f"CC={compiler}", "MODE=baremetal"]
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith("MAKE") and key != "MFLAGS"}

            def configure(locale, flags="-O2"):
                run = subprocess.run(command + [f"CMP_OPT_FLAGS={flags}"],
                                     env={**environment, "LC_ALL": locale},
                                     text=True, capture_output=True, timeout=30)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

            configure("C")
            original = stamp.read_bytes()
            binary = stamp.parent / "bin/preserved.bin"
            binary.parent.mkdir()
            binary.write_bytes(b"existing artifact")
            configure(alternate)
            self.assertEqual(stamp.read_bytes(), original)
            self.assertTrue(binary.exists())
            configure("C", "-O3")
            self.assertNotEqual(stamp.read_bytes(), original)
            self.assertFalse(binary.exists())


if __name__ == "__main__":
    unittest.main()
