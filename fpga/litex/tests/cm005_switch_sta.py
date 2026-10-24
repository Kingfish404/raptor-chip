#!/usr/bin/env python3
"""Generate switch OOC and complete CPU-port/PHY composition for scoped synthesis."""
import argparse
from pathlib import Path
import sys

from migen import ClockDomain
from migen.fhdl import verilog
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc_core import SoCMini

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_switch import CM005Switch, add_cpu_frame_mac
from cm005_bridge import add_cm005_forwarder
from ku15p_soc import _CRG, KU15P_SYNTH_OPTIONS
from mlk_cu08_ku15p import BOARD


class BridgeComposition(SoCMini):
    def __init__(self):
        platform = BOARD.platform()
        super().__init__(platform, 50_000_000, ident="CM005 CPU-port composition")
        self.crg = _CRG(platform, 50_000_000, with_ethernet=True,
                        cm005_oversample=True, cm005_tx_split=True, cm005_tx_dual=True)
        self.add_uartbone(baudrate=115200)
        mac = add_cpu_frame_mac(self)
        add_cm005_forwarder(self, platform, cpu_mac=mac)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    switch = CM005Switch()
    switch.cd_sys = ClockDomain('sys')
    ios = {switch.cd_sys.clk, switch.cd_sys.rst}
    for endpoint in switch.sinks + switch.sources:
        ios.update(endpoint.flatten())
    for csr in switch.get_csrs():
        ios.add(csr.status)
    verilog.convert(switch, ios=ios, name='cm005_switch').write(str(args.output / 'switch.v'))
    soc = BridgeComposition()
    Builder(soc, output_dir=str(args.output / 'composition'), compile_software=False).build(
        run=False, build_name='cm005_cpu_bridge',
        vivado_synth_directive='default' + KU15P_SYNTH_OPTIONS)


if __name__ == '__main__':
    main()
