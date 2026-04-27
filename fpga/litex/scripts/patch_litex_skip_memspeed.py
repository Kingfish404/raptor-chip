#!/usr/bin/env python3
"""Patch LiteX BIOS to skip the auto-memspeed call after memtest.

Why
---
On Raptor (Tang Mega 138K Pro, BSRAM main_ram @ 0x80000000) the BIOS auto
`memspeed()` reliably hangs after printing "Write speed: X MiB/s" — likely
either the post-write `fence` (Raptor `fence` waiting on a writeback drain
that never asserts) or 128K consecutive cached loads exposing an LSU /
L1D backpressure bug. `memtest()` itself passes (writes + reads + compares
the entire 512 KB), so the memory path is functional; only the dedicated
speed loop hangs.

Until that RTL bug is fixed, this patch lets the BIOS reach the `litex>`
prompt so we can `serialboot` upload payloads (the entire reason the
bitstream was rebuilt with main_ram in the first place).

Idempotent. Restore via `git checkout -- litex/soc/software/bios/main.c`.
"""

from __future__ import annotations

import sys
from pathlib import Path

NEEDLE = "\tmemspeed((unsigned int *) MAIN_RAM_BASE, min(MAIN_RAM_SIZE, MEMTEST_DATA_SIZE), false, 0);"
REPLACEMENT = "\t/* Raptor: memspeed disabled (hangs in fence/read-loop) */ (void)0;"


def patch(litex_root: Path) -> None:
    main_c = litex_root / "litex/soc/software/bios/main.c"
    text = main_c.read_text()

    if REPLACEMENT in text:
        print(f"[patch_litex_skip_memspeed] already patched: {main_c}")
        return

    if NEEDLE not in text:
        print(
            f"[patch_litex_skip_memspeed] needle not found in {main_c} — "
            "BIOS layout changed, refusing to patch.",
            file=sys.stderr,
        )
        sys.exit(1)

    main_c.write_text(text.replace(NEEDLE, REPLACEMENT))
    print(f"[patch_litex_skip_memspeed] patched: {main_c}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <litex-root>", file=sys.stderr)
        sys.exit(2)
    patch(Path(sys.argv[1]).resolve())
