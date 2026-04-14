#
# This file is part of LiteX.
#
# Copyright (c) 2023 Florent Kermarrec <florent@enjoy-digital.fr>
# Copyright (c) 2025 Yu Jin <lambda.jinyu@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause

import os
import hashlib

from migen import *

from litex.gen import *

from litex.soc.interconnect import axi
from litex.soc.integration.soc import SoCRegion

from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV32

# Variants -----------------------------------------------------------------------------------------

CPU_VARIANTS = {
    "standard": "raptor",
    "linux": "raptor",
}

# Per-variant configuration.
VARIANT_CONFIGS = {
    "standard": {
        "arch": "rv32imac_zicntr_zicond_zicsr_zifencei_zba_zbb_zbs",
        "abi": "ilp32",
        "gcc_flags": "",
        "verilog_defines": [],
        "icache_size": 512,
        "icache_ways": 1,
        "icache_block_size": 16,
        "dcache_size": 256,
        "dcache_ways": 2,
        "dcache_block_size": 8,
    },
    "linux": {
        "arch": "rv32imac_zicntr_zicond_zicsr_zifencei_zba_zbb_zbs",
        "abi": "ilp32",
        "gcc_flags": "",
        "verilog_defines": [],
        "icache_size": 512,
        "icache_ways": 1,
        "icache_block_size": 16,
        "dcache_size": 256,
        "dcache_ways": 2,
        "dcache_block_size": 8,
    },
}

# Raptor (Sparrow) ---------------------------------------------------------------------------------


class ysyx(CPU):
    category = "softcore"
    family = "riscv"
    name = "raptor-sparrow"
    human_name = "raptor-sparrow"
    variants = CPU_VARIANTS
    data_width = 32
    endianness = "little"
    gcc_triple = ("riscv64-elf", "riscv64-linux-gnu", "riscv64-unknown-elf")
    linker_output_format = "elf32-littleriscv"
    nop = "nop"
    io_regions = {
        0x0200_0000: 0x000C_0000,  # CLINT
        0x0C00_0000: 0x0040_0000,  # PLIC (4MB actual)
        0x1000_0000: 0x0002_0000,  # Peripheral I/O
        0xA000_0000: 0x1000_0000,  # MMIO extension
    }

    # Command line configuration arguments.
    @staticmethod
    def args_fill(parser):
        # Note: --cpu-variant is already handled by LiteX's core parser.
        pass

    @staticmethod
    def args_read(args):
        pass

    # GCC Flags.
    @property
    def gcc_flags(self):
        vcfg = VARIANT_CONFIGS[self.variant]
        flags = f" -march={vcfg['arch']} -mabi={vcfg['abi']}"
        flags += f" -D__raptor__"
        if self.variant == "linux":
            flags += f" -D__riscv_plic__"
        return flags

    # Memory Mapping.
    @property
    def mem_map(self):
        return {
            "rom": 0x2000_0000,
            "sram": 0x0F00_0000,
            "main_ram": 0x8000_0000,
            "clint": 0x0200_0000,
            "plic": 0x0C00_0000,
            "csr": 0x1001_0000,
        }

    # Reserved Interrupts.
    @property
    def reserved_interrupts(self):
        return {"noirq": 0}

    def __init__(self, platform, variant="standard"):
        self.platform = platform
        self.variant = variant
        self.human_name = f"Raptor-Sparrow-{variant.upper()}"
        self.reset = Signal()
        self.interrupt = Signal(32)
        self.memory_buses = []

        axi_if = axi.AXIInterface(data_width=32, address_width=32, id_width=4)
        self.periph_buses = [axi_if]

        # Raptor Instance.
        # -----------------
        self.cpu_params = dict(
            # Clk / Rst.
            i_clock=ClockSignal("sys"),
            i_reset=(ResetSignal("sys") | self.reset),
            # Interrupt.
            i_io_interrupt=self.interrupt[0],
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
        self.add_sources(platform, variant)

    def set_reset_address(self, reset_address):
        self.xlen = 32
        self.reset_address = reset_address
        self.cpu_params.update(p_XLEN=Constant(self.xlen, 32))

    @staticmethod
    def add_sources(platform, variant):
        print(f"Adding Raptor (Sparrow) sources [variant={variant}]")
        base_dir = os.environ.get("YSYX_HOME")
        if base_dir is None:
            raise EnvironmentError(
                "Please set YSYX_HOME environment variable to the path of your YSYX repository."
            )
        vdir = os.path.join(base_dir, "nsim/build")

        # Cache-aware rebuild: only re-pack when variant changes.
        config_hash = hashlib.md5(f"{variant}".encode()).hexdigest()[:8]
        stamp = os.path.join(vdir, f".litex_stamp_{config_hash}")
        if not os.path.exists(stamp):
            os.makedirs(vdir, exist_ok=True)
            os.system(f"make -C {base_dir}/nsim pack")
            with open(stamp, "w") as f:
                f.write(variant)

        # Pass variant-specific Verilog defines.
        vcfg = VARIANT_CONFIGS.get(variant, {})
        for d in vcfg.get("verilog_defines", []):
            platform.add_verilog_define(d)

        platform.add_verilog_include_path(vdir)
        platform.add_source_dir(vdir)

    def add_soc_components(self, soc):
        # Set human name with variant.
        self.human_name = f"Raptor-Sparrow-{self.variant.upper()}"

        # Linux variant: set up OpenSBI region and CSR ordering.
        if self.variant == "linux":
            # Set UART/Timer0 CSRs to the ones used by OpenSBI.
            soc.csr.add("uart", n=2)
            soc.csr.add("timer0", n=3)

            # Add OpenSBI region in main RAM.
            soc.bus.add_region(
                "opensbi",
                SoCRegion(
                    origin=self.mem_map["main_ram"] + 0x00F0_0000,
                    size=0x8_0000,
                    cached=True,
                    linker=True,
                ),
            )

        # CPU metadata.
        vcfg = VARIANT_CONFIGS[self.variant]
        soc.add_config("CPU_COUNT", 1)
        soc.add_config("CPU_ISA", vcfg["arch"])
        soc.add_config("CPU_MMU", "sv32")

        # Cache parameters → Device Tree.
        soc.add_config("CPU_HAS_DCACHE")
        soc.add_config("CPU_HAS_ICACHE")
        soc.add_config("CPU_DCACHE_SIZE", vcfg["dcache_size"])
        soc.add_config("CPU_DCACHE_WAYS", vcfg["dcache_ways"])
        soc.add_config("CPU_DCACHE_BLOCK_SIZE", vcfg["dcache_block_size"])
        soc.add_config("CPU_ICACHE_SIZE", vcfg["icache_size"])
        soc.add_config("CPU_ICACHE_WAYS", vcfg["icache_ways"])
        soc.add_config("CPU_ICACHE_BLOCK_SIZE", vcfg["icache_block_size"])

        # PLIC as Bus Slave.
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

        # CLINT as Bus Slave.
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

    def _add_axi_dummy_responder(self, bus, name):
        """Dummy AXI slave that accepts all transactions and returns 0 on reads."""
        # -- Read channel ----------------------------------------------------
        ar_pending = Signal(name=f"{name}_ar_pending")
        ar_id = Signal(len(bus.ar.id), name=f"{name}_ar_id")
        self.sync += [
            If(
                bus.ar.valid & bus.ar.ready,
                ar_pending.eq(1),
                ar_id.eq(bus.ar.id),
            ).Elif(
                bus.r.valid & bus.r.ready,
                ar_pending.eq(0),
            )
        ]
        self.comb += [
            bus.ar.ready.eq(~ar_pending),
            bus.r.valid.eq(ar_pending),
            bus.r.data.eq(0),
            bus.r.resp.eq(0b00),
            bus.r.last.eq(1),
            bus.r.id.eq(ar_id),
        ]
        # -- Write channel ---------------------------------------------------
        aw_pending = Signal(name=f"{name}_aw_pending")
        w_done = Signal(name=f"{name}_w_done")
        aw_id = Signal(len(bus.aw.id), name=f"{name}_aw_id")
        self.sync += [
            If(
                bus.aw.valid & bus.aw.ready,
                aw_pending.eq(1),
                aw_id.eq(bus.aw.id),
            ).Elif(
                bus.b.valid & bus.b.ready,
                aw_pending.eq(0),
                w_done.eq(0),
            ),
            If(
                bus.w.valid & bus.w.ready & bus.w.last,
                w_done.eq(1),
            ),
        ]
        self.comb += [
            bus.aw.ready.eq(~aw_pending),
            bus.w.ready.eq(1),
            bus.b.valid.eq(aw_pending & w_done),
            bus.b.resp.eq(0b00),
            bus.b.id.eq(aw_id),
        ]

    def _add_plic_responder(self, bus):
        """Functional SiFive-compatible PLIC (32 sources, 2 contexts).

        Register map (offsets from PLIC base 0x0c00_0000):
          0x000000 + src*4   : Source priority   (RW)  src 0..32
          0x001000           : Pending bits       (RO)  1 word
          0x002000 + ctx*0x80: Enable bits        (RW)  ctx 0..1
          0x200000 + ctx*0x1000: Threshold        (RW)  ctx 0..1
          0x200004 + ctx*0x1000: Claim/Complete   (RW)  ctx 0..1
        """
        N_SRC = 33  # source 0 reserved + 1..32
        N_CTX = 2  # context 0 = M-mode, context 1 = S-mode

        # Registers (Memory elements).
        priority = Array([Signal(32, name=f"plic_pri_{i}") for i in range(N_SRC)])
        pending = Signal(32, name="plic_pending")  # bit per source (0..31)
        enable = Array([Signal(32, name=f"plic_en_{c}") for c in range(N_CTX)])
        threshold = Array([Signal(32, name=f"plic_thr_{c}") for c in range(N_CTX)])

        # --- AXI Read channel -----------------------------------------------
        ar_pending = Signal(name="plic_ar_pending")
        ar_id = Signal(len(bus.ar.id), name="plic_ar_id")
        ar_addr = Signal(22, name="plic_ar_addr")  # 22 bits = 4 MB

        rdata = Signal(32, name="plic_rdata")

        self.sync += [
            If(
                bus.ar.valid & bus.ar.ready,
                ar_pending.eq(1),
                ar_id.eq(bus.ar.id),
                ar_addr.eq(bus.ar.addr[:22]),
            ).Elif(
                bus.r.valid & bus.r.ready,
                ar_pending.eq(0),
            )
        ]

        # Combinational read decode.
        self.comb += [
            rdata.eq(0),  # default
            If(
                ar_addr < 0x001000,
                # Source priority: offset / 4 = source index
                rdata.eq(priority[ar_addr[2:9]]),
            )
            .Elif(
                ar_addr == 0x001000,
                rdata.eq(pending),
            )
            .Elif(
                (ar_addr >= 0x002000) & (ar_addr < 0x002100),
                # Enable: (addr - 0x2000) / 0x80 = context
                If(
                    ar_addr[7:14] == 0,
                    rdata.eq(enable[0]),
                ).Else(
                    rdata.eq(enable[1]),
                ),
            )
            .Elif(
                ar_addr == 0x200000,
                rdata.eq(threshold[0]),
            )
            .Elif(
                ar_addr == 0x200004,
                # Claim ctx 0: return 0 (no pending interrupt)
                rdata.eq(0),
            )
            .Elif(
                ar_addr == 0x201000,
                rdata.eq(threshold[1]),
            )
            .Elif(
                ar_addr == 0x201004,
                # Claim ctx 1: return 0 (no pending interrupt)
                rdata.eq(0),
            ),
        ]

        self.comb += [
            bus.ar.ready.eq(~ar_pending),
            bus.r.valid.eq(ar_pending),
            bus.r.data.eq(rdata),
            bus.r.resp.eq(0b00),
            bus.r.last.eq(1),
            bus.r.id.eq(ar_id),
        ]

        # --- AXI Write channel ----------------------------------------------
        aw_pending = Signal(name="plic_aw_pending")
        w_done = Signal(name="plic_w_done")
        aw_id = Signal(len(bus.aw.id), name="plic_aw_id")
        aw_addr = Signal(22, name="plic_aw_addr")
        w_data = Signal(32, name="plic_w_data")
        w_strobe = Signal(name="plic_w_strobe")  # single-cycle write pulse

        self.sync += [
            w_strobe.eq(0),
            If(
                bus.aw.valid & bus.aw.ready,
                aw_pending.eq(1),
                aw_id.eq(bus.aw.id),
                aw_addr.eq(bus.aw.addr[:22]),
            ).Elif(
                bus.b.valid & bus.b.ready,
                aw_pending.eq(0),
                w_done.eq(0),
            ),
            If(
                bus.w.valid & bus.w.ready & bus.w.last,
                w_done.eq(1),
                w_data.eq(bus.w.data),
                w_strobe.eq(1),
            ),
        ]

        # Sequential write decode.
        self.sync += [
            If(
                w_strobe,
                If(
                    aw_addr < 0x001000,
                    # Source priority
                    priority[aw_addr[2:9]].eq(w_data),
                )
                .Elif(
                    (aw_addr >= 0x002000) & (aw_addr < 0x002100),
                    # Enable bits
                    If(
                        aw_addr[7:14] == 0,
                        enable[0].eq(w_data),
                    ).Else(
                        enable[1].eq(w_data),
                    ),
                )
                .Elif(
                    aw_addr == 0x200000,
                    threshold[0].eq(w_data),
                )
                .Elif(
                    aw_addr == 0x201000,
                    threshold[1].eq(w_data),
                ),
                # Claim/Complete writes (0x200004, 0x201004): accepted, no-op
            )
        ]

        self.comb += [
            bus.aw.ready.eq(~aw_pending),
            bus.w.ready.eq(1),
            bus.b.valid.eq(aw_pending & w_done),
            bus.b.resp.eq(0b00),
            bus.b.id.eq(aw_id),
        ]

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        self.specials += Instance("ysyx", **self.cpu_params)

        # Functional PLIC (SiFive-compatible, 32 sources, 2 contexts).
        self._add_plic_responder(self.plicbus)

        # Dummy AXI responder for CLINT (handled internally by CPU RTL).
        self._add_axi_dummy_responder(self.clintbus, "clint")
