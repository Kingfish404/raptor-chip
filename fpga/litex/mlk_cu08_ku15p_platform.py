# LiteX platform definition for the MiLianKe MLK-CU08-KU15P.
# Device: XCKU15P-L2FFVA1156E.

from litex.build.generic_platform import *
from litex.build.xilinx import XilinxUSPPlatform
from litex.build.openfpgaloader import OpenFPGALoader


_io = [
    ("clk100", 0, Pins("P26"), IOStandard("LVCMOS18")),
    ("clk100_ddr", 0,
        Subsignal("p", Pins("N24")),
        Subsignal("n", Pins("M24")),
        IOStandard("DIFF_SSTL12"),
    ),
    ("cpu_resetn", 0, Pins("AJ14"), IOStandard("LVCMOS18"), Misc("PULLTYPE PULLUP")),

    ("user_btn", 0, Pins("AJ14"), IOStandard("LVCMOS18")),
    ("user_btn", 1, Pins("AJ15"), IOStandard("LVCMOS18")),
    ("user_btn", 2, Pins("AM15"), IOStandard("LVCMOS18")),
    ("user_btn", 3, Pins("AM16"), IOStandard("LVCMOS18")),

    ("user_led", 0, Pins("AD9"), IOStandard("LVCMOS33")),
    ("user_led", 1, Pins("AD8"), IOStandard("LVCMOS33")),
    ("user_led", 2, Pins("AE8"), IOStandard("LVCMOS33")),
    ("user_led", 3, Pins("AF8"), IOStandard("LVCMOS33")),
    ("user_led", 4, Pins("AD10"), IOStandard("LVCMOS33")),

    ("serial", 0,
        Subsignal("tx", Pins("AN11")),
        Subsignal("rx", Pins("AM11")),
        IOStandard("LVCMOS33"),
    ),

    ("sdcard", 0,
        Subsignal("clk", Pins("AG19")),
        Subsignal("cmd", Pins("AH19"), Misc("PULLTYPE PULLUP")),
        Subsignal("data", Pins("AE16 AE15 AF15 AF14"), Misc("PULLTYPE PULLUP")),
        Subsignal("cd", Pins("AL14"), Misc("PULLTYPE PULLUP")),
        IOStandard("LVCMOS18"),
    ),

    ("i2c", 0,
        Subsignal("scl", Pins("AP11")),
        Subsignal("sda", Pins("AP10")),
        IOStandard("LVCMOS33"),
    ),

    ("ddram", 0,
        Subsignal("a", Pins(
            "AM34 AN26 AP34 AK26 AL32 AK28 AK32 AL30",
            "AL34 AP26 AK31 AL33 AH32 AM32"),
            IOStandard("SSTL12_DCI")),
        Subsignal("ba", Pins("AJ31 AK27"), IOStandard("SSTL12_DCI")),
        Subsignal("bg", Pins("AJ30"), IOStandard("SSTL12_DCI")),
        Subsignal("ras_n", Pins("AJ33"), IOStandard("SSTL12_DCI")),
        Subsignal("cas_n", Pins("AJ34"), IOStandard("SSTL12_DCI")),
        Subsignal("we_n", Pins("AJ28"), IOStandard("SSTL12_DCI")),
        Subsignal("cs_n", Pins("AH33"), IOStandard("SSTL12_DCI")),
        Subsignal("act_n", Pins("AH31"), IOStandard("SSTL12_DCI")),
        Subsignal("dm", Pins("Y26 V27 AA22 W23 AE25 AD21 AM21 AJ21"),
            IOStandard("POD12_DCI")),
        Subsignal("dq", Pins(
            "AD25 AA27 AC24 AB25 AB24 AB27 AD26 AB26",
            "U25 W28 W26 W29 U24 V29 V26 Y28",
            "AB20 Y23 AC22 AA24 AA20 AA25 AC23 AA23",
            "U22 T22 T23 W21 U21 Y25 V21 W25",
            "AJ23 AF23 AJ24 AG25 AH23 AF24 AH22 AG24",
            "AG20 AE22 AF20 AF22 AD20 AE23 AG22 AE20",
            "AM22 AM24 AN22 AN24 AN23 AP24 AP23 AP25",
            "AL24 AL25 AK22 AL22 AK23 AM20 AL20 AL23"),
            IOStandard("POD12_DCI")),
        Subsignal("dqs_p", Pins("AC26 U26 AB21 V22 AH24 AG21 AP20 AJ20"),
            IOStandard("DIFF_POD12_DCI")),
        Subsignal("dqs_n", Pins("AC27 U27 AC21 V23 AJ25 AH21 AP21 AK20"),
            IOStandard("DIFF_POD12_DCI")),
        Subsignal("clk_p", Pins("AJ29"), IOStandard("DIFF_SSTL12_DCI")),
        Subsignal("clk_n", Pins("AK30"), IOStandard("DIFF_SSTL12_DCI")),
        Subsignal("cke", Pins("AH27"), IOStandard("SSTL12_DCI")),
        Subsignal("odt", Pins("AH28"), IOStandard("SSTL12_DCI")),
        Subsignal("reset_n", Pins("AJ26"), IOStandard("LVCMOS12")),
        Misc("SLEW=FAST"),
    ),
]


class Platform(XilinxUSPPlatform):
    default_clk_name = "clk100"
    default_clk_period = 1e9 / 100e6

    def __init__(self, toolchain="vivado"):
        XilinxUSPPlatform.__init__(self, "xcku15p-ffva1156-2-e", _io, toolchain=toolchain)

    def create_programmer(self):
        return OpenFPGALoader(cable="ft2232", fpga_part="xcku15p-ffva1156")

    def do_finalize(self, fragment):
        XilinxUSPPlatform.do_finalize(self, fragment)
        self.add_period_constraint(self.lookup_request("clk100", loose=True), 1e9 / 100e6)
        self.add_platform_command("set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.CONFIGRATE 85.0 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]")
        self.add_platform_command("set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]")
        self.add_platform_command("set_property CONFIG_VOLTAGE 1.8 [current_design]")
        self.add_platform_command("set_property CFGBVS GND [current_design]")
        self.add_platform_command("set_property CONFIG_MODE SPIx4 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]")
