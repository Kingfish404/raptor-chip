#!/usr/bin/env python3
"""Adapt an AM RV32 image's terminal halt to the board's sifive,test finisher.

Only EBREAK followed immediately by a self-loop is replaced. Other EBREAKs
(including libgcc's divide-by-zero trap) remain intact. The original is never
modified. BSS/stack bounds and the heap limit are taken from its companion ELF.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

BASE = 0x80000000
RAM_END = BASE + 262144
CONTROL = RAM_END - 16


def symbols(elf, prefix):
    output = subprocess.check_output([prefix + "nm", "-n", str(elf)], text=True)
    result = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3:
            result[fields[2]] = int(fields[0], 16)
    return result


def jump(offset):
    if offset % 2 or not -(1 << 20) <= offset < (1 << 20):
        raise ValueError("finisher stub is outside JAL range")
    word = 0x6f | ((offset >> 20) & 1) << 31 | ((offset >> 1) & 0x3ff) << 21
    word |= ((offset >> 11) & 1) << 20 | ((offset >> 12) & 0xff) << 12
    return word.to_bytes(4, "little")


def prepare(source, output, stub, elf=None, prefix="riscv64-elf-"):
    elf = elf or source.with_suffix(".elf")
    syms = symbols(elf, prefix)
    original = source.read_bytes()
    data = bytearray(original)
    stub_data = stub.read_bytes()
    bss_end = syms["__am_apps_bss_end"]
    stub_address = (max(BASE + len(data), bss_end) + 3) & ~3
    if stub_address + len(stub_data) > syms["_stack_top"]:
        raise ValueError("no space between BSS and stack for finisher stub")
    if syms["_heap_start"] >= CONTROL or stub_address + len(stub_data) >= CONTROL:
        raise ValueError("image/BSS/stack exceeds board RAM")
    data.extend(bytes(stub_address - BASE + len(stub_data) - len(data)))
    data[stub_address - BASE:] = stub_data
    disassembly = subprocess.check_output([prefix + "objdump", "-d", str(elf)], text=True)
    instructions = []
    for line in disassembly.splitlines():
        match = re.match(r"\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(.+)", line)
        if match:
            instructions.append((int(match[1], 16), bytes.fromhex(match[2]), match[3]))
    patched, untouched = [], []
    for index, (address, encoding, asm) in enumerate(instructions[:-1]):
        if asm.strip() != "ebreak":
            continue
        next_address, next_encoding, next_asm = instructions[index + 1]
        loop = re.match(r"j\s+([0-9a-f]+)\b", next_asm)
        if (next_address != address + len(encoding) or not loop
                or int(loop[1], 16) != next_address):
            untouched.append(hex(address))
            continue
        if len(encoding) + len(next_encoding) < 4:
            raise ValueError("terminal halt sequence is shorter than JAL")
        data[address - BASE:address - BASE + 4] = jump(stub_address - address)
        patched.append(hex(address))
    if not patched:
        raise ValueError("no terminal EBREAK/self-loop sequence found")
    heap_patch = None
    if "heap" in syms:
        offset = syms["heap"] - BASE + 4
        if offset + 4 > len(original):
            raise ValueError("heap.end is outside initialized data")
        old = int.from_bytes(data[offset:offset + 4], "little")
        data[offset:offset + 4] = CONTROL.to_bytes(4, "little")
        heap_patch = {"address": hex(BASE + offset), "old": hex(old), "new": hex(CONTROL)}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    record = {"source": str(source), "elf": str(elf), "bytes": len(data),
              "original_sha256": hashlib.sha256(original).hexdigest(),
              "prepared_sha256": hashlib.sha256(data).hexdigest(),
              "terminal_patches": patched, "untouched_ebreak": untouched,
              "finisher_stub": hex(stub_address), "heap_patch": heap_patch}
    output.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--stub", required=True, type=Path)
    parser.add_argument("--elf", type=Path)
    parser.add_argument("--prefix", default=os.environ.get("CROSS_COMPILE", "riscv64-elf-"))
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output, args.stub, args.elf, args.prefix)))


if __name__ == "__main__":
    main()
