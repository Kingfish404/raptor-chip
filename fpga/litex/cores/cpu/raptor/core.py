#
# Raptor CPU — LiteX integration
#
# Dual-issue out-of-order RISC-V core (RV32/RV64 IMAC + Zb* extensions).
# AXI4 master bus, 31 external PLIC interrupt sources.

import os
import re
import subprocess
import sys

from migen import *
from litex.gen import *
from litex.soc.interconnect import axi
from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV32, CPU_GCC_TRIPLE_RISCV64
from litex.soc.integration.soc import SoCRegion

# Variants -----------------------------------------------------------------------------------------

CPU_VARIANTS = {
    "linux32": "raptor",
    "linux64": "raptor",
}

# GCC Flags ----------------------------------------------------------------------------------------

GCC_FLAGS = {
    "linux32": "-march=rv32imac_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs -mabi=ilp32",
    "linux64": "-march=rv64imac_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs -mabi=lp64",
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

    def __init__(self, platform, variant="linux32"):
        self.platform = platform
        self.variant = variant
        self.human_name = f"Raptor ({variant})"
        if variant == "linux64":
            self.data_width = 64
            self.gcc_triple = CPU_GCC_TRIPLE_RISCV64
            self.linker_output_format = "elf64-littleriscv"
        else:
            self.data_width = 32
            self.gcc_triple = CPU_GCC_TRIPLE_RISCV32
            self.linker_output_format = "elf32-littleriscv"
        self.reset = Signal()
        self.pmem_size = None  # Optional board-specific PMA window, in bytes.
        self.interrupt = Signal(32)

        # AXI4 master peripheral bus (connected to main SoC bus).
        axi_if = axi.AXIInterface(data_width=self.data_width, address_width=32, id_width=4)
        self.periph_buses = [axi_if]
        self.memory_buses = []

        # # #

        # CPU Instance parameters.
        self.cpu_params = dict(
            # Clock / Reset.
            i_clock=ClockSignal("sys"),
            i_reset=ResetSignal("sys") | self.reset,
            # Interrupt.
            # LiteX IRQ n maps to PLIC source n+1 (source 0 is reserved).
            # Raptor's ext_irq_i[31:1] packs source 1 into its low bit.
            # Route all sources: forwarding only bit 0 loses SDCard/Ethernet.
            i_io_interrupt=0,
            i_ext_irq_i=self.interrupt[:31],
            # AXI4 Master — Write Address Channel.
            o_io_master_awvalid=axi_if.aw.valid,
            i_io_master_awready=axi_if.aw.ready,
            o_io_master_awid=axi_if.aw.id,
            o_io_master_awaddr=axi_if.aw.addr,
            o_io_master_awlen=axi_if.aw.len,
            o_io_master_awsize=axi_if.aw.size,
            o_io_master_awburst=axi_if.aw.burst,
            o_io_master_awcache=axi_if.aw.cache,
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
            o_io_master_arcache=axi_if.ar.cache,
            # AXI4 Master — Read Data Channel.
            i_io_master_rvalid=axi_if.r.valid,
            o_io_master_rready=axi_if.r.ready,
            i_io_master_rid=axi_if.r.id,
            i_io_master_rdata=axi_if.r.data,
            i_io_master_rresp=axi_if.r.resp,
            i_io_master_rlast=axi_if.r.last,
            # JTAG (always-on at the cluster boundary). LiteX targets do not
            # expose a JTAG header for the Raptor core today, so park the
            # DTM in TLR by tying trst_n=0/tms=1/tdi=0; tdo is left floating.
            i_jtag_trst_n=0,
            i_jtag_tms=1,
            i_jtag_tdi=0,
            o_jtag_tdo=Signal(),
        )

    def set_reset_address(self, reset_address):
        self.reset_address = reset_address

    @staticmethod
    def add_sources(platform, variant="linux32", pmem_size=None):
        raptor_home = os.environ.get(
            "RAPTOR_HOME",
            os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", ".."),
        )
        raptor_home = os.path.abspath(raptor_home)
        rtl_dir = os.path.join(raptor_home, "hdl")

        # Do not invoke sim/Makefile: its Kconfig includes and shared exports
        # are not independent of concurrent simulator/other-XLEN builds.
        scripts = os.path.join(raptor_home, "fpga", "litex", "scripts")
        if scripts not in sys.path:
            sys.path.insert(0, scripts)
        from isolated_pack import pack
        from pathlib import Path

        # The Make prerequisite and direct Python entry share this isolated
        # preset/defines cache, without modifying simulator configuration.
        env_vflags = os.environ.get("RAPT_PACK_VFLAGS", "")
        if not any(flag == "-DRAPT_FPGA_DSP" or flag.startswith("-DRAPT_FPGA_DSP=")
                   for flag in env_vflags.split()):
            env_vflags = (env_vflags + " -DRAPT_FPGA_DSP=1").strip()
        if variant == "linux32" and any(
            flag == "-DRAPT_RV64" or flag.startswith("-DRAPT_RV64=")
            for flag in env_vflags.split()
        ):
            raise ValueError("VARIANT=linux32 conflicts with RAPT_PACK_VFLAGS defining RAPT_RV64")
        if pmem_size is not None:
            if not 0 < pmem_size <= 0x40000000 or pmem_size & (pmem_size - 1):
                raise ValueError("PMEM size must be a power of two up to 1 GiB (MMIO starts at 0xc0000000)")
            # Board geometry is authoritative, including for direct Python builds.
            wanted = f"-DRAPT_PMEM_BYTES={pmem_size}"
            if [f for f in env_vflags.split() if f.startswith("-DRAPT_PMEM_BYTES=")] != [wanted]:
                env_vflags = " ".join(f for f in env_vflags.split() if not f.startswith("-DRAPT_PMEM_BYTES="))
                env_vflags += " " + wanted
        if variant in ("linux32", "linux64") and "-DRAPT_LINUX" not in env_vflags:
            env_vflags = (env_vflags + " -DRAPT_LINUX").strip()
        if variant == "linux64" and "-DRAPT_RV64" not in env_vflags:
            env_vflags = (env_vflags + " -DRAPT_RV64").strip()

        # Allow the integrator to pick an RTL config preset (hdl/configs/<name>/).
        env_config = os.environ.get("RAPT_CONFIG", "") or "default"
        root = Path(os.environ.get("RAPT_PACK_ROOT", os.path.join(raptor_home, "fpga/litex/build/rtl")))
        pack_sv = pack(Path(raptor_home), root, env_config, env_vflags)
        platform.add_source(str(pack_sv))

    def add_software_packages(self, builder):
        private = os.environ.get("RAPT_LITEX_SOFTWARE_DIR", "")
        if private:
            private = os.path.abspath(private)
            if not os.path.isfile(os.path.join(private, "common.mak")):
                raise RuntimeError(f"Private LiteX software missing: {private}")
            builder.software_packages = [
                (name, os.path.join(private, name) if os.path.isfile(os.path.join(private, name, "Makefile")) else src)
                for name, src in builder.software_packages
            ]
            # Builder has no per-instance SOC_DIRECTORY override. Wrap only
            # this instance's emitter, not the shared builder module/global.
            original = builder._get_variables_contents
            def private_variables():
                content, count = re.subn(r"^SOC_DIRECTORY=.*$", lambda _: "SOC_DIRECTORY=" + os.path.dirname(private),
                                         original(), flags=re.MULTILINE)
                if count != 1:
                    raise RuntimeError("Cannot isolate LiteX SOC_DIRECTORY")
                return content
            builder._get_variables_contents = private_variables
        # Linux's embedded stage0/DTB belongs to this build, not to a shared
        # patched LiteX checkout (another preset can have a different CBOM size).
        bios_dir = os.environ.get("RAPT_BIOS_SOURCE_DIR", "")
        if bios_dir:
            bios_dir = os.path.abspath(bios_dir)
            if not os.path.isfile(os.path.join(bios_dir, "boot.c")):
                raise RuntimeError(f"Private BIOS sources missing: {bios_dir}")
            builder.software_packages = [
                (name, bios_dir if name == "bios" else src_dir)
                for name, src_dir in builder.software_packages
            ]

    def add_soc_components(self, soc):
        soc.add_config("CPU_HAS_DCACHE")
        soc.add_config("CPU_HAS_ICACHE")

        raptor_home = os.path.abspath(os.environ.get(
            "RAPTOR_HOME",
            os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", ".."),
        ))
        rapt_config = os.environ.get("RAPT_CONFIG", "") or "default"
        config_path = os.path.join(raptor_home, "hdl", "configs", rapt_config, "rapt_config.svh")
        with open(config_path, encoding="utf-8") as config_file:
            config_text = config_file.read()

        def config_int(name):
            match = re.search(rf"^`define {name}\s+(\d+)(?:\s+.*)?$", config_text, re.MULTILINE)
            if match is None:
                raise RuntimeError(f"{name} missing from {config_path}")
            return int(match.group(1))

        cache_block_size = config_int("RAPT_CACHE_LINE_BYTES")
        icache_ways = config_int("RAPT_L1I_N_WAYS")
        dcache_ways = config_int("RAPT_L1D_N_WAYS")
        icache_size = cache_block_size * (1 << config_int("RAPT_L1I_LEN")) * icache_ways
        dcache_size = cache_block_size * (1 << config_int("RAPT_L1D_LEN")) * dcache_ways

        # Pin the Raptor CLINT mtime tick rate to the LiteX sys_clk so that
        # `rdtime` advances once per cycle (MTIME_DIV=1). Without this the
        # RTL default (RAPT_CORE_CLOCK_MHZ=1000, RAPT_MTIME_FREQ_MHZ=10)
        # gives MTIME_DIV=100 and any firmware that assumes
        # `EE_TICKS_PER_SEC == sys_clk_freq` (e.g. CoreMark) reports
        # wall-clock times that are 100x too small.
        # Injected via RAPT_PACK_VFLAGS so it flows into the sim pack rule
        # (see add_sources below). Only set when the user hasn't already
        # pinned the rate themselves.
        sys_clk_mhz = max(1, int(round(soc.sys_clk_freq / 1_000_000)))
        existing = os.environ.get("RAPT_PACK_VFLAGS", "")
        extra = []
        if "-DRAPT_CORE_CLOCK_MHZ=" not in existing:
            extra.append(f"-DRAPT_CORE_CLOCK_MHZ={sys_clk_mhz}")
        if "-DRAPT_MTIME_FREQ_MHZ=" not in existing:
            extra.append(f"-DRAPT_MTIME_FREQ_MHZ={sys_clk_mhz}")
        if extra:
            os.environ["RAPT_PACK_VFLAGS"] = (existing + " " + " ".join(extra)).strip()

        # Cache parameters for Device Tree, derived from the selected RTL preset.
        soc.add_config("CPU_DCACHE_SIZE", dcache_size)
        soc.add_config("CPU_DCACHE_WAYS", dcache_ways)
        soc.add_config("CPU_DCACHE_BLOCK_SIZE", cache_block_size)
        soc.add_config("CPU_ICACHE_SIZE", icache_size)
        soc.add_config("CPU_ICACHE_WAYS", icache_ways)
        soc.add_config("CPU_ICACHE_BLOCK_SIZE", cache_block_size)

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        self.add_sources(self.platform, self.variant,
                         pmem_size=self.pmem_size)
        self.specials += Instance("rapt", **self.cpu_params)
