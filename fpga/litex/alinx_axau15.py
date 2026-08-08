#!/usr/bin/env python3

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "cores"))

from cpu.raptor.core import Raptor

from migen import Cat, ClockDomain, If, Instance, ResetSignal, Signal
from migen.genlib.cdc import MultiReg
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen import LiteXModule
from litex.build.io import DifferentialInput
from litex.build.parser import LiteXArgumentParser
from litex.soc.cores.clock import USPMMCM
from litex.soc.cores.cpu import CPUS
from litex.soc.cores.led import LedChaser
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex.soc.interconnect import axi, stream

from litex_boards.platforms import alinx_axau15


CPUS["raptor"] = Raptor

DEFAULT_FPGA_SYS_CLK = int(25e6)
DEFAULT_FPGA_BOOT_MODE = "bios"


class Platform(alinx_axau15.Platform):
    def __init__(self, toolchain="vivado"):
        super().__init__(toolchain=toolchain)
        self.name = "alinx_axau15"


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq):
        self.rst = Signal()
        self.cd_sys = ClockDomain()
        self.cd_por = ClockDomain()

        clk200_pads = platform.request("clk200")
        clk200_raw = Signal()
        self.clk200 = Signal()
        self.specials += [
            DifferentialInput(clk200_pads.p, clk200_pads.n, clk200_raw),
            Instance("BUFG", i_I=clk200_raw, o_O=self.clk200),
        ]

        por_count = Signal(16, reset=2**16 - 1)
        por_done = Signal()
        self.comb += [
            self.cd_por.clk.eq(self.clk200),
            por_done.eq(por_count == 0),
        ]
        self.sync.por += If(~por_done, por_count.eq(por_count - 1))

        self.pll = pll = USPMMCM(speedgrade=-2)
        self.comb += pll.reset.eq(~por_done | self.rst)
        pll.register_clkin(self.clk200, 200e6)
        pll.create_clkout(self.cd_sys, sys_clk_freq, margin=0, with_reset=False)
        self.specials += AsyncResetSynchronizer(self.cd_sys, ~pll.locked)

        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)


class AXIClockDomainCrossing(LiteXModule):
    def __init__(self, master, slave, cd_from="sys", cd_to="sys", depth=16):
        if cd_from == cd_to:
            self.comb += master.connect(slave)
            return

        aw_cdc = stream.ClockDomainCrossing(
            master.aw.description, cd_from, cd_to, depth=depth, buffered=True,
            with_common_rst=True,
        )
        w_cdc = stream.ClockDomainCrossing(
            master.w.description, cd_from, cd_to, depth=depth, buffered=True,
            with_common_rst=True,
        )
        b_cdc = stream.ClockDomainCrossing(
            master.b.description, cd_to, cd_from, depth=depth, buffered=True,
            with_common_rst=True,
        )
        ar_cdc = stream.ClockDomainCrossing(
            master.ar.description, cd_from, cd_to, depth=depth, buffered=True,
            with_common_rst=True,
        )
        r_cdc = stream.ClockDomainCrossing(
            master.r.description, cd_to, cd_from, depth=depth, buffered=True,
            with_common_rst=True,
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


class AXAU15DDR4MIG(LiteXModule):
    def __init__(self, platform, sys_clk):
        self.bus = axi.AXIInterface(
            data_width=32,
            address_width=32,
            id_width=4,
            clock_domain="ddr4",
        )
        self.init_done = Signal()
        self.ui_reset = Signal()
        self.cd_ddr4 = ClockDomain()

        pads = platform.request("ddram")
        platform.add_ip(os.path.join(_here, "scripts", "axau15_ddr4_mig.tcl"))

        mig_bus = axi.AXIInterface(
            data_width=32,
            address_width=30,
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
            "raptor_axau15_ddr4_0",
            i_sys_rst=ResetSignal("sys"),
            i_c0_sys_clk_i=sys_clk,
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


class RaptorAlinxAXAU15SoC(SoCCore):
    csr_map = {
        "ctrl": 0,
        "identifier_mem": 1,
        "timer0": 2,
        "uart": 3,
        "sdcard": 4,
    }
    interrupt_map = {
        "uart": 0,
        "timer0": 1,
        "sdcard": 2,
    }

    def __init__(
        self,
        sys_clk_freq=DEFAULT_FPGA_SYS_CLK,
        with_mig=False,
        mig_size=0x40000000,
        with_sdcard=False,
        sdcard_boot=False,
        with_led_chaser=False,
        **kwargs,
    ):
        platform = Platform(toolchain="vivado")

        kwargs["cpu_type"] = "raptor"
        kwargs.setdefault("cpu_variant", "linux32")
        kwargs.setdefault("ident", "Raptor LiteX SoC on ALINX AXAU15")
        kwargs.setdefault("ident_version", True)
        kwargs.setdefault("uart_name", "serial")
        kwargs.setdefault("uart_baudrate", 115200)
        kwargs.setdefault("uart_fifo_depth", 64)
        kwargs.setdefault("integrated_rom_size", 0x8000)
        kwargs.setdefault("integrated_sram_size", 0x2000)
        kwargs.setdefault("integrated_main_ram_size", 0)
        kwargs.setdefault("bus_timeout", 4096)

        if with_mig and kwargs.get("integrated_main_ram_size", 0) != 0:
            raise ValueError("--with-mig requires --integrated-main-ram-size=0")

        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)
        self.crg = _CRG(platform, sys_clk_freq)

        if with_mig:
            self.ddr4_mig = AXAU15DDR4MIG(platform, self.crg.clk200)
            mig_ready_sys = Signal()
            self.specials += MultiReg(self.ddr4_mig.init_done, mig_ready_sys, "sys")
            self.cpu.cpu_params["i_reset"] = (
                ResetSignal("sys") | self.cpu.reset | self.cpu.dbg_reset
                | ~mig_ready_sys
            )

            mig_sys_axi = axi.AXIInterface(
                data_width=32,
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
            platform.add_false_path_constraints(
                self.crg.cd_sys.clk, self.ddr4_mig.cd_ddr4.clk
            )

        if with_sdcard:
            self.add_sdcard(name="sdcard", mode="read+write")
            if not sdcard_boot:
                self.add_constant("SDCARD_BOOT_DISABLE")

        if with_led_chaser:
            self.leds = LedChaser(
                pads=platform.request_all("user_led"),
                sys_clk_freq=sys_clk_freq,
            )


def main():
    parser = LiteXArgumentParser(
        platform=Platform,
        description="Raptor LiteX SoC on ALINX AXAU15 (Vivado).",
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
        help="Enable the two user LEDs.",
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
        "--with-sdcard",
        action="store_true",
        help="Enable the on-board 4-bit SDCard controller and DMA engine.",
    )
    parser.add_target_argument(
        "--sdcard-boot",
        action="store_true",
        help="Automatically try SDCard during BIOS boot.",
    )
    parser.add_target_argument(
        "--vivado-incremental",
        action="store_true",
        help="Reserved for compatibility with the common FPGA Makefile.",
    )
    parser.set_defaults(cpu_type="raptor", cpu_variant="linux32")

    args = parser.parse_args()
    if args.sdcard_boot and not args.with_sdcard:
        parser.error("--sdcard-boot requires --with-sdcard")

    soc_kwargs = dict(parser.soc_argdict)
    builder_kwargs = dict(parser.builder_argdict)
    has_integrated_rom_init = soc_kwargs.get("integrated_rom_init") not in (
        None,
        [],
        "",
    )

    if args.boot_mode == "custom":
        if not has_integrated_rom_init:
            parser.error("--boot-mode=custom requires --integrated-rom-init=<path>")
        builder_kwargs["compile_software"] = False
    else:
        if has_integrated_rom_init:
            parser.error(
                "--boot-mode=bios cannot be combined with --integrated-rom-init"
            )
        if not builder_kwargs.get("compile_software", True):
            parser.error("--boot-mode=bios requires software compilation")

    soc = RaptorAlinxAXAU15SoC(
        sys_clk_freq=int(args.sys_clk_freq),
        with_mig=args.with_mig,
        mig_size=args.mig_size,
        with_sdcard=args.with_sdcard,
        sdcard_boot=args.sdcard_boot,
        with_led_chaser=args.with_led_chaser,
        **soc_kwargs,
    )

    toolchain_argdict = dict(parser.toolchain_argdict)
    toolchain_argdict["vivado_synth_directive"] = (
        str(toolchain_argdict.get("vivado_synth_directive") or "default")
        + " -resource_sharing off -no_lc -fanout_limit 24"
    )

    hold_uncertainty = 0.050 if args.with_mig else 0.250
    soc.platform.toolchain.pre_optimize_commands.add(
        f"set_clock_uncertainty -hold {hold_uncertainty:.3f} [all_clocks]"
    )

    builder = Builder(soc, **builder_kwargs)
    if args.build:
        builder.build(build_name="alinx_axau15", **toolchain_argdict)


if __name__ == "__main__":
    main()