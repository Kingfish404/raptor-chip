#!/usr/bin/env python3

import argparse
import re
from pathlib import Path


def replace_once(
    text: str, original: str, replacement: str, adapted: str, source: Path
) -> str:
    original_matches = re.findall(original, text, flags=re.MULTILINE)
    adapted_matches = re.findall(adapted, text, flags=re.MULTILINE)
    if len(original_matches) == 1 and not adapted_matches:
        return re.sub(original, replacement, text, count=1, flags=re.MULTILINE)
    if not original_matches and len(adapted_matches) == 1:
        return text
    raise SystemExit(f"{source}: expected exactly one original or adapted pattern")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Adapt riscv-dv's Spike tohost exit to NPC's ebreak exit"
    )
    parser.add_argument("--illegal-burst-count", type=int, default=0)
    parser.add_argument("asm_dir", type=Path)
    args = parser.parse_args()

    sources = sorted(args.asm_dir.glob("*.S"))
    if not sources:
        parser.error(f"no generated assembly files in {args.asm_dir}")

    replacements = (
        (
            r"^(\s*)csrw\s+0x301,\s*x\d+\s*$",
            r"\1nop # Raptor MISA is read-only",
            r"^\s*nop # Raptor MISA is read-only\s*$",
        ),
        (
            r"^(\s*)li\s+gp,\s*1\s*\n\1ecall\s*$",
            r"\1li gp, 1\n\1j write_tohost",
            r"^\s*li gp, 1\s*\n\s*j write_tohost\s*$",
        ),
        (
            r"^(\s*)sw\s+gp,\s*tohost,\s*t5\s*$",
            r"\1li t5, 0x00100000\n\1li t4, 0x5555\n\1sw t4, 0(t5)",
            r"^\s*li t5, 0x00100000\s*\n\s*li t4, 0x5555\s*\n\s*sw t4, 0\(t5\)\s*$",
        ),
    )
    for source in sources:
        text = source.read_text()
        for original, replacement, adapted in replacements:
            text = replace_once(text, original, replacement, adapted, source)
        if args.illegal_burst_count:
            count = args.illegal_burst_count
            start_marker = ".Lraptor_illegal_burst:"
            end_marker = ".Lraptor_illegal_burst_end:"
            if text.count(start_marker) == 1 and text.count(end_marker) == 1:
                burst = text.split(start_marker, 1)[1].split(end_marker, 1)[0]
                opcode_count = sum(
                    line.strip() == ".4byte 0xffffffff"
                    for line in burst.splitlines()
                )
                if opcode_count != count:
                    raise SystemExit(
                        f"{source}: expected {count} injected illegal instructions"
                    )
            elif start_marker not in text and end_marker not in text:
                illegal_burst = "\n".join(
                    "                  .4byte 0xffffffff" for _ in range(count)
                )
                text = replace_once(
                    text,
                    r"^main:\s+(.+)$",
                    "main:\n"
                    f"{start_marker}\n"
                    f"{illegal_burst}\n"
                    f"{end_marker}\n"
                    r"                  \1",
                    r"$^",
                    source,
                )
            else:
                raise SystemExit(f"{source}: incomplete illegal burst markers")
        source.write_text(text)


if __name__ == "__main__":
    main()