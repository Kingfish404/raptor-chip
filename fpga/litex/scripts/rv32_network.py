#!/usr/bin/env python3
"""Opt-in CU08 RV32/Buildroot/FMC_C gigabit profile with isolated outputs.

Reuse the checked network build policy without changing the RV64 defaults.
The default package is the RV32 Buildroot payload previously booted on CU08;
that history does not validate a newly built bitstream.
"""
from functools import partial
import sys

import rv64_network as shared

DEFAULT_PACKAGE = shared.REPO / "linux/build/linux-riscv-rv32-qemu-rv32-buildroot-v6.18.51"
check_package = partial(shared.check_package, bits=32)
make_command = partial(shared.make_command, bits=32)
main = partial(shared.main, bits=32, default_package=DEFAULT_PACKAGE)


if __name__ == "__main__":
    sys.exit(main())
