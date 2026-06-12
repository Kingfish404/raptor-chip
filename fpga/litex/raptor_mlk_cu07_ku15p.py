#!/usr/bin/env python3
#
# raptor_mlk_cu07_ku15p.py — Raptor LiteX SoC on the Milianke MLK-CU07-KU15P
# (Xilinx Kintex UltraScale+ XCKU15P-FFVA1156-2-E) using the Vivado toolchain.
#
# This is the Vivado counterpart to raptor_tang_mega_138k_pro.py (Gowin). It
# builds the UART bring-up SoC by default: integrated ROM (BIOS or custom
# firmware) + integrated SRAM + optional BSRAM main_ram, a single LiteUART on
# the on-board USB-UART, and the Raptor OoO core. Pass --with-mig to switch
# main_ram to the on-board DDR4 through Xilinx DDR4 MIG for large Linux payloads.
# The earlier --with-litedram path is retained as an experimental reference.
#
# Board facts (from third_party/security-hw-fpga/board/mlk-cu07-ku15p/):
#   * Part        : xcku15p-ffva1156-2-e  (L2 1.0V, -2 speed, FFVA1156, comm.)
#   * sys_clock   : AH18, LVCMOS18, 100 MHz single-ended
#   * resetn      : J23, LVCMOS18, active-low push-button (BUT1)
#   * UART TX     : AN13, LVCMOS33  (FPGA -> Host, usb_uart_txd)
#   * UART RX     : AP13, LVCMOS33  (Host -> FPGA, usb_uart_rxd)
#   * Cfg flash   : MT25QU256 QSPI, SPIx4
#
# Usage (driven by the Makefile fpga-* targets with FPGA_BOARD=mlk_cu07_ku15p):
#   python3 raptor_mlk_cu07_ku15p.py --boot-mode=bios --build
#   python3 raptor_mlk_cu07_ku15p.py --boot-mode=custom \
#       --integrated-rom-init=build/.../boot.bin --build

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "cores"))

from cpu.raptor.core import Raptor

from migen import *
from migen.genlib.cdc import MultiReg
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen import *
from litex.build.generic_platform import Subsignal, Pins, IOStandard, Misc
from litex.build.io import DifferentialInput
from litex.build.xilinx import XilinxUSPPlatform
from litex.build.openfpgaloader import OpenFPGALoader
from litex.build.parser import LiteXArgumentParser

from litex.soc.cores.clock import USPMMCM, USPIDELAYCTRL
from litex.soc.cores.cpu import CPUS
from litex.soc.cores.led import LedChaser
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex.soc.interconnect import axi, stream

from litedram.modules import MT40A512M16
from litedram.phy import usddrphy


CPUS["raptor"] = Raptor

DEVICE_PART = "xcku15p-ffva1156-2-e"
DEFAULT_FPGA_SYS_CLK = int(75e6)
DEFAULT_FPGA_BOOT_MODE = "bios"

# IOs --------------------------------------------------------------------------

_io = [
    # 100 MHz single-ended system clock (Y2 / AH18, LVCMOS18).
    ("clk100", 0, Pins("AH18"), IOStandard("LVCMOS18")),

    # 100 MHz DDR4 reference clock (Y1 / AK17-AK16, DIFF_SSTL12).
    (
        "clk100_ddr",
        0,
        Subsignal("p", Pins("AK17")),
        Subsignal("n", Pins("AK16")),
        IOStandard("DIFF_SSTL12"),
    ),

    # Active-low reset push-button (BUT1 / J23, LVCMOS18).
    ("cpu_resetn", 0, Pins("J23"), IOStandard("LVCMOS18")),

    # On-board USB-UART (LVCMOS33). tx = FPGA->Host, rx = Host->FPGA.
    (
        "serial",
        0,
        Subsignal("tx", Pins("AN13")),
        Subsignal("rx", Pins("AP13")),
        IOStandard("LVCMOS33"),
    ),

    # 4GB DDR4 SDRAM: 4 x Hynix H5AN8G6NCJR-VKI, modeled as MT40A512M16.
    (
        "ddram",
        0,
        Subsignal(
            "a",
            Pins(
                "AM34 AN26 AP34 AK26 AL32 AK28 AK32 AL30",
                "AL34 AP26 AK31 AL33 AH32 AM32",
            ),
            IOStandard("SSTL12_DCI"),
        ),
        Subsignal("ba", Pins("AJ31 AK27"), IOStandard("SSTL12_DCI")),
        Subsignal("bg", Pins("AJ30"), IOStandard("SSTL12_DCI")),
        Subsignal("ras_n", Pins("AJ33"), IOStandard("SSTL12_DCI")),
        Subsignal("cas_n", Pins("AJ34"), IOStandard("SSTL12_DCI")),
        Subsignal("we_n", Pins("AJ28"), IOStandard("SSTL12_DCI")),
        Subsignal("cs_n", Pins("AH33"), IOStandard("SSTL12_DCI")),
        Subsignal("act_n", Pins("AH31"), IOStandard("SSTL12_DCI")),
        Subsignal(
            "dm",
            Pins("Y26 V27 AA22 W23 AE25 AD21 AM21 AJ21"),
            IOStandard("POD12_DCI"),
        ),
        Subsignal(
            "dq",
            Pins(
                "AD25 AA27 AC24 AB25 AB24 AB27 AD26 AB26",
                "U25 W28 W26 W29 U24 V29 V26 Y28",
                "AB20 Y23 AC22 AA24 AA20 AA25 AC23 AA23",
                "U22 T22 T23 W21 U21 Y25 V21 W25",
                "AJ23 AF23 AJ24 AG25 AH23 AF24 AH22 AG24",
                "AG20 AE22 AF20 AF22 AD20 AE23 AG22 AE20",
                "AM22 AM24 AN22 AN24 AN23 AP24 AP23 AP25",
                "AL24 AL25 AK22 AL22 AK23 AM20 AL20 AL23",
            ),
            IOStandard("POD12_DCI"),
        ),
        Subsignal(
            "dqs_p",
            Pins("AC26 U26 AB21 V22 AH24 AG21 AP20 AJ20"),
            IOStandard("DIFF_POD12_DCI"),
        ),
        Subsignal(
            "dqs_n",
            Pins("AC27 U27 AC21 V23 AJ25 AH21 AP21 AK20"),
            IOStandard("DIFF_POD12_DCI"),
        ),
        Subsignal("clk_p", Pins("AJ29"), IOStandard("DIFF_SSTL12_DCI")),
        Subsignal("clk_n", Pins("AK30"), IOStandard("DIFF_SSTL12_DCI")),
        Subsignal("cke", Pins("AH27"), IOStandard("SSTL12_DCI")),
        Subsignal("odt", Pins("AH28"), IOStandard("SSTL12_DCI")),
        Subsignal("reset_n", Pins("AJ26"), IOStandard("LVCMOS12")),
        Misc("SLEW=FAST"),
    ),
]

_connectors = []


# Platform ---------------------------------------------------------------------


class Platform(XilinxUSPPlatform):
    default_clk_name = "clk100"
    default_clk_period = 1e9 / 100e6

    def __init__(self, toolchain="vivado"):
        XilinxUSPPlatform.__init__(
            self, DEVICE_PART, _io, _connectors, toolchain=toolchain
        )
        # Match the on-board config flash so `make fpga-flash` can write it.
        self.add_platform_command(
            "set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]"
        )
        self.add_platform_command(
            "set_property BITSTREAM.GENERAL.COMPRESS true [current_design]"
        )
        self.add_platform_command(
            "set_property CONFIG_VOLTAGE 1.8 [current_design]"
        )
        self.add_platform_command("set_property CFGBVS GND [current_design]")
        self.add_platform_command(
            "set_property CONFIG_MODE SPIx4 [current_design]"
        )
        self.add_platform_command(
            "set_property BITSTREAM.CONFIG.UNUSEDPIN pulldown [current_design]"
        )

    def create_programmer(self):
        return OpenFPGALoader(fpga_part="xcku15p-ffva1156", cable="ft2232")

    def do_finalize(self, fragment):
        XilinxUSPPlatform.do_finalize(self, fragment)
        self.add_period_constraint(
            self.lookup_request("clk100", loose=True), 1e9 / 100e6
        )


# CRG --------------------------------------------------------------------------


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq, with_litedram=False):
        self.rst = Signal()
        self.cd_sys = ClockDomain()
        self.cd_por = ClockDomain()
        if with_litedram:
            self.cd_sys4x = ClockDomain()
            self.cd_pll4x = ClockDomain()
            self.cd_idelay = ClockDomain()

        clk100 = platform.request("clk100")
        # The J23 reset button (cpu_resetn) is intentionally left unused for
        # bring-up. Gating any reset on it is risky: if the board does not pull
        # the pin up it can idle low and hold the SoC (or the MMCM) in reset
        # forever, preventing the BIOS from ever running. A free-running
        # power-on reset (POR) clocked by the raw 100 MHz input brings the
        # design up reliably regardless of the button. Request it so the pin is
        # still constrained, but do not connect it.
        platform.request("cpu_resetn")

        # Power-on reset: hold the MMCM in reset for a fixed number of input
        # clocks after configuration, then release (mirrors the Tang Mega CRG).
        por_count = Signal(16, reset=2**16 - 1)
        por_done = Signal()
        self.comb += [
            self.cd_por.clk.eq(clk100),
            por_done.eq(por_count == 0),
        ]
        self.sync.por += If(~por_done, por_count.eq(por_count - 1))

        self.pll = pll = USPMMCM(speedgrade=-2)
        self.comb += pll.reset.eq(~por_done | self.rst)
        if with_litedram:
            clk100_ddr_pads = platform.request("clk100_ddr")
            clk100_ddr = Signal()
            platform.add_period_constraint(clk100_ddr_pads.p, 1e9 / 100e6)
            self.specials += DifferentialInput(clk100_ddr_pads.p, clk100_ddr_pads.n, clk100_ddr)
            pll.register_clkin(clk100_ddr, 100e6)
            pll.create_clkout(self.cd_pll4x, sys_clk_freq * 4, buf=None, with_reset=False)
            pll.create_clkout(self.cd_idelay, 400e6)
            self.specials += [
                Instance(
                    "BUFGCE_DIV",
                    p_BUFGCE_DIVIDE=4,
                    i_CE=pll.locked,
                    i_I=self.cd_pll4x.clk,
                    o_O=self.cd_sys.clk,
                ),
                Instance(
                    "BUFGCE",
                    i_CE=pll.locked,
                    i_I=self.cd_pll4x.clk,
                    o_O=self.cd_sys4x.clk,
                ),
            ]
            self.idelayctrl = USPIDELAYCTRL(cd_ref=self.cd_idelay, cd_sys=self.cd_sys)
        else:
            pll.register_clkin(clk100, 100e6)
            pll.create_clkout(self.cd_sys, sys_clk_freq, with_reset=False)
            self.specials += AsyncResetSynchronizer(self.cd_sys, ~pll.locked)

        # Ignore the sys_clk -> pll.clkin path created by the SoC reset.
        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)


# AXI / DDR4 MIG ---------------------------------------------------------------


class AXIClockDomainCrossing(LiteXModule):
    def __init__(self, master, slave, cd_from="sys", cd_to="sys", depth=16):
        if cd_from == cd_to:
            self.comb += master.connect(slave)
            return

        aw_cdc = stream.ClockDomainCrossing(
            master.aw.description, cd_from, cd_to, depth=depth, buffered=True, with_common_rst=True
        )
        w_cdc = stream.ClockDomainCrossing(
            master.w.description, cd_from, cd_to, depth=depth, buffered=True, with_common_rst=True
        )
        b_cdc = stream.ClockDomainCrossing(
            master.b.description, cd_to, cd_from, depth=depth, buffered=True, with_common_rst=True
        )
        ar_cdc = stream.ClockDomainCrossing(
            master.ar.description, cd_from, cd_to, depth=depth, buffered=True, with_common_rst=True
        )
        r_cdc = stream.ClockDomainCrossing(
            master.r.description, cd_to, cd_from, depth=depth, buffered=True, with_common_rst=True
        )
        self.submodules += aw_cdc, w_cdc, b_cdc, ar_cdc, r_cdc
        self.comb += [
            master.aw.connect(aw_cdc.sink),
            aw_cdc.source.connect(slave.aw),
            master.w.connect(w_cdc.sink),
            w_cdc.source.connect(slave.w),
            slave.b.connect(b_cdc.sink),
            b_cdc.source.connect(master.b),
            master.ar.connect(ar_cdc.sink),
            ar_cdc.source.connect(slave.ar),
            slave.r.connect(r_cdc.sink),
            r_cdc.source.connect(master.r),
        ]


class AXIInitGate(LiteXModule):
    def __init__(self, master, slave, enable):
        self.comb += [
            master.aw.connect(slave.aw, omit={"valid", "ready"}),
            master.w.connect(slave.w, omit={"valid", "ready"}),
            master.ar.connect(slave.ar, omit={"valid", "ready"}),
            slave.b.connect(master.b),
            slave.r.connect(master.r),

            slave.aw.valid.eq(master.aw.valid & enable),
            master.aw.ready.eq(slave.aw.ready & enable),
            slave.w.valid.eq(master.w.valid & enable),
            master.w.ready.eq(slave.w.ready & enable),
            slave.ar.valid.eq(master.ar.valid & enable),
            master.ar.ready.eq(slave.ar.ready & enable),
        ]


class KU15PDDR4MIG(LiteXModule):
    def __init__(self, platform):
        self.bus = axi.AXIInterface(
            data_width=512,
            address_width=32,
            id_width=4,
            clock_domain="ddr4",
        )
        self.init_done = Signal()
        self.ui_reset = Signal()
        self.cd_ddr4 = ClockDomain()

        pads = platform.request("ddram")
        refclk = platform.request("clk100_ddr")
        platform.add_period_constraint(refclk.p, 1e9 / 100e6)
        platform.add_ip(os.path.join(_here, "scripts", "ku15p_ddr4_mig.tcl"))

        mig_bus = axi.AXIInterface(
            data_width=512,
            address_width=32,
            id_width=4,
            clock_domain="ddr4",
        )
        self.submodules.init_gate = AXIInitGate(self.bus, mig_bus, self.init_done)

        ui_clk = Signal()
        ui_rst = Signal()
        dbg_clk = Signal()
        dbg_bus = Signal(512)

        self.comb += [
            self.cd_ddr4.clk.eq(ui_clk),
            self.ui_reset.eq(ui_rst),
        ]
        self.specials += AsyncResetSynchronizer(self.cd_ddr4, ui_rst)

        self.specials += Instance(
            "raptor_ddr4_0",
            i_sys_rst=ResetSignal("sys"),
            i_c0_sys_clk_p=refclk.p,
            i_c0_sys_clk_n=refclk.n,

            o_c0_init_calib_complete=self.init_done,
            o_c0_ddr4_ui_clk=ui_clk,
            o_c0_ddr4_ui_clk_sync_rst=ui_rst,
            o_dbg_clk=dbg_clk,
            o_dbg_bus=dbg_bus,

            o_c0_ddr4_act_n=pads.act_n,
            o_c0_ddr4_adr=Cat(pads.a, pads.we_n, pads.cas_n, pads.ras_n),
            o_c0_ddr4_ba=pads.ba,
            o_c0_ddr4_bg=pads.bg,
            o_c0_ddr4_cke=pads.cke,
            o_c0_ddr4_odt=pads.odt,
            o_c0_ddr4_cs_n=pads.cs_n,
            o_c0_ddr4_ck_t=pads.clk_p,
            o_c0_ddr4_ck_c=pads.clk_n,
            o_c0_ddr4_reset_n=pads.reset_n,
            io_c0_ddr4_dm_dbi_n=pads.dm,
            io_c0_ddr4_dq=pads.dq,
            io_c0_ddr4_dqs_c=pads.dqs_n,
            io_c0_ddr4_dqs_t=pads.dqs_p,

            i_c0_ddr4_aresetn=~ResetSignal("ddr4"),
            i_c0_ddr4_s_axi_awid=mig_bus.aw.id,
            i_c0_ddr4_s_axi_awaddr=mig_bus.aw.addr,
            i_c0_ddr4_s_axi_awlen=mig_bus.aw.len,
            i_c0_ddr4_s_axi_awsize=mig_bus.aw.size,
            i_c0_ddr4_s_axi_awburst=mig_bus.aw.burst,
            i_c0_ddr4_s_axi_awlock=mig_bus.aw.lock,
            i_c0_ddr4_s_axi_awcache=mig_bus.aw.cache,
            i_c0_ddr4_s_axi_awprot=mig_bus.aw.prot,
            i_c0_ddr4_s_axi_awqos=mig_bus.aw.qos,
            i_c0_ddr4_s_axi_awvalid=mig_bus.aw.valid,
            o_c0_ddr4_s_axi_awready=mig_bus.aw.ready,
            i_c0_ddr4_s_axi_wdata=mig_bus.w.data,
            i_c0_ddr4_s_axi_wstrb=mig_bus.w.strb,
            i_c0_ddr4_s_axi_wlast=mig_bus.w.last,
            i_c0_ddr4_s_axi_wvalid=mig_bus.w.valid,
            o_c0_ddr4_s_axi_wready=mig_bus.w.ready,
            i_c0_ddr4_s_axi_bready=mig_bus.b.ready,
            o_c0_ddr4_s_axi_bid=mig_bus.b.id,
            o_c0_ddr4_s_axi_bresp=mig_bus.b.resp,
            o_c0_ddr4_s_axi_bvalid=mig_bus.b.valid,
            i_c0_ddr4_s_axi_arid=mig_bus.ar.id,
            i_c0_ddr4_s_axi_araddr=mig_bus.ar.addr,
            i_c0_ddr4_s_axi_arlen=mig_bus.ar.len,
            i_c0_ddr4_s_axi_arsize=mig_bus.ar.size,
            i_c0_ddr4_s_axi_arburst=mig_bus.ar.burst,
            i_c0_ddr4_s_axi_arlock=mig_bus.ar.lock,
            i_c0_ddr4_s_axi_arcache=mig_bus.ar.cache,
            i_c0_ddr4_s_axi_arprot=mig_bus.ar.prot,
            i_c0_ddr4_s_axi_arqos=mig_bus.ar.qos,
            i_c0_ddr4_s_axi_arvalid=mig_bus.ar.valid,
            o_c0_ddr4_s_axi_arready=mig_bus.ar.ready,
            i_c0_ddr4_s_axi_rready=mig_bus.r.ready,
            o_c0_ddr4_s_axi_rid=mig_bus.r.id,
            o_c0_ddr4_s_axi_rdata=mig_bus.r.data,
            o_c0_ddr4_s_axi_rresp=mig_bus.r.resp,
            o_c0_ddr4_s_axi_rlast=mig_bus.r.last,
            o_c0_ddr4_s_axi_rvalid=mig_bus.r.valid,
        )


# SoC --------------------------------------------------------------------------


class RaptorMLKCU07SoC(SoCCore):
    def __init__(
        self,
        sys_clk_freq=DEFAULT_FPGA_SYS_CLK,
        with_litedram=False,
        litedram_size=0x40000000,
        with_mig=False,
        mig_size=0x40000000,
        with_led_chaser=False,
        rapt_memspeed_trace=False,
        **kwargs,
    ):
        platform = Platform(toolchain="vivado")

        kwargs["cpu_type"] = "raptor"
        kwargs.setdefault("cpu_variant", "standard")
        kwargs.setdefault("ident", "Raptor LiteX SoC on MLK-CU07-KU15P")
        kwargs.setdefault("ident_version", True)
        kwargs.setdefault("uart_name", "serial")
        kwargs.setdefault("uart_baudrate", 115200)
        kwargs.setdefault("uart_fifo_depth", 64)
        kwargs.setdefault("integrated_rom_size", 0x8000)
        kwargs.setdefault("integrated_sram_size", 0x2000)
        kwargs.setdefault("integrated_main_ram_size", 0)
        # Tighten the wishbone interconnect timeout so an access to an unmapped
        # address raises wb.err quickly (mirrors the Tang Mega SoC).
        kwargs.setdefault("bus_timeout", 4096)

        if with_litedram and with_mig:
            raise ValueError("--with-litedram and --with-mig are mutually exclusive")
        if with_litedram and kwargs.get("integrated_main_ram_size", 0) != 0:
            raise ValueError("--with-litedram requires --integrated-main-ram-size=0")
        if with_mig and kwargs.get("integrated_main_ram_size", 0) != 0:
            raise ValueError("--with-mig requires --integrated-main-ram-size=0")

        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)

        if rapt_memspeed_trace:
            self.add_config("RAPT_MEMSPEED_TRACE")

        self.crg = _CRG(platform, sys_clk_freq, with_litedram=with_litedram)

        if with_mig:
            self.ddr4_mig = KU15PDDR4MIG(platform)
            mig_ready_sys = Signal()
            self.specials += MultiReg(self.ddr4_mig.init_done, mig_ready_sys, "sys")
            self.cpu.cpu_params["i_reset"] = ResetSignal("sys") | self.cpu.reset | ~mig_ready_sys

            mig_sys_axi = axi.AXIInterface(
                data_width=512,
                address_width=32,
                id_width=4,
                clock_domain="sys",
            )
            self.submodules.ddr4_mig_cdc = AXIClockDomainCrossing(
                mig_sys_axi,
                self.ddr4_mig.bus,
                cd_from="sys",
                cd_to="ddr4",
                depth=16,
            )
            self.bus.add_slave(
                "main_ram",
                slave=mig_sys_axi,
                region=SoCRegion(
                    origin=self.mem_map.get("main_ram", 0x80000000),
                    size=mig_size,
                    mode="rwx",
                ),
                strip_origin=True,
            )
            platform.add_false_path_constraints(self.crg.cd_sys.clk, self.ddr4_mig.cd_ddr4.clk)

        if with_litedram:
            self.ddrphy = usddrphy.USPDDRPHY(
                platform.request("ddram"),
                memtype="DDR4",
                sys_clk_freq=sys_clk_freq,
                iodelay_clk_freq=400e6,
            )
            self.add_sdram(
                "sdram",
                phy=self.ddrphy,
                module=MT40A512M16(sys_clk_freq, "1:4"),
                size=litedram_size,
                l2_cache_size=kwargs.get("l2_size", 8192),
            )

        if with_led_chaser:
            try:
                self.leds = LedChaser(
                    pads=platform.request_all("user_led"),
                    sys_clk_freq=sys_clk_freq,
                )
            except Exception:
                pass


def main():
    parser = LiteXArgumentParser(
        platform=Platform,
        description="Raptor LiteX SoC on Milianke MLK-CU07-KU15P (Vivado).",
    )
    parser.add_target_argument(
        "--sys-clk-freq",
        default=DEFAULT_FPGA_SYS_CLK,
        type=float,
        help="System clock frequency.",
    )
    parser.add_target_argument(
        "--boot-mode",
        default=DEFAULT_FPGA_BOOT_MODE,
        choices=["bios", "custom"],
        help="Boot image source for the integrated ROM.",
    )
    parser.add_target_argument(
        "--with-led-chaser",
        action="store_true",
        help="Enable LedChaser (no LEDs are mapped by default).",
    )
    parser.add_target_argument(
        "--with-litedram",
        action="store_true",
        help="Use the on-board DDR4 through LiteDRAM as main_ram.",
    )
    parser.add_target_argument(
        "--litedram-size",
        default=0x40000000,
        type=lambda value: int(value, 0),
        help="Mapped LiteDRAM main_ram size in bytes.",
    )
    parser.add_target_argument(
        "--with-mig",
        action="store_true",
        help="Use the on-board DDR4 through Xilinx DDR4 MIG as main_ram.",
    )
    parser.add_target_argument(
        "--mig-size",
        default=0x40000000,
        type=lambda value: int(value, 0),
        help="Mapped DDR4 MIG main_ram size in bytes.",
    )
    parser.add_target_argument(
        "--rapt-memspeed-trace",
        action="store_true",
        help="Enable Raptor LiteX BIOS memspeed phase trace markers.",
    )
    parser.set_defaults(cpu_type="raptor", cpu_variant="standard")

    args = parser.parse_args()

    soc_kwargs = dict(parser.soc_argdict)
    builder_kwargs = dict(parser.builder_argdict)
    has_integrated_rom_init = soc_kwargs.get("integrated_rom_init") not in (
        None,
        [],
        "",
    )

    if args.boot_mode == "custom":
        if not has_integrated_rom_init:
            parser.error(
                "--boot-mode=custom requires --integrated-rom-init=<path>"
            )
        builder_kwargs["compile_software"] = False
    else:
        if has_integrated_rom_init:
            parser.error(
                "--boot-mode=bios cannot be combined with --integrated-rom-init; "
                "use --boot-mode=custom"
            )
        if not builder_kwargs.get("compile_software", True):
            parser.error(
                "--boot-mode=bios requires software compilation; remove "
                "--no-compile-software or use --boot-mode=custom"
            )

    soc = RaptorMLKCU07SoC(
        sys_clk_freq=int(args.sys_clk_freq),
        with_litedram=args.with_litedram,
        litedram_size=args.litedram_size,
        with_mig=args.with_mig,
        mig_size=args.mig_size,
        with_led_chaser=args.with_led_chaser,
        rapt_memspeed_trace=args.rapt_memspeed_trace,
        **soc_kwargs,
    )

    # Hold-timing hardening. The system clock (main_clkout) fans the whole core
    # out of a single global buffer with large (~2.4 ns) net skew, leaving some
    # reg->reg paths -- notably the divider remainder shift register
    # (rapt/core/exu/u_rs/mul/div_remainder_reg[*]) -- with razor-thin hold
    # slack (+0.010..0.024 ns). Those sign off in STA ("0 failing endpoints")
    # but sit inside silicon PVT noise, so on real hardware the divider can
    # latch a half-shifted remainder and corrupt a result/control-flow target
    # (observed as a jump to PC=0x4 whenever a divide is in flight). Vivado on
    # Gowin/Tang happens to route these paths with more margin, which is why the
    # same RTL boots there. Over-constrain hold so opt/place/route/phys_opt add
    # genuine hold margin everywhere. Setup has >1.5 ns slack at 10 MHz, so this
    # costs nothing functionally. Injected as a pre-optimize command, which the
    # LiteX Vivado toolchain emits after synth_design (so the MMCM-generated
    # clocks already exist) and before opt/place/route -- the constraint thus
    # applies to every downstream implementation step. LiteDRAM adds fixed
    # intra-site RAMD32/FDRE paths that Vivado cannot detour, so keep a smaller
    # extra hold margin for the Linux/DDR build. NOTE: no curly braces in the
    # pre-optimize command -- the toolchain str.format()s these command strings.
    hold_uncertainty = 0.050 if (args.with_litedram or args.with_mig) else 0.250
    soc.platform.toolchain.pre_optimize_commands.add(
        f"set_clock_uncertainty -hold {hold_uncertainty:.3f} [all_clocks]"
    )

    if args.with_litedram:
        # Keep the 4x DDR PHY clock and divided sys clock on matched global
        # routing. OSERDESE3/ISERDESE3 CLK-to-CLKDIV skew is otherwise tight on
        # KU15P at low DDR frequencies.
        soc.platform.add_platform_command(
            "set_property CLOCK_DELAY_GROUP raptor_ddr_phy_clkgrp "
            "[get_nets -hierarchical {{sys4x_clk sys_clk}}]"
        )

    # High-fanout net replication (mirrors the Gowin/Tang synth_maxfan=24 that
    # makes the same RTL boot there). Limiting synth fanout forces Vivado to
    # replicate high-fanout control/enable nets, cutting skew and widening
    # hold margin on short reg->reg paths.
    soc.platform.toolchain.vivado_synth_fanout_limit = 24

    # Vivado synthesis occasionally miscompiles a control-flow corner (observed
    # as a jump to PC=4 when a divide is in flight) that Verilator and Gowin
    # get correct. Disabling resource sharing and LUT combining prevents this
    # misoptimization. The root-cause RTL fix is tracked separately; until then
    # these options are required for functional correctness on KU15P Vivado.
    soc.platform.toolchain.vivado_synth_extra_options = "-resource_sharing off -no_lc"

    builder = Builder(soc, **builder_kwargs)

    if args.build:
        builder.build(build_name="mlk_cu07_ku15p", **parser.toolchain_argdict)


if __name__ == "__main__":
    main()
