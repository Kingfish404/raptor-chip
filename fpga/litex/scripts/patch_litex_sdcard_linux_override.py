#!/usr/bin/env python3
"""Embed Linux stage0/DTB/OpenSBI fixes in LiteX BIOS SD-card boot.

The SD card may keep an older contiguous boot.bin.  After LiteX BIOS copies it
to main RAM, the injected hook replaces stage0 and the DTB slot, then patches
the release OpenSBI header to keep its FDT relocation outside the Linux Image.
The large Linux payload remains the one read from the card.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


INCLUDE_ANCHOR = "#include <libfatfs/ff.h>\n"
BOOT_ANCHOR = """static void sdcardboot_from_bin(const char * filename)
{
\tuint32_t result;
\tresult = copy_file_from_sdcard_to_ram(filename, MAIN_RAM_BASE_VA, MAIN_RAM_SIZE);
\tif (result == 0)
\t\treturn;
\tboot(0, 0, 0, MAIN_RAM_BASE_VA);
}
"""
MARKER = "RAPTOR_SDCARD_LINUX_OVERRIDE"
FDT_MAGIC = 0xD00DFEED
RISCV_LUI_A1_MASK = 0x00000FFF
RISCV_LUI_A1_BITS = 0x000005B7
RISCV_ADD_A0_A0_A1 = 0x00B50533
RISCV_RET = 0x00008067


def c_array(name: str, data: bytes) -> str:
    rows = []
    for offset in range(0, len(data), 12):
        chunk = data[offset : offset + 12]
        rows.append("\t" + ", ".join(f"0x{byte:02x}" for byte in chunk) + ",")
    return f"static const uint8_t {name}[] = {{\n" + "\n".join(rows) + "\n};\n"


def parse_offset(value: str) -> int:
    try:
        offset = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer: {value}") from exc
    if offset <= 0 or offset > 0xFFFFFFFF:
        raise argparse.ArgumentTypeError("address/offset must be in 1..0xffffffff")
    return offset


def encode_lui_a1(value: int) -> int:
    if value < 0 or value > 0x7FFFFFFF or value & 0xFFF:
        raise ValueError("OpenSBI FDT offset must be positive and 4 KiB aligned")
    return (value & 0xFFFFF000) | RISCV_LUI_A1_BITS


def find_opensbi_fdt_lui(payload: bytes) -> tuple[int, int]:
    """Locate fw_next_arg1's ``lui a1, <FDT offset>`` instruction."""
    candidates: list[tuple[int, int]] = []
    limit = min(len(payload), 0x100000)
    for offset in range(0, limit - 12 + 1, 4):
        lui, add, ret = struct.unpack_from("<III", payload, offset)
        if (
            lui & RISCV_LUI_A1_MASK == RISCV_LUI_A1_BITS
            and add == RISCV_ADD_A0_A0_A1
            and ret == RISCV_RET
        ):
            candidates.append((offset, lui))
    if len(candidates) != 1:
        raise ValueError(
            "expected exactly one OpenSBI fw_next_arg1 LUI sequence in the "
            f"first 1 MiB, found {len(candidates)}"
        )
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("litex_root", type=Path)
    parser.add_argument("stage0", type=Path)
    parser.add_argument("dtb", type=Path)
    parser.add_argument("payload", type=Path)
    parser.add_argument("payload_offset", type=parse_offset)
    parser.add_argument("dtb_offset", type=parse_offset)
    parser.add_argument("dtb_address", type=parse_offset)
    parser.add_argument("main_ram_base", type=parse_offset)
    args = parser.parse_args()

    boot_c = args.litex_root / "litex/soc/software/bios/boot.c"
    try:
        source = boot_c.read_text()
        stage0 = args.stage0.read_bytes()
        dtb = args.dtb.read_bytes()
        payload = args.payload.read_bytes()
    except OSError as exc:
        print(f"[patch_litex_sdcard_linux_override] error: {exc}", file=sys.stderr)
        return 1

    if MARKER in source:
        print(f"[patch_litex_sdcard_linux_override] already patched: {boot_c}")
        return 0
    if source.count(INCLUDE_ANCHOR) != 1 or source.count(BOOT_ANCHOR) != 1:
        print(
            "[patch_litex_sdcard_linux_override] expected LiteX BIOS anchors "
            f"not found exactly once: {boot_c}",
            file=sys.stderr,
        )
        return 1
    if not stage0 or len(stage0) > 0x100000:
        print(
            f"[patch_litex_sdcard_linux_override] invalid stage0 size: {len(stage0)}",
            file=sys.stderr,
        )
        return 1
    if len(dtb) < 40 or struct.unpack_from(">I", dtb, 0)[0] != FDT_MAGIC:
        print("[patch_litex_sdcard_linux_override] invalid DTB", file=sys.stderr)
        return 1
    if struct.unpack_from(">I", dtb, 4)[0] != len(dtb):
        print(
            "[patch_litex_sdcard_linux_override] DTB file has trailing or missing bytes",
            file=sys.stderr,
        )
        return 1
    if args.dtb_address <= args.main_ram_base:
        print(
            "[patch_litex_sdcard_linux_override] DTB address must be above main RAM base",
            file=sys.stderr,
        )
        return 1
    try:
        opensbi_patch_offset, opensbi_old_lui = find_opensbi_fdt_lui(payload)
        opensbi_new_lui = encode_lui_a1(args.dtb_address - args.main_ram_base)
    except ValueError as exc:
        print(f"[patch_litex_sdcard_linux_override] error: {exc}", file=sys.stderr)
        return 1
    opensbi_old_fdt_address = args.main_ram_base + (opensbi_old_lui & 0xFFFFF000)

    embedded = f"""
/* {MARKER}: generated by Raptor's build wrapper. */
{c_array("raptor_linux_stage0", stage0)}
{c_array("raptor_linux_dtb", dtb)}
static int raptor_patch_opensbi_fdt_relocation(void)
{{
\tvolatile uint32_t *patch = (volatile uint32_t *)(uintptr_t)
\t\t(MAIN_RAM_BASE_VA + 0x{args.payload_offset + opensbi_patch_offset:08x}UL);
\tif (patch[0] != 0x{opensbi_old_lui:08x}UL ||
\t    patch[1] != 0x{RISCV_ADD_A0_A0_A1:08x}UL ||
\t    patch[2] != 0x{RISCV_RET:08x}UL) {{
\t\tprintf("Raptor: SD OpenSBI header mismatch; refusing unsafe boot\\n");
\t\treturn 0;
\t}}
\tpatch[0] = 0x{opensbi_new_lui:08x}UL;
\tprintf("Raptor: patched OpenSBI FDT relocation 0x{opensbi_old_fdt_address:08x}"
\t       " -> 0x{args.dtb_address:08x}\\n");
\treturn 1;
}}

static void raptor_sdcard_linux_override(void)
{{
\tmemcpy((void *)(uintptr_t)MAIN_RAM_BASE_VA,
\t\traptor_linux_stage0, sizeof(raptor_linux_stage0));
\tmemcpy((void *)(uintptr_t)(MAIN_RAM_BASE_VA + 0x{args.dtb_offset:08x}UL),
\t\traptor_linux_dtb, sizeof(raptor_linux_dtb));
\tprintf("Raptor: replaced SD stage0 (%lu bytes) and DTB (%lu bytes)\\n",
\t\t(unsigned long)sizeof(raptor_linux_stage0),
\t\t(unsigned long)sizeof(raptor_linux_dtb));
}}
"""
    source = source.replace(INCLUDE_ANCHOR, INCLUDE_ANCHOR + embedded)
    source = source.replace(
        BOOT_ANCHOR,
        """static void sdcardboot_from_bin(const char * filename)
{
\tuint32_t result;
\tresult = copy_file_from_sdcard_to_ram(filename, MAIN_RAM_BASE_VA, MAIN_RAM_SIZE);
\tif (result == 0)
\t\treturn;
\traptor_sdcard_linux_override();
\tif (!raptor_patch_opensbi_fdt_relocation())
\t\treturn;
\tboot(0, 0, 0, MAIN_RAM_BASE_VA);
}
""",
    )
    try:
        boot_c.write_text(source)
    except OSError as exc:
        print(f"[patch_litex_sdcard_linux_override] error: {exc}", file=sys.stderr)
        return 1

    print(
        f"[patch_litex_sdcard_linux_override] embedded stage0={len(stage0)} "
        f"DTB={len(dtb)} offset=0x{args.dtb_offset:x}; OpenSBI patch "
        f"payload+0x{opensbi_patch_offset:x}: 0x{opensbi_old_fdt_address:x} -> "
        f"0x{args.dtb_address:x}: {boot_c}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
