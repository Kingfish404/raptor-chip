#!/usr/bin/env python3
"""
patch_litex_uart_polling.py — switch the LiteX BIOS UART driver to polling
mode by uncommenting `#define UART_POLLING` in libbase/uart.c.

Why
---
The IRQ-driven path (default) routes every byte that doesn't fit in the
hardware TX FIFO through a 128-byte ring buffer drained by `uart_isr`.
On Raptor + Tang Mega 138K Pro, BIOS reliably hangs mid-banner — strongly
suggests an IRQ-delivery / `mret` corner case in our trap path. This
patch disables the IRQ path entirely so `uart_write` becomes a tight
`while(txfull); rxtx_write(c);` loop, exactly the same pattern that
firmware/fpga/ uses successfully on hardware.

Idempotent. Restore via `git checkout libbase/uart.c`.
"""

from __future__ import annotations

import sys
from pathlib import Path

UART_C = Path("litex/soc/software/libbase/uart.c")
ORIG = "//#define UART_POLLING"
NEW = "#define UART_POLLING  /* forced on by patch_litex_uart_polling.py */"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("Usage: patch_litex_uart_polling.py <litex-repo-root>", file=sys.stderr)
        return 2
    f = Path(argv[1]) / UART_C
    if not f.exists():
        sys.exit(f"[patch_litex_uart_polling] not found: {f}")
    txt = f.read_text()
    if NEW in txt:
        print(f"[patch_litex_uart_polling] already patched: {f}")
        return 0
    if ORIG not in txt:
        sys.exit(
            f"[patch_litex_uart_polling] expected line not found in {f}; "
            "has uart.c changed upstream?"
        )
    f.write_text(txt.replace(ORIG, NEW, 1))
    print(f"[patch_litex_uart_polling] patched: {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
