"""Effective preset/VFLAGS and reference-width rejection checks, without builds."""

from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "sim/scripts/paddr_config.py"


class PaddrConfigTest(unittest.TestCase):
    @unittest.skipUnless(all(shutil.which(tool) for tool in
                             ("make", "dtc", "fdtget", "fdtput", "xxd")),
                         "device-tree tools required")
    def test_vector_mrom_isa_and_extensions_invalidate_together(self):
        with tempfile.TemporaryDirectory() as temporary:
            for xlen in (32, 64):
                baseline = None
                for enabled in (0, 1, 0):
                    with self.subTest(xlen=xlen, vector=enabled):
                        output = Path(temporary) / f"rv{xlen}"
                        command = ["make", "-s", "-C", str(ROOT / "sim/csrc/mem/mrom-data"),
                                   str(output / "dtb.c"), f"BUILD_DIR={output}",
                                   f"ISA64={int(xlen == 64)}", f"VECTOR={enabled}",
                                   f"DT_SOURCE=spike-rv{xlen}gc.dts"]
                        subprocess.run(command, capture_output=True, text=True, check=True)
                        def property_value(name):
                            return subprocess.check_output(
                                ["fdtget", "-t", "s", str(output / "raptor.dtb"),
                                 "/cpus/cpu@0", name], text=True).strip()
                        isa = property_value("riscv,isa")
                        extensions = property_value("riscv,isa-extensions").split()
                        # The 'v' in the rv32/rv64 prefix is not an extension.
                        letters = isa.split("_", 1)[0][4:]
                        self.assertEqual("v" in letters, bool(enabled))
                        self.assertEqual(extensions.count("v"), enabled)
                        other = (letters.replace("v", ""),
                                 set(extensions) - {"v"})
                        if baseline is None:
                            baseline = other
                        self.assertEqual(other, baseline)

    @unittest.skipUnless(all(shutil.which(tool) for tool in
                             ("make", "dtc", "fdtget", "fdtput", "xxd")),
                         "device-tree tools required")
    def test_vector_mrom_accepts_either_isa_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            default = (ROOT / "linux/dts/spike-rv64gc.dts").read_text()
            for property_name, expected in (("riscv,isa", "rv64imafdcv_zicsr_zifencei_zicntr"),
                                            ("riscv,isa-extensions", "i m a f d c zicsr zifencei zicntr v")):
                with self.subTest(property_name=property_name):
                    removed = ("riscv,isa-extensions" if property_name == "riscv,isa"
                               else "riscv,isa")
                    dts = root / f"{property_name.replace(',', '-')}.dts"
                    dts.write_text("\n".join(line for line in default.splitlines()
                                             if not line.strip().startswith(f"{removed} =")))
                    output = root / "rom"
                    command = ["make", "-s", "-C", str(ROOT / "sim/csrc/mem/mrom-data"),
                               str(output / "dtb.c"), f"BUILD_DIR={output}",
                               "ISA64=1", "VECTOR=1", f"DT_SOURCE={dts}"]
                    subprocess.run(command, capture_output=True, text=True, check=True)
                    args = ["fdtget", "-d", "", "-t", "s", str(output / "raptor.dtb"),
                            "/cpus/cpu@0"]
                    value = subprocess.check_output(args + [property_name], text=True).strip()
                    self.assertEqual(value, expected)
                    self.assertEqual(subprocess.check_output(args + [removed], text=True).strip(), "")

    def test_vector_defaults_and_effective_overrides(self):
        presets = sorted((ROOT / "rtl/configs").glob("*/rapt_config.svh"))
        for preset in presets:
            for xlen in (32, 64):
                if xlen == 64 and preset.parent.name.startswith("chip32-"):
                    continue
                if xlen == 32 and preset.parent.name.startswith("chip64-"):
                    continue
                command = [sys.executable, str(SCRIPT), "--features", "--config",
                           str(preset.parent), "--hdl", str(ROOT / "rtl"), "--"]
                if xlen == 64:
                    command.append("-DRAPT_RV64")
                with self.subTest(preset=preset.parent.name, xlen=xlen):
                    result = subprocess.run(command, capture_output=True, text=True, check=True)
                    fields = result.stdout.split()
                    expected = (preset.parent.name.startswith(("default", "chip64-"))
                                or preset.parent.name == "large")
                    self.assertEqual(list(map(int, fields[2:6])), [int(expected), 128, 64, 2])
                    required = {"b", "h", "zawrs", "zfa", "ssnpm", "smnpm", "svnapot",
                                "sscofpmf", "smstateen", "ssstateen", "shgatpa", "svvptc",
                                "zvbb", "zvfhmin", "zvkt", "zicclsm"}
                    advertised = set(fields[6].split(","))
                    if xlen == 64 and expected:
                        self.assertTrue(required <= advertised)
                        no_h = set(subprocess.check_output(
                            command + ["-DRAPT_NO_H_EXTENSION"], text=True).split()[6].split(","))
                        self.assertFalse(no_h & {"h", "shgatpa", "shvsatpa"})
                        self.assertTrue({"svnapot", "sscofpmf", "smstateen", "smnpm"} <= no_h)
                        user_only = set(subprocess.check_output(
                            command + ["-DRAPT_NO_RVA23S64"], text=True).split()[6].split(","))
                        self.assertFalse(user_only & {"h", "svnapot", "sscofpmf", "smstateen"})
                        self.assertTrue({"b", "zawrs", "zfa", "ssnpm", "zvbb"} <= user_only)
                        legacy = subprocess.check_output(command + ["-DRAPT_NO_RVA23U64"], text=True)
                        self.assertEqual(legacy.split()[2:], ["1", "128", "64", "2", "-"])
                    else:
                        self.assertEqual(advertised, {"-"})
                    if expected:
                        disabled = subprocess.run(command + ["-DRAPT_NO_VPU"],
                                                  capture_output=True, text=True, check=True)
                        self.assertEqual(disabled.stdout.split()[2], "0")
                        self.assertEqual(disabled.stdout.split()[6], "-")

    def widths(self, *flags, config="small-cache"):
        return subprocess.run([sys.executable, str(SCRIPT), "--config",
                               str(ROOT / "rtl/configs" / config), "--hdl",
                               str(ROOT / "rtl"), "--", *flags],
                              capture_output=True, text=True)

    def test_default_and_wide_pa_presets(self):
        for config in ("default", "default-pa38"):
            for xlen in (32, 64):
                with self.subTest(config=config, xlen=xlen):
                    flags = ("-DRAPT_RV64",) if xlen == 64 else ()
                    result = self.widths(*flags, config=config)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    pa = 38 if config == "default-pa38" and xlen == 64 else 32
                    pmp = pa - 2 if xlen == 64 else 32
                    self.assertEqual(result.stdout.strip(), f"{pa} {pmp}")

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
