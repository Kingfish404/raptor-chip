#!/usr/bin/env python3
"""Compile production PMP code against an independent interval oracle."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    for xlen in (32, 64):
        with tempfile.TemporaryDirectory(prefix="nemu-pmp-") as tmp:
            work = Path(tmp)
            (work / "generated").mkdir()
            (work / "generated/autoconf.h").write_text(
                "#define CONFIG_ISA_riscv 1\n" +
                ("#define CONFIG_ISA64 1\n#define CONFIG_RV64 1\n" if xlen == 64 else ""))
            command = ["cc", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                       "-Wno-unused-parameter", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                       "-D__GUEST_ISA__=riscv", "-I" + str(work),
                       "-I" + str(root / "nemu/include"),
                       "-I" + str(root / "nemu/src/isa/riscv/include"),
                       "-I" + str(root / "nemu/src/isa/riscv/system"),
                       str(args.source or root / "nemu/src/isa/riscv/system/pmp.c"),
                       str(root / "app/tests/host/nemu_pmp_priority.c"), "-o", str(work / "test")]
            subprocess.run(command, check=True)
            subprocess.run([str(work / "test")], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
