"""Integration contracts with the existing public FPGA helpers and dependencies."""
import ast
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("bringup_build", ROOT / "fpga/bringup/build.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class BuildTests(unittest.TestCase):
    def test_shared_source_selection_preserves_native_scope(self):
        native = BUILD.rtl_sources(ROOT)
        chip = BUILD.rtl_sources(ROOT, pin_limited=True)
        self.assertEqual(chip[:len(native)], native)
        self.assertEqual(native[0], ROOT / "rtl/rapt_pkg.sv")
        self.assertEqual(len(chip), len(set(chip)))
        extra = chip[len(native):]
        self.assertTrue(extra)
        self.assertTrue(all(p.parent == ROOT / "synth/configs/pin-limited/rtl" for p in extra))
        self.assertIn(ROOT / "synth/configs/pin-limited/rtl/rapt_chip_pads.sv", extra)
        self.assertEqual([p.name for p in chip if p.parent.name == "generated"],
                         ["rapt_idu_decoder.sv", "rapt_idu_decoder_c.sv"])
        self.assertEqual(BUILD.sources()[:len(chip)], chip)

    def test_missing_test_dependency_is_an_error(self):
        with tempfile.TemporaryDirectory(prefix="bringup-dependency-") as directory:
            with self.assertRaisesRegex(ValueError, "Missing AM cpu-tests"):
                BUILD.cpu_tests(Path(directory))

    def test_io25_source_selection_includes_shared_chip_and_uart(self):
        chip = BUILD.rtl_sources(ROOT, pin_limited=True)
        expanded = BUILD.rtl_sources(ROOT, io25=True)
        self.assertEqual(expanded[:len(chip)], chip)
        self.assertEqual(len(expanded), len(set(expanded)))
        self.assertIn(ROOT / "synth/configs/io25/rtl/rapt_chip_pads25.sv", expanded)
        self.assertIn(ROOT / "fpga/common/rtl/rapt_native_uart.sv", expanded)

    def test_cpu_test_sources_are_present(self):
        tests, sources = BUILD.cpu_tests(ROOT)
        self.assertTrue((tests / "include/trap.h").is_file())
        self.assertGreater(len(sources), 1)
        self.assertTrue(all(p.suffix == ".c" for p in sources))

    def test_connector_agrees_with_existing_board_mapping(self):
        # Read public mapping literals without loading Migen/LiteEth dependencies.
        tree = ast.parse((ROOT / "fpga/litex/cm005.py").read_text())
        values = next(n.value for n in tree.body if isinstance(n, ast.Assign)
                      and any(isinstance(t, ast.Name) and t.id == "PINOUTS" for t in n.targets))
        pinouts = {}
        for key, value in zip(values.keys, values.values):
            self.assertIsInstance(value, ast.Call)
            self.assertEqual(value.func.attr, "split")
            self.assertFalse(value.args or value.keywords)
            pinouts[ast.literal_eval(key)] = ast.literal_eval(value.func.value).split()
        a = pinouts[("mlk_cu08_ku15p", "c", "a")]
        b = pinouts[("mlk_cu08_ku15p", "c", "b")]
        expected = dict(zip(
            ["pad_xspi_sclk", "pad_clk", "pad_xspi_cs_n",
             *[f"pad_xspi_dq[{i}]" for i in range(4)], "pad_reset_n",
             *[f"pad_xspi_dq[{i}]" for i in range(4, 8)],
             "pad_irq", "pad_jtag_tck", "pad_jtag_tms"], a))
        expected.update(external_clock=b[0], pad_jtag_tdi=b[8],
                        pad_jtag_tdo=b[9], pad_diag=b[10])
        xdc = (ROOT / "fpga/bringup/cu08/pins.xdc").read_text()
        actual = dict((name.strip("{}"), pin) for pin, name in re.findall(
            r"set_property PACKAGE_PIN (\w+) \[get_ports ([^\n]+)\]", xdc))
        for name, pin in expected.items():
            self.assertEqual(actual[name], pin, name)


if __name__ == "__main__":
    unittest.main()
