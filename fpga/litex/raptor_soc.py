#!/usr/bin/env python3
#
# raptor_soc.py — LiteX SoC with Raptor CPU (Verilator simulation only)
#
# Usage:
#   python3 raptor_soc.py            # build sim
#   python3 raptor_soc.py --run      # build + run sim
#

import os
import sys
import argparse

# ------------------------------------------------------------------
# Patch LiteX CPU registry to include Raptor
# ------------------------------------------------------------------
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "cores"))

from cpu.raptor.core import Raptor

from migen import *
from litex.gen import *

from litex.build.generic_platform import Subsignal, Pins
from litex.build.io import CRG
from litex.build.sim import SimPlatform
from litex.build.sim.config import SimConfig
from litex.build.sim.verilator import verilator_build_args, verilator_build_argdict

from litex.soc.cores.cpu import CPUS
from litex.soc.integration.soc_core import SoCCore
from litex.soc.integration.builder import Builder, builder_args, builder_argdict
from litex.gen import LiteXModule

# Register Raptor CPU in LiteX.
CPUS["raptor"] = Raptor

# Sim IOs (minimal for Verilator) ------------------------------------------------------------------

_sim_io = [
    # Clk / Rst.
    ("sys_clk", 0, Pins(1)),
    ("sys_rst", 0, Pins(1)),
    # Serial.
    (
        "serial",
        0,
        Subsignal("source_valid", Pins(1)),
        Subsignal("source_ready", Pins(1)),
        Subsignal("source_data", Pins(8)),
        Subsignal("sink_valid", Pins(1)),
        Subsignal("sink_ready", Pins(1)),
        Subsignal("sink_data", Pins(8)),
    ),
]

# SoC ----------------------------------------------------------------------------------------------


class RaptorSoC(SoCCore):
    def __init__(
        self,
        platform=None,
        sys_clk_freq=int(10e6),
        trace=False,
        trace_start_cycle=0,
        trace_end_cycle=-1,
        **kwargs,
    ):
        # Force Raptor CPU.
        kwargs["cpu_type"] = "raptor"

        # Sim-only: always SimPlatform with sim UART.
        if platform is None:
            platform = SimPlatform("sim", _sim_io)
        if kwargs.get("uart_name", "serial") == "serial":
            kwargs["uart_name"] = "sim"

        # Default 64 MB main RAM at 0x80000000.
        # OpenSBI generic platform relocates FDT to _fw_start + 0x2200000 (~34 MB),
        # so we need at least 36 MB.  64 MB leaves headroom for kernel payloads.
        kwargs.setdefault("integrated_main_ram_size", 0x400_0000)

        # Set defaults (don't override if already provided by CLI).
        kwargs.setdefault("ident", "Raptor LiteX SoC")
        kwargs.setdefault("ident_version", True)
        # bus-timeout watchdog. Tightens default 1e6 to 4096 so unmapped
        # bus accesses raise wb.err -> AXI SLVERR -> in-CPU access-fault (P1)
        # promptly. See `cores/cpu/raptor/crt0.S` for the BIOS recovery path.
        kwargs.setdefault("bus_timeout", 4096)

        # SoCCore (includes CPU, bus, SRAM, UART, timer).
        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)

        # Sim CRG.
        self.crg = CRG(platform.request("sys_clk"))

        # Enable waveform tracing with exact cycle windowing.
        # LiteX's SimPlatform always requests a `sim_trace` pin; the C testbench
        # gates each dump on this value. We drive it from a cycle counter so
        # TRACE_START/TRACE_END are interpreted in clock cycles, not time units.
        if trace:
            start = max(0, int(trace_start_cycle))
            end = int(trace_end_cycle)
            if end != -1 and end < start:
                raise ValueError(
                    f"trace_end_cycle ({end}) must be -1 or >= trace_start_cycle ({start})"
                )

            cycle = Signal(64)
            self.sync += cycle.eq(cycle + 1)

            if end == -1:
                self.comb += platform.trace.eq(cycle >= start)
            else:
                # End is exclusive, so [start, end) spans exactly end-start cycles.
                self.comb += platform.trace.eq((cycle >= start) & (cycle < end))


# Build --------------------------------------------------------------------------------------------


def main():
    from litex.soc.integration.soc_core import soc_core_args, soc_core_argdict

    parser = argparse.ArgumentParser(description="Raptor LiteX SoC")
    # SoC / Builder / Verilator options.
    soc_core_args(parser)
    builder_args(parser)
    verilator_build_args(parser)

    # Raptor-specific options.
    parser.add_argument(
        "--sys-clk-freq",
        default=10e6,
        type=float,
        help="System clock frequency (default: 10 MHz)",
    )
    parser.add_argument(
        "--ram-init",
        default=None,
        type=str,
        help="Binary to load into main RAM at 0x80000000",
    )
    parser.add_argument(
        "--run",
        action="store_true",
        help="Run simulation after build (default: build only)",
    )
    parser.add_argument(
        "--sim-timeout",
        default=0,
        type=int,
        help="Simulation timeout in seconds (0 = no timeout)",
    )
    parser.add_argument(
        "--trace-start-cycle",
        default=0,
        type=int,
        help="Start waveform dump at cycle N (default: 0)",
    )
    parser.add_argument(
        "--trace-end-cycle",
        default=-1,
        type=int,
        help="Stop waveform dump at cycle N, exclusive (-1: no end)",
    )

    args = parser.parse_args()

    soc_kwargs = soc_core_argdict(args)

    # Load payload binary into main RAM.
    if args.ram_init is not None:
        from litex.soc.integration.common import get_mem_data

        # Auto-expand main_ram if payload exceeds configured size.
        payload_size = os.path.getsize(args.ram_init)
        current_size = soc_kwargs.get("integrated_main_ram_size", 0x80_0000)
        if payload_size > current_size:
            new_size = ((payload_size + 0x3F_FFFF) >> 22) << 22  # Round up to 4MB
            print(
                f"[INFO] Expanding main_ram: {current_size//(1024*1024)}MB -> "
                f"{new_size//(1024*1024)}MB (payload: {payload_size/(1024*1024):.1f}MB)"
            )
            soc_kwargs["integrated_main_ram_size"] = new_size

        soc_kwargs["integrated_main_ram_init"] = get_mem_data(
            args.ram_init,
            data_width=32,
            endianness="little",
            offset=0x8000_0000,
        )

    # ------------------------------------------------------------------
    # Sim path: Verilator.
    # ------------------------------------------------------------------
    soc = RaptorSoC(
        sys_clk_freq=int(args.sys_clk_freq),
        trace=args.trace,
        trace_start_cycle=args.trace_start_cycle,
        trace_end_cycle=args.trace_end_cycle,
        **soc_kwargs,
    )

    builder_kwargs = builder_argdict(args)
    builder = Builder(soc, **builder_kwargs)

    sim_config = SimConfig()
    sim_config.add_clocker("sys_clk", freq_hz=int(args.sys_clk_freq))
    sim_config.add_module("serial2console", "serial")

    verilator_kwargs = verilator_build_argdict(args)
    verilator_kwargs["run"] = args.run

    builder.build(
        sim_config=sim_config,
        **verilator_kwargs,
    )

    if args.run and args.sim_timeout > 0:
        print(f"\n[INFO] Simulation was limited to --sim-timeout={args.sim_timeout}s")


if __name__ == "__main__":
    main()
