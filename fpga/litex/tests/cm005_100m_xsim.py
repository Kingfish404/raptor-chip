#!/usr/bin/env python3
"""Emit the production 100M adapters + UltraScale+ primitives for XSim.

Usage: fpga/litex/.venv/bin/python fpga/litex/tests/cm005_100m_xsim.py OUTPUT_DIR
Then compile cm005_100m.v and tb_cm005_100m.sv with unisims_ver/secureip.
This is a functional primitive test, not a substitute for routed STA.
"""
from pathlib import Path
import sys

from migen import *
from migen.fhdl import verilog
from liteeth.phy.usrgmii import LiteEthPHYRGMIITX, LiteEthPHYRGMIIRX

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005 import CM005TX100, CM005RX100


def main():
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    dut = Module()
    dut.clock_domains.cd_eth_tx = ClockDomain("eth_tx")
    dut.clock_domains.cd_eth_rx = ClockDomain("eth_rx")
    shifted = Signal(name_override="tx_shifted")
    txc = Signal(name_override="txc")
    pads = Record([("tx_data", 4), ("tx_ctl", 1), ("rx_data", 4), ("rx_ctl", 1)])
    for name in ("tx_data", "tx_ctl", "rx_data", "rx_ctl"):
        getattr(pads, name).name_override = name
    dut.submodules.tx_adapter = ClockDomainsRenamer("eth_tx")(CM005TX100())
    dut.submodules.rx_adapter = ClockDomainsRenamer("eth_rx")(CM005RX100())
    dut.submodules.tx_phy = ClockDomainsRenamer("eth_tx")(LiteEthPHYRGMIITX(pads))
    dut.submodules.rx_phy = ClockDomainsRenamer("eth_rx")(
        LiteEthPHYRGMIIRX(pads, rx_delay=1e-9, usp=True))
    dut.comb += [dut.tx_adapter.source.connect(dut.tx_phy.sink),
                 dut.rx_phy.source.connect(dut.rx_adapter.sink)]
    dut.specials += Instance("ODDRE1", i_C=shifted, i_SR=0, i_D1=1, i_D2=0, o_Q=txc)
    ios = {shifted, txc, pads.tx_data, pads.tx_ctl, pads.rx_data, pads.rx_ctl,
           dut.cd_eth_tx.clk, dut.cd_eth_tx.rst, dut.cd_eth_rx.clk, dut.cd_eth_rx.rst}
    for prefix, endpoint in (("tx", dut.tx_adapter.sink), ("rx", dut.rx_adapter.source)):
        for name in ("valid", "ready", "data", "last", "error"):
            signal = getattr(endpoint, name)
            signal.name_override = prefix + "_" + name
            ios.add(signal)
    verilog.convert(dut, ios=ios, name="cm005_100m").write(str(output / "cm005_100m.v"))


if __name__ == "__main__":
    main()
