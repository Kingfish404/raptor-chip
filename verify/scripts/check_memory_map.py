#!/usr/bin/env python3
"""Check replicated hardware, simulator and firmware map constants against JSON."""

import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
MAP = json.loads((ROOT / "hdl/configs/memory_map.json").read_text())


def number(value):
    return int(value, 0) if value.lower().startswith("0x") else int(value, 16)


def require(condition, description):
    if not condition:
        raise ValueError(description)


def source(path):
    return (ROOT / path).read_text()


def contains(path, pattern, description):
    require(re.search(pattern, source(path), re.MULTILINE | re.DOTALL) is not None,
            f"{path}: {description}")


def same(path, pattern, expected, description):
    match = re.search(pattern, source(path), re.MULTILINE)
    require(match is not None, f"{path}: missing {description}")
    require(number(match.group(1).replace("_", "")) == expected,
            f"{path}: wrong {description}: {match.group(1)}")


def check():
    regions = MAP["regions"]
    profiles = MAP["profiles"]
    require(MAP["address_bits"] == 32, "physical address width changed")
    for name, entry in regions.items():
        base = number(entry["base"])
        size = number(entry.get("size", entry.get("max_size")))
        require(0 <= base < base + size <= 1 << 32, f"{name}: outside physical map")
    require(regions["litex_uart"]["base"] == "0x11001800", "UART must remain CSR slot 3")
    require(number(regions["main_ram"]["base"]) +
            number(regions["main_ram"]["max_size"]) == 1 << 32,
            "2 GiB RAM must end exactly at the 4 GiB boundary")
    for name, entry in profiles.items():
        size = number(entry["ram_size"])
        require(0 < size <= number(regions["main_ram"]["max_size"]),
                f"{name}: invalid RAM size")
        if "rv32_linux_size" in entry:
            require(number(entry["rv32_linux_size"]) <= size,
                    f"{name}: RV32 Linux exceeds hardware RAM")

    same("hdl/rapt_pkg.sv", r"SramBase\s*=\s*32'h([0-9a-fA-F_]+)",
         number(regions["sram"]["base"]), "SRAM base")
    same("hdl/rapt_pkg.sv", r"SramBytes\s*=\s*32'h([0-9a-fA-F_]+)",
         number(regions["sram"]["size"]), "SRAM size")
    contains("hdl/rapt_pkg.sv", r"PmemEnd\s*=\s*64'h80000000\s*\+\s*64'\(PmemBytes\)",
             "PMEM end must be widened before addition")
    contains("hdl/rapt_pkg.sv", r"addr_in_pmem\(\s*addr\s*\)", "PMEM PMA helper")
    for start, end in (("11000000", "12000000"), ("18000000", "19000000")):
        contains("hdl/rapt_pkg.sv", rf"'h{start}\s*&&\s*a\s*<\s*'h{end}",
                 f"low device window {start}")
    mmio = source("hdl/rapt_pkg.sv").split("function automatic logic addr_mmio", 1)[1].split(
        "endfunction", 1)[0]
    require("32'hc0000000" not in mmio.lower() and "32'hf000" not in mmio.lower(),
            "RTL MMIO skip must not cover high RAM or legacy aliases")

    same("fpga/litex/cores/cpu/raptor/core.py", r'"csr":\s*(0x[\da-fA-F_]+)',
         number(regions["litex_csr"]["base"]), "CPU CSR base")
    same("fpga/litex/cores/cpu/raptor/core.py", r'"main_ram":\s*(0x[\da-fA-F_]+)',
         number(regions["main_ram"]["base"]), "CPU RAM base")
    contains("fpga/litex/cores/cpu/raptor/core.py", r"io_regions\s*=\s*\{0x1000_0000:\s*0x1000_0000\}",
             "CPU low I/O region")
    config = "fpga/litex/mk/config.mk"
    for board, key in (("mlk_cu07_ku15p", "ku15p_mig"),
                       ("mlk_cu08_ku15p", "ku15p_mig"),
                       ("alinx_axau15", "axau15_mig")):
        same(config, rf"BOARD_{board}_MIG_SIZE\s*:=\s*(0x[\da-fA-F_]+)",
             number(profiles[key]["ram_size"]), f"{board} MIG size")
    contains("fpga/litex/Makefile", r"LINUX_FPGA_RAM_SIZE\s*\?=.*LINUX_XLEN.*0x80000000.*0x40000000",
             "RV32 Linux 1 GiB cap")
    same("fpga/litex/Makefile", r"LINUX_FPGA_UART_BASE\s*:=\s*(0x[\da-fA-F_]+)",
         number(regions["litex_uart"]["base"]), "Linux UART base")
    for board in ("ku15p_soc.py", "alinx_axau15.py", "xilinx_vcu118.py",
                  "tang_mega_138k_pro.py", "raptor_soc.py"):
        contains(f"fpga/litex/{board}", r'kwargs\["bus_data_width"\]\s*=\s*64',
                 "64-bit Wishbone setting must override LiteX's CLI default")

    same("sim/include/common.h", r"#define MBASE\s+(0x[\da-fA-F_]+)",
         number(regions["main_ram"]["base"]), "NPC RAM base")
    same("sim/include/common.h", r"#ifdef RAPT_LARGE_PMEM\s*#define MSIZE\s+(0x[\da-fA-F_]+)",
         number(profiles["npc_large"]["ram_size"]), "NPC large RAM size")
    same("sim/csrc/mem/memory.cc", r"#define LITEX_UART_HW_BASE\s+(0x[\da-fA-F_]+)",
         number(regions["litex_uart"]["base"]), "NPC LiteUART base")
    contains("sim/csrc/mem/memory.cc", r"MAP_PRIVATE\s*\|\s*MAP_ANONYMOUS", "sparse 2 GiB RAM")
    contains("sim/rtl/rapt_npc_soc.sv", r"RAPT_LARGE_PMEM.*?a\s*>=\s*32'h80000000",
             "NPC RTL 2 GiB window")
    for xlen in (32, 64):
        same(f"nemu/configs/riscv{xlen}_ref_2g_defconfig",
             r"CONFIG_MSIZE=(0x[\da-fA-F_]+)",
             number(profiles["nemu_large"]["ram_size"]), f"NEMU RV{xlen} size")
    contains("nemu/src/memory/paddr.c", r"CONFIG_RAPTOR_PMEM_2G.*?mmap\(",
             "NEMU sparse 2 GiB RAM")
    contains("fpga/litex/firmware/linux-fpga/litex-soc.dts.in",
             r"reg\s*=\s*<0x80000000\s+@MEM_SIZE@>", "Linux DT RAM template")
    contains("fpga/litex/scripts/add_linux_ethernet_dts.py",
             r"0x18000000\s*<=\s*address.*?0x19000000", "Ethernet buffer aperture")
    contains("fpga/litex/scripts/add_linux_sdcard_dts.py",
             r"0x11000000\s*<=\s*base.*?0x12000000", "SD CSR aperture")
    for path in ("hdl/rapt_pkg.sv", "sim/csrc/mem/memory.cc", "nemu/src/device/serial.c"):
        require("0xf0001800" not in source(path).lower(), f"{path}: old UART alias")
    contains("hdl/rapt_pkg.sv", r"a >= 'h00100000 && a < 'h00101000", "test finisher aperture")
    contains("hdl/rapt_pkg.sv", r"a >= 'h21000000 && a < 'h21200000", "VGA device aperture")
    require(number(regions["vga"]["base"]) == 0x21000000 and number(regions["vga"]["size"]) == 0x200000,
            "VGA aperture must match rapt_pkg::addr_mapped")
    import subprocess
    import sys
    subprocess.run([sys.executable, str(ROOT / "verify/scripts/gen_platform_header.py"), "--check"], check=True)
    print("PASS: hdl/configs/memory_map.json matches RTL, LiteX, firmware, NPC, NEMU and raptor_platform.h")


if __name__ == "__main__":
    check()
