"""LiteX pin map for the RK-XCKU5P-F V1.2 board."""

from pathlib import Path
import re

from litex.build.generic_platform import IOStandard, Misc, Pins, Subsignal
from litex.build.xilinx import XilinxUSPPlatform


_ROOT = Path(__file__).resolve().parents[1] / "rk-xcku5p-f"
_DDR_XDC = (_ROOT / "constraints/ddr4.xdc").read_text()
_PIN_RE = re.compile(r"set_property PACKAGE_PIN (\w+) \[get_ports \{(ddram_\w+(?:\[\d+\])?)\}\]")
_DDR_PINS = {name: pin for pin, name in _PIN_RE.findall(_DDR_XDC)}


def _pins(name, width=1):
    ports = [name] if width == 1 else [f"{name}[{i}]" for i in range(width)]
    try:
        return Pins(" ".join(_DDR_PINS[port] for port in ports))
    except KeyError as exc:
        raise ValueError(f"Missing RK DDR pin in {_ROOT / 'constraints/ddr4.xdc'}: {exc}") from exc


_io = [
    ("clk200", 0, Subsignal("p", Pins("T24")), Subsignal("n", Pins("U24")),
     IOStandard("DIFF_SSTL12")),
    ("cpu_resetn", 0, Pins("K9"), IOStandard("LVCMOS33"), Misc("PULLTYPE PULLUP")),
    ("serial", 0, Subsignal("rx", Pins("AD13")), Subsignal("tx", Pins("AC14")),
     IOStandard("LVCMOS33")),
    ("user_led", 0, Pins("H9"), IOStandard("LVCMOS33")),
    ("user_led", 1, Pins("J9"), IOStandard("LVCMOS33")),
    ("user_led", 2, Pins("G11"), IOStandard("LVCMOS33")),
    ("user_led", 3, Pins("H11"), IOStandard("LVCMOS33")),
    ("fan_enable", 0, Pins("G9"), IOStandard("LVCMOS33")),
    # RTL8211F-CG RGMII pins: board schematic and 12_UDP_TEST/pin.xdc.
    ("eth_clocks", 0, Subsignal("rx", Pins("K22")), Subsignal("tx", Pins("M25")),
     IOStandard("LVCMOS18")),
    ("eth", 0,
     Subsignal("rx_data", Pins("L24 L25 K25 K26")),
     Subsignal("rx_ctl", Pins("K23")),
     Subsignal("tx_data", Pins("L23 L22 L20 K20")),
     Subsignal("tx_ctl", Pins("M26")),
     Subsignal("mdc", Pins("L19")),
     Subsignal("mdio", Pins("M19")),
     IOStandard("LVCMOS18")),
    ("ddram", 0,
     Subsignal("a", _pins("ddram_adr", 17), IOStandard("SSTL12_DCI")),
     Subsignal("ba", _pins("ddram_ba", 2), IOStandard("SSTL12_DCI")),
     Subsignal("bg", _pins("ddram_bg"), IOStandard("SSTL12_DCI")),
     Subsignal("act_n", _pins("ddram_act_n"), IOStandard("SSTL12_DCI")),
     Subsignal("cke", _pins("ddram_cke"), IOStandard("SSTL12_DCI")),
     Subsignal("odt", _pins("ddram_odt"), IOStandard("SSTL12_DCI")),
     Subsignal("cs_n", _pins("ddram_cs_n"), IOStandard("SSTL12_DCI")),
     Subsignal("clk_p", _pins("ddram_clk_p"), IOStandard("DIFF_SSTL12_DCI")),
     Subsignal("clk_n", _pins("ddram_clk_n"), IOStandard("DIFF_SSTL12_DCI")),
     Subsignal("reset_n", _pins("ddram_reset_n"), IOStandard("LVCMOS12")),
     Subsignal("dm", _pins("ddram_dm", 4), IOStandard("POD12_DCI")),
     Subsignal("dq", _pins("ddram_dq", 32), IOStandard("POD12_DCI")),
     Subsignal("dqs_p", _pins("ddram_dqs_p", 4), IOStandard("DIFF_POD12_DCI")),
     Subsignal("dqs_n", _pins("ddram_dqs_n", 4), IOStandard("DIFF_POD12_DCI"))),
]


class Platform(XilinxUSPPlatform):
    default_clk_name = "clk200"
    default_clk_period = 5.0

    def __init__(self, toolchain="vivado"):
        super().__init__("xcku5p-ffvb676-2-i", _io, toolchain=toolchain)
        self.name = "rk_xcku5p_f"

    def do_finalize(self, fragment):
        super().do_finalize(fragment)
        self.add_period_constraint(self.lookup_request("clk200", loose=True).p, 5.0)
        self.add_platform_command("set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]")
        self.add_platform_command("set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]")
        self.add_platform_command("set_property CONFIG_VOLTAGE 1.8 [current_design]")
        self.add_platform_command("set_property CFGBVS GND [current_design]")
        self.add_platform_command("set_property CONFIG_MODE SPIx4 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]")
