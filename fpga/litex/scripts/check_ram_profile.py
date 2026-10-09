#!/usr/bin/env python3
"""Validate a single LiteX build's PMA, main_ram and Linux DT capacities."""

import argparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hardware", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--linux", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--xlen", required=True, type=int, choices=(32, 64))
    args = parser.parse_args()
    if not 0 < args.hardware <= 0x80000000:
        parser.error("main_ram must fit in the 2 GiB PMA window")
    if not 0 < args.linux <= args.hardware:
        parser.error("Linux DT memory must fit in the gateware main_ram window")
    if args.xlen == 32 and args.linux > 0x40000000:
        parser.error("RV32 Linux may advertise at most 1 GiB")


if __name__ == "__main__":
    main()
