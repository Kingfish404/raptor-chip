"""Effective preset/VFLAGS and reference-width rejection checks, without builds."""

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "sim/scripts/paddr_config.py"


class PaddrConfigTest(unittest.TestCase):
    def widths(self, *flags, config="small-cache"):
        return subprocess.run([sys.executable, str(SCRIPT), "--config",
                               str(ROOT / "rtl/configs" / config), "--hdl",
                               str(ROOT / "rtl"), "--", *flags],
                              capture_output=True, text=True)

    def test_all_presets_use_expected_width(self):
        for preset in (ROOT / "rtl/configs").glob("*/rapt_config.svh"):
            with self.subTest(preset=preset.parent.name):
                result = self.widths("-DRAPT_RV64", config=preset.parent.name)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = "38 36" if preset.parent.name == "default-pa38" else "32 30"
                self.assertEqual(result.stdout.strip(), expected)

    def test_every_supported_width(self):
        for pa in range(32, 39):
            with self.subTest(pa=pa):
                result = self.widths("-DRAPT_RV64", f"-DRAPT_PADDR_BITS={pa}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"{pa} {pa - 2}")

    def test_selected_preset_value_and_command_line_override(self):
        with tempfile.TemporaryDirectory() as directory:
            config = (ROOT / "rtl/configs/small-cache/rapt_config.svh").read_text()
            config = config.replace("`define RAPT_PADDR_BITS 32", "`define RAPT_PADDR_BITS 38")
            (Path(directory) / "rapt_config.svh").write_text(config)
            result = self.widths("-DRAPT_RV64", config=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "38 36")
            result = self.widths("-DRAPT_RV64", "-DRAPT_PADDR_BITS=34", config=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "34 32")

    def test_invalid_widths_and_pmp_override(self):
        for flags in (("-DRAPT_RV64", "-DRAPT_PADDR_BITS=31"),
                      ("-DRAPT_RV64", "-DRAPT_PADDR_BITS=39"),
                      ("-DRAPT_PADDR_BITS=38",),
                      ("-DRAPT_RV64", "-DRAPT_PADDR_BITS=38", "-DRAPT_PMPADDR_BITS=30")):
            with self.subTest(flags=flags):
                result = self.widths(*flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("PA configuration error", result.stderr)

    def test_rv32_stays_32(self):
        result = self.widths()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "32 32")

    def test_sim_rejects_mismatched_reference(self):
        result = subprocess.run(["make", "-C", str(ROOT / "sim"), "-n", "nemu-reference",
                                 "VFLAGS=-DRAPT_RV64 -DRAPT_PADDR_BITS=38",
                                 "NEMU_REF_PMPADDR_BITS=30"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NEMU PMP width mismatch", result.stderr)

    def test_rv64_entrypoints_preserve_pa_and_other_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            calls = directory / "calls.jsonl"
            capture = directory / "make-capture"
            capture.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                               f"with open({str(calls)!r}, 'a') as stream:\n"
                               "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n")
            capture.chmod(0o755)
            flags = "-DRAPT_RV64 -DRAPT_PADDR_BITS=38 -DRAPT_TLB_PLRU=1"
            for target in ("configure-rv64", "build-rv64", "run-rv64",
                           "build-rv64-linux", "build-nemu64-ref"):
                with self.subTest(target=target):
                    calls.write_text("")
                    result = subprocess.run(["make", "--no-print-directory", "-C", str(ROOT),
                                             "-o", "verilog", target, "MAKE=" + str(capture),
                                             "VFLAGS=" + flags, "RAPT_CONFIG=small-cache",
                                             "HDL_FORMAT_SOURCES=", "ALL_SV_FORMAT_SOURCES="],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    invocations = [json.loads(line) for line in calls.read_text().splitlines()]
                    sim_calls = [args for args in invocations if str(ROOT / "sim") in args]
                    self.assertTrue(sim_calls)
                    for args in sim_calls:
                        actual = next(arg for arg in args if arg.startswith("VFLAGS="))
                        self.assertEqual(actual, "VFLAGS=" + flags)
                    if target == "build-nemu64-ref":
                        self.assertIn("nemu-reference", sim_calls[0])

    def test_reference_rejects_stale_generated_width(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "include/generated").mkdir(parents=True)
            (directory / ".config").write_text("CONFIG_RV_PMPADDR_BITS=36\n")
            (directory / "include/generated/autoconf.h").write_text(
                "#define CONFIG_RV_PMPADDR_BITS 30\n")
            result = subprocess.run(["make", "-C", str(directory), "-f",
                                     str(ROOT / "nemu/scripts/reference.mk"), "reference-build",
                                     "-o", ".configured", "REF_DEFCONFIG=riscv64_ref_defconfig",
                                     "REF_PMPADDR_BITS=36", "REF_DIR=" + str(directory),
                                     "NEMU_HOME=" + str(ROOT / "nemu")],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("NEMU PMP width mismatch", result.stdout)


if __name__ == "__main__":
    unittest.main()
