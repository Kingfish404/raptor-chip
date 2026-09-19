"""Peripheral-only checks; no synthesis or hardware validation.

Run with fpga/litex/.venv/bin/python fpga/litex/tests/test_cm005.py.
"""
import json
import ast
import inspect
import os
import pathlib
import re
import sys
import tempfile
import unittest
import random
from dataclasses import FrozenInstanceError
from unittest.mock import patch

from migen import Module, ResetInserter
from migen.sim import run_simulation, passive
from litex.soc.integration.builder import Builder
from liteeth.mac.gap import LiteEthMACGap
from liteeth.mac.preamble import LiteEthMACPreambleChecker

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
import ku15p_soc as shared
import mlk_cu07_ku15p as cu07
import mlk_cu08_ku15p as cu08
from cm005 import CM005Reset, CM005TX100, CM005RX100, CM005MDIOInit, CM005MDIOInit100, CM005MDIO, CM005MDIO100, CM005PHY, add_pads
from add_linux_ethernet_dts import ethernet_node


class CM005Test(unittest.TestCase):
    def setUp(self):
        # SoC construction injects clock defines into the process environment.
        # Do not leak those overrides into subsequent fixed-profile Make tests.
        environment = patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)

    def test_gigabit_defaults(self):
        root = pathlib.Path(shared.__file__).resolve().parent
        for cls, parameter in ((shared._CRG, "eth_speed"),
                               (shared.RaptorKU15PSoC, "eth_speed"),
                               (CM005PHY, "speed"), (CM005MDIO, "speed"),
                               (CM005MDIOInit, "speed")):
            self.assertEqual(inspect.signature(cls.__init__).parameters[parameter].default, 1000)
        for name in ("Makefile", "mk/config.mk"):
            defaults = re.findall(r"^ETH_SPEED\s*\?=\s*(\d+)\s*$",
                                  (root / name).read_text(), re.M)
            self.assertEqual(defaults, ["1000"], name)
        # Inspect the actual CLI declaration without running the build entry
        # point or Makefile parsing (which can have unrelated side effects).
        calls = [node for node in ast.walk(ast.parse((root / "ku15p_soc.py").read_text()))
                 if isinstance(node, ast.Call) and node.args
                 and isinstance(node.args[0], ast.Constant)
                 and node.args[0].value == "--eth-speed"]
        self.assertEqual(len(calls), 1)
        keywords = {kw.arg: ast.literal_eval(kw.value) for kw in calls[0].keywords
                    if kw.arg in ("default", "choices")}
        self.assertEqual(keywords, {"default": 1000, "choices": [100, 1000]})
        # Explicit legacy classes must not silently inherit the gigabit default.
        with patch.object(CM005MDIOInit, "__init__", return_value=None) as init:
            CM005MDIOInit100(1000)
            init.assert_called_once_with(1000, speed=100)
        with patch.object(CM005MDIO, "__init__", return_value=None) as init:
            CM005MDIO100(None, None, 1000)
            init.assert_called_once_with(None, None, 1000, speed=100)

    def test_cu08_short_edge_mapping_and_constraints(self):
        from cm005 import PINOUTS
        expected = "L19 F18 D14 B16 B17 A18 A19 F17 D15 E15 L18 C14 B15 A15 E8".split()
        self.assertEqual(PINOUTS[(cu08.BOARD.name, "c", "a")], expected)
        self.assertEqual(len(set(expected)), 15)
        self.assertEqual(cu08.BOARD.default_fmc_slot, "c")
        self.assertEqual(cu07.BOARD.default_fmc_slot, "a")
        for variant, dram, speed in ((v, d, s) for v in ("linux32", "linux64")
                                     for d in (False, True) for s in (100, 1000)):
            with self.subTest(variant=variant, dram=dram, speed=speed), tempfile.TemporaryDirectory() as tmp:
                with patch.object(shared.Raptor, "add_sources", lambda *args, **kwargs: None):
                    soc = cu08.RaptorMLKCU08SoC(sys_clk_freq=50e6, cpu_variant=variant,
                        with_ethernet=True, with_litedram=dram, eth_speed=speed,
                        integrated_main_ram_size=0 if dram else 0x10000)
                    Builder(soc, output_dir=tmp, compile_software=False).build(run=False)
                xdc = next((pathlib.Path(tmp) / "gateware").glob("*.xdc")).read_text()
                for pin in expected:
                    self.assertIn("set_property LOC " + pin + " ", xdc)
                self.assertNotIn("CLOCK_DEDICATED_ROUTE FALSE", xdc)
                self.assertIn("set_property LOC MMCM_X0Y8 [get_cells cm005_sample_pll]", xdc)
                self.assertIn("CLOCK_DELAY_GROUP cm005_sampling", xdc)
                # Synthesis merges cm005_sample_div_clk into eth_rx_clk.
                # Select both clock nets by their stable BUFGCE_DIV outputs,
                # so neither physical property silently misses the word clock.
                sample_clocks = ("[get_nets -of_objects [get_pins "
                                 "{cm005_sample_fast_buf/O cm005_sample_word_buf/O}]]")
                self.assertIn("set_property USER_CLOCK_ROOT X2Y8 " + sample_clocks, xdc)
                self.assertIn("set_property CLOCK_DELAY_GROUP cm005_sampling " + sample_clocks, xdc)
                self.assertIn("set_max_delay 2.0 -datapath_only", xdc)
                self.assertEqual(xdc.count("set_input_delay"), 0)
                self.assertEqual(xdc.count("set_output_delay"), 4)
                self.assertNotIn("create_clock -name cm005_rxclk", xdc)
                verilog = next((pathlib.Path(tmp) / "gateware").glob("*.v")).read_text()
                self.assertEqual(len(re.findall(r"\) cm005_sample_\w+_iserdes \(", verilog)), 6)
                self.assertNotIn("IDDRE1 #(", verilog)
                self.assertEqual(soc.ethphy.rx_clk_freq, 156.25e6)
                for name, divide in (("fast", 1), ("word", 4)):
                    block = re.search(
                        r"BUFGCE_DIV #\(([^;]*?)\) cm005_sample_" + name + r"_buf\s*\(([^;]*)\);",
                        verilog, re.S)
                    self.assertIsNotNone(block)
                    self.assertRegex(block[1], r"\.BUFGCE_DIVIDE\s*\(\d+'d" + str(divide) + r"\)")
                    self.assertRegex(block[2], r"\.I\s*\(cm005_sample_raw_clk\)")
                    self.assertRegex(block[2], r"\.CLR\s*\(\(~ethpll_locked\)\)")
                self.assertEqual(soc.ethphy.tx_clk_freq, 25e6 if speed == 100 else 125e6)
                checker = next(stage for stage in soc.ethmac.core.rx_datapath.pipeline
                               if isinstance(stage, LiteEthMACPreambleChecker))
                self.assertEqual(len(checker.sink.data), 8 if speed == 1000 else 32)
                self.assertEqual(len(soc.ethmac.bus_rx.dat_r), 32)
                self.assertEqual(len(soc.ethmac.bus_tx.dat_w), 32)
                if speed == 1000:
                    self.assertEqual(soc.ethphy.rx.decoder.data_sample_advance, (0, 2, 0, 2))
                    self.assertEqual(soc.ethphy.rx.decoder.control_sample_advance, 2)
                    self.assertEqual(len(re.findall(r"ODDRE1 cm005_tx_\w+_ddr\(", verilog)), 6)
                    self.assertIn("cm005_tx_phase", verilog)
                    self.assertIn("-edges {2 4 6}", xdc)
                    self.assertIn("CLOCK_DELAY_GROUP cm005_transmit", xdc)
                    self.assertIn("set_property CLOCK_LOW_FANOUT TRUE", xdc)
                    self.assertIn("set_property SLEW FAST", xdc)
                    self.assertNotIn("PHASESHIFT_MODE", xdc)
                tcl = next((pathlib.Path(tmp) / "gateware").glob("*.tcl")).read_text()
                self.assertIn("cm005_check_sampling_aperture cm005_aperture.rpt", tcl)
                self.assertIn("check_cm005_aperture.tcl", tcl)

    def test_100m_interframe_gap(self):
        dut = Module()
        dut.submodules.gap = LiteEthMACGap(8, cycles=24)
        dut.submodules.tx = CM005TX100()
        dut.comb += dut.gap.source.connect(dut.tx.sink)
        transfers = []

        @passive
        def monitor():
            cycle = 0
            while True:
                if (yield dut.tx.source.valid):
                    transfers.append((cycle, (yield dut.tx.source.last)))
                cycle += 1
                yield

        def stimulus():
            yield dut.tx.source.ready.eq(1)
            for b in (0x35, 0xa2):
                yield dut.gap.sink.valid.eq(1)
                yield dut.gap.sink.data.eq(b)
                yield dut.gap.sink.last.eq(1)
                yield
                while not (yield dut.gap.sink.ready):
                    yield
            yield dut.gap.sink.valid.eq(0)
            for _ in range(30):
                yield

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(len(transfers), 4)
        self.assertEqual([last for _, last in transfers], [0, 1, 0, 1])
        self.assertGreaterEqual(transfers[2][0] - transfers[1][0] - 1, 24)

    def test_rv64_100m_elaboration(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(shared.Raptor, "add_sources", lambda *args, **kwargs: None):
                soc = cu08.RaptorMLKCU08SoC(sys_clk_freq=50e6, cpu_variant="linux64",
                    with_ethernet=True, eth_speed=100, integrated_main_ram_size=0x10000)
                Builder(soc, output_dir=tmp, compile_software=False).build(run=False)
            csr = json.loads((pathlib.Path(tmp) / "csr.json").read_text())
            self.assertEqual(csr["constants"]["cm005_eth_speed"], 100)
            self.assertEqual(soc.ethphy.dw, 8)
            self.assertEqual(soc.ethphy.tx_clk_freq, 25e6)
            self.assertIn("interrupts = <4>;", ethernet_node(csr))

    def test_100m_loopback(self):
        dut = Module()
        dut.submodules.tx = CM005TX100()
        dut.submodules.rx = CM005RX100()
        dut.comb += dut.tx.source.connect(dut.rx.sink)
        packets = [bytes((j * 37 + n) & 255 for j in range(n))
                   for n in (1, 2, 3, 60, 64, 1518)]
        expected = [(b, i == len(p) - 1) for p in packets for i, b in enumerate(p)]
        received, nibbles = [], []

        @passive
        def monitor():
            rng = random.Random(8531)
            while True:
                if (yield dut.tx.source.valid) and (yield dut.tx.source.ready):
                    b = (yield dut.tx.source.data)
                    self.assertEqual(b & 15, b >> 4)
                    nibbles.append((b & 15, (yield dut.tx.source.last)))
                if (yield dut.rx.source.valid) and (yield dut.rx.source.ready):
                    self.assertEqual((yield dut.rx.source.error), 0)
                    received.append(((yield dut.rx.source.data), (yield dut.rx.source.last)))
                yield dut.rx.source.ready.eq(rng.randrange(4) != 0)
                yield

        def stimulus():
            for p in packets:
                for i, b in enumerate(p):
                    yield dut.tx.sink.valid.eq(1)
                    yield dut.tx.sink.data.eq(b)
                    yield dut.tx.sink.last.eq(i == len(p) - 1)
                    yield
                    while not (yield dut.tx.sink.ready):
                        yield
                yield dut.tx.sink.valid.eq(0)
                yield dut.tx.sink.last.eq(0)
                for _ in range(24):
                    yield
            for _ in range(20):
                yield

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(received, expected)
        expected_nibbles = []
        for b, last in expected:
            expected_nibbles.extend([(b & 15, 0), (b >> 4, int(last))])
        self.assertEqual(nibbles, expected_nibbles)

    def test_100m_odd_frame_and_reset(self):
        dut = ResetInserter()(CM005RX100())
        received = []

        @passive
        def monitor():
            while True:
                if (yield dut.source.valid) and (yield dut.source.ready):
                    received.append(((yield dut.source.data), (yield dut.source.last),
                                     (yield dut.source.error)))
                yield

        def send(nibble, last=0):
            yield dut.sink.valid.eq(1)
            yield dut.sink.data.eq(nibble * 17)
            yield dut.sink.last.eq(last)
            yield
            while not (yield dut.sink.ready):
                yield

        def stimulus():
            yield dut.source.ready.eq(1)
            yield from send(3, 1)  # Odd nibble count must not become a clean byte.
            yield from send(5)
            yield from send(10, 1)
            yield dut.sink.valid.eq(0)
            for _ in range(4):
                yield
            yield from send(7)  # Reset in the middle of a byte.
            yield dut.sink.valid.eq(0)
            yield dut.reset.eq(1)
            yield
            yield dut.reset.eq(0)
            yield
            yield from send(2)
            yield from send(11, 1)
            yield dut.sink.valid.eq(0)
            for _ in range(4):
                yield

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(len(received), 3)
        self.assertEqual(received[0][1:], (1, 1))
        self.assertEqual(received[1:], [(0xa5, 1, 0), (0xb2, 1, 0)])

    def check_mdio_init(self, speed):
        dut = CM005MDIOInit(1000, speed=speed)
        frames = []

        @passive
        def monitor():
            previous_clock, bits = 0, []
            while True:
                clk = (yield dut.mdc)
                if (yield dut.reset):
                    bits = []
                elif clk and not previous_clock and (yield dut.oe):
                    bits.append((yield dut.data))
                    if len(bits) == 64:
                        value = 0
                        for b in bits:
                            value = (value << 1) | b
                        frames.append(value)
                        bits = []
                previous_clock = clk
                yield

        def stimulus():
            for _ in range(2):
                yield dut.reset.eq(1)
                yield
                yield dut.reset.eq(0)
                yield
                self.assertEqual((yield dut.done), 0)
                for cycle in range(450):
                    if (yield dut.done):
                        break
                    yield
                else:
                    self.fail("MDIO initialization timed out")
                self.assertEqual((yield dut.mdc), 0)
                self.assertEqual((yield dut.oe), 0)
                for _ in range(5):
                    yield

        run_simulation(dut, [stimulus(), monitor()])
        expected = [(0xffffffff << 32) | (5 << 28) | (reg << 18) | (2 << 16) | val
                    for reg, val in ((9, 0x200 if speed == 1000 else 0),
                                     (4, 0x001 if speed == 1000 else 0x101), (0, 0x1200))]
        self.assertEqual(frames, expected * 2)

    def test_100m_mdio_init_repeats_after_reset(self):
        self.check_mdio_init(100)

    def test_1000m_mdio_init_repeats_after_reset(self):
        self.check_mdio_init(1000)

    def test_board_configuration_isolation(self):
        # Both entry points are already imported in this process. Construct
        # them alternately to catch accidental shared-module rebinding.
        for target, soc_type in (
            (cu08, cu08.RaptorMLKCU08SoC),
            (cu07, cu07.RaptorMLKCU07SoC),
            (cu08, cu08.RaptorMLKCU08SoC),
        ):
            with self.subTest(board=target.BOARD.name):
                soc = soc_type(sys_clk_freq=50e6, integrated_main_ram_size=0x10000)
                self.assertIs(type(soc.platform), target.BOARD.platform)
                with patch.object(target, "run_target") as run:
                    target.main()
                run.assert_called_once_with(target.BOARD)
        self.assertFalse(cu07.BOARD.cm005_rx_tuned)
        self.assertTrue(cu08.BOARD.cm005_rx_tuned)
        self.assertEqual(cu07.BOARD.bare_hold_uncertainty, 0.250)
        self.assertEqual(cu08.BOARD.bare_hold_uncertainty, 0.050)
        with self.assertRaises(FrozenInstanceError):
            cu08.BOARD.name = "mlk_cu07_ku15p"

    def test_power_reset(self):
        dut = CM005Reset(1000)

        def stimulus():
            for cycle in range(25):
                self.assertEqual((yield dut.active), int(cycle < 20))
                yield

        run_simulation(dut, stimulus())

    def test_reset_restart(self):
        dut = CM005Reset(1000)

        def stimulus():
            for _ in range(25):
                yield
            self.assertEqual((yield dut.active), 0)
            # A sustained fault holds the counter loaded. After it clears,
            # require the full 20 cycles, not the remainder from startup.
            yield dut.restart.eq(1)
            for _ in range(30):
                yield
            self.assertEqual((yield dut.active), 1)
            yield dut.restart.eq(0)
            yield
            for cycle in range(25):
                self.assertEqual((yield dut.active), int(cycle < 20))
                yield

        run_simulation(dut, stimulus())

    def test_unverified_mapping_rejected(self):
        with self.assertRaises(ValueError):
            add_pads(None, "mlk_cu07_ku15p", "b", "a")

    def test_cpu_has_no_temporary_debug_reset(self):
        soc = cu07.RaptorMLKCU07SoC(sys_clk_freq=50e6,
            integrated_main_ram_size=0x10000)
        self.assertFalse(hasattr(soc.cpu, "dbg_reset"))

    def test_peripheral_elaboration(self):
        for target, soc_type, dram, speed in (
            (target, soc_type, dram, speed)
            for target, soc_type in ((cu07, cu07.RaptorMLKCU07SoC), (cu08, cu08.RaptorMLKCU08SoC))
            for dram in (False, True) for speed in (100, 1000)
        ):
            board = target.BOARD.name
            with self.subTest(board=board, litedram=dram, speed=speed), tempfile.TemporaryDirectory() as tmp:
                # Intentionally omit CPU RTL source collection: this verifies
                # peripheral construction, CSR layout and emitted constraints only.
                with patch.object(shared.Raptor, "add_sources", lambda *args, **kwargs: None):
                    soc = soc_type(sys_clk_freq=50e6,
                        with_ethernet=True, with_litedram=dram, eth_speed=speed, fmc_slot="a",
                        integrated_main_ram_size=0 if dram else 0x10000)
                    Builder(soc, output_dir=tmp, compile_software=False).build(run=False)
                csr = json.loads((pathlib.Path(tmp) / "csr.json").read_text())
                self.assertEqual(csr["memories"]["ethmac"]["base"], 0xe0000000)
                self.assertIn("interrupts = <4>;", ethernet_node(csr))
                phy = csr["csr_bases"]["ethphy"]
                for register, offset in (("crg_reset", 0), ("mdio_w", 4), ("mdio_r", 8)):
                    self.assertEqual(csr["csr_registers"]["ethphy_" + register]["addr"], phy + offset)
                xdc = next((pathlib.Path(tmp) / "gateware").glob("*.xdc")).read_text()
                self.assertLess(xdc.index("create_clock -name cm005_rxclk"),
                                xdc.index("set_input_delay"))
                self.assertEqual(csr["constants"]["cm005_eth_speed"], speed)
                self.assertEqual(soc.ethphy.tx_clk_freq, 25e6 if speed == 100 else 125e6)
                if speed == 100:
                    self.assertEqual(soc.ethphy.tx_gap_cycles, 24)
                    self.assertIn("cm005_rxclk -period 40.0", xdc)
                    self.assertIn("-max 19.2", xdc)
                else:
                    self.assertIn("cm005_rxclk -period 8.0", xdc)
                    self.assertIn("-max 3.2", xdc)
                self.assertEqual(xdc.count("set_input_delay"), 4)
                # IDDRE1 retains CB checks even when the repeated Q2 sample
                # is unused. Guard the half-cycle model, not just the rate.
                self.assertIn(f"-max {19.2 if speed == 100 else 3.2} -clock_fall -add_delay", xdc)
                self.assertIn("-min 0.8 -clock_fall -add_delay", xdc)
                self.assertEqual(xdc.count("set_output_delay"), 4)
                self.assertIn("-min 0.8", xdc)
                self.assertIn("NAME =~ *cm005_txclk_ddr", xdc)
                self.assertIn("REF_PIN_NAME == C || REF_PIN_NAME == CLK", xdc)
                self.assertIn("set_property PHASESHIFT_MODE WAVEFORM", xdc)
                verilog = next((pathlib.Path(tmp) / "gateware").glob("*.v")).read_text()
                rx_delays = [block for block in re.findall(
                    r"\bIDELAYE3 #\((.*?)\n\);", verilog, re.S)
                    if re.search(r"\.IDATAIN\s*\([^)]*rx_(?:ctl|data)_ibuf", block)]
                self.assertEqual(len(rx_delays), 5)
                delay_values = [re.search(
                    r"\.DELAY_VALUE\s*\((?:\d+'d)?(\d+)\)", block).group(1)
                    for block in rx_delays]
                if board == "mlk_cu08_ku15p" and not dram:
                    self.assertCountEqual(delay_values, ["900"] + ["950"] * 4)
                    control = next(block for block in rx_delays
                                   if "rx_ctl_ibuf" in block)
                    self.assertRegex(control, r"\.DELAY_VALUE\s*\((?:\d+'d)?900\)")
                    self.assertIn("set_property LOC MMCM_X0Y8", xdc)
                    self.assertIn("CLOCK_DEDICATED_ROUTE SAME_CMT_COLUMN", xdc)
                    self.assertIn("USER_CLOCK_ROOT X2Y8", xdc)
                else:
                    self.assertEqual(delay_values, ["1000"] * 5)
                    self.assertNotIn("USER_CLOCK_ROOT X2Y8", xdc)
                if not dram:
                    self.assertNotIn("sys_rst <=", verilog)
                    self.assertIn("cm005_ready_rst <=", verilog)


if __name__ == "__main__":
    unittest.main()
