#!/usr/bin/env python3
"""Validate a NEMU subsystem trace and retain its workload provenance."""

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            value.update(block)
    return value.hexdigest()


def control_packet_bound(
    instructions: list[tuple[int, int]], width: int, window_halfwords: int | None = None
) -> dict[str, float | int]:
    """Optimistic one-fetch-packet-per-cycle bound for the traced control flow.

    A packet ends at its first control instruction. A JALR after slot zero
    starts the next packet because the IFU needs a fresh primary BTB query.
    A finite halfword window limits the number of instructions per packet.
    Serial-instruction boundaries, cache, prediction, and pipeline costs are
    intentionally omitted.
    """
    packets = index = 0
    while index < len(instructions):
        packets += 1
        slots = 0
        halfwords = 0
        while index < len(instructions) and slots < width:
            instruction, length = instructions[index]
            opcode = instruction & 0x7F
            if opcode == 0x67 and slots:
                break
            if window_halfwords is not None and halfwords + length > window_halfwords:
                break
            slots += 1
            halfwords += length
            index += 1
            if opcode in (0x63, 0x67, 0x6F):
                break
    return {"packets": packets, "uops_per_cycle_ceiling": len(instructions) / packets}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--inst", type=Path, required=True)
    parser.add_argument("--mem", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base", type=lambda x: int(x, 0), default=0x80000000)
    args = parser.parse_args()
    image = args.image.read_bytes()
    image_size = len(image)
    addresses: set[int] = set()
    pc_by_sequence: list[int] = []
    program_instructions: list[tuple[int, int]] = []
    count = 0
    program_count = 0
    linked = 0
    previous_npc = None
    first_program_pc = None
    with args.inst.open() as source:
        for number, line in enumerate(source, 1):
            fields = line.split()
            if len(fields) != 3:
                raise ValueError(f"{args.inst}:{number}: expected PC instruction next-PC")
            pc, instruction, npc = (int(field, 16) for field in fields)
            if previous_npc == pc:
                linked += 1
            previous_npc = npc
            addresses.add(pc)
            pc_by_sequence.append(pc)
            count += 1
            if args.base <= pc < args.base + image_size:
                program_count += 1
                image_offset = pc - args.base
                if image_offset + 1 >= image_size:
                    raise ValueError(f"{args.inst}:{number}: instruction is outside image")
                first_halfword = int.from_bytes(image[image_offset:image_offset+2], "little")
                program_instructions.append((instruction, 2 if first_halfword & 3 == 3 else 1))
                if first_program_pc is None:
                    first_program_pc = pc
    if count < 100 or len(addresses) < 10 or program_count < 0.9 * count:
        raise ValueError("trace does not contain a substantial program execution window")
    if linked < 0.95 * (count - 1):
        raise ValueError("successive PCs rarely follow NEMU's recorded next PC")

    operations: Counter[str] = Counter()
    bytes_by_op: Counter[str] = Counter()
    skipped_addresses = 0
    last_sequence = -1
    with args.mem.open() as source:
        for number, line in enumerate(source, 1):
            fields = line.split()
            if len(fields) != 6 or fields[2] not in ("r", "w"):
                raise ValueError(f"{args.mem}:{number}: invalid memory event")
            sequence_text, pc, op, address, size, value = fields
            sequence = int(sequence_text)
            if sequence < last_sequence or sequence >= count or int(pc, 16) != pc_by_sequence[sequence]:
                raise ValueError(f"{args.mem}:{number}: event does not match instruction trace")
            last_sequence = sequence
            int(value, 16)
            address_int = int(address, 16)
            size_int = int(size)
            if size_int not in (1, 2, 4, 8):
                raise ValueError(f"{args.mem}:{number}: unsupported size {size_int}")
            operations[op] += 1
            bytes_by_op[op] += size_int
            skipped_addresses += not (args.base <= address_int < args.base + 0x10000000)

    result = {
        "image": str(args.image.resolve()),
        "image_sha256": digest(args.image),
        "inst_sha256": digest(args.inst),
        "mem_sha256": digest(args.mem),
        "image_bytes": image_size,
        "instructions": count,
        "program_instructions": program_count,
        "first_program_pc": f"0x{first_program_pc:x}",
        "unique_pcs": len(addresses),
        "next_pc_links": linked,
        "memory_events": dict(operations),
        "memory_bytes": dict(bytes_by_op),
        "non_pmem_memory_events": skipped_addresses,
        "optimistic_fe_packet_bound": {
            str(width): control_packet_bound(program_instructions, width)
            for width in (2, 4, 8, 16)
        },
        "window_limited_fe_packet_bound": {
            str(window): {
                str(width): control_packet_bound(program_instructions, width, window)
                for width in (2, 4, 8, 16)
            }
            for window in (6, 8)
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
