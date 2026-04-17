#!/usr/bin/env python3
#
# raptor_soc.py — LiteX SoC with Raptor CPU
#
# Copyright (c) 2024-2026 Yujin Wang
# SPDX-License-Identifier: BSD-2-Clause
#
# Usage:
#   python3 raptor_soc.py --cpu-variant=standard           # Verilator sim
#   python3 raptor_soc.py --cpu-variant=standard --build    # Build bitstream
#   python3 raptor_soc.py --build --load                    # Build + load FPGA

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
from litex.soc.integration.soc import SoCRegion
from litex.soc.interconnect import wishbone

# Register Raptor CPU in LiteX.
CPUS["raptor"] = Raptor

# AM Serial Shim (maps AM SERIAL_PORT 0x10000000 to $write for Verilator) -------------------------


class AMSerialShim(Module):
    """Wishbone slave that prints bytes written to it via $write (Verilator stdout).

    AM binaries use ``outb(0x10000000, ch)`` for console output. This shim
    intercepts those writes and forwards them to Verilator's stdout so
    serial2console-style output appears without modifying the AM source.
    """

    def __init__(self, platform):
        self.bus = wishbone.Interface(data_width=32, adr_width=30)

        wr_valid = Signal()
        wr_data = Signal(8)

        # Wishbone ack (single-cycle).
        self.sync += self.bus.ack.eq(self.bus.cyc & self.bus.stb & ~self.bus.ack)
        self.comb += [
            self.bus.dat_r.eq(0),
            wr_valid.eq(self.bus.cyc & self.bus.stb & self.bus.we & ~self.bus.ack),
            wr_data.eq(self.bus.dat_w[:8]),
        ]

        # Verilog blackbox: $write("%c", data) on valid write.
        self.specials += Instance(
            "am_serial_shim",
            i_clk=ClockSignal(),
            i_wr_valid=wr_valid,
            i_wr_data=wr_data,
        )
        platform.add_source(os.path.join(_here, "cores", "am_serial_shim.v"))


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
        sys_clk_freq=int(50e6),
        trace=False,
        trace_start_cycle=0,
        trace_end_cycle=-1,
        **kwargs,
    ):
        # Force Raptor CPU.
        kwargs["cpu_type"] = "raptor"

        # Use sim UART for Verilator simulation.
        if kwargs.get("uart_name", "serial") == "serial":
            kwargs["uart_name"] = "sim"

        # Default 64 MB main RAM at 0x80000000.
        # OpenSBI generic platform relocates FDT to _fw_start + 0x2200000 (~34 MB),
        # so we need at least 36 MB.  64 MB leaves headroom for kernel payloads.
        kwargs.setdefault("integrated_main_ram_size", 0x400_0000)

        # Set defaults (don't override if already provided by CLI).
        kwargs.setdefault("ident", "Raptor LiteX SoC")
        kwargs.setdefault("ident_version", True)

        # Platform (Verilator sim by default).
        platform = SimPlatform("sim", _sim_io)

        # SoCCore (includes CPU, bus, SRAM, UART, timer).
        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)

        # CRG (Clock Reset Generator).
        self.crg = CRG(platform.request("sys_clk"))

        # AM Serial Shim: bridge AM's outb(0x10000000, ch) to Verilator stdout.
        # SRAM has been moved to 0x0f000000, so 0x10000000 is free.
        # Note: cached=True satisfies LiteX region check; hardware does NOT cache
        # this address (0x10000000 is outside RTL addr_cacheable).
        am_serial = AMSerialShim(platform)
        self.submodules.am_serial = am_serial
        self.bus.add_slave(
            "am_serial",
            am_serial.bus,
            SoCRegion(origin=0x1000_0000, size=0x1000, cached=True),
        )

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
        default=50e6,
        type=float,
        help="System clock frequency (default: 50 MHz)",
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
                f"[INFO] Expanding main_ram: {current_size//(1024*1024)}MB → "
                f"{new_size//(1024*1024)}MB (payload: {payload_size/(1024*1024):.1f}MB)"
            )
            soc_kwargs["integrated_main_ram_size"] = new_size

        soc_kwargs["integrated_main_ram_init"] = get_mem_data(
            args.ram_init,
            data_width=32,
            endianness="little",
            offset=0x8000_0000,
        )

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
