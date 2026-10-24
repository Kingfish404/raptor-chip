#!/usr/bin/env python3
"""Shared Raptor LiteX SoC implementation for MLK KU15P boards.

Board entry points supply immutable platform and timing policy explicitly.
Pin assignments remain in each board platform; generated outputs stay separate.
"""

from dataclasses import dataclass

import os
import sys
import math

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "cores"))

from cpu.raptor.core import Raptor

from migen import *
from migen.genlib.cdc import MultiReg
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen import *
from litex.build.io import DifferentialInput
from litex.build.parser import LiteXArgumentParser

from litex.soc.cores.clock import USPMMCM
from usp_clock import USPIDELAYCTRL
from litex.soc.cores.cpu import CPUS
from litex.soc.cores.led import LedChaser
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex.soc.interconnect import axi, stream


from litedram.modules import MT40A512M16
from litedram.phy import usddrphy


CPUS["raptor"] = Raptor

DEFAULT_FPGA_SYS_CLK = int(75e6)
DEFAULT_FPGA_BOOT_MODE = "bios"
KU15P_SYNTH_OPTIONS = " -resource_sharing off -no_lc -fanout_limit 24"


@dataclass(frozen=True)
class KU15PBoard:
    name: str
    ident: str
    platform: type
    cm005_rx_tuned: bool = False
    bare_hold_uncertainty: float = 0.250
    default_fmc_slot: str = "a"
    mig_tcl: str = "ku15p_ddr4_mig.tcl"


def ku15p_final_setup_command(sys_setup_margin_ns, sys_final_wns_ns=None):
    """Keep implementation tightening separate from the final setup gate."""
    if not math.isfinite(sys_setup_margin_ns) or sys_setup_margin_ns < 0:
        raise ValueError("System setup margin must be finite and nonnegative")
    if sys_final_wns_ns is not None and (
            not math.isfinite(sys_final_wns_ns) or sys_final_wns_ns < 0):
        raise ValueError("Final system WNS must be finite and nonnegative")
    if sys_setup_margin_ns:
        suffix = "" if sys_final_wns_ns is None else f" {sys_final_wns_ns:.6f}"
        return "raptor_restore_sys_setup_margin {build_name}" + suffix
    if sys_final_wns_ns is not None:
        return f"raptor_check_sys_setup_wns {sys_final_wns_ns:.6f}"
    return None


def configure_ku15p_timing(platform, board, with_litedram=False, with_mig=False,
                          sys_setup_margin_ns=0.0, sys_final_wns_ns=None):
    """Shared implementation policy for CLI builds and peripheral STA."""
    final_command = ku15p_final_setup_command(sys_setup_margin_ns, sys_final_wns_ns)
    # A scalar implicit net on a cache lookup port can silently discard the
    # address. Reject that mismatch without changing unrelated width warnings.
    platform.toolchain.pre_synthesis_commands.add(
        "set_msg_config -id \"Synth 8-689\" -string \"port connection 'lookup_addr'\" "
        "-new_severity ERROR")
    hold = 0.050 if with_litedram or with_mig else board.bare_hold_uncertainty
    platform.toolchain.pre_optimize_commands.add(
        f"set_clock_uncertainty -hold {hold:.3f} [all_clocks]")
    if final_command is not None:
        margin_tcl = os.path.join(_here, "scripts", "vivado_setup_margin.tcl")
        platform.toolchain.pre_optimize_commands.add(
            f'source "{margin_tcl}"')
    if sys_setup_margin_ns:
        platform.toolchain.pre_optimize_commands.add(
            f"raptor_apply_sys_setup_margin {sys_setup_margin_ns:.6f}")
    # LiteX MultiReg CDC synchronizers are emitted as plain
    # xilinxmultiregimpl* flop pairs and carry no ASYNC_REG attribute. Mark
    # them so the placer keeps each synchronizer stage together; each domain
    # pair also has an explicit asynchronous clock group.
    platform.add_platform_command(
        "set raptor_cdc_cells [get_cells -hier -quiet -filter "
        "{{NAME =~ *xilinxmultiregimpl*}}]; "
        "if {{[llength $raptor_cdc_cells] > 0}} "
        "{{set_property ASYNC_REG TRUE $raptor_cdc_cells}}")
    if with_litedram:
        platform.add_platform_command(
            "set_property CLOCK_DELAY_GROUP raptor_ddr_phy_clkgrp "
            "[get_nets -hierarchical {{sys4x_clk sys_clk}}]")


# CRG --------------------------------------------------------------------------


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq, with_litedram=False, with_ethernet=False,
                 eth_speed=1000, cm005_oversample=False, cm005_tx_split=False,
                 cm005_tx_dual=False, external_sys=None):
        if cm005_tx_dual and not cm005_tx_split:
            raise ValueError("Dual-port TX clocks require split PHY clocks")
        if cm005_tx_split and not (with_ethernet and cm005_oversample and eth_speed == 1000):
            raise ValueError("Split TX clocks require oversampled gigabit Ethernet")
        self.rst = Signal()
        self.cd_sys = ClockDomain()
        self.cd_por = ClockDomain()
        if with_ethernet:
            self.cd_cm005_tx = ClockDomain(reset_less=True)
            if cm005_oversample and eth_speed == 1000:
                self.cd_cm005_tx_raw = ClockDomain(reset_less=True)
                self.cd_cm005_tx_serial = ClockDomain(reset_less=True)
                if cm005_tx_split:
                    self.cd_cm005_tx_phy = ClockDomain(reset_less=True)
                if cm005_tx_dual:
                    self.cd_cm005_b_tx_raw = ClockDomain(reset_less=True)
                    self.cd_cm005_b_tx = ClockDomain(reset_less=True)
                    self.cd_cm005_b_tx_serial = ClockDomain(reset_less=True)
                    self.cd_cm005_b_tx_phy = ClockDomain(reset_less=True)
            else:
                self.cd_cm005_tx_shifted = ClockDomain(reset_less=True)
            if cm005_oversample:
                self.cd_cm005_sample_raw = ClockDomain(reset_less=True)
                self.cd_cm005_sample = ClockDomain(reset_less=True)
                self.cd_cm005_sample_div = ClockDomain(reset_less=True)
            if not with_litedram:
                self.cd_idelay = ClockDomain()
                self.cd_cm005_ready = ClockDomain()
        if with_litedram:
            self.cd_sys4x = ClockDomain()
            self.cd_pll4x = ClockDomain()
            self.cd_idelay = ClockDomain()

        clk100 = platform.request("clk100")
        # The J23 reset button (cpu_resetn) is intentionally left unused for
        # bring-up. Gating any reset on it is risky: if the board does not pull
        # the pin up it can idle low and hold the SoC (or the MMCM) in reset
        # forever, preventing the BIOS from ever running.
        # A free-running power-on reset (POR) clocked by the raw 100 MHz input
        # brings the design up reliably regardless of the button. Request it so
        # the pin stays constrained; it does not gate the CPU reset.
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

        if external_sys is not None and with_litedram:
            raise ValueError("External system clock cannot drive the LiteDRAM CRG")
        if external_sys is None:
            self.pll = pll = USPMMCM(speedgrade=-2)
            self.comb += pll.reset.eq(~por_done | self.rst)
        if external_sys is not None:
            self.comb += [self.cd_sys.clk.eq(external_sys[0]),
                          self.cd_sys.rst.eq(external_sys[1])]
        elif with_litedram:
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

        if with_ethernet:
            # Separate MMCM: 125 MHz Ethernet and 400 MHz DDR IDELAY
            # cannot share integer output dividers at a legal common VCO.
            self.ethpll = ethpll = USPMMCM(speedgrade=-2,
                name="cm005_sample_pll" if cm005_oversample else None)
            self.comb += ethpll.reset.eq(~por_done | self.rst)
            ethpll.register_clkin(clk100, 100e6)
            eth_clk_freq = 25e6 if eth_speed == 100 else 125e6
            if cm005_oversample and eth_speed == 1000:
                # Both TX buffers take the SAME 250 MHz MMCM output. Derive
                # the 125 MHz byte clock with a matched dedicated divider.
                ethpll.create_clkout(self.cd_cm005_tx_raw, 250e6, buf=None,
                                     margin=0, with_reset=False)
                if cm005_tx_split:
                    # The PHY I/O clock has only the DDR launch loads. Keep
                    # the MAC on its own, phase-aligned divide-by-two buffer.
                    self.specials += [
                        Instance("BUFGCE", name="cm005_tx_serial_buf", attr={"keep"}, p_CE_TYPE="SYNC",
                            i_I=self.cd_cm005_tx_raw.clk, i_CE=ethpll.locked,
                            o_O=self.cd_cm005_tx_serial.clk),
                        Instance("BUFGCE_DIV", name="cm005_tx_phy_buf", attr={"keep"},
                            p_BUFGCE_DIVIDE=2, i_I=self.cd_cm005_tx_raw.clk,
                            i_CE=1, i_CLR=~ethpll.locked, o_O=self.cd_cm005_tx_phy.clk),
                    ]
                    if cm005_tx_dual:
                        self.eth_b_pll = bpll = USPMMCM(speedgrade=-2, name="cm005_b_tx_pll")
                        self.comb += bpll.reset.eq(~por_done | self.rst)
                        bpll.register_clkin(clk100, 100e6)
                        bpll.create_clkout(self.cd_cm005_b_tx_raw, 250e6, buf=None,
                                          margin=0, with_reset=False)
                        self.specials += [
                            Instance("BUFGCE_DIV", name="cm005_b_tx_serial_buf", attr={"keep"},
                                p_BUFGCE_DIVIDE=1, i_I=self.cd_cm005_b_tx_raw.clk,
                                i_CE=1, i_CLR=~bpll.locked,
                                o_O=self.cd_cm005_b_tx_serial.clk),
                            Instance("BUFGCE_DIV", name="cm005_b_tx_phy_buf", attr={"keep"},
                                p_BUFGCE_DIVIDE=2, i_I=self.cd_cm005_b_tx_raw.clk,
                                i_CE=1, i_CLR=~bpll.locked, o_O=self.cd_cm005_b_tx_phy.clk),
                            Instance("BUFGCE_DIV", name="cm005_b_tx_word_buf", attr={"keep"},
                                p_BUFGCE_DIVIDE=2, i_I=self.cd_cm005_b_tx_raw.clk,
                                i_CE=1, i_CLR=~bpll.locked, o_O=self.cd_cm005_b_tx.clk),
                        ]
                else:
                    self.specials += Instance("BUFGCE_DIV", name="cm005_tx_serial_buf",
                        p_BUFGCE_DIVIDE=1, i_I=self.cd_cm005_tx_raw.clk,
                        i_CE=1, i_CLR=~ethpll.locked, o_O=self.cd_cm005_tx_serial.clk)
                self.specials += Instance("BUFGCE_DIV", name="cm005_tx_word_buf",
                        attr={"keep"} if cm005_tx_split else set(),
                        p_BUFGCE_DIVIDE=2, i_I=self.cd_cm005_tx_raw.clk,
                        i_CE=1, i_CLR=~ethpll.locked, o_O=self.cd_cm005_tx.clk)
            else:
                ethpll.create_clkout(self.cd_cm005_tx, eth_clk_freq, with_reset=False)
                ethpll.create_clkout(self.cd_cm005_tx_shifted, eth_clk_freq, phase=90, with_reset=False)
            if cm005_oversample:
                from cm005_oversample import CM005SampleClocks, SAMPLE_CLK_FREQ
                ethpll.create_clkout(self.cd_cm005_sample_raw, SAMPLE_CLK_FREQ,
                                     buf=None, margin=0, with_reset=False)
                # ISERDES CLK and CLKDIV share a source and divider reset.
                self.cm005_sample_clocks = CM005SampleClocks(
                    self.cd_cm005_sample_raw.clk, ~ethpll.locked,
                    self.cd_cm005_sample.clk, self.cd_cm005_sample_div.clk)
            if not with_litedram:
                from cm005_oversample import SAMPLE_IDELAY_FREQ
                ethpll.create_clkout(self.cd_idelay,
                    SAMPLE_IDELAY_FREQ if cm005_oversample else 300e6)
                # USPIDELAYCTRL drives cd_sys.rst itself. Keep its readiness
                # output separate from the main MMCM's system-reset driver.
                self.comb += self.cd_cm005_ready.clk.eq(self.cd_sys.clk)
                self.idelayctrl = USPIDELAYCTRL(cd_ref=self.cd_idelay, cd_sys=self.cd_cm005_ready)

        # Ignore the sys_clk -> pll.clkin path created by the SoC reset.
        if external_sys is None:
            # LiteX preserves signals used as timing endpoints. Preserving
            # the MMCM input alias separately from the shared input clock
            # inserts an identity LUT on the CU08 clock tree. Reference the
            # actual input clock for the dual-port design instead.
            clock_input = clk100 if cm005_tx_dual else pll.clkin
            platform.add_false_path_constraints(self.cd_sys.clk, clock_input)


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
    def __init__(self, platform, mig_tcl):
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
        # LiteX inlines add_ip() Tcl into the generated project script, so a
        # board override must be inserted before the shared MIG script.
        if mig_tcl != "ku15p_ddr4_mig.tcl":
            platform.add_ip(os.path.join(_here, "scripts", mig_tcl))
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


class RaptorKU15PSoC(SoCCore):
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
        board,
        sys_clk_freq=DEFAULT_FPGA_SYS_CLK,
        with_litedram=False,
        litedram_size=0x40000000,
        with_mig=False,
        mig_size=0x80000000,
        with_sdcard=False,
        sdcard_autoboot=False,
        with_ethernet=False,
        with_cm005_bridge=None,
        eth_speed=1000,
        fmc_slot=None,
        eth_port="a",
        with_led_chaser=False,
        **kwargs,
    ):
        if sdcard_autoboot:
            raise ValueError("Automatic boot is disabled; enter sdcardboot or netboot manually at litex>")
        fmc_slot = (fmc_slot or board.default_fmc_slot).lower()
        eth_port = eth_port.lower()
        oversampled_rx = (board.name, fmc_slot, eth_port) == ("mlk_cu08_ku15p", "c", "a")
        if with_cm005_bridge is None:
            with_cm005_bridge = board.name == "mlk_cu08_ku15p"
        if with_cm005_bridge and (not oversampled_rx or eth_speed != 1000 or with_litedram):
            raise ValueError("CM005 forwarding requires CU08 FMC_C port A, 1000 Mb/s and MIG or SRAM; "
                             "use --without-cm005-bridge for other wiring or LiteDRAM")
        self.cm005_oversampled_rx = (with_ethernet or with_cm005_bridge) and oversampled_rx
        self.with_cm005_bridge = with_cm005_bridge
        platform = board.platform(toolchain="vivado")

        kwargs["cpu_type"] = "raptor"
        kwargs.setdefault("cpu_variant", "linux32")
        kwargs.setdefault("ident", board.ident)
        kwargs.setdefault("ident_version", True)
        kwargs.setdefault("uart_name", "serial")
        kwargs.setdefault("uart_baudrate", 115200)
        kwargs.setdefault("integrated_rom_size", 0x8000)
        kwargs.setdefault("integrated_sram_size", 0x2000)
        kwargs.setdefault("integrated_main_ram_size", 0)
        kwargs["bus_data_width"] = 64
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

        if with_mig or with_litedram:
            self.cpu.pmem_size = mig_size if with_mig else litedram_size
            if not 0 < self.cpu.pmem_size <= 0x80000000 or self.cpu.pmem_size & (self.cpu.pmem_size - 1):
                raise ValueError("KU15P DDR window must be a power of two up to 2 GiB")
        elif kwargs["integrated_main_ram_size"]:
            self.cpu.pmem_size = kwargs["integrated_main_ram_size"]

        if eth_speed not in (100, 1000):
            raise ValueError("CM005 speed must be 100 or 1000 Mb/s")
        self.crg = _CRG(platform, sys_clk_freq, with_litedram=with_litedram,
                        with_ethernet=with_ethernet or with_cm005_bridge, eth_speed=eth_speed,
                        cm005_oversample=oversampled_rx,
                        cm005_tx_split=with_cm005_bridge, cm005_tx_dual=with_cm005_bridge)

        if with_cm005_bridge:
            from cm005_bridge import add_cm005_forwarder
            from cm005_switch import add_cpu_frame_mac
            cpu_mac = add_cpu_frame_mac(self) if with_ethernet else None
            add_cm005_forwarder(self, platform, sys_clk_freq, cpu_mac=cpu_mac)
            self.add_constant("CM005_BRIDGE", 1)
            self.add_constant("CM005_ETH_SPEED", 1000)
            self.add_constant("CM005_RX_OVERSAMPLE", 1)
        elif with_ethernet:
            from cm005 import CM005PHY, add_pads
            from cm005_oversample import SAMPLE_IDELAY_FREQ
            clocks, pads = add_pads(platform, board.name, fmc_slot, eth_port)
            tuned_ethernet = (board.cm005_rx_tuned and not with_litedram
                              and (fmc_slot, eth_port) == ("a", "a"))
            self.ethphy = CM005PHY(clocks, pads, sys_clk_freq,
                                  speed=eth_speed,
                                  rx_oversample=oversampled_rx,
                                  # CU08/FMC_C/port A raw captures require two
                                  # later samples on RXD1/3. Do not propagate
                                  # this lane calibration to other pin maps.
                                  rx_data_sample_advance=(0, 2, 0, 2)
                                      if oversampled_rx and eth_speed == 1000 else (0, 0, 0, 0),
                                  # Keep DV/RX_ER away from the captured
                                  # transition boundary as well. This uses
                                  # the same full-cycle (1.6ns) deskew as
                                  # the odd lanes, not a half-cycle shift.
                                  rx_control_sample_advance=2
                                      if oversampled_rx and eth_speed == 1000 else 0,
                                  iodelay_clk_freq=400e6 if with_litedram else
                                      (SAMPLE_IDELAY_FREQ if oversampled_rx else 300e6),
                                  rx_delay=950e-12 if tuned_ethernet else 1e-9,
                                  rx_ctl_delay=900e-12 if tuned_ethernet else None)
            self.comb += self.ethphy.crg.clock_unlocked.eq(
                ~self.crg.ethpll.locked |
                (0 if with_litedram else self.crg.cd_cm005_ready.rst))
            # Keep packet SRAM in Raptor's noncached external I/O aperture.
            self.mem_map["ethmac"] = 0x18000000
            # Detect SFD before byte-to-word conversion: the physical PHY
            # can present a shortened preamble. A 32-bit preamble checker
            # only finds SFD at word boundaries and discards such frames.
            # LiteX data_width=8 selects byte-clocked formatting/checking,
            # while retaining its 32-bit Wishbone packet SRAM interface.
            self.add_ethernet(phy=self.ethphy,
                              data_width=8 if oversampled_rx and eth_speed == 1000 else 32,
                              nrxslots=8,
                              with_timing_constraints=False)
            self.add_constant("CM005_ETH_SPEED", eth_speed)
            self.add_constant("CM005_RX_OVERSAMPLE", int(oversampled_rx))
            from cm005_timing import constrain_cm005
            constrain_cm005(platform, self.crg, self.ethphy, clocks, pads,
                            eth_speed=eth_speed, oversampled_rx=oversampled_rx,
                            tuned_ethernet=tuned_ethernet)

        if with_mig:
            self.ddr4_mig = KU15PDDR4MIG(platform, board.mig_tcl)
            mig_ready_sys = Signal()
            self.specials += MultiReg(self.ddr4_mig.init_done, mig_ready_sys, "sys")
            self.cpu.cpu_params["i_reset"] = (ResetSignal("sys") | self.cpu.reset
                                              | ~mig_ready_sys)

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

        # BOOT_MODE=bios selects the firmware, not its startup policy. Stop at
        # litex> unconditionally; CONFIG_BIOS_NO_BOOT skips only main.c's automatic
        # sequence and leaves the interactive boot commands available.
        self.add_config("BIOS_NO_BOOT")

        if with_sdcard:
            self.add_sdcard(name="sdcard", mode="read+write")
            self.add_constant("SDCARD_BOOT_DISABLE")

        if with_led_chaser:
            try:
                self.leds = LedChaser(
                    pads=platform.request_all("user_led"),
                    sys_clk_freq=sys_clk_freq,
                )
            except Exception:
                pass


def main(board, soc_class=RaptorKU15PSoC):
    parser = LiteXArgumentParser(
        platform=board.platform,
        description=f"{board.ident} (Vivado).",
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
        default=0x80000000,
        type=lambda value: int(value, 0),
        help="Mapped DDR4 MIG main_ram size in bytes.",
    )
    parser.add_target_argument(
        "--with-sdcard",
        action="store_true",
        help="Enable the on-board 4-bit SDCard controller and DMA engine.",
    )
    parser.add_target_argument("--with-ethernet", action="store_true",
                               help="Enable the CM005 YT8531 Ethernet MAC.")
    parser.add_target_argument("--without-cm005-bridge", action="store_true",
                               help="Disable default CU08 FMC_C A/B forwarding (disconnects KU5P transit).")
    parser.add_target_argument("--sdcard-autoboot", action="store_true",
                               help="Unsupported legacy option; automatic boot is rejected.")
    parser.add_target_argument("--eth-speed", type=int, choices=[100, 1000], default=1000,
                               help="Fixed CM005 link speed in Mb/s (default: 1000).")
    parser.add_target_argument("--export-ethernet-csr", metavar="PATH",
                               help="Finalize SoC and export CSR JSON only, without building firmware or gateware.")
    parser.add_target_argument("--fmc-slot", default=board.default_fmc_slot, choices=["a", "b", "c"],
                               help="Physical FMC connector (mapping must be verified).")
    parser.add_target_argument("--eth-port", default="a", choices=["a", "b", "c", "d"],
                               help="CM005 RJ45 port (mapping must be verified).")
    parser.add_target_argument(
        "--uart-polling",
        action="store_true",
        help="Build BIOS with UART_POLLING (no IRQ-driven UART ring buffer).",
    )
    parser.add_target_argument(
        "--vivado-incremental",
        action="store_true",
        help="Reuse the previous routed checkpoint for incremental implementation.",
    )
    parser.add_target_argument(
        "--vivado-no-timing-driven",
        action="store_true",
        help="Disable synthesis timing optimization; retain implementation and STA constraints.",
    )
    parser.add_target_argument(
        "--vivado-sys-setup-margin-ns", type=float, default=0.0,
        help="Extra system setup margin during implementation; restore original constraints for final reports.",
    )
    parser.add_target_argument(
        "--vivado-sys-final-wns-ns", type=float, default=None,
        help="Minimum final system WNS under original constraints; defaults to the implementation margin.",
    )
    parser.set_defaults(cpu_type="raptor", cpu_variant="linux32")

    args = parser.parse_args()

    soc_kwargs = dict(parser.soc_argdict)
    soc_kwargs["uart_fifo_depth"] = max(int(soc_kwargs.get("uart_fifo_depth", 16)), 1024)
    builder_kwargs = dict(parser.builder_argdict)
    has_integrated_rom_init = soc_kwargs.get("integrated_rom_init") not in (
        None,
        [],
        "",
    )

    if args.export_ethernet_csr:
        if not args.with_ethernet:
            parser.error("--export-ethernet-csr requires --with-ethernet")
    elif args.boot_mode == "custom":
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

    if board.name in ("mlk_cu08_ku15p", "mlk_cu07_ku15p"):
        soc_kwargs["with_cm005_bridge"] = False if args.without_cm005_bridge else None

    soc = soc_class(
        board=board,
        sys_clk_freq=int(args.sys_clk_freq),
        with_litedram=args.with_litedram,
        litedram_size=args.litedram_size,
        with_mig=args.with_mig,
        mig_size=args.mig_size,
        with_sdcard=args.with_sdcard,
        sdcard_autoboot=args.sdcard_autoboot,
        with_ethernet=args.with_ethernet,
        eth_speed=args.eth_speed,
        fmc_slot=args.fmc_slot,
        eth_port=args.eth_port,
        with_led_chaser=args.with_led_chaser,
        **soc_kwargs,
    )

    if args.uart_polling:
        soc.add_constant("UART_POLLING")

    if args.export_ethernet_csr:
        from pathlib import Path
        from litex.soc.integration.export import get_csr_json
        soc.finalize()
        destination = Path(args.export_ethernet_csr)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(get_csr_json(soc=soc, csr_regions=soc.csr_regions,
            constants=soc.constants, mem_regions=soc.mem_regions))
        return

    # Preserve the existing board-specific hold uncertainty; DDR builds use
    # 0.050 ns. Emit after synthesis and before implementation, when generated
    # clocks exist. Actual timing margins must be checked per build.
    # No curly braces: the toolchain str.format()s these command strings.
    configure_ku15p_timing(soc.platform, board, args.with_litedram, args.with_mig,
                          args.vivado_sys_setup_margin_ns, args.vivado_sys_final_wns_ns)

    # High-fanout net replication (mirrors the Gowin/Tang synth_maxfan=24 that
    # makes the same RTL boot there). Limiting synth fanout forces Vivado to
    # replicate high-fanout control/enable nets, cutting skew and widening
    # hold margin on short reg->reg paths.
    #
    # Vivado synthesis occasionally miscompiles a control-flow corner (observed
    # as a jump to PC=4 when a divide is in flight) that Verilator and Gowin
    # get correct. Disabling resource sharing and LUT combining prevents this
    # misoptimization. The root-cause RTL fix is tracked separately; until then
    # these options are required for functional correctness on KU15P Vivado.
    #
    # NOTE: the LiteX Vivado toolchain has no `vivado_synth_extra_options` /
    # `vivado_synth_fanout_limit` attributes -- setting them is silently
    # ignored. The only string that reaches the generated `synth_design`
    # command is `vivado_synth_directive` (spliced verbatim right after
    # `-directive`), so smuggle the extra options through it. It must be set
    # via the toolchain argdict: toolchain.build() re-assigns the attribute
    # from its kwargs (CLI default "default") and would overwrite a value set
    # directly on the toolchain object before builder.build().
    toolchain_argdict = dict(parser.toolchain_argdict)
    # Optimize placement before routing the CPU and the board-specific MIG UI.
    # LiteX otherwise only runs phys_opt after routing, when replication and
    # movement have fewer opportunities. Explicit CLI directives still win.
    if args.with_mig and toolchain_argdict.get("vivado_post_place_phys_opt_directive") is None:
        toolchain_argdict["vivado_post_place_phys_opt_directive"] = "AggressiveExplore"
    if args.with_mig:
        # A second route can exploit the netlist changes made by post-route
        # phys_opt. Run it only when setup still fails, before write_bitstream,
        # and regenerate timing/DRC reports for the resulting implementation.
        retry_tcl = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "scripts", "vivado_retry_timing.tcl")
        soc.platform.toolchain.bitstream_commands.extend([
            f'source "{retry_tcl}"',
            "raptor_retry_timing {build_name}",
        ])
    toolchain_argdict["vivado_synth_directive"] = (
        str(toolchain_argdict.get("vivado_synth_directive") or "default")
        + KU15P_SYNTH_OPTIONS
        + (" -no_timing_driven" if args.vivado_no_timing_driven else "")
    )
    final_setup_command = ku15p_final_setup_command(
        args.vivado_sys_setup_margin_ns, args.vivado_sys_final_wns_ns)
    if final_setup_command is not None:
        # Retry routing under the extra setup margin first. The final checkpoint
        # and reports then return to the original clock/hold/jitter constraints.
        soc.platform.toolchain.bitstream_commands.append(final_setup_command)
    if getattr(soc, "with_cm005_bridge", False):
        commands = soc.platform.toolchain.bitstream_commands
        first = commands.index("set bridge_methodology [report_methodology -return_string]")
        checks = commands[first:first + 5]
        del commands[first:first + 5]
        commands.extend(checks)
    if soc.cm005_oversampled_rx:
        # A MIG timing retry can change routing. Check the final layout, not
        # merely the initial routed candidate before that retry.
        aperture_check = "cm005_check_sampling_aperture cm005_aperture.rpt"
        soc.platform.toolchain.bitstream_commands.remove(aperture_check)
        soc.platform.toolchain.bitstream_commands.append(aperture_check)

    route_checkpoint = os.path.join(
        builder_kwargs["output_dir"],
        "gateware",
        f"{board.name}_route.dcp",
    )
    if args.vivado_incremental and os.path.isfile(route_checkpoint):
        soc.platform.toolchain.incremental_implementation = True
        print(f"[litex] Vivado incremental reference: {route_checkpoint}")
    elif args.vivado_incremental:
        print("[litex] No routed checkpoint found; using full implementation")

    builder = Builder(soc, **builder_kwargs)
    if getattr(soc, "with_cm005_bridge", False):
        from cm005_switch import check_dependency_origins
        check_dependency_origins()

    if args.build:
        builder.build(build_name=board.name, **toolchain_argdict)
