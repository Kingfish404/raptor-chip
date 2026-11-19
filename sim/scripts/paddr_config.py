#!/usr/bin/env python3
"""Read effective RTL address widths and ISA features."""

import argparse
import ast
from pathlib import Path
import re
import shlex
import subprocess
import sys

RVA23_BASE_EXTENSIONS = (
    "b", "d", "f", "za64rs", "zba", "zbb", "zbs", "zcb", "zcmop", "zfhmin",
    "zic64b", "zicbom", "zicbop", "zicboz", "ziccamoa", "ziccif", "zicclsm",
    "ziccrse", "zicntr", "zicond", "zicsr", "zifencei", "zihintntl", "zihintpause",
    "zihpm", "zimop", "zkt",
)
RVA23_SCALAR_MACROS = {"zawrs": "RAPT_ZAWRS", "zfa": "RAPT_ZFA", "ssnpm": "RAPT_SSNPM"}
RVA23_VECTOR_MACROS = {"zvbb": "RAPT_ZVBB", "zvfhmin": "RAPT_ZVFHMIN", "zvkt": "RAPT_ZVKT",
                      "zicclsm": "RAPT_ZICCLSM_VECTOR"}


def extend_isa(isa, extensions):
    base, *suffixes = isa.split("_")
    letters = base[4:]
    order = "iemafdqlcbkjtpvnhsu"
    for name in extensions:
        if len(name) == 1:
            if name not in letters:
                index = next((i for i, ch in enumerate(letters)
                              if ch in order and order.index(ch) > order.index(name)), len(letters))
                letters = letters[:index] + name + letters[index:]
        elif name not in suffixes:
            suffixes.append(name)
    return "_".join((base[:4] + letters, *suffixes))


def rva23_extensions():
    return sorted(set(RVA23_BASE_EXTENSIONS) | RVA23_SCALAR_MACROS.keys() | RVA23_VECTOR_MACROS.keys())


def update_dtb(dtb, extensions):
    node = "/cpus/cpu@0"

    def read(name):
        return subprocess.check_output(["fdtget", "-d", "", "-t", "s", dtb, node, name],
                                       text=True).split()

    def write(name, *values, data_type="s"):
        subprocess.run(["fdtput", "-t", data_type, dtb, node, name, *values], check=True)

    isa = read("riscv,isa")
    listed = read("riscv,isa-extensions")
    if isa:
        write("riscv,isa", extend_isa(isa[0], extensions))
    if listed:
        write("riscv,isa-extensions", *dict.fromkeys((*listed, *extensions)))
    for extension in ("zicbom", "zicbop", "zicboz"):
        if extension in extensions:
            write(f"riscv,{extension[2:]}-block-size", "64", data_type="u")


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
    parser.add_argument("--config", type=Path)
    parser.add_argument("--hdl", type=Path)
    parser.add_argument("--pmp-only", action="store_true")
    parser.add_argument("--features", action="store_true",
                        help="append V enable, geometry and comma-delimited ISA extensions")
    parser.add_argument("--isa", metavar="BASE_ISA", help="add the effective ISA to a base string")
    parser.add_argument("--update-dtb", type=Path,
                        help="append the supplied ISA extensions to a compiled device tree")
    parser.add_argument("flags", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    flags = args.flags[1:] if args.flags[:1] == ["--"] else args.flags
    if args.update_dtb:
        update_dtb(str(args.update_dtb), flags)
        return
    if args.config is None or args.hdl is None:
        parser.error("--config and --hdl are required to read RTL features")
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
    if args.features or args.isa:
        names = set(re.findall(r"^`define (\w+)", result.stdout, re.M))
        enabled = "RAPT_V_EXTENSION" in names
        geometry = [constant(defines[name], defines)
                    for name in ("RAPT_VLEN", "RAPT_VRF_BANK_BITS", "RAPT_VRF_BANKS")]
        extensions = set(RVA23_BASE_EXTENSIONS) if "RAPT_RVA23U64" in names else set()
        if enabled:
            extensions.update(extension for extension, macro in RVA23_VECTOR_MACROS.items()
                              if macro in names)
        extensions.update(extension for extension, macro in RVA23_SCALAR_MACROS.items()
                          if macro in names and (xlen == 64 or extension == "zawrs"))
        if args.isa:
            if enabled:
                extensions.add("v")
            print(extend_isa(args.isa, sorted(extensions)))
        else:
            print(pa, pmp, int(enabled), *geometry, ",".join(sorted(extensions)) or "-")
    else:
        print(pmp if args.pmp_only else f"{pa} {pmp}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, SyntaxError, OSError, subprocess.CalledProcessError) as error:
        print(f"PA configuration error: {error}", file=sys.stderr)
        print("ERROR")
        sys.exit(1)
