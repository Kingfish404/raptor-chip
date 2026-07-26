#!/usr/bin/env python3

import sys
from pathlib import Path


OLD = """#if defined(CSR_SPISDCARD_BASE) || defined(CSR_SDCARD_BASE)
	sdcardboot();
#endif
"""
NEW = """#if (defined(CSR_SPISDCARD_BASE) || defined(CSR_SDCARD_BASE)) && !defined(SDCARD_BOOT_DISABLE)
    sdcardboot();
#endif
"""


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("Usage: patch_litex_sdcard_boot.py <litex-repo-root>")

    path = Path(sys.argv[1]) / "litex/soc/software/bios/main.c"
    if not path.is_file():
        sys.exit(f"[patch_litex_sdcard_boot] not found: {path}")

    text = path.read_text()
    if "SDCARD_BOOT_DISABLE" in text:
        print(f"[patch_litex_sdcard_boot] SDCard boot policy already supported: {path}")
        return
    if text.count(OLD) != 1:
        sys.exit(
            f"[patch_litex_sdcard_boot] expected boot block not found exactly once: {path}"
        )

    path.write_text(text.replace(OLD, NEW))
    print(f"[patch_litex_sdcard_boot] patched: {path}")


if __name__ == "__main__":
    main()