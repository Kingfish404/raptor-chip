#!/usr/bin/env python3
"""Raptor LiteX SoC for RK-XCKU5P-F V1.2 with DDR4 and onboard RGMII."""

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "cores"))

from cpu.raptor.core import Raptor
from ku15p_soc import AXIClockDomainCrossing, AXIInitGate, KU15PBoard, main as run_target
import rk_xcku5p_f_platform as rk_platform

from migen import ClockDomain, ClockDomainsRenamer, ClockSignal, If, Instance, ResetSignal, Signal
from migen.genlib.cdc import MultiReg
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.build.io import DifferentialInput
from litex.gen import LiteXModule
from litex.soc.cores.clock import USPMMCM, USPIDELAYCTRL
from litex.soc.cores.cpu import CPUS
from litex.soc.cores.led import LedChaser
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex.soc.interconnect import axi, stream
from litex.soc.interconnect.csr import CSRStorage
from liteeth.common import eth_phy_description
from liteeth.phy.common import LiteEthPHYHWReset, LiteEthPHYMDIO
from liteeth.phy.usrgmii import LiteEthPHYRGMIITX


CPUS["raptor"] = Raptor

BOARD = KU15PBoard(
    name="rk_xcku5p_f",
    ident="Raptor LiteX SoC on RK-XCKU5P-F V1.2",
    platform=rk_platform.Platform,
    bare_hold_uncertainty=0.050,
)


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq, with_ethernet):
        self.rst = Signal()
        self.cd_sys = ClockDomain()
        self.cd_por = ClockDomain()
        pads = platform.request("clk200")
        self.clk200_raw = Signal()
        clk200 = Signal()
        self.specials += [
            DifferentialInput(pads.p, pads.n, self.clk200_raw),
            Instance("BUFG", i_I=self.clk200_raw, o_O=clk200),
        ]
        platform.request("cpu_resetn")  # Constrain the pin; power-on reset is independent.
        count = Signal(16, reset=2**16 - 1)
        done = Signal()
        self.comb += [self.cd_por.clk.eq(clk200), done.eq(count == 0)]
        self.sync.por += If(~done, count.eq(count - 1))

        self.pll = pll = USPMMCM(speedgrade=-2)
        self.comb += pll.reset.eq(~done | self.rst)
        pll.register_clkin(clk200, 200e6)
        pll.create_clkout(self.cd_sys, sys_clk_freq, margin=0, with_reset=False)
        self.specials += AsyncResetSynchronizer(self.cd_sys, ~pll.locked)
        if with_ethernet:
            self.cd_idelay = ClockDomain()
            self.cd_idelay_ready = ClockDomain()
            pll.create_clkout(self.cd_idelay, 300e6)
            self.comb += self.cd_idelay_ready.clk.eq(self.cd_sys.clk)
            self.idelayctrl = USPIDELAYCTRL(cd_ref=self.cd_idelay, cd_sys=self.cd_idelay_ready)
        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)


class RKRGMIIClocking(LiteXModule):
    """Use the RX input MMCM to align the undelayed RGMII receive lanes."""

    def __init__(self, clocks, pads):
        self._reset = CSRStorage(description="Ethernet PHY clock-domain reset.")
        self.cd_eth_rx = ClockDomain()
        self.cd_eth_tx = ClockDomain()
        self.cd_eth_tx_delayed = ClockDomain(reset_less=True)
        rxclk = Signal()
        self.specials += Instance("IBUF", i_I=clocks.rx, o_O=rxclk)
        self.pll = pll = USPMMCM(speedgrade=-2)
        pll.register_clkin(rxclk, 125e6)
        # The MMCM/BUFG receive path adds about 2.6 ns at the IDDR. A
        # negative half-cycle shift puts both DDR sample edges in the data
        # eyes and requires swapping the IDDR's Q1/Q2 lane assignments.
        pll.create_clkout(self.cd_eth_rx, 125e6, phase=-180, with_reset=False)
        pll.create_clkout(self.cd_eth_tx, 125e6, with_reset=False)
        self.comb += self.cd_eth_tx_delayed.clk.eq(self.cd_eth_tx.clk)

        forwarded = Signal()
        self.specials += [
            Instance("ODDRE1", name="rk_eth_txc_ddr",
                     i_C=self.cd_eth_tx_delayed.clk, i_SR=0,
                     i_D1=1, i_D2=0, o_Q=forwarded),
            Instance("OBUF", i_I=forwarded, o_O=clocks.tx),
        ]
        self.hw_reset = LiteEthPHYHWReset()
        self.reset = reset = Signal()
        self.comb += reset.eq(self._reset.storage | self.hw_reset.reset | ~pll.locked)
        if hasattr(pads, "rst_n"):
            self.comb += pads.rst_n.eq(~reset)
        self.specials += [
            AsyncResetSynchronizer(self.cd_eth_rx, reset),
            AsyncResetSynchronizer(self.cd_eth_tx, reset),
        ]


class RKRGMIIReceive(LiteXModule):
    """Capture the PHY's edge-aligned lanes with the inverted receive clock."""

    def __init__(self, pads):
        self.source = source = stream.Endpoint(eth_phy_description(8))
        rx_ctl_ibuf, rx_ctl_idelay, rx_ctl = Signal(), Signal(), Signal()
        rx_data_ibuf, rx_data_idelay, rx_data = Signal(4), Signal(4), Signal(8)

        def input_lane(pad, buffered, delayed, low, high=None):
            self.specials += [
                Instance("IBUF", i_I=pad, o_O=buffered),
                Instance("IDELAYE3", p_DELAY_SRC="IDATAIN", p_CASCADE="NONE",
                         p_DELAY_TYPE="FIXED", p_DELAY_VALUE=0,
                         p_REFCLK_FREQUENCY=300.0, p_DELAY_FORMAT="TIME",
                         p_UPDATE_MODE="ASYNC", p_SIM_DEVICE="ULTRASCALE_PLUS",
                         i_CASC_IN=0, i_CASC_RETURN=0, i_CE=0, i_CLK=0,
                         i_INC=0, i_LOAD=0, i_CNTVALUEIN=0, i_IDATAIN=buffered,
                         i_RST=0, i_EN_VTC=1, o_DATAOUT=delayed),
                Instance("IDDRE1", p_DDR_CLK_EDGE="SAME_EDGE_PIPELINED",
                         p_IS_C_INVERTED=0, p_IS_CB_INVERTED=1,
                         i_C=ClockSignal("eth_rx"), i_CB=ClockSignal("eth_rx"),
                         i_R=0, i_D=delayed,
                         o_Q1=high if high is not None else Signal(), o_Q2=low),
            ]

        input_lane(pads.rx_ctl, rx_ctl_ibuf, rx_ctl_idelay, rx_ctl)
        for bit in range(4):
            input_lane(pads.rx_data[bit], rx_data_ibuf[bit], rx_data_idelay[bit],
                       rx_data[bit], rx_data[bit + 4])

        rx_ctl_d = Signal()
        self.sync += [
            rx_ctl_d.eq(rx_ctl),
            source.valid.eq(rx_ctl),
            source.data.eq(rx_data),
        ]
        self.comb += source.last.eq(~rx_ctl & rx_ctl_d)


class RKRGMII(LiteXModule):
    dw = 8
    tx_clk_freq = 125e6
    rx_clk_freq = 125e6

    def __init__(self, clocks, pads):
        self.crg = RKRGMIIClocking(clocks, pads)
        self.tx = ClockDomainsRenamer("eth_tx")(LiteEthPHYRGMIITX(pads))
        self.rx = ClockDomainsRenamer("eth_rx")(RKRGMIIReceive(pads))
        self.sink, self.source = self.tx.sink, self.rx.source
        self.mdio = LiteEthPHYMDIO(pads)


class RKDDR4MIG(LiteXModule):
    def __init__(self, platform, clk200_raw):
        self.bus = axi.AXIInterface(data_width=256, address_width=32, id_width=4,
                                    clock_domain="ddr4")
        self.init_done = Signal()
        self.cd_ddr4 = ClockDomain()
        pads = platform.request("ddram")
        platform.add_ip(os.path.join(_here, "scripts/rk_xcku5p_f_ddr4_mig.tcl"))

        mig_bus = axi.AXIInterface(data_width=256, address_width=31, id_width=4,
                                   clock_domain="ddr4")
        self.submodules.init_gate = AXIInitGate(self.bus, mig_bus, self.init_done)
        ui_clk, ui_rst = Signal(), Signal()
        dbg_clk, dbg_bus = Signal(), Signal(512)
        dci_locked, dci_ready = Signal(), Signal()
        self.specials += [
            Instance("DCIRESET", i_RST=ResetSignal("sys"), o_LOCKED=dci_locked),
            MultiReg(dci_locked, dci_ready, "sys"),
            AsyncResetSynchronizer(self.cd_ddr4, ui_rst),
        ]
        self.comb += self.cd_ddr4.clk.eq(ui_clk)

        # The native RK implementation also gates MIG reset on DCI lock. Keep
        # the AXI gate closed until calibration finishes.
        ports = dict(
            i_sys_rst=ResetSignal("sys") | ~dci_ready,
            i_c0_sys_clk_i=clk200_raw,
            o_c0_init_calib_complete=self.init_done,
            o_c0_ddr4_ui_clk=ui_clk,
            o_c0_ddr4_ui_clk_sync_rst=ui_rst,
            o_dbg_clk=dbg_clk, o_dbg_bus=dbg_bus,
            o_c0_ddr4_adr=pads.a, o_c0_ddr4_ba=pads.ba, o_c0_ddr4_bg=pads.bg,
            o_c0_ddr4_act_n=pads.act_n, o_c0_ddr4_cke=pads.cke,
            o_c0_ddr4_odt=pads.odt, o_c0_ddr4_cs_n=pads.cs_n,
            o_c0_ddr4_ck_t=pads.clk_p, o_c0_ddr4_ck_c=pads.clk_n,
            o_c0_ddr4_reset_n=pads.reset_n,
            io_c0_ddr4_dm_dbi_n=pads.dm, io_c0_ddr4_dq=pads.dq,
            io_c0_ddr4_dqs_t=pads.dqs_p, io_c0_ddr4_dqs_c=pads.dqs_n,
            i_c0_ddr4_aresetn=~ResetSignal("ddr4"),
        )
        for channel, fields in (
            ("aw", "id addr len size burst lock cache prot qos valid ready"),
            ("w", "data strb last valid ready"),
            ("b", "id resp valid ready"),
            ("ar", "id addr len size burst lock cache prot qos valid ready"),
            ("r", "id data resp last valid ready"),
        ):
            endpoint = getattr(mig_bus, channel)
            for field in fields.split():
                # AXI address/write channels drive MIG; B/R responses return.
                output = (channel in ("b", "r")) != (field == "ready")
                prefix = "o" if output else "i"
                ports[f"{prefix}_c0_ddr4_s_axi_{channel}{field}"] = getattr(endpoint, field)
        self.specials += Instance("raptor_rk_litex_ddr4_0", **ports)


class RaptorRKSoC(SoCCore):
    csr_map = {"ctrl": 0, "identifier_mem": 1, "timer0": 2, "uart": 3}
    interrupt_map = {"uart": 0, "timer0": 1}

    def __init__(self, board, sys_clk_freq=50_000_000, with_litedram=False,
                 litedram_size=0x40000000, with_mig=True, mig_size=0x80000000,
                 with_sdcard=False, sdcard_autoboot=False, with_ethernet=True,
                 eth_speed=1000, fmc_slot=None, eth_port="a", with_led_chaser=False,
                 **kwargs):
        if with_litedram or with_sdcard or sdcard_autoboot:
            raise ValueError("RK supports MIG DDR4 and onboard Ethernet; LiteDRAM/SDCard are unavailable")
        if with_ethernet and eth_speed != 1000:
            raise ValueError("RK Ethernet is configured for 1000 Mb/s")
        if with_mig and kwargs.get("integrated_main_ram_size", 0) != 0:
            raise ValueError("MIG requires --integrated-main-ram-size=0")
        if not 0 < mig_size <= 0x80000000 or mig_size & (mig_size - 1):
            raise ValueError("MIG window must be a power of two up to 2 GiB")

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
        kwargs.setdefault("bus_timeout", 4096)
        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)
        self.cpu.pmem_size = mig_size if with_mig else kwargs["integrated_main_ram_size"]
        self.add_config("BIOS_NO_BOOT")
        self.cm005_oversampled_rx = False  # Shared build entry point's report hook.
        self.crg = _CRG(platform, sys_clk_freq, with_ethernet)
        self.comb += platform.request("fan_enable").eq(1)

        if with_mig:
            self.ddr4_mig = RKDDR4MIG(platform, self.crg.clk200_raw)
            ready_sys = Signal()
            self.specials += MultiReg(self.ddr4_mig.init_done, ready_sys, "sys")
            self.cpu.cpu_params["i_reset"] = ResetSignal("sys") | self.cpu.reset | ~ready_sys
            mig_sys_axi = axi.AXIInterface(data_width=256, address_width=32,
                                            id_width=4, clock_domain="sys")
            self.submodules.ddr4_mig_cdc = AXIClockDomainCrossing(
                mig_sys_axi, self.ddr4_mig.bus, cd_from="sys", cd_to="ddr4", depth=16)
            self.bus.add_slave("main_ram", slave=mig_sys_axi,
                               region=SoCRegion(origin=self.mem_map.get("main_ram", 0x80000000),
                                                size=mig_size, mode="rwx"), strip_origin=True)
            # The MIG UI clock does not exist while the top XDC is first read.
            # Resolve both clocks after IP linking/synthesis, before placement.
            platform.toolchain.pre_optimize_commands.append(
                "set rk_sys_clock [get_clocks -quiet -of_objects [get_nets sys_clk]]; "
                "set rk_ddr_clock [get_clocks -quiet -of_objects "
                "[get_pins raptor_rk_litex_ddr4_0/c0_ddr4_ui_clk]]; "
                "if {{[llength $rk_sys_clock] != 1 || [llength $rk_ddr_clock] != 1}} "
                "{{error RK_DDR_CLOCKS_UNRESOLVED}}; "
                "set_clock_groups -asynchronous -group $rk_sys_clock -group $rk_ddr_clock")
            # MIG's MMCM is fixed near the DDR bank, away from the 200 MHz
            # input. Let its auto-inserted BUFG use the dedicated backbone.
            # The net exists after optimization, before I/O clock placement.
            platform.toolchain.pre_placement_commands.append(
                "set rk_mig_ref [get_nets -quiet *crg_clk200_raw_BUFGCE]; "
                "if {{[llength $rk_mig_ref] != 1}} {{error RK_MIG_REFERENCE_UNRESOLVED}}; "
                "set_property CLOCK_DEDICATED_ROUTE BACKBONE $rk_mig_ref")

        if with_ethernet:
            clocks, pads = platform.request("eth_clocks"), platform.request("eth")
            # Board schematic: TXDLY/RXD1 is pulled high, RXDLY/RXCTL low.
            # The PHY delays its TX sampling clock. RX is captured by the
            # MMCM's compensated clock path; routed I/O timing is checked.
            self.ethphy = RKRGMII(clocks, pads)
            # Vivado reports this fixed RK pin as unavailable while MIG's
            # DDR byte performs BISC. The CPU stays in reset until MIG
            # calibration completes and the MAC has no startup TX traffic.
            platform.add_platform_command(
                "set_property UNAVAILABLE_DURING_CALIBRATION TRUE "
                "[get_ports {{eth_tx_data[1]}}]")
            self.mem_map["ethmac"] = 0x18000000
            self.add_ethernet(phy=self.ethphy, data_width=8, nrxslots=8,
                              with_timing_constraints=False)
            self.add_constant("RK_ETH_SPEED", 1000)
            platform.add_platform_command(
                "create_clock -name rk_eth_rxc -period 8.000 [get_ports {rxclk}]",
                rxclk=clocks.rx)
            # RXDLY is low. Budget the PHY's +/-0.5 ns output skew plus
            # another 0.5 ns for package, trace, and board uncertainty.
            for edge in ("", "-clock_fall -add_delay"):
                for bound, delay in (("max", 1.0), ("min", -1.0)):
                    platform.add_platform_command(
                        f"set_input_delay -clock rk_eth_rxc -{bound} {delay} {edge} "
                        "[get_ports {{ {rxdata}[*] {rxctl} }}]",
                        rxdata=pads.rx_data, rxctl=pads.rx_ctl)
            platform.add_false_path_constraints(self.crg.cd_sys.clk,
                                                self.ethphy.crg.cd_eth_rx.clk)
            platform.add_false_path_constraints(self.crg.cd_sys.clk,
                                                self.ethphy.crg.cd_eth_tx.clk)
            # Keep the forwarded clock and represent the PHY's TXDLY strap
            # with a separate sample clock two nanoseconds later.
            platform.add_platform_command(
                "create_generated_clock -name rk_eth_txc -source [get_pins rk_eth_txc_ddr/C] "
                "-divide_by 1 [get_ports {txclk}]", txclk=clocks.tx)
            platform.add_platform_command(
                "create_generated_clock -name rk_eth_phy_sample "
                "-source [get_pins rk_eth_txc_ddr/C] -edges {{1 2 3}} "
                "-edge_shift {{2.000 2.000 2.000}} "
                "-master_clock [get_clocks -of_objects [get_pins rk_eth_txc_ddr/C]] "
                "-add [get_ports {txclk}]", txclk=clocks.tx)
            for edge in ("", "-clock_fall -add_delay"):
                for bound, delay in (("max", 1.0), ("min", -1.0)):
                    platform.add_platform_command(
                        f"set_output_delay -clock rk_eth_phy_sample -{bound} {delay} {edge} "
                        "[get_ports {{ {txdata}[*] {txctl} }}]",
                        txdata=pads.tx_data, txctl=pads.tx_ctl)

        if with_led_chaser:
            self.leds = LedChaser(pads=platform.request_all("user_led"),
                                  sys_clk_freq=sys_clk_freq)


def main():
    run_target(BOARD, soc_class=RaptorRKSoC)


if __name__ == "__main__":
    main()
