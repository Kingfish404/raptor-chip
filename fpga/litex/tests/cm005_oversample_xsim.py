#!/usr/bin/env python3
"""Emit the production oversampling RX including IDELAYE3/ISERDESE3."""
from pathlib import Path
import argparse
import sys
from migen import *
from migen.fhdl import verilog

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_oversample import CM005RXOversample, CM005SampleClocks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--speed", type=int, choices=(100, 1000), default=100)
    parser.add_argument("--data-sample-advance", type=int, nargs=4, default=(0, 0, 0, 0))
    parser.add_argument("--control-sample-advance", type=int, default=0, choices=range(8))
    parser.add_argument("--clock-buffers", action="store_true",
                        help="Use the production common-source CLK/CLKDIV buffers")
    args = parser.parse_args()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    dut = Module()
    dut.clock_domains.cd_eth_rx = ClockDomain("eth_rx")
    dut.clock_domains.cd_cm005_sample = ClockDomain("cm005_sample", reset_less=True)
    rx_clock = Signal(name_override="phy_clock")
    pads = Record([("rx_data", 4), ("rx_ctl", 1)])
    pads.rx_data.name_override = "phy_data"
    pads.rx_ctl.name_override = "phy_control"
    dut.submodules.rx = ClockDomainsRenamer("eth_rx")(
        CM005RXOversample(rx_clock, pads, speed=args.speed,
                         data_sample_advance=args.data_sample_advance,
                         control_sample_advance=args.control_sample_advance))
    ios = {rx_clock, pads.rx_data, pads.rx_ctl, dut.cd_eth_rx.clk,
           dut.cd_eth_rx.rst, dut.cd_cm005_sample.clk}
    if args.clock_buffers:
        raw = Signal(name_override="sample_raw")
        reset = Signal(name_override="clock_reset")
        dut.submodules.sample_clocks = CM005SampleClocks(
            raw, reset, dut.cd_cm005_sample.clk, dut.cd_eth_rx.clk)
        ios.remove(dut.cd_cm005_sample.clk)
        ios.update({raw, reset})
    for name in ("valid", "ready", "data", "last", "error"):
        signal = getattr(dut.rx.source, name)
        signal.name_override = "rx_" + name
        ios.add(signal)
    dut.rx.fault.name_override = "rx_fault"
    dut.rx.decoder.clock.name_override = "sampled_clock"
    ios.update({dut.rx.fault, dut.rx.decoder.clock})
    verilog.convert(dut, ios=ios, name="cm005_oversample").write(str(output / "cm005_oversample.v"))


if __name__ == "__main__":
    main()
