#!/usr/bin/env python3
"""Emit the production gigabit native-DDR TX and common-source clock logic."""
from pathlib import Path
import argparse
import sys
from migen import *
from migen.fhdl import verilog
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005 import CM005TX1000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--experimental-split-clock", action="store_true",
        help="Model the physical ECO: separate PHY divider and SYNC BUFGCE serial clock")
    args = parser.parse_args()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    dut = Module()
    dut.clock_domains.cd_eth_tx = ClockDomain("eth_tx")
    dut.clock_domains.cd_cm005_tx_serial = ClockDomain("cm005_tx_serial", reset_less=True)
    raw = Signal(name_override="tx_raw")
    clock_reset = Signal(name_override="clock_reset")
    if args.experimental_split_clock:
        dut.clock_domains.cd_cm005_tx_phy = ClockDomain("cm005_tx_phy", reset_less=True)
        dut.specials += [
            Instance("BUFGCE", name="cm005_tx_serial_buf", p_CE_TYPE="SYNC",
                i_I=raw, i_CE=~clock_reset, o_O=dut.cd_cm005_tx_serial.clk),
            Instance("BUFGCE_DIV", name="cm005_tx_phy_buf", p_BUFGCE_DIVIDE=2,
                i_I=raw, i_CE=1, i_CLR=clock_reset, o_O=dut.cd_cm005_tx_phy.clk),
        ]
    else:
        dut.specials += Instance("BUFGCE_DIV", name="cm005_tx_serial_buf", p_BUFGCE_DIVIDE=1,
            i_I=raw, i_CE=1, i_CLR=clock_reset, o_O=dut.cd_cm005_tx_serial.clk)
    dut.specials += [
        Instance("BUFGCE_DIV", name="cm005_tx_word_buf", p_BUFGCE_DIVIDE=2,
            i_I=raw, i_CE=1, i_CLR=clock_reset, o_O=dut.cd_eth_tx.clk),
    ]
    txc = Signal(name_override="txc")
    pads = Record([("tx_data", 4), ("tx_ctl", 1)])
    pads.tx_data.name_override = "tx_pins"
    pads.tx_ctl.name_override = "tx_ctl"
    clocks = Record([("tx", 1)])
    clocks.tx = txc
    phy = CM005TX1000(clocks, pads)
    if args.experimental_split_clock:
        phy = ClockDomainsRenamer({"eth_tx": "cm005_tx_phy"})(phy)
    dut.submodules.phy = phy
    ios = {raw, clock_reset, dut.cd_cm005_tx_serial.clk, txc, pads.tx_data, pads.tx_ctl,
           dut.cd_eth_tx.clk, dut.cd_eth_tx.rst}
    for name in ("valid", "ready", "data", "last", "error"):
        signal = getattr(dut.phy.sink, name)
        signal.name_override = "tx_byte" if name == "data" else "tx_" + name
        ios.add(signal)
    verilog.convert(dut, ios=ios, name="cm005_gigabit_tx").write(str(output / "cm005_gigabit_tx.v"))


if __name__ == "__main__":
    main()
