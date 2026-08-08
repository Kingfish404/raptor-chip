#!/usr/bin/env python3

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "cores"))

from cpu.raptor.core import Raptor

from migen import *

from litex.gen import *
from litex.build.parser import LiteXArgumentParser
from litex.soc.cores.clock import USIDELAYCTRL, USMMCM
from litex.soc.cores.cpu import CPUS
from litex.soc.cores.led import LedChaser
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc_core import SoCCore

from litex_boards.platforms import xilinx_vcu118
from litedram.modules import EDY4016A
from litedram.phy import usddrphy


CPUS["raptor"] = Raptor

DEFAULT_FPGA_SYS_CLK = int(75e6)
DEFAULT_FPGA_BOOT_MODE = "bios"


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq, with_litedram=False):
        self.rst = Signal()
        self.cd_sys = ClockDomain()

        if with_litedram:
            self.cd_sys4x = ClockDomain()
            self.cd_pll4x = ClockDomain()
            self.cd_idelay = ClockDomain()

        self.pll = pll = USMMCM(speedgrade=-2)
        self.comb += pll.reset.eq(platform.request("cpu_reset") | self.rst)
        pll.register_clkin(platform.request("clk125"), 125e6)

        if with_litedram:
            pll.create_clkout(
                self.cd_pll4x,
                sys_clk_freq * 4,
                buf=None,
                with_reset=False,
            )
            pll.create_clkout(self.cd_idelay, 500e6)
            self.specials += [
                Instance(
                    "BUFGCE_DIV",
                    p_BUFGCE_DIVIDE=4,
                    i_CE=pll.locked,
                    i_I=self.cd_pll4x.clk,
                    o_O=self.cd_sys.clk,
                ),
                Instance(
                    "BUFGCE",
                    i_CE=pll.locked,
                    i_I=self.cd_pll4x.clk,
                    o_O=self.cd_sys4x.clk,
                ),
            ]
            self.idelayctrl = USIDELAYCTRL(
                cd_ref=self.cd_idelay,
                cd_sys=self.cd_sys,
            )
        else:
            pll.create_clkout(self.cd_sys, sys_clk_freq)

        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)


class RaptorVCU118SoC(SoCCore):
    csr_map = {
        "ctrl": 0,
        "identifier_mem": 1,
        "timer0": 2,
        "uart": 3,
    }
    interrupt_map = {
        "uart": 0,
        "timer0": 1,
    }

    def __init__(
        self,
        sys_clk_freq=DEFAULT_FPGA_SYS_CLK,
        with_litedram=False,
        litedram_size=0x40000000,
        with_led_chaser=False,
        **kwargs,
    ):
        platform = xilinx_vcu118.Platform(toolchain="vivado")

        kwargs["cpu_type"] = "raptor"
        kwargs.setdefault("cpu_variant", "linux32")
        kwargs.setdefault("ident", "Raptor LiteX SoC on Xilinx VCU118")
        kwargs.setdefault("ident_version", True)
        kwargs.setdefault("uart_name", "serial")
        kwargs.setdefault("uart_baudrate", 115200)
        kwargs.setdefault("uart_fifo_depth", 64)
        kwargs.setdefault("integrated_rom_size", 0x8000)
        kwargs.setdefault("integrated_sram_size", 0x2000)
        kwargs.setdefault("integrated_main_ram_size", 0)
        kwargs.setdefault("bus_timeout", 4096)

        if with_litedram and kwargs.get("integrated_main_ram_size", 0) != 0:
            raise ValueError(
                "--with-litedram requires --integrated-main-ram-size=0"
            )

        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)
        self.crg = _CRG(platform, sys_clk_freq, with_litedram=with_litedram)

        if with_litedram:
            self.ddrphy = usddrphy.USPDDRPHY(
                platform.request("ddram"),
                memtype="DDR4",
                sys_clk_freq=sys_clk_freq,
                iodelay_clk_freq=500e6,
            )
            self.add_sdram(
                "sdram",
                phy=self.ddrphy,
                module=EDY4016A(sys_clk_freq, "1:4"),
                size=litedram_size,
                l2_cache_size=kwargs.get("l2_size", 8192),
            )

        if with_led_chaser:
            self.leds = LedChaser(
                pads=platform.request_all("user_led"),
                sys_clk_freq=sys_clk_freq,
            )


def main():
    parser = LiteXArgumentParser(
        platform=xilinx_vcu118.Platform,
        description="Raptor LiteX SoC on Xilinx VCU118 (Vivado).",
    )
    parser.add_target_argument(
        "--sys-clk-freq",
        default=DEFAULT_FPGA_SYS_CLK,
        type=float,
        help="System clock frequency.",
    )
    parser.add_target_argument(
        "--boot-mode",
        default=DEFAULT_FPGA_BOOT_MODE,
        choices=["bios", "custom"],
        help="Boot image source for the integrated ROM.",
    )
    parser.add_target_argument(
        "--with-led-chaser",
        action="store_true",
        help="Enable the eight user LEDs.",
    )
    parser.add_target_argument(
        "--with-litedram",
        action="store_true",
        help="Use VCU118 DDR4 channel C1 through LiteDRAM as main_ram.",
    )
    parser.add_target_argument(
        "--litedram-size",
        default=0x40000000,
        type=lambda value: int(value, 0),
        help="Mapped LiteDRAM main_ram size in bytes.",
    )
    parser.add_target_argument(
        "--vivado-incremental",
        action="store_true",
        help="Reserved for compatibility with the common FPGA Makefile.",
    )
    parser.set_defaults(cpu_type="raptor", cpu_variant="linux32")

    args = parser.parse_args()
    soc_kwargs = dict(parser.soc_argdict)
    builder_kwargs = dict(parser.builder_argdict)
    has_integrated_rom_init = soc_kwargs.get("integrated_rom_init") not in (
        None,
        [],
        "",
    )

    if args.boot_mode == "custom":
        if not has_integrated_rom_init:
            parser.error(
                "--boot-mode=custom requires --integrated-rom-init=<path>"
            )
        builder_kwargs["compile_software"] = False
    else:
        if has_integrated_rom_init:
            parser.error(
                "--boot-mode=bios cannot be combined with --integrated-rom-init"
            )
        if not builder_kwargs.get("compile_software", True):
            parser.error("--boot-mode=bios requires software compilation")

    soc = RaptorVCU118SoC(
        sys_clk_freq=int(args.sys_clk_freq),
        with_litedram=args.with_litedram,
        litedram_size=args.litedram_size,
        with_led_chaser=args.with_led_chaser,
        **soc_kwargs,
    )

    builder = Builder(soc, **builder_kwargs)
    if args.build:
        builder.build(build_name="xilinx_vcu118", **parser.toolchain_argdict)


if __name__ == "__main__":
    main()