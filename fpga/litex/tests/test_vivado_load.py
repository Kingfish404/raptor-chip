"""Exercise JTAG target selection and part checks without accessing hardware."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/vivado_load.tcl"


@unittest.skipUnless(shutil.which("tclsh"), "tclsh is required")
class VivadoLoadTest(unittest.TestCase):
    def run_loader(self, targets="selected", devices="xcku15p", explicit=True):
        harness = r'''
proc open_hw_manager {} {}
proc connect_hw_server {args} {}
proc disconnect_hw_server {} {}
proc close_hw_manager {} {}
proc get_hw_targets {args} {return $::env(TEST_TARGETS)}
proc current_hw_target {target} {puts "SELECTED=$target"}
proc open_hw_target {args} {puts "OPENED=$args"}
proc close_hw_target {} {}
proc get_hw_devices {} {return $::env(TEST_DEVICES)}
proc refresh_hw_device {args} {}
proc get_property {property device} {return $device}
proc current_hw_device {device} {}
proc set_property {args} {}
proc program_hw_devices {device} {puts "PROGRAMMED=$device"}
set argv [list $::env(TEST_BITSTREAM) xcku15p]
if {$::env(TEST_EXPLICIT)} {lappend argv */selected}
set argc [llength $argv]
source $::env(TEST_SCRIPT)
'''
        with tempfile.TemporaryDirectory() as temp:
            bitstream = Path(temp) / "test.bit"
            bitstream.write_bytes(b"test")
            wrapper = Path(temp) / "test.tcl"
            wrapper.write_text(harness)
            return subprocess.run(
                ["tclsh", str(wrapper)], text=True, capture_output=True,
                env={**os.environ, "TEST_SCRIPT": str(SCRIPT),
                     "TEST_BITSTREAM": str(bitstream), "TEST_TARGETS": targets,
                     "TEST_DEVICES": devices, "TEST_EXPLICIT": str(int(explicit))})

    def test_make_passes_selector_as_one_argument(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = root / "vivado"
            fake.write_text(f"#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            fake.chmod(0o755)
            result = subprocess.run(
                ["make", "--no-print-directory", "-f", "Makefile", "-f", "-", "check-load-command",
                 "FPGA_BOARD=mlk_cu08_ku15p", "FPGA_AUTO_DETECT=0", "VARIANT=linux32",
                 f"BUILD_DIR={root}/build", f"VIVADO={fake}", "FPGA_HW_TARGET=*/adapter with spaces"],
                cwd=SCRIPT.parents[1], text=True, capture_output=True,
                input="check-load-command:\n\t@$(FPGA_LOAD_CMD)\n")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            arguments = json.loads(result.stdout)
            self.assertEqual(arguments[-2:], ["xcku15p", "*/adapter with spaces"])

    def test_exact_target_programs_matching_part(self):
        result = self.run_loader()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OPENED=selected", result.stdout)
        self.assertIn("PROGRAMMED=xcku15p", result.stdout)

    def test_missing_or_ambiguous_target_never_opens_or_programs(self):
        for targets in ("", "first second"):
            with self.subTest(targets=targets):
                result = self.run_loader(targets=targets)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("OPENED=", result.stdout)
                self.assertNotIn("PROGRAMMED=", result.stdout)

    def test_wrong_or_duplicate_part_never_programs(self):
        for devices in ("xcku5p", "", "xcku15p xcku15p"):
            with self.subTest(devices=devices):
                result = self.run_loader(devices=devices)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("PROGRAMMED=", result.stdout)

    def test_legacy_default_target_still_checks_part(self):
        result = self.run_loader(explicit=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("SELECTED=", result.stdout)
        self.assertIn("PROGRAMMED=xcku15p", result.stdout)
        rejected = self.run_loader(explicit=False, devices="xcku5p")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertNotIn("PROGRAMMED=", rejected.stdout)


if __name__ == "__main__":
    unittest.main()
