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

import os
import re
import sys
from pathlib import Path

UART_C = Path("litex/soc/software/libbase/uart.c")
MAIN_C = Path("litex/soc/software/bios/main.c")
COMMON_MAK = Path("litex/soc/software/common.mak")
ORIG = "//#define UART_POLLING"
NEW = "#define UART_POLLING  /* forced on by patch_litex_uart_polling.py */"
BYPASS_TXFULL_RE = re.compile(
    r"void uart_write\(char c\)\n"
    r"\{\n"
    r"[ \t]*while \(uart_txfull_read\(\)\);\n"
    r"[ \t]*uart_rxtx_write\(c\);\n"
    r"\}\n"
)
BYPASS_TXFULL_NEW = """void uart_write(char c)
{
    uart_rxtx_write(c);
}
"""
STORE_PROBE_INSTALLED_RE = re.compile(
    r"#ifdef CSR_UART_BASE\n"
    r"[ \t]*uart_init\(\);\n"
    r"#endif\n"
    r"(?:\n\n#ifdef CONFIG_HAS_I2C\n"
    r"[ \t]*i2c_send_init_cmds\(\);\n"
    r"#endif\n)?"
    r"\n\n#ifdef CSR_UART_BASE\n"
    r"[ \t]*for \(unsigned int probe_idx = 0; probe_idx < [0-9]+; probe_idx\+\+\) \{\n"
    r"[ \t]*uart_write\('U'\);\n"
    r"[ \t]*\}\n"
    r"[ \t]*while \(1\) \{\}\n"
    r"#endif\n"
)
STORE_PROBE_ASM_INSTALLED_RE = re.compile(
    r"#ifdef CSR_UART_BASE\n"
    r"[ \t]*uart_init\(\);\n"
    r"#endif\n"
    r"(?:\n\n#ifdef CONFIG_HAS_I2C\n"
    r"[ \t]*i2c_send_init_cmds\(\);\n"
    r"#endif\n)?"
    r"\n\n#ifdef CSR_UART_BASE\n"
    r"[ \t]*__asm__ volatile \(\n"
    r".*?"
    r"[ \t]*while \(1\) \{\}\n"
    r"#endif\n",
    re.DOTALL,
)
STORE_PROBE_RE = re.compile(
    r"#ifdef CSR_UART_BASE\n"
    r"[ \t]*uart_init\(\);\n"
    r"#endif\n"
    r"\n"
    r"#ifdef CONFIG_HAS_I2C\n"
    r"[ \t]*i2c_send_init_cmds\(\);\n"
    r"#endif\n"
)
CRT0_CFLAGS_BLOCK = """
ifneq ($(RAPT_LITEX_CRT0_UART_PROBE),)
CFLAGS += -DRAPT_LITEX_CRT0_UART_PROBE
ifneq ($(RAPT_LITEX_CRT0_UART_PROBE_COUNT),)
CFLAGS += -DRAPT_LITEX_CRT0_UART_PROBE_COUNT=$(RAPT_LITEX_CRT0_UART_PROBE_COUNT)
endif
ifneq ($(RAPT_LITEX_CRT0_UART_PROBE_DELAY),)
CFLAGS += -DRAPT_LITEX_CRT0_UART_PROBE_DELAY=$(RAPT_LITEX_CRT0_UART_PROBE_DELAY)
endif
ifneq ($(RAPT_LITEX_CRT0_UART_PROBE_GAP),)
CFLAGS += -DRAPT_LITEX_CRT0_UART_PROBE_GAP=$(RAPT_LITEX_CRT0_UART_PROBE_GAP)
endif
ifneq ($(RAPT_LITEX_CRT0_UART_PROBE_FENCE),)
CFLAGS += -DRAPT_LITEX_CRT0_UART_PROBE_FENCE=$(RAPT_LITEX_CRT0_UART_PROBE_FENCE)
endif
endif
"""


def store_probe_new() -> str:
    count = int(os.environ.get("RAPT_LITEX_UART_STORE_PROBE_COUNT", "256"), 0)
    delay = int(os.environ.get("RAPT_LITEX_UART_STORE_PROBE_DELAY", "0"), 0)
    gap = int(os.environ.get("RAPT_LITEX_UART_STORE_PROBE_GAP", "0"), 0)
    fence = os.environ.get("RAPT_LITEX_UART_STORE_PROBE_FENCE") == "1"
    if count < 1:
        sys.exit("[patch_litex_uart_polling] RAPT_LITEX_UART_STORE_PROBE_COUNT must be >= 1")
    if delay < 0:
        sys.exit("[patch_litex_uart_polling] RAPT_LITEX_UART_STORE_PROBE_DELAY must be >= 0")
    if gap < 0:
        sys.exit("[patch_litex_uart_polling] RAPT_LITEX_UART_STORE_PROBE_GAP must be >= 0")
    if os.environ.get("RAPT_LITEX_UART_STORE_PROBE_ASM") == "1":
        delay_asm = ""
        if delay:
            delay_asm = f"""        \"li t3, {delay}\\n\\t\"
        \"3: addi t3, t3, -1\\n\\t\"
        \"bnez t3, 3b\\n\\t\"
"""
        gap_asm = ""
        if gap:
            gap_asm = f"""        \"li t3, {gap}\\n\\t\"
        \"4: addi t3, t3, -1\\n\\t\"
        \"bnez t3, 4b\\n\\t\"
"""
        fence_before = "        \"fence\\n\\t\"\n" if fence else ""
        fence_after = "        \"fence\\n\\t\"\n" if fence else ""
        return f"""#ifdef CSR_UART_BASE
    uart_init();
#endif

#ifdef CONFIG_HAS_I2C
    i2c_send_init_cmds();
#endif

#ifdef CSR_UART_BASE
    __asm__ volatile (
{delay_asm}        \"li t0, {count}\\n\\t\"
        \"1: li t1, 85\\n\\t\"
        \"lui t2, 0xf0002\\n\\t\"
{fence_before}
        \"sw t1, -2048(t2)\\n\\t\"
{fence_after}{gap_asm}        \"addi t0, t0, -1\\n\\t\"
        \"bnez t0, 1b\\n\\t\"
        :
        :
        : \"t0\", \"t1\", \"t2\", \"t3\", \"memory\");
    while (1) {{}}
#endif
"""
    return f"""#ifdef CSR_UART_BASE
    uart_init();
#endif

#ifdef CONFIG_HAS_I2C
    i2c_send_init_cmds();
#endif

#ifdef CSR_UART_BASE
    for (unsigned int probe_idx = 0; probe_idx < {count}; probe_idx++) {{
        uart_write('U');
    }}
    while (1) {{}}
#endif
"""


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
    elif ORIG in txt:
        txt = txt.replace(ORIG, NEW, 1)
        f.write_text(txt)
        print(f"[patch_litex_uart_polling] patched: {f}")
    else:
        sys.exit(
            f"[patch_litex_uart_polling] expected line not found in {f}; "
            "has uart.c changed upstream?"
        )

    if os.environ.get("RAPT_LITEX_UART_BYPASS_TXFULL") == "1":
        txt = f.read_text()
        txt, replacements = BYPASS_TXFULL_RE.subn(BYPASS_TXFULL_NEW, txt, count=1)
        if replacements != 1:
            if BYPASS_TXFULL_NEW in txt:
                print(f"[patch_litex_uart_polling] uart_txfull_read already bypassed in uart_write: {f}")
            else:
                sys.exit(
                    f"[patch_litex_uart_polling] expected uart_write polling block not found in {f}; "
                    "has uart.c changed upstream?"
                )
        else:
            f.write_text(txt)
            print(f"[patch_litex_uart_polling] bypassed uart_txfull_read in uart_write: {f}")

    if os.environ.get("RAPT_LITEX_UART_STORE_PROBE") == "1":
        main_c = Path(argv[1]) / MAIN_C
        if not main_c.exists():
            sys.exit(f"[patch_litex_uart_polling] not found: {main_c}")
        txt = main_c.read_text()
        probe_new = store_probe_new()
        if probe_new in txt:
            print(f"[patch_litex_uart_polling] UART store probe already patched: {main_c}")
        else:
            txt, replacements = STORE_PROBE_ASM_INSTALLED_RE.subn(lambda _: probe_new, txt, count=1)
            if replacements == 0:
                txt, replacements = STORE_PROBE_INSTALLED_RE.subn(lambda _: probe_new, txt, count=1)
            if replacements == 0:
                txt, replacements = STORE_PROBE_RE.subn(lambda _: probe_new, txt, count=1)
            if replacements != 1:
                sys.exit(
                    f"[patch_litex_uart_polling] expected uart_init block not found in {main_c}; "
                    "has main.c changed upstream?"
                )
            main_c.write_text(txt)
            print(f"[patch_litex_uart_polling] inserted UART store probe: {main_c}")

    if os.environ.get("RAPT_LITEX_CRT0_UART_PROBE") == "1":
        common_mak = Path(argv[1]) / COMMON_MAK
        if not common_mak.exists():
            sys.exit(f"[patch_litex_uart_polling] not found: {common_mak}")
        txt = common_mak.read_text()
        if CRT0_CFLAGS_BLOCK in txt:
            print(f"[patch_litex_uart_polling] crt0 UART probe CFLAGS already patched: {common_mak}")
        else:
            common_mak.write_text(txt.rstrip() + "\n" + CRT0_CFLAGS_BLOCK)
            print(f"[patch_litex_uart_polling] enabled crt0 UART probe CFLAGS: {common_mak}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
