#
# Raptor CPU — LiteX integration
#
# Dual-issue out-of-order RISC-V core (RV32/RV64 IMAC + Zb* extensions).
# AXI4 master bus, single external interrupt input.

import os
import subprocess

from migen import *
from litex.gen import *
from litex.soc.interconnect import axi
from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV32, CPU_GCC_TRIPLE_RISCV64
from litex.soc.integration.soc import SoCRegion

# Variants -----------------------------------------------------------------------------------------

CPU_VARIANTS = {
    "standard": "raptor",
    "linux": "raptor",
    "linux64": "raptor",
}

# GCC Flags ----------------------------------------------------------------------------------------

GCC_FLAGS = {
    "standard": "-march=rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs -mabi=ilp32",
    "linux": "-march=rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs -mabi=ilp32",
    "linux64": "-march=rv64imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs -mabi=lp64",
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
        if variant == "linux64":
            self.data_width = 64
            self.gcc_triple = CPU_GCC_TRIPLE_RISCV64
            self.linker_output_format = "elf64-littleriscv"
        else:
            self.data_width = 32
            self.gcc_triple = CPU_GCC_TRIPLE_RISCV32
            self.linker_output_format = "elf32-littleriscv"
        self.reset = Signal()
        # Debug-only extra CPU reset (e.g. wired to the J23 button) so an ILA
        # can be armed while the core is held in reset and then released to
        # capture the boot.  Defaults to 0 (no effect) when left unconnected.
        self.dbg_reset = Signal()
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
            i_reset=ResetSignal("sys") | self.reset | self.dbg_reset,
            # Interrupt.
            i_io_interrupt=self.interrupt[0],
            i_ext_irq_i=0,
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
    def add_sources(platform, variant="standard"):
        raptor_home = os.environ.get(
            "RAPTOR_HOME",
            os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", ".."),
        )
        raptor_home = os.path.abspath(raptor_home)
        rtl_dir = os.path.join(raptor_home, "rtl_sv")

        # Pack all SV into a single preprocessed file for synthesis tools.
        # nsim/Makefile scopes its build outputs per RAPT_CONFIG, so mirror
        # that layout here when locating the packed RTL.
        env_config_for_path = os.environ.get("RAPT_CONFIG", "") or "default"
        pack_dir = os.path.join(raptor_home, "nsim", "build", env_config_for_path)
        pack_sv = os.path.join(pack_dir, "rapt_pack.sv")

        # Allow the integrator (e.g. FPGA target) to override RTL preprocessor
        # defines via env. nsim/Makefile auto-invalidates the pack when VFLAGS
        # changes, so switching presets just works.
        env_vflags = os.environ.get("RAPT_PACK_VFLAGS", "")
        if variant in ("linux", "linux64") and "-DRAPT_LINUX" not in env_vflags:
            env_vflags = (env_vflags + " -DRAPT_LINUX").strip()
        if variant == "linux64" and "-DRAPT_RV64" not in env_vflags:
            env_vflags = (env_vflags + " -DRAPT_RV64").strip()

        # Allow the integrator to pick a config preset (configs/<name>/).
        env_config = os.environ.get("RAPT_CONFIG", "")

        # Always re-invoke the pack rule; the underlying Makefile uses file
        # mtimes plus a VFLAGS / RAPT_CONFIG stamp to skip the no-op case.
        os.makedirs(pack_dir, exist_ok=True)
        # Use subprocess instead of os.system: avoids shell injection on the
        # VFLAGS / RAPT_CONFIG pass-through and silences the Pylance
        # `os.system is deprecated` notice.
        cmd = ["make", "-C", os.path.join(raptor_home, "nsim"), "pack"]
        if env_vflags:
            cmd.append(f"VFLAGS={env_vflags}")
        if env_config:
            cmd.append(f"RAPT_CONFIG={env_config}")
        # Force the NPC (non-ysyxSoC) source set regardless of nsim's Kconfig
        # state: a leftover CONFIG_MODE="soc" (from ysyxsoc sim targets) would
        # otherwise pull ysyxSoC peripherals (PSRAM/SPI, `default_nettype none)
        # into the pack and break Vivado synthesis.
        cmd.append("CONFIG_MODE=")
        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(f"Failed to pack RTL (exit code {exc.returncode})") from exc
        if not os.path.exists(pack_sv):
            raise RuntimeError(f"Pack succeeded but {pack_sv} missing")

        platform.add_source(pack_sv)

    def add_soc_components(self, soc):
        soc.add_config("CPU_HAS_DCACHE")
        soc.add_config("CPU_HAS_ICACHE")

        # Pin the Raptor CLINT mtime tick rate to the LiteX sys_clk so that
        # `rdtime` advances once per cycle (MTIME_DIV=1). Without this the
        # RTL default (RAPT_CORE_CLOCK_MHZ=1000, RAPT_MTIME_FREQ_MHZ=10)
        # gives MTIME_DIV=100 and any firmware that assumes
        # `EE_TICKS_PER_SEC == sys_clk_freq` (e.g. CoreMark) reports
        # wall-clock times that are 100x too small.
        # Injected via RAPT_PACK_VFLAGS so it flows into the nsim pack rule
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

        # Cache parameters for Device Tree.
        if self.variant in ("linux", "linux64"):
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
