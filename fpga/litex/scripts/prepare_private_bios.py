#!/usr/bin/env python3
"""Copy and patch private LiteX software. Never edit or restore the checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

from patch_litex_picolibc import patch_common_mak, patch_libc_mk


def prepare(source, dest):
    if dest.resolve().is_relative_to(source.resolve()):
        raise ValueError("private software must not be inside the LiteX source tree")
    software = dest / "litex/soc/software"
    shutil.copytree(source / "litex/soc/software", software, dirs_exist_ok=True)
    patch_common_mak(software / "common.mak")
    patch_libc_mk(software / "libc/Makefile")
    return software


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("boot_arguments", nargs="*")
    args = parser.parse_args()
    prepare(args.source, args.destination)
    if args.boot_arguments:
        subprocess.run([sys.executable, str(Path(__file__).with_name("patch_litex_sdcard_linux_override.py")),
                        str(args.destination), *args.boot_arguments], check=True)


if __name__ == "__main__":
    main()
