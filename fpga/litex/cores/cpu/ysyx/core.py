#
# This file is part of LiteX.
#
# Copyright (c) 2023 Florent Kermarrec <florent@enjoy-digital.fr>
# Copyright (c) 2025 Yu Jin <lambda.jinyu@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause

import os

from migen import *

from litex.gen import *

from litex.soc.interconnect import axi
from litex.soc.integration.soc import SoCRegion

from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV32

# Variants -----------------------------------------------------------------------------------------

CPU_VARIANTS = {
    "standard": "bird",
}
RISCV_ARCH = "rv32imac_zicsr_zifencei_zicntr"

# GCC Flags ----------------------------------------------------------------------------------------

GCC_FLAGS = {
    #                       /------------ Base ISA
    #                       |/------- Hardware Multiply + Divide
    #                       || /----- Atomics
    #                       || |/---- Compressed ISA
    #                       || ||/--- Single-Precision Floating-Point
    #                       || |||/-- Double-Precision Floating-Point
    #                       im[acfd](TODO)
    "standard": f"-march={RISCV_ARCH}   -mabi=ilp32",
}

# KianV ------------------------------------------------------------------------------------------


class ysyx(CPU):
    category = "softcore"
    family = "riscv"
    name = "sparrow"
    human_name = "sparrow"
    variants = CPU_VARIANTS
    data_width = 32
    endianness = "little"
    gcc_triple = ("riscv64-elf", "riscv64-linux-gnu", "riscv64-unknown-elf")
    linker_output_format = "elf32-littleriscv"
    nop = "nop"
    io_regions = {
        0x0200_0000: 0x000C_0000,
        0x0C00_0000: 0x0100_0000,
        0x1000_0000: 0x0002_0000,
        0xA000_0000: 0x1000_0000,
    }  # Origin, Length.

    # GCC Flags.
    @property
    def gcc_flags(self):
        flags = GCC_FLAGS[self.variant]
        flags += " -D__raptor__ "
        return flags

    @property
    def mem_map(self):
        return {
            "rom": 0x2000_0000,
            "sram": 0x8020_0000,
            "main_ram": 0x8000_0000,
            "clint": 0x0200_0000,
            "plic": 0x0C00_0000,
            "csr": 0x1001_0000,
            "mmap_m": 0xA000_0000,
        }

    def __init__(self, platform, variant="standard"):
        self.platform = platform
        self.variant = variant
        self.human_name = f"Sparrow-{variant.upper()}"
        self.reset = Signal()
        self.memory_buses = []  # Memory buses (Connected directly to LiteDRAM).

        axi_if = axi.AXIInterface(data_width=32, address_width=32, id_width=4)
        self.periph_buses = [axi_if]

        # Bird Instance.
        # -----------------
        self.cpu_params = dict(
            # Clk / Rst.
            i_clock=ClockSignal("sys"),
            i_reset=(ResetSignal("sys") | self.reset),
            # AXI4 Read Address
            o_io_master_arburst=axi_if.ar.burst,
            o_io_master_arsize=axi_if.ar.size,
            o_io_master_arlen=axi_if.ar.len,
            o_io_master_arid=axi_if.ar.id,
            o_io_master_araddr=axi_if.ar.addr,
            o_io_master_arvalid=axi_if.ar.valid,
            i_io_master_arready=axi_if.ar.ready,
            # AXI4 Read Data
            i_io_master_rid=axi_if.r.id,
            i_io_master_rlast=axi_if.r.last,
            i_io_master_rdata=axi_if.r.data,
            i_io_master_rresp=axi_if.r.resp,
            i_io_master_rvalid=axi_if.r.valid,
            o_io_master_rready=axi_if.r.ready,
            # AXI4 Write Address
            o_io_master_awburst=axi_if.aw.burst,
            o_io_master_awsize=axi_if.aw.size,
            o_io_master_awlen=axi_if.aw.len,
            o_io_master_awid=axi_if.aw.id,
            o_io_master_awaddr=axi_if.aw.addr,
            o_io_master_awvalid=axi_if.aw.valid,
            i_io_master_awready=axi_if.aw.ready,
            # AXI4 Write Data
            o_io_master_wlast=axi_if.w.last,
            o_io_master_wdata=axi_if.w.data,
            o_io_master_wstrb=axi_if.w.strb,
            o_io_master_wvalid=axi_if.w.valid,
            i_io_master_wready=axi_if.w.ready,
            # AXI4 Write Back
            i_io_master_bid=axi_if.b.id,
            i_io_master_bresp=axi_if.b.resp,
            i_io_master_bvalid=axi_if.b.valid,
            o_io_master_bready=axi_if.b.ready,
            # Parameters.
            p_XLEN=Constant(32, 32),
        )

        # Add Verilog sources.
        # --------------------
        self.add_sources(platform, variant)

    def set_reset_address(self, reset_address):
        self.xlen = 32
        self.reset_address = reset_address
        self.cpu_params.update(p_XLEN=Constant(self.xlen, 32))

    @staticmethod
    def add_sources(platform, variant):
        print("Adding Chip sources")
        base_dir = os.environ.get("YSYX_HOME")
        if base_dir is None:
            raise EnvironmentError(
                "Please set YSYX_HOME environment variable to the path of your YSYX repository."
            )
        os.system("make -C ${YSYX_HOME}/nsim pack")
        vdir = os.path.join(base_dir, "nsim/build")
        platform.add_verilog_include_path(vdir)
        platform.add_source_dir(vdir)
        print(base_dir)

    def add_soc_components(self, soc):
        soc.add_config("CPU_COUNT", 1)
        soc.add_config("CPU_ISA", RISCV_ARCH)
        soc.add_config("CPU_MMU", "sv32")

        self.plicbus = plicbus = axi.AXIInterface(
            data_width=32, address_width=32, id_width=4
        )
        soc.bus.add_slave(
            "plic",
            self.plicbus,
            region=SoCRegion(
                origin=soc.mem_map.get("plic"), size=0x40_0000, cached=False
            ),
        )

        self.clintbus = clintbus = axi.AXIInterface(
            data_width=32, address_width=32, id_width=4
        )
        soc.bus.add_slave(
            "clint",
            clintbus,
            region=SoCRegion(
                origin=soc.mem_map.get("clint"), size=0x1_0000, cached=False
            ),
        )
        soc.add_constant("uart_interrupt", 0x10000000)

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        self.specials += Instance("ysyx", **self.cpu_params)
