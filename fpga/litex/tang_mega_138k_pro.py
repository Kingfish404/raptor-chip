#!/usr/bin/env python3

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "cores"))

from cpu.raptor.core import Raptor

from migen import *
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen import *
from litex.build.parser import LiteXArgumentParser
from litex.soc.cores.clock.gowin_gw5a import GW5APLL
from litex.soc.cores.cpu import CPUS
from litex.soc.cores.led import LedChaser
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc_core import SoCCore

from litex_boards.platforms import sipeed_tang_mega_138k_pro


CPUS["raptor"] = Raptor

DEFAULT_FPGA_SYS_CLK = int(10e6)
DEFAULT_FPGA_SYNTH_MAXFAN = 24
DEFAULT_FPGA_ROUTE_MAXFAN = 8
DEFAULT_FPGA_BOOT_MODE = "bios"


class Platform(sipeed_tang_mega_138k_pro.Platform):
    def __init__(
        self,
        toolchain="gowin",
        synth_maxfan=DEFAULT_FPGA_SYNTH_MAXFAN,
        route_maxfan=DEFAULT_FPGA_ROUTE_MAXFAN,
    ):
        super().__init__(toolchain=toolchain)
        self.name = "sipeed_tang_mega_138k_pro"
        # NOTE: Tang Mega 138K Pro uses the GW5AST-LV138FPG676AES package; the
        # 138C variant override that works on the non-Pro PBGA484 part is
        # rejected by gw_sh `set_device` here. Keep the platform default
        # (GW5AST-138B). PnR density on the Pro must be addressed via
        # design-side levers (see docs-ref/uarch.memory-subsystem.md).
        # Gowin's Tcl frontend accepts `verilog_std=sysv2017`; without it, the
        # default LiteX flow falls back to Verilog 2001 and rejects the
        # SystemVerilog packages/packed structs in rapt_pack.sv.
        self.toolchain.options["verilog_std"] = "sysv2017"
        # Gowin was auto-promoting several ordinary high-fanout control/data
        # nets onto PRIMARY/LW clock resources, which exhausted clock routing
        # and produced PR0004 unrouted nets during PnR. Tighten the fanout
        # guidance so replication happens earlier and these nets stay off the
        # scarce global clock network.
        # NOTE: Gowin V1.9.x exposes no `globalclkmaxnum`-style cap (verified
        # against the IDE option catalog under data/options); the only fanout
        # knobs are -maxfan and -route_maxfan. Address PRIMARY exhaustion via
        # design-side levers (e.g. with_led_chaser=False, smaller ROB/RS/BTB)
        # rather than synthesis options.
        self.toolchain.options["maxfan"] = int(synth_maxfan)
        self.toolchain.options["route_maxfan"] = int(route_maxfan)
        self.toolchain.options["print_all_synthesis_warning"] = 1
        self.toolchain.options["show_all_warn"] = 1


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq):
        self.rst = Signal()
        self.cd_sys = ClockDomain()
        self.cd_por = ClockDomain()

        clk50 = platform.request("clk50")

        por_count = Signal(16, reset=2**16 - 1)
        por_done = Signal()
        self.comb += [
            self.cd_por.clk.eq(clk50),
            por_done.eq(por_count == 0),
        ]
        self.sync.por += If(~por_done, por_count.eq(por_count - 1))

        self.pll = pll = GW5APLL(devicename=platform.devicename, device=platform.device)
        self.comb += pll.reset.eq(~por_done | self.rst)
        pll.register_clkin(clk50, 50e6)
        pll.create_clkout(self.cd_sys, sys_clk_freq, with_reset=False)

        self.specials += AsyncResetSynchronizer(self.cd_sys, ~pll.locked)

        platform.toolchain.additional_cst_commands.append('INS_LOC "PLL" PLL_R[0]')


class RaptorTangMega138KSoC(SoCCore):
    def __init__(
        self,
        sys_clk_freq=DEFAULT_FPGA_SYS_CLK,
        synth_maxfan=DEFAULT_FPGA_SYNTH_MAXFAN,
        route_maxfan=DEFAULT_FPGA_ROUTE_MAXFAN,
        with_led_chaser=False,
        **kwargs,
    ):
        platform = Platform(
            toolchain="gowin",
            synth_maxfan=synth_maxfan,
            route_maxfan=route_maxfan,
        )

        kwargs["cpu_type"] = "raptor"
        kwargs.setdefault("cpu_variant", "linux32")
        kwargs.setdefault("ident", "Raptor LiteX SoC on Tang Mega 138K Pro")
        kwargs.setdefault("ident_version", True)
        kwargs.setdefault("uart_name", "serial")
        kwargs.setdefault("uart_baudrate", 115200)
        # Larger RX FIFO gives the IRQ-driven LiteX UART driver more slack
        # vs. our trap-entry latency (~32 GPR save/restore + dispatch). Keeps
        # back-to-back 64B SFL frames from overflowing the HW FIFO. Default
        # was 16 (1.4 ms @ 115200) — bump to 64 (5.6 ms).
        kwargs.setdefault("uart_fifo_depth", 64)
        kwargs.setdefault("integrated_rom_size", 0x8000)
        kwargs.setdefault("integrated_sram_size", 0x2000)
        kwargs.setdefault("integrated_main_ram_size", 0)
        # Tighten the wishbone interconnect timeout so that an access to
        # an unmapped address (e.g. a stray `mem_read 0xdeadbeef` from BIOS)
        # raises wb.err quickly. The AXI<->Wishbone bridge translates wb.err
        # to AXI SLVERR; combined with the in-CPU bus-error -> access-fault
        # path (P1) and the BIOS exception recovery (P2), an erroneous access
        # is reported and the BIOS prompt is restored without deadlock.
        # Default is 1e6 cycles (~100 ms @ 10 MHz); 4096 cycles (~410 us)
        # is plenty for any real slave on this SoC.
        kwargs.setdefault("bus_timeout", 4096)

        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)

        self.crg = _CRG(platform, sys_clk_freq)

        if with_led_chaser:
            # Pro platform exposes active-low LEDs as `led_n`. Off by default
            # because the chaser eats CLS and adds clock-fanout pressure on
            # an already-dense Pro PnR (PRIMARY 100%). Enable explicitly via
            # `--with-led-chaser` (Make: `WITH_LED_CHASER=1`).
            self.leds = LedChaser(
                pads=platform.request_all("led_n"),
                sys_clk_freq=sys_clk_freq,
            )


def main():
    parser = LiteXArgumentParser(
        platform=Platform,
        description="Raptor LiteX SoC on Tang Mega 138K Pro.",
    )
    parser.add_target_argument(
        "--sys-clk-freq",
        default=DEFAULT_FPGA_SYS_CLK,
        type=float,
        help="System clock frequency.",
    )
    parser.add_target_argument(
        "--synth-maxfan",
        default=DEFAULT_FPGA_SYNTH_MAXFAN,
        type=int,
        help="Gowin synthesis maxfan guideline for Tang Mega routing relief.",
    )
    parser.add_target_argument(
        "--route-maxfan",
        default=DEFAULT_FPGA_ROUTE_MAXFAN,
        type=int,
        help="Gowin PnR route maxfan guideline for Tang Mega routing relief.",
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
        help="Enable LedChaser (off by default on the Pro to relieve PnR density).",
    )
    parser.set_defaults(cpu_type="raptor", cpu_variant="linux32")

    args = parser.parse_args()

    soc_kwargs = dict(parser.soc_argdict)
    builder_kwargs = dict(parser.builder_argdict)
    has_integrated_rom_init = soc_kwargs.get("integrated_rom_init") not in (None, [], "")

    if args.boot_mode == "custom":
        if not has_integrated_rom_init:
            parser.error("--boot-mode=custom requires --integrated-rom-init=<path>")
        # Custom bring-up ROM fully replaces LiteX BIOS; skip software build.
        builder_kwargs["compile_software"] = False
    else:
        if has_integrated_rom_init:
            parser.error("--boot-mode=bios cannot be combined with --integrated-rom-init; use --boot-mode=custom")
        if not builder_kwargs.get("compile_software", True):
            parser.error("--boot-mode=bios requires software compilation; remove --no-compile-software or use --boot-mode=custom")

    soc = RaptorTangMega138KSoC(
        sys_clk_freq=int(args.sys_clk_freq),
        synth_maxfan=args.synth_maxfan,
        route_maxfan=args.route_maxfan,
        with_led_chaser=args.with_led_chaser,
        **soc_kwargs,
    )

    builder = Builder(soc, **builder_kwargs)

    if args.build:
        builder.build(build_name="sipeed_tang_mega_138k_pro", **parser.toolchain_argdict)


if __name__ == "__main__":
    main()
