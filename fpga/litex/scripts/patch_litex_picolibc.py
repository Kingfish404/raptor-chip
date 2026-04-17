#!/usr/bin/env python3
"""Patch LiteX's libc build for newer pythondata-software-picolibc layout.

Newer picolibc (>=1.7) moved sources under ``newlib/libc/`` and split the
tinystdio variant into ``newlib/libc/tinystdio/``. LiteX's
``litex/soc/software/common.mak`` and ``litex/soc/software/libc/Makefile``
still reference the legacy ``libc/...`` paths, so C builds fail with
``FDEV_SETUP_STREAM undeclared`` and ``_tls_stdout`` TLS conflicts
(toolchain newlib stdio.h is picked instead of picolibc's).

This script patches both files in place. Restore with
``git checkout -- <path>``.

Usage: patch_litex_picolibc.py <litex_path>
"""
from __future__ import annotations

import pathlib
import re
import sys

# stdio .c files that live in ``newlib/libc/tinystdio/`` in newer picolibc.
STDIO_FILES = {
    "fgetc.c",
    "fputc.c",
    "fputs.c",
    "printf.c",
    "puts.c",
    "strtoul.c",
    "vfprintf.c",
    "vfiprintf.c",
    "vffprintf.c",
    "dtoa_engine.c",
    "ftoa_engine.c",
    "dtox_engine.c",
    "ftox_engine.c",
}

# libc subdirs that stayed under ``newlib/libc/`` (not tinystdio).
LIBC_SUBDIRS = ("ctype", "errno", "string", "stdlib", "machine", "include", "locale")


def patch_common_mak(path: pathlib.Path) -> bool:
    t = path.read_text()
    if "newlib/libc/tinystdio" in t:
        return False
    t = t.replace(
        "-I$(PICOLIBC_DIRECTORY)/libc/include",
        "-I$(PICOLIBC_DIRECTORY)/newlib/libc/include "
        "-I$(PICOLIBC_DIRECTORY)/newlib/libc/tinystdio",
    )
    path.write_text(t)
    return True


def patch_libc_mk(path: pathlib.Path) -> bool:
    t = path.read_text()
    orig = t
    # stdio .c files -> newlib/libc/tinystdio/
    for f in STDIO_FILES:
        t = t.replace(
            f"$(PICOLIBC_SRC_DIR)/libc/stdio/{f}",
            f"$(PICOLIBC_SRC_DIR)/newlib/libc/tinystdio/{f}",
        )
    # Non-stdio libc subdirs -> newlib/libc/<sub>
    t = re.sub(
        r"\$\(PICOLIBC_SRC_DIR\)/libc/(" + "|".join(LIBC_SUBDIRS) + r")",
        r"$(PICOLIBC_SRC_DIR)/newlib/libc/\1",
        t,
    )
    # libm -> newlib/libm
    t = re.sub(
        r"\$\(PICOLIBC_SRC_DIR\)/libm/",
        r"$(PICOLIBC_SRC_DIR)/newlib/libm/",
        t,
    )
    # Any remaining libc/stdio include/src path -> tinystdio
    t = t.replace(
        "$(PICOLIBC_SRC_DIR)/libc/stdio",
        "$(PICOLIBC_SRC_DIR)/newlib/libc/tinystdio",
    )
    if t == orig:
        return False
    path.write_text(t)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <litex_path>", file=sys.stderr)
        return 2
    litex = pathlib.Path(sys.argv[1])
    common = litex / "litex/soc/software/common.mak"
    libc = litex / "litex/soc/software/libc/Makefile"
    for p in (common, libc):
        if not p.exists():
            print(f"error: not found: {p}", file=sys.stderr)
            return 1
    c_changed = patch_common_mak(common)
    l_changed = patch_libc_mk(libc)
    print(
        f"[INFO] picolibc patch: common.mak {'patched' if c_changed else 'already patched'}, "
        f"libc/Makefile {'patched' if l_changed else 'already patched'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
