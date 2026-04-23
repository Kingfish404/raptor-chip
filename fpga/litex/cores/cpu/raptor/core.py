#
# Raptor CPU — LiteX integration
#
# Dual-issue out-of-order RISC-V core (RV32/RV64 IMAC + Zb* extensions).
# AXI4 master bus, single external interrupt input.

import os

from migen import *
from litex.gen import *
from litex.soc.interconnect import axi
from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV32, CPU_GCC_TRIPLE_RISCV64
from litex.soc.integration.soc import SoCRegion

# Variants -----------------------------------------------------------------------------------------

CPU_VARIANTS = {
    "standard": "raptor",
    "linux": "raptor",
}

# GCC Flags ----------------------------------------------------------------------------------------

GCC_FLAGS = {
    "standard": "-march=rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs -mabi=ilp32",
    "linux": "-march=rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs -mabi=ilp32",
}

# Raptor -------------------------------------------------------------------------------------------


class Raptor(CPU):
    category = "softcore"
    family = "riscv"
    name = "raptor"
    human_name = "Raptor"
    variants = CPU_VARIANTS
    data_width = 32
    endianness = "little"
    gcc_triple = CPU_GCC_TRIPLE_RISCV32
    linker_output_format = "elf32-littleriscv"
    nop = "nop"
    # I/O region: 0xc0000000-0xffffffff (CSR, peripherals).
    # main_ram at 0x80000000 must NOT be in io_regions (it's cacheable RAM).
    io_regions = {0xC000_0000: 0x4000_0000}  # Origin, Length

    # Memory Mapping (ROM at 0x20000000 matches RTL RAPT_PC_INIT).
    @property
    def mem_map(self):
        return {
            "rom": 0x2000_0000,
            "sram": 0x0F00_0000,
            "main_ram": 0x8000_0000,
            "csr": 0xF000_0000,
        }

    # GCC Flags.
    @property
    def gcc_flags(self):
        flags = GCC_FLAGS[self.variant]
        flags += " -D__raptor__"
        return flags

    def __init__(self, platform, variant="standard"):
        self.platform = platform
        self.variant = variant
        self.human_name = f"Raptor ({variant})"
        self.reset = Signal()
        self.interrupt = Signal(32)

        # AXI4 master peripheral bus (connected to main SoC bus).
        axi_if = axi.AXIInterface(data_width=32, address_width=32, id_width=4)
        self.periph_buses = [axi_if]
        self.memory_buses = []

        # # #

        # CPU Instance parameters.
        self.cpu_params = dict(
            # Clock / Reset.
            i_clock=ClockSignal("sys"),
            i_reset=ResetSignal("sys") | self.reset,
            # Interrupt.
            i_io_interrupt=self.interrupt[0],
            # AXI4 Master — Write Address Channel.
            o_io_master_awvalid=axi_if.aw.valid,
            i_io_master_awready=axi_if.aw.ready,
            o_io_master_awid=axi_if.aw.id,
            o_io_master_awaddr=axi_if.aw.addr,
            o_io_master_awlen=axi_if.aw.len,
            o_io_master_awsize=axi_if.aw.size,
            o_io_master_awburst=axi_if.aw.burst,
            # AXI4 Master — Write Data Channel.
            o_io_master_wvalid=axi_if.w.valid,
            i_io_master_wready=axi_if.w.ready,
            o_io_master_wdata=axi_if.w.data,
            o_io_master_wstrb=axi_if.w.strb,
            o_io_master_wlast=axi_if.w.last,
            # AXI4 Master — Write Response Channel.
            i_io_master_bvalid=axi_if.b.valid,
            o_io_master_bready=axi_if.b.ready,
            i_io_master_bid=axi_if.b.id,
            i_io_master_bresp=axi_if.b.resp,
            # AXI4 Master — Read Address Channel.
            o_io_master_arvalid=axi_if.ar.valid,
            i_io_master_arready=axi_if.ar.ready,
            o_io_master_arid=axi_if.ar.id,
            o_io_master_araddr=axi_if.ar.addr,
            o_io_master_arlen=axi_if.ar.len,
            o_io_master_arsize=axi_if.ar.size,
            o_io_master_arburst=axi_if.ar.burst,
            # AXI4 Master — Read Data Channel.
            i_io_master_rvalid=axi_if.r.valid,
            o_io_master_rready=axi_if.r.ready,
            i_io_master_rid=axi_if.r.id,
            i_io_master_rdata=axi_if.r.data,
            i_io_master_rresp=axi_if.r.resp,
            i_io_master_rlast=axi_if.r.last,
        )

    def set_reset_address(self, reset_address):
        self.reset_address = reset_address

    @staticmethod
    def add_sources(platform, variant="standard"):
        raptor_home = os.environ.get(
            "RAPTOR_HOME",
            os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", ".."),
        )
        raptor_home = os.path.abspath(raptor_home)
        rtl_dir = os.path.join(raptor_home, "rtl_sv")

        # Pack all SV into a single preprocessed file for synthesis tools.
        pack_dir = os.path.join(raptor_home, "nsim", "build")
        pack_sv = os.path.join(pack_dir, "rapt_pack.sv")

        vflags = ""
        if variant == "linux":
            vflags = "VFLAGS='-DRAPT_LINUX'"

        if not os.path.exists(pack_sv):
            os.makedirs(pack_dir, exist_ok=True)
            ret = os.system(
                f"make -C {os.path.join(raptor_home, 'nsim')} pack {vflags}"
            )
            if ret != 0:
                raise RuntimeError(f"Failed to pack RTL (exit code {ret})")

        platform.add_source(pack_sv)

    def add_soc_components(self, soc):
        soc.add_config("CPU_HAS_DCACHE")
        soc.add_config("CPU_HAS_ICACHE")

        # Cache parameters for Device Tree.
        if self.variant == "linux":
            soc.add_config("CPU_DCACHE_SIZE", 4096)
            soc.add_config("CPU_DCACHE_WAYS", 4)
            soc.add_config("CPU_DCACHE_BLOCK_SIZE", 8)
            soc.add_config("CPU_ICACHE_SIZE", 8192)
            soc.add_config("CPU_ICACHE_WAYS", 2)
            soc.add_config("CPU_ICACHE_BLOCK_SIZE", 16)
        else:  # standard
            soc.add_config("CPU_DCACHE_SIZE", 512)
            soc.add_config("CPU_DCACHE_WAYS", 2)
            soc.add_config("CPU_DCACHE_BLOCK_SIZE", 8)
            soc.add_config("CPU_ICACHE_SIZE", 1024)
            soc.add_config("CPU_ICACHE_WAYS", 1)
            soc.add_config("CPU_ICACHE_BLOCK_SIZE", 16)

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        self.add_sources(self.platform, self.variant)
        self.specials += Instance("rapt", **self.cpu_params)
