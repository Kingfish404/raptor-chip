#!/usr/bin/env python3
"""Route the RK production CRG/RGMII at board pins, without CPU or DDR."""
import argparse
from pathlib import Path
import sys
from unittest.mock import patch

from migen import Module, Signal, If

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ku15p_soc import Raptor, configure_ku15p_timing, KU15P_SYNTH_OPTIONS
from rk_xcku5p_f import BOARD, RaptorRKSoC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with patch.object(Raptor, "add_sources", lambda *args, **kwargs: None):
        soc = RaptorRKSoC(BOARD, with_mig=False, integrated_main_ram_size=0x10000)
    dut = Module()
    dut.submodules.crg = soc.crg
    dut.submodules.ethphy = phy = soc.ethphy
    pattern = Signal(8, name="tx_pattern")
    checksum = Signal(8, name="rx_checksum")
    dut.sync.eth_tx += If(phy.sink.ready, pattern.eq(pattern + 1))
    dut.comb += [phy.sink.valid.eq(1), phy.sink.data.eq(pattern),
                 phy.sink.last.eq(pattern == 255), phy.sink.error.eq(0),
                 phy.source.ready.eq(1)]
    dut.sync.eth_rx += If(phy.source.valid, checksum.eq(
        checksum + phy.source.data + phy.source.error + phy.source.last + phy.source.last_be))
    for i in range(4):
        led = soc.platform.request("user_led", i)
        dut.comb += led.eq(checksum[i] ^ checksum[i + 4])
        soc.platform.add_platform_command("set_false_path -to [get_ports {led}]", led=led)
    configure_ku15p_timing(soc.platform, BOARD, with_mig=True)
    soc.platform.toolchain.pre_synthesis_commands += ["set_param general.maxThreads 8"]
    soc.platform.toolchain.bitstream_commands += [
        "report_timing_summary -delay_type min_max -report_unconstrained -file peripheral_timing.rpt",
        "report_timing -from [get_ports {{eth_rx_data[*] eth_rx_ctl}}] "
        "-delay_type min_max -max_paths 20 -file peripheral_rx.rpt",
        "foreach delay {{min max}} {{ "
        "set worst [get_timing_paths -delay_type $delay -max_paths 1]; "
        "if {{[llength $worst] != 1}} {{error RK_PERIPHERAL_PATH_MISSING}}; "
        "if {{[get_property SLACK $worst] < 0}} {{error RK_PERIPHERAL_TIMING_FAILED}} "
        "}}",
    ]
    soc.platform.build(dut, build_dir=str(args.output.resolve()), build_name="rk_rgmii",
                       vivado_synth_directive="default" + KU15P_SYNTH_OPTIONS)


if __name__ == "__main__":
    main()
