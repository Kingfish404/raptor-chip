#!/usr/bin/env python3
"""Raptor SoC on Arty A7-100T: DDR3, MII Ethernet and the CPU's JTAG TAP."""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "cores"))

from migen import ClockDomain, ClockSignal, ResetSignal, Signal
from migen.genlib.cdc import MultiReg
from migen.genlib.resetsync import AsyncResetSynchronizer
from litex.build.generic_platform import IOStandard, Misc, Pins, Subsignal
from litex.build.parser import LiteXArgumentParser
from litex.gen import LiteXModule
from litex.soc.cores.cpu import CPUS
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc_core import SoCCore
from litex_boards.platforms import digilent_arty
from litex_boards.targets.digilent_arty import _CRG
from litedram.modules import MT41K128M16
from litedram.phy.s7ddrphy import A7DDRPHY
from liteeth.phy.mii import LiteEthPHYMII
from cpu.raptor.core import Raptor


class SampledJTAG(LiteXModule):
    """Oversample the external TAP in its CPU domain; TCK is never a clock tree."""

    def __init__(self, cpu, pads):
        tck, tms, tdi = Signal(), Signal(reset=1), Signal()
        previous = Signal()
        self.specials += [
            MultiReg(pads.tck, tck, "cpu"),
            MultiReg(pads.tms, tms, "cpu", reset=1),
            MultiReg(pads.tdi, tdi, "cpu"),
        ]
        self.sync.cpu += previous.eq(tck)
        tdo = Signal()
        cpu.cpu_params.update(
            i_jtag_trst_n=~ResetSignal("cpu"),
            i_jtag_tck_en=tck & ~previous,
            i_jtag_tms=tms,
            i_jtag_tdi=tdi,
            o_jtag_tdo=tdo,
        )
        self.comb += pads.tdo.eq(tdo)


class RaptorArtySoC(SoCCore):
    csr_map = {"ctrl": 0, "identifier_mem": 1, "timer0": 2, "uart": 3}
    interrupt_map = {"uart": 0, "timer0": 1}

    def __init__(self, sys_clk_freq=20_000_000, with_litedram=True,
                 litedram_size=0x10000000, with_ethernet=False,
                 with_led_chaser=False, **kwargs):
        if sys_clk_freq not in (20_000_000, 25_000_000, 50_000_000, 100_000_000):
            raise ValueError("Arty CPU clock must be 20, 25, 50 or 100 MHz")
        if with_litedram and litedram_size != 0x10000000:
            raise ValueError("Arty has exactly 256 MiB DDR3")
        if with_litedram and kwargs.get("integrated_main_ram_size", 0):
            raise ValueError("DDR3 requires --integrated-main-ram-size=0")
        ram_bytes = kwargs.get("integrated_main_ram_size", 0x20000)
        if not with_litedram and (not 0x4000 <= ram_bytes <= 0x100000 or
                                  ram_bytes & (ram_bytes - 1)):
            raise ValueError("BRAM size must be a power of two between 16 KiB and 1 MiB")
        # DDR3 runs at 320 MHz / 640 MT/s, below the board's 667 MT/s rating.
        # The CPU can be slower while the DDR3 DLL remains in its operating range.
        fabric_hz = 80_000_000
        platform = digilent_arty.Platform(variant="a7-100", toolchain="vivado")
        platform.raptor_cpu_clock_domain = "cpu"
        CPUS["raptor"] = Raptor
        kwargs["cpu_type"] = "raptor"
        kwargs.setdefault("cpu_variant", "linux32")
        kwargs.setdefault("integrated_rom_size", 0x10000)
        kwargs.setdefault("integrated_sram_size", 0x2000)
        kwargs.setdefault("integrated_main_ram_size", 0 if with_litedram else 0x20000)
        kwargs.setdefault("uart_baudrate", 115200)
        kwargs.setdefault("uart_fifo_depth", 64)
        kwargs.setdefault("ident", "Raptor LiteX SoC on Arty A7-100T")
        kwargs["bus_data_width"] = 64
        super().__init__(platform, fabric_hz, **kwargs)
        self.cpu.pmem_size = litedram_size if with_litedram else kwargs["integrated_main_ram_size"]
        self.add_config("BIOS_NO_BOOT")
        self.add_config("CPU_CLOCK_FREQUENCY", sys_clk_freq)
        self.crg = _CRG(platform, fabric_hz, with_dram=with_litedram)
        self.crg.cd_cpu = ClockDomain("cpu")
        if sys_clk_freq == fabric_hz:
            self.comb += self.crg.cd_cpu.clk.eq(self.crg.cd_sys.clk)
            self.specials += AsyncResetSynchronizer(self.crg.cd_cpu, ResetSignal("sys"))
        else:
            self.crg.pll.create_clkout(self.crg.cd_cpu, sys_clk_freq)
        # The PLL domains are related. Keep their relationship for timing;
        # LiteX's AXI CDC marks the synchronizers and constrains FIFO pointers.

        if with_litedram:
            self.ddrphy = A7DDRPHY(platform.request("ddram"), memtype="DDR3",
                                  nphases=4, sys_clk_freq=fabric_hz)
            self.add_sdram("sdram", phy=self.ddrphy,
                           module=MT41K128M16(fabric_hz, "1:4"),
                           size=litedram_size, l2_cache_size=8192)
        if with_ethernet:
            clocks, pads = platform.request("eth_clocks"), platform.request("eth")
            self.ethphy = LiteEthPHYMII(clocks, pads)
            self.mem_map["ethmac"] = 0x18000000
            self.add_ethernet(phy=self.ethphy, data_width=8, nrxslots=2, ntxslots=2,
                              with_timing_constraints=False)
            # Constrain the physical clock ports: aliases on eth_*_clk nets
            # disappear during synthesis. DP83848J (SNLS250E, table 5.6):
            # RX clock-to-data 10..30 ns; TX setup 10 ns, hold 0 ns.
            # Reserve another +/-1 ns for board/package clock-data skew.
            platform.add_platform_command(
                "create_clock -name arty_eth_rx -period 40 [get_ports {rxclk}]",
                rxclk=clocks.rx)
            platform.add_platform_command(
                "create_clock -name arty_eth_tx -period 40 [get_ports {txclk}]",
                txclk=clocks.tx)
            for bound, delay in (("min", 9.0), ("max", 31.0)):
                platform.add_platform_command(
                    f"set_input_delay -clock arty_eth_rx -{bound} {delay} "
                    "[get_ports {{ {data}[*] {valid} {error} }}]",
                    data=pads.rx_data, valid=pads.rx_dv, error=pads.rx_er)
            for bound, delay in (("min", -1.0), ("max", 11.0)):
                platform.add_platform_command(
                    f"set_output_delay -clock arty_eth_tx -{bound} {delay} "
                    "[get_ports {{ {data}[*] {enable} }}]",
                    data=pads.tx_data, enable=pads.tx_en)
            platform.add_false_path_constraints(self.crg.cd_sys.clk, clocks.rx, clocks.tx)
        platform.add_platform_command(
            "set raptor_cdc_cells [get_cells -hier -quiet -filter "
            "{{NAME =~ *xilinxmultiregimpl*}}]; "
            "if {{[llength $raptor_cdc_cells] > 0}} "
            "{{set_property ASYNC_REG TRUE $raptor_cdc_cells}}")
        timing = HERE / "scripts/arty_timing.tcl"
        platform.toolchain.bitstream_commands.extend([
            f'source "{timing}"', "raptor_arty_check_timing {build_name}"])

        # Preserve the existing Arty fixture's ChipKIT CPU JTAG wiring.
        platform.add_extension([("raptor_jtag", 0,
            Subsignal("tck", Pins("P17"), Misc("PULLDOWN TRUE")),
            Subsignal("tms", Pins("R17"), Misc("PULLUP TRUE")),
            Subsignal("tdi", Pins("U18"), Misc("PULLDOWN TRUE")),
            Subsignal("tdo", Pins("V17")), IOStandard("LVCMOS33"))])
        self.jtag = SampledJTAG(self.cpu, platform.request("raptor_jtag"))
        if with_led_chaser:
            from litex.soc.cores.led import LedChaser
            self.leds = LedChaser(platform.request_all("user_led"), fabric_hz)


def main():
    parser = LiteXArgumentParser(platform=digilent_arty.Platform,
                                description=__doc__)
    parser.add_target_argument("--sys-clk-freq", type=float, default=20e6,
                               help="CPU clock; DDR3 fabric remains at 80 MHz.")
    parser.add_target_argument("--boot-mode", choices=("bios", "custom"), default="bios")
    parser.add_target_argument("--with-litedram", action="store_true")
    parser.add_target_argument("--litedram-size", type=lambda s: int(s, 0), default=0x10000000)
    parser.add_target_argument("--with-ethernet", action="store_true")
    parser.add_target_argument("--eth-speed", type=int, choices=(100,), default=100)
    parser.add_target_argument("--with-led-chaser", action="store_true")
    parser.add_target_argument("--export-ethernet-csr")
    parser.add_target_argument("--vivado-incremental", action="store_true")
    parser.add_target_argument("--synth-only", action="store_true")
    parser.set_defaults(cpu_type="raptor", cpu_variant="linux32")
    args = parser.parse_args()
    soc_kwargs, builder_kwargs = dict(parser.soc_argdict), dict(parser.builder_argdict)
    if args.boot_mode == "custom":
        if not soc_kwargs.get("integrated_rom_init"):
            parser.error("custom boot requires --integrated-rom-init")
        builder_kwargs["compile_software"] = False
    elif soc_kwargs.get("integrated_rom_init"):
        parser.error("BIOS boot cannot use --integrated-rom-init")
    soc = RaptorArtySoC(sys_clk_freq=int(args.sys_clk_freq), with_litedram=args.with_litedram,
                        litedram_size=args.litedram_size, with_ethernet=args.with_ethernet,
                        with_led_chaser=args.with_led_chaser, **soc_kwargs)
    if args.synth_only:
        soc.platform.toolchain.pre_optimize_commands.append("exit 0")
    builder = Builder(soc, **builder_kwargs)
    if args.export_ethernet_csr:
        if not args.with_ethernet:
            parser.error("--export-ethernet-csr requires --with-ethernet")
        # Finalization exports the same CSR layout used by the actual bitstream.
        soc.finalize()
        from litex.soc.integration.export import get_csr_json
        output = Path(args.export_ethernet_csr)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(get_csr_json(soc=soc, csr_regions=soc.csr_regions,
                                       constants=soc.constants, mem_regions=soc.mem_regions))
    else:
        run_gateware = (args.build or args.synth_only) and builder.compile_gateware
        builder.build(build_name="arty_a7_t100", run=run_gateware,
                      **parser.toolchain_argdict)


if __name__ == "__main__":
    main()
