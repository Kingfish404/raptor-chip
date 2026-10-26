#!/usr/bin/env python3
"""Read the effective RTL PA/PMP widths using the simulator's preprocessor."""

import argparse
import ast
from pathlib import Path
import re
import shlex
import subprocess
import sys


def constant(text, defines):
    text = re.sub(r"`(\w+)", lambda m: str(constant(defines[m[1]], defines)), text)
    node = ast.parse(text, mode="eval")
    allowed = (ast.Expression, ast.Constant, ast.BinOp, ast.UnaryOp,
               ast.Add, ast.Sub, ast.Mult, ast.FloorDiv, ast.LShift,
               ast.RShift, ast.BitOr, ast.BitAnd, ast.USub, ast.UAdd)
    if any(not isinstance(n, allowed) for n in ast.walk(node)):
        raise ValueError(f"unsupported width expression: {text}")
    return int(eval(compile(node, "<RTL width>", "eval"), {"__builtins__": {}}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--hdl", type=Path, required=True)
    parser.add_argument("--pmp-only", action="store_true")
    parser.add_argument("flags", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    flags = args.flags[1:] if args.flags[:1] == ["--"] else args.flags
    result = subprocess.run(shlex.split(args.verilator) + ["-E", "--dump-defines",
                            "-I" + str(args.config), "-I" + str(args.hdl / "include")]
                            + flags + [str(args.hdl / "include/rapt.svh")],
                            check=True, capture_output=True, text=True)
    defines = dict(re.findall(r"^`define (\w+)[ \t]+([^\n]+)", result.stdout, re.M))
    xlen = constant(defines["RAPT_XLEN"], defines)
    pa = constant(defines["RAPT_PADDR_BITS"], defines)
    pmp = constant(defines["RAPT_PMPADDR_BITS"], defines)
    if (xlen == 64 and not 32 <= pa <= 38) or (xlen == 32 and pa != 32):
        raise ValueError("RAPT_PADDR_BITS: RV64 requires 32..38; RV32 requires 32; "
                         "PMA is 32-bit with a Bare alias and PC40 requires PA <= 39")
    if xlen == 64 and pmp != pa - 2:
        raise ValueError("RAPT_PMPADDR_BITS must equal RAPT_PADDR_BITS - 2")
    print(pmp if args.pmp_only else f"{pa} {pmp}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, SyntaxError, OSError, subprocess.CalledProcessError) as error:
        print(f"PA configuration error: {error}", file=sys.stderr)
        print("ERROR")
        sys.exit(1)
