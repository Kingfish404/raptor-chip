#!/usr/bin/env python3
"""Patch LiteX's libc build for the current pythondata picolibc layout.

Recent ``pythondata_software_picolibc`` packages expose the source tree under
``data/newlib`` instead of the older ``data/libc`` layout. Their LiteX-facing
stdio API also lives in ``libc/tinystdio/stdio.h`` while the fuller newlib
stdio implementation lives in ``libc/stdio``. LiteX's vendored Makefiles still
assume the legacy layout, so BIOS builds can fail with missing sources or with
``FDEV_SETUP_STREAM``/TLS stdio conflicts.

This script patches the vendored LiteX files in place. The surrounding Makefile
restores them with ``git checkout -- <path>`` after the BIOS build.
"""
from __future__ import annotations

import pathlib
import sys

MAKE_CONT = " " + "\\" + "\n"
TAB_CONT = "\t" + "\\" + "\n"

STDIO_FILES = {
    "fgetc.c",
    "fputc.c",
    "fputs.c",
    "printf.c",
    "puts.c",
    "strtoul.c",
    "strtoull.c",
    "vfprintf.c",
    "vfiprintf.c",
    "vffprintf.c",
    "vfprintff.c",
    "dtoa_engine.c",
    "ftoa_engine.c",
    "dtox_engine.c",
    "ftox_engine.c",
}


def patch_common_mak(path: pathlib.Path) -> bool:
    text = path.read_text()
    original = text
    root_dir = (
        "PICOLIBC_ROOT_DIR ?= "
        "$(if $(wildcard $(PICOLIBC_DIRECTORY)/libc),$(PICOLIBC_DIRECTORY),$(PICOLIBC_DIRECTORY)/newlib)\n"
    )
    root_includes = (
        "-I$(PICOLIBC_ROOT_DIR)/libc/include" + MAKE_CONT
        + "           -I$(PICOLIBC_ROOT_DIR)/libc/tinystdio"
    )

    if "PICOLIBC_ROOT_DIR ?=" not in text:
        text = text.replace("# Toolchain options\n", "# Toolchain options\n" + root_dir)
    text = text.replace(
        "-I$(PICOLIBC_DIRECTORY)/newlib/libc/include -I$(PICOLIBC_DIRECTORY)/newlib/libc/tinystdio",
        root_includes,
    )
    text = text.replace("-I$(PICOLIBC_DIRECTORY)/libc/include", root_includes)
    text = text.replace(
        "-I$(PICOLIBC_ROOT_DIR)/libc/include" + MAKE_CONT + "+           -I$(PICOLIBC_ROOT_DIR)/libc/tinystdio",
        root_includes,
    )

    if text == original:
        return False
    path.write_text(text)
    return True


def patch_libc_mk(path: pathlib.Path) -> bool:
    text = path.read_text()
    original = text

    text = text.replace(
        "cp -a $(PICOLIBC_DIRECTORY) $(BUILDINC_DIRECTORY)/../picolibc_src",
        "cp -a $(PICOLIBC_ROOT_DIR) $(BUILDINC_DIRECTORY)/../picolibc_src",
    )
    text = text.replace("$(PICOLIBC_SRC_DIR)/newlib/libc/", "$(PICOLIBC_SRC_DIR)/libc/")
    text = text.replace("$(PICOLIBC_SRC_DIR)/newlib/libm/", "$(PICOLIBC_SRC_DIR)/libm/")
    text = text.replace("$(PICOLIBC_SRC_DIR)/newlib/semihost", "$(PICOLIBC_SRC_DIR)/semihost")
    text = text.replace(
        "$(BUILDINC_DIRECTORY)/../picolibc_src/newlib/libc/machine/$(CPUFAMILY)/",
        "$(BUILDINC_DIRECTORY)/../picolibc_src/libc/machine/$(CPUFAMILY)/",
    )

    for filename in STDIO_FILES:
        text = text.replace(
            f"$(PICOLIBC_SRC_DIR)/libc/stdio/{filename}",
            f"$(PICOLIBC_SRC_DIR)/libc/tinystdio/{filename}",
        )

    old_minimal_includes = (
        "\t-I$(PICOLIBC_SRC_DIR)/libc/machine/$(CPUFAMILY)" + MAKE_CONT
        + "\t-I$(PICOLIBC_SRC_DIR)/libc/stdio" + MAKE_CONT
    )
    new_minimal_includes = (
        "\t-I$(PICOLIBC_SRC_DIR)/libc/machine/$(CPUFAMILY)" + MAKE_CONT
        + "\t-I$(PICOLIBC_SRC_DIR)/libc/tinystdio" + MAKE_CONT
        + "\t-I$(PICOLIBC_SRC_DIR)/libc/stdio" + MAKE_CONT
    )
    text = text.replace(old_minimal_includes, new_minimal_includes)
    text = text.replace(
        "$(filter-out $(DEPFLAGS),$(CFLAGS))",
        "$(filter-out $(DEPFLAGS) -I$(PICOLIBC_ROOT_DIR)/libc/tinystdio,$(CFLAGS))",
    )
    text = text.replace(
        "$(filter-out $(DEPFLAGS) -I$(PICOLIBC_DIRECTORY)/newlib/libc/tinystdio,$(CFLAGS))",
        "$(filter-out $(DEPFLAGS) -I$(PICOLIBC_ROOT_DIR)/libc/tinystdio,$(CFLAGS))",
    )

    if "cp \"$(PICOLIBC_SRC_DIR)/libc/stdlib/strtoul.c\"" not in text:
        cpu_copy = (
            "\tif [ -d \"$(LIBC_DIRECTORY)/$(CPUFAMILY)\" ]; then" + MAKE_CONT
            + "\t\tcp $(LIBC_DIRECTORY)/$(CPUFAMILY)/* $(BUILDINC_DIRECTORY)/../picolibc_src/libc/machine/$(CPUFAMILY)/ ;" + TAB_CONT
            + "\tfi\n"
        )
        compat_copy = (
            "\n\tif [ ! -f \"$(PICOLIBC_SRC_DIR)/libc/tinystdio/strtoul.c\" ] && "
            + "[ -f \"$(PICOLIBC_SRC_DIR)/libc/stdlib/strtoul.c\" ]; then" + MAKE_CONT
            + "\t\tcp \"$(PICOLIBC_SRC_DIR)/libc/stdlib/strtoul.c\" \"$(PICOLIBC_SRC_DIR)/libc/tinystdio/strtoul.c\" ;" + TAB_CONT
            + "\tfi\n"
            + "\tif [ ! -f \"$(PICOLIBC_SRC_DIR)/libc/tinystdio/strtoull.c\" ] && "
            + "[ -f \"$(PICOLIBC_SRC_DIR)/libc/stdlib/strtoull.c\" ]; then" + MAKE_CONT
            + "\t\tcp \"$(PICOLIBC_SRC_DIR)/libc/stdlib/strtoull.c\" \"$(PICOLIBC_SRC_DIR)/libc/tinystdio/strtoull.c\" ;" + TAB_CONT
            + "\tfi\n"
        )
        text = text.replace(cpu_copy, cpu_copy + compat_copy)
    text = text.replace(
        "$(PICOLIBC_SRC_DIR)/newlib/libc/tinystdio/strtoul.c",
        "$(PICOLIBC_SRC_DIR)/libc/tinystdio/strtoul.c",
    )
    text = text.replace(
        "$(PICOLIBC_SRC_DIR)/newlib/libc/stdlib/strtoul.c",
        "$(PICOLIBC_SRC_DIR)/libc/stdlib/strtoul.c",
    )
    text = text.replace(
        "$(PICOLIBC_SRC_DIR)/newlib/libc/tinystdio/strtoull.c",
        "$(PICOLIBC_SRC_DIR)/libc/tinystdio/strtoull.c",
    )
    text = text.replace(
        "$(PICOLIBC_SRC_DIR)/newlib/libc/stdlib/strtoull.c",
        "$(PICOLIBC_SRC_DIR)/libc/stdlib/strtoull.c",
    )

    if text == original:
        return False
    path.write_text(text)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <litex_path>", file=sys.stderr)
        return 2
    litex = pathlib.Path(sys.argv[1])
    common = litex / "litex/soc/software/common.mak"
    libc = litex / "litex/soc/software/libc/Makefile"
    for path in (common, libc):
        if not path.exists():
            print(f"error: not found: {path}", file=sys.stderr)
            return 1
    common_changed = patch_common_mak(common)
    libc_changed = patch_libc_mk(libc)
    print(
        f"[INFO] picolibc patch: common.mak {'patched' if common_changed else 'already patched'}, "
        f"libc/Makefile {'patched' if libc_changed else 'already patched'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())