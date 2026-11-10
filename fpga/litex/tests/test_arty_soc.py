"""Exercise Arty clocks, the sampled CPU TAP and board-aware build profiles."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from migen import ClockDomain, ClockSignal, Instance, Module, Record, ResetSignal, Signal
from migen.fhdl import verilog
from migen.sim import run_simulation

LITEX = Path(__file__).resolve().parents[1]
REPO = LITEX.parents[1]
sys.path.insert(0, str(LITEX))
sys.path.insert(0, str(LITEX / "scripts"))
from arty_a7_t100 import RaptorArtySoC, SampledJTAG
from add_linux_ethernet_dts import ethernet_node


class ArtySoCTest(unittest.TestCase):
    def test_cpu_clock_and_ddr_are_independent(self):
        for variant in ("linux32", "linux64"):
            with self.subTest(variant=variant), patch.dict(os.environ, {"RAPT_CONFIG": "small"}):
                with contextlib.redirect_stdout(io.StringIO()):
                    soc = RaptorArtySoC(sys_clk_freq=25_000_000, cpu_variant=variant,
                                        with_litedram=True, with_ethernet=True)
                self.assertEqual(soc.sys_clk_freq, 80_000_000)
                self.assertEqual(soc.constants["CONFIG_CPU_CLOCK_FREQUENCY"], 25_000_000)
                self.assertEqual(soc.bus.regions["main_ram"].size, 0x10000000)
                self.assertEqual(soc.cpu.pmem_size, 0x10000000)
                self.assertTrue(hasattr(soc.cpu, "axi_cdc"))
                self.assertEqual(soc.cpu.cpu_params["i_clock"].cd, "cpu")
                self.assertNotIsInstance(soc.cpu.cpu_params["i_jtag_trst_n"], int)

    def test_bram_has_no_ddr_phy(self):
        with patch.dict(os.environ, {}), contextlib.redirect_stdout(io.StringIO()):
            soc = RaptorArtySoC(with_litedram=False, integrated_main_ram_size=0x20000)
        self.assertEqual(soc.cpu.pmem_size, 0x20000)
        self.assertFalse(hasattr(soc, "ddrphy"))

    def test_reject_invalid_memory_and_clock(self):
        for kwargs in ({"litedram_size": 0x80000000},
                       {"sys_clk_freq": 10_000_000},
                       {"integrated_main_ram_size": 0x20000}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                RaptorArtySoC(**kwargs)

    def test_jtag_one_enable_per_slow_tck_edge(self):
        cpu = SimpleNamespace(cpu_params={})
        pads = Record([("tck", 1), ("tms", 1), ("tdi", 1), ("tdo", 1)])
        dut = Module()
        dut.clock_domains.cd_cpu = ClockDomain("cpu")
        dut.submodules.jtag = SampledJTAG(cpu, pads)
        captured = []
        expected = [(0, 1), (1, 0), (1, 1), (0, 0)]

        def drive():
            for tms, tdi in expected:
                yield pads.tck.eq(0)
                yield pads.tms.eq(tms)
                yield pads.tdi.eq(tdi)
                for _ in range(7):
                    yield
                yield pads.tck.eq(1)
                for _ in range(7):
                    yield
            yield pads.tck.eq(0)
            for _ in range(8):
                yield

        def observe():
            for _ in range(64):
                if (yield cpu.cpu_params["i_jtag_tck_en"]):
                    captured.append(((yield cpu.cpu_params["i_jtag_tms"]),
                                     (yield cpu.cpu_params["i_jtag_tdi"])))
                yield

        run_simulation(dut, {"cpu": [drive(), observe()]}, clocks={"cpu": 10})
        self.assertEqual(captured, expected)

    def test_matching_ethernet_export(self):
        with tempfile.TemporaryDirectory() as scratch:
            csr = Path(scratch) / "csr.json"
            env = dict(os.environ, RAPT_CONFIG="small", RAPT_PACK_ROOT=scratch)
            command = [sys.executable, str(LITEX / "arty_a7_t100.py"),
                       "--with-litedram", "--with-ethernet", "--cpu-variant=linux64",
                       "--export-ethernet-csr=" + str(csr)]
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr[-4000:])
            data = json.loads(csr.read_text())
            self.assertEqual(data["csr_bases"]["uart"], 0x11001800)
            self.assertEqual(data["memories"]["main_ram"]["size"], 0x10000000)
            node = ethernet_node(data)
            self.assertIn('compatible = "litex,liteeth"', node)
            self.assertIn("0x18000000", node)

    @unittest.skipUnless(shutil.which("verilator"), "requires Verilator")
    def test_sampled_real_dtm(self):
        dut = Module()
        dut.clock_domains.cd_cpu = ClockDomain("cpu")
        pads = Record([("tck", 1), ("tms", 1), ("tdi", 1), ("tdo", 1)], name="jtag")
        cpu = SimpleNamespace(cpu_params={})
        dut.submodules.tap = SampledJTAG(cpu, pads)
        params = cpu.cpu_params
        dut.specials += Instance(
            "rapt_dtm", i_clock=ClockSignal("cpu"), i_reset=ResetSignal("cpu"),
            i_trst_n=params["i_jtag_trst_n"], i_tck_en=params["i_jtag_tck_en"],
            i_tms=params["i_jtag_tms"], i_tdi=params["i_jtag_tdi"],
            o_tdo=params["o_jtag_tdo"], o_dmi_req=Signal(name="dmi_req"),
            o_dmi_wr=Signal(name="dmi_wr"), o_dmi_addr=Signal(7, name="dmi_addr"),
            o_dmi_wdata=Signal(32, name="dmi_data"), i_dmi_rdata=0x12345678, i_dmi_resp=0)
        with tempfile.TemporaryDirectory(prefix="raptor-arty-jtag-", dir="/tmp") as scratch:
            work = Path(scratch)
            bridge = work / "tap_bridge.v"
            bridge.write_text(str(verilog.convert(
                dut, ios={*pads.flatten(), dut.cd_cpu.clk, dut.cd_cpu.rst}, name="tap_bridge")))
            top = "tb_rapt_arty_soc_jtag"
            command = ["verilator", "--binary", "--timing", "-j", "2", "-Wno-fatal",
                       "-DSYNTHESIS", "-I" + str(REPO / "rtl/configs/small"),
                       "-I" + str(REPO / "rtl/include"), "--top-module", top,
                       "--Mdir", str(work / "obj"), str(bridge),
                       str(REPO / "fpga/arty-a7-t100/tests" / (top + ".sv")),
                       str(REPO / "rtl/uncore/debug/rapt_dtm.sv")]
            build = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout[-4000:] + build.stderr[-4000:])
            result = subprocess.run([str(work / "obj" / ("V" + top))],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: sampled external JTAG", result.stdout)

    def test_netboot_uses_ddr3_and_mii(self):
        command = ["make", "-s", "-n", "-C", str(LITEX), "fpga-netboot-rv64-info",
                   "FPGA_BOARD=arty_a7_t100", "NETBOOT_BUILD_ROOT=/tmp/raptor-arty-test"]
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(("RAPT_", "MAKE", "MFLAGS"))}
        result = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for setting in ("WITH_MIG=0", "WITH_LITEDRAM=1", "WITH_SDCARD=0",
                        "ETH_SPEED=100", "RAPT_CONFIG=small"):
            self.assertIn(setting, result.stdout)

    def test_no_fpu_preset_does_not_advertise_gc_linux(self):
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(("RAPT_", "MAKE", "MFLAGS"))}
        probe = "isa-probe:\n\t@printf '%s\\n' '$(LINUX_ISA)'\n"
        command = ["make", "--no-print-directory", "-s", "-C", str(LITEX),
                   "-f", "Makefile", "-f", "-", "isa-probe", "FPGA_BOARD=arty_a7_t100",
                   "FPGA_AUTO_DETECT=0", "VARIANT=linux32", "RAPT_CONFIG=chip32-small"]
        result = subprocess.run(command, input=probe, env=environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("rv32imac_"), result.stdout)
        result = subprocess.run(
            ["make", "-s", "-n", "-C", str(LITEX), "fpga-netboot-rv32-build",
             "FPGA_BOARD=arty_a7_t100", "RAPT_CONFIG=chip32-small"],
            env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires F/D", result.stderr)


if __name__ == "__main__":
    unittest.main()
