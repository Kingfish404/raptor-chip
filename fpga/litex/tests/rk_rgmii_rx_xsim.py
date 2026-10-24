#!/usr/bin/env python3
"""Emit the production RK receive lanes for simulation with AMD primitives."""
from pathlib import Path
import argparse
import sys

from migen import ClockDomain, ClockDomainsRenamer, Module, Record
from litex.gen.fhdl import verilog

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from rk_xcku5p_f import RKRGMIIReceive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--with-mac", action="store_true",
                        help="Include the production 8-bit RX MAC pipeline and 32-bit sys CDC")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    dut = Module()
    dut.clock_domains.cd_eth_rx = ClockDomain("eth_rx")
    pads = Record([("rx_data", 4), ("rx_ctl", 1)])
    pads.rx_data.name_override = "rx_pins"
    pads.rx_ctl.name_override = "rx_ctl"
    dut.submodules.rx = rx = ClockDomainsRenamer("eth_rx")(RKRGMIIReceive(pads))
    ios = {dut.cd_eth_rx.clk, dut.cd_eth_rx.rst, pads.rx_data, pads.rx_ctl}
    output = rx.source
    if args.with_mac:
        from litex.soc.interconnect import stream
        from liteeth.common import eth_phy_description
        from liteeth.mac.core import LiteEthMACCore

        dut.clock_domains.cd_sys = ClockDomain("sys")
        rx.dw = 8
        rx.sink = stream.Endpoint(eth_phy_description(8))
        mac = LiteEthMACCore(rx, 32, with_sys_datapath=False)
        # Elaborate the production receive pipeline, including its actual
        # preamble/CRC checkers, converter, FIFO, and error counters.
        dut.submodules.mac_rx = mac.rx_datapath
        output = mac.source
        ios.update({dut.cd_sys.clk, dut.cd_sys.rst})
    for name in ("valid", "ready", "data", "last", "last_be", "error"):
        signal = getattr(output, name)
        signal.name_override = "rx_" + name
        ios.add(signal)
    name = "rk_rgmii_mac" if args.with_mac else "rk_rgmii_rx"
    verilog.convert(dut, ios=ios, name=name).write(str(args.output / (name + ".v")))


if __name__ == "__main__":
    main()
