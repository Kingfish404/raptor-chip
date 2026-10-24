#!/usr/bin/env python3
"""CU08 FMC_C CM005 A/B gigabit bridge with UARTBone diagnostics, no CPU/DDR."""
import argparse
from pathlib import Path

from migen import ClockDomainsRenamer, ResetInserter
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc_core import SoCMini
from liteeth.mac.core import LiteEthMACCore

from cm005 import CM005PHY, add_pads
from cm005_bridge_queue import EthernetFrameQueue
from cm005_oversample import SAMPLE_IDELAY_FREQ
from cm005_timing import constrain_cm005
from ku15p_soc import _CRG, configure_ku15p_timing, KU15P_SYNTH_OPTIONS
from mlk_cu08_ku15p import BOARD


class CM005Bridge(SoCMini):
    def __init__(self):
        platform = BOARD.platform()
        frequency = 50_000_000
        super().__init__(platform, frequency, ident="CM005 A/B store-and-forward bridge")
        self.crg = _CRG(platform, frequency, with_ethernet=True, cm005_oversample=True,
                        cm005_tx_split=True, cm005_tx_dual=True)
        self.add_uartbone(baudrate=115200)
        add_cm005_forwarder(self, platform, frequency)


def buffer_slow_cm005_tx(mac):
    """Commit a complete wire frame before a slow sys clock feeds 1Gb/s TX.

    Keep the existing IFG stage after this FIFO. The payload holds the maximum
    1536-byte frame plus its preamble/FCS; packet metadata publishes only when
    the last byte arrives. A paused CPU-side stream cannot create a wire gap.
    """
    from litex.soc.interconnect.packet import PacketFIFO
    from liteeth.common import eth_phy_description
    from liteeth.mac.gap import LiteEthMACGap
    pipeline = mac.tx_datapath.pipeline
    if not isinstance(pipeline[-2], LiteEthMACGap):
        raise ValueError("CM005 frame buffering requires the MAC's final IFG stage")
    mac.tx_frame_fifo = fifo = ClockDomainsRenamer("eth_tx")(
        PacketFIFO(eth_phy_description(8), payload_depth=2048, param_depth=2, buffered=True))
    pipeline.insert(-2, fifo)


def add_cm005_forwarder(self, platform, frequency=50_000_000, cpu_mac=None):
    """Attach the same PHY/MAC/queue datapath to standalone or native wrappers."""
    clocks_a, pads_a = add_pads(platform, BOARD.name, "c", "a")
    clocks_b, pads_b = add_pads(platform, BOARD.name, "c", "b",
                                name="cm005_b", with_reset_gate=False)
    self.phy_a = CM005PHY(clocks_a, pads_a, frequency,
        iodelay_clk_freq=SAMPLE_IDELAY_FREQ, rx_oversample=True,
        rx_data_sample_advance=(0, 2, 0, 2), rx_control_sample_advance=2,
        drive_reset=False, tx_phy_clock="cm005_tx_phy")
    rename_b = {"eth_rx": "eth_b_rx", "eth_tx": "eth_b_tx"}
    self.phy_b = ClockDomainsRenamer(rename_b)(CM005PHY(
        clocks_b, pads_b, frequency, iodelay_clk_freq=SAMPLE_IDELAY_FREQ,
        tx_serial=True, tx_name_prefix="cm005_b_tx", drive_reset=False,
        rx_delay=650e-12, tx_phy_clock="cm005_b_tx_phy",
        tx_serial_clock="cm005_b_tx_serial", tx_mac_clock="cm005_b_tx"))
    # Both PHYs share one physical reset gate. A software reset of either
    # port restarts both reset timers, MDIO initializers and CDC domains.
    restart = (~self.crg.ethpll.locked | ~self.crg.eth_b_pll.locked |
               self.crg.cd_cm005_ready.rst |
               self.phy_a.crg._reset.storage | self.phy_b.crg._reset.storage)
    self.comb += [self.phy_a.crg.clock_unlocked.eq(restart),
                 self.phy_b.crg.clock_unlocked.eq(restart),
                 pads_a.reset_gate.eq(self.phy_a.crg.reset | self.phy_b.crg.reset)]
    self.mac_a = ResetInserter(["sys"])(LiteEthMACCore(
        self.phy_a, 32, rx_cdc_depth=512, tx_cdc_depth=512))
    self.mac_b = ClockDomainsRenamer(rename_b)(ResetInserter(["sys"])(LiteEthMACCore(
        self.phy_b, 32, rx_cdc_depth=512, tx_cdc_depth=512)))
    # Below 50 MHz, the 32-bit system path cannot continuously feed every
    # 125 MHz wire cycle. Preserve the existing fast path at the proven clock.
    if frequency < 50_000_000:
        for mac in (self.mac_a, self.mac_b):
            buffer_slow_cm005_tx(mac)
    reset = self.phy_a.crg.reset | self.phy_b.crg.reset
    for module in (self.mac_a, self.mac_b):
        self.comb += module.reset_sys.eq(reset)
    if cpu_mac is None:
        self.a_to_b = ResetInserter(["sys"])(EthernetFrameQueue())
        self.b_to_a = ResetInserter(["sys"])(EthernetFrameQueue())
        for module in (self.a_to_b, self.b_to_a):
            self.comb += module.reset_sys.eq(reset)
        self.comb += [self.mac_a.source.connect(self.a_to_b.sink),
                     self.a_to_b.source.connect(self.mac_b.sink),
                     self.mac_b.source.connect(self.b_to_a.sink),
                     self.b_to_a.source.connect(self.mac_a.sink)]
    else:
        from cm005_switch import CM005Switch
        self.cm005_switch = switch = ResetInserter(["sys"])(CM005Switch())
        # Flush the CPU packet reader/writer together with the switch. A PHY
        # restart must not resume the tail of an old CPU frame as a new frame.
        ResetInserter(["sys"])(cpu_mac)
        self.comb += [switch.reset_sys.eq(reset), cpu_mac.reset_sys.eq(reset)]
        for index, mac in enumerate((self.mac_a, self.mac_b, cpu_mac)):
            self.comb += [mac.source.connect(switch.sinks[index]),
                         switch.sources[index].connect(mac.sink)]
    constrain_cm005(platform, self.crg, self.phy_a, clocks_a, pads_a,
                    oversampled_rx=True, tx_local_clock=True,
                    tx_word_net="cm005_tx_phy_clk")
    constrain_cm005(platform, self.crg, self.phy_b, clocks_b, pads_b,
                    tx_serial=True, name="cm005_b", tx_mac_clock=self.crg.cd_cm005_b_tx.clk)
    # Balance the physical LVCMOS18 output-buffer delays within the
    # unchanged 1.2 ns external setup/hold window on both DDR edges.
    platform.add_platform_command(
        "set_property DRIVE 8 [get_ports {{ {data}[*] {ctl} }}]",
        data=pads_a.tx_data, ctl=pads_a.tx_ctl)
    platform.add_platform_command(
        "set_property DRIVE 6 [get_ports {clock}]", clock=clocks_a.tx)
    platform.add_platform_command(
        "set_property SLEW SLOW [get_ports {clock}]", clock=clocks_a.tx)
    platform.add_platform_command(
        "set_property SLEW MEDIUM [get_ports {{ {data}[*] {ctl} }}]",
        data=pads_b.tx_data, ctl=pads_b.tx_ctl)
    # F13 shares BITSLICE_6 with calibrated native-RX I/O. The shared
    # PHY reset and all MAC resets remain asserted until IDELAY RDY.
    platform.add_platform_command(
        "set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports {ctl}]",
        ctl=pads_b.tx_ctl)
    platform.add_platform_command(
        "set_property LOC MMCM_X0Y2 [get_cells cm005_b_tx_pll]")
    platform.add_platform_command(
        "set_property USER_CLOCK_ROOT X2Y2 "
        "[get_nets {{cm005_b_tx_phy_clk cm005_b_tx_serial_clk}}]")
    platform.add_platform_command(
        "set_property CLOCK_DELAY_GROUP cm005_b_transmit "
        "[get_nets {{cm005_b_tx_phy_clk cm005_b_tx_serial_clk}}]")
    platform.add_platform_command(
        "set_property CLOCK_LOW_FANOUT TRUE "
        "[get_nets {{cm005_b_tx_phy_clk cm005_b_tx_serial_clk}}]")
    # All ETHB receive pins are in X2Y2. Keep its native clock and MAC
    # loads nearby instead of allowing the root to drift to X1Y4.
    platform.add_platform_command(
        "set_property USER_CLOCK_ROOT X2Y2 [get_nets eth_b_rx_clk]")
    platform.add_platform_command(
        "set_property CLOCK_LOW_FANOUT TRUE [get_nets eth_b_rx_clk]")
    configure_ku15p_timing(platform, BOARD)
    platform.toolchain.pre_synthesis_commands.add("set_param general.maxThreads 8")
    platform.toolchain.pre_optimize_commands.add(
        "foreach cell {{{{cm005_tx_phy_buf cm005_b_tx_phy_buf cm005_tx_word_buf "
        "cm005_tx_serial_buf cm005_b_tx_serial_buf cm005_b_tx_word_buf}}}} {{{{ "
        "if {{{{[llength [get_cells -quiet $cell]] != 1}}}} "
        "{{{{error \"Missing independent TX clock buffer: $cell\"}}}} }}}}")
    platform.toolchain.bitstream_commands += [
        "set bridge_methodology [report_methodology -return_string]",
        "set bridge_report [open bridge_methodology.rpt w]; "
        "puts $bridge_report $bridge_methodology; close $bridge_report",
        "if {{[string first \"Critical Warning\" $bridge_methodology] >= 0}} "
        "{{error \"Bridge clock/methodology check failed\"}}",
        "report_timing_summary -delay_type min_max -report_unconstrained -file bridge_timing.rpt",
        "foreach delay {{min max}} {{ set paths [get_timing_paths -delay_type $delay -max_paths 1]; "
        "if {{[llength $paths] != 1 || [get_property SLACK $paths] < 0}} "
        "{{error \"Bridge timing failed ($delay)\"}} }}",
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    builder = Builder(CM005Bridge(), output_dir=str(args.output_dir),
                      csr_csv=str(args.output_dir / "csr.csv"),
                      csr_json=str(args.output_dir / "csr.json"), compile_software=False)
    builder.build(run=args.build, build_name="cm005_bridge",
                  vivado_synth_directive="default" + KU15P_SYNTH_OPTIONS)


if __name__ == "__main__":
    main()
