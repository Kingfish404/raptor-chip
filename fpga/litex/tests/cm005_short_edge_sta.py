#!/usr/bin/env python3
"""Route the production CU08 C/ETHA CRG/PHY without CPU, DDR or a board load.

Usage: .venv/bin/python tests/cm005_short_edge_sta.py /tmp/unique-output
The SoC supplies its actual pin and timing constraints. Only its CRG/PHY are
elaborated; a TX pattern and observable RX checksum keep the datapaths alive.
This is peripheral STA, not full-SoC timing or an Ethernet hardware test.
"""
import argparse
import sys
from pathlib import Path
from unittest.mock import patch

from migen import Module, Signal, If

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ku15p_soc as shared
from mlk_cu08_ku15p import BOARD, RaptorMLKCU08SoC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--litedram", action="store_true")
    parser.add_argument("--speed", type=int, choices=(100, 1000), default=100)
    args = parser.parse_args()
    dram_clocks = args.litedram
    with patch.object(shared.Raptor, "add_sources", lambda *args, **kwargs: None):
        soc = RaptorMLKCU08SoC(sys_clk_freq=50e6, with_ethernet=True,
                              with_litedram=dram_clocks,
                              fmc_slot="c", eth_speed=args.speed,
                              integrated_main_ram_size=0 if dram_clocks else 0x10000)
    dut = Module()
    dut.submodules.crg = soc.crg
    dut.submodules.ethphy = soc.ethphy
    phy = soc.ethphy
    dut.comb += phy.crg.clock_unlocked.eq(~soc.crg.ethpll.locked |
        (0 if dram_clocks else soc.crg.cd_cm005_ready.rst))
    pattern = Signal(8)
    checksum = Signal(8)
    dut.sync.eth_tx += If(phy.sink.ready, pattern.eq(pattern + 1))
    dut.comb += [phy.sink.valid.eq(1), phy.sink.data.eq(pattern),
                 phy.sink.last.eq(pattern == 255), phy.sink.error.eq(0),
                 phy.source.ready.eq(1)]
    dut.sync.eth_rx += If(phy.source.valid,
        checksum.eq(checksum + phy.source.data + phy.source.error + phy.source.last))
    for i in range(5):
        led = soc.platform.request("user_led", i)
        dut.comb += led.eq(checksum[i] ^ checksum[(i + 3) % 8])
        # LEDs are observation endpoints, not synchronous board interfaces.
        soc.platform.add_platform_command("set_false_path -to [get_ports {led}]", led=led)
    soc.platform.toolchain.pre_synthesis_commands += ["set_param general.maxThreads 4"]
    shared.configure_ku15p_timing(soc.platform, BOARD, with_litedram=dram_clocks)
    soc.platform.toolchain.bitstream_commands += [
        "report_timing_summary -delay_type min_max -report_unconstrained -file peripheral_timing.rpt",
        "report_timing -from [get_ports {{cm005_clocks_rx cm005_rx_data[*] cm005_rx_ctl}}] -delay_type min_max -max_paths 24 -nworst 4 -file peripheral_rx.rpt",
        "foreach delay {{min max}} {{ "
        "set worst [get_timing_paths -delay_type $delay -max_paths 1]; "
        "if {{[llength $worst] != 1}} {{error \"Missing peripheral timing paths\"}}; "
        "if {{[get_property SLACK $worst] < 0}} {{error \"Peripheral timing failed ($delay); do not load\"}} "
        "}}",
    ]
    soc.platform.build(dut, build_dir=str(args.output.resolve()),
                       build_name="cm005_short_edge", run=True,
                       vivado_synth_directive="default" + shared.KU15P_SYNTH_OPTIONS)


if __name__ == "__main__":
    main()
