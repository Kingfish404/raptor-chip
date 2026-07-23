#!/usr/bin/env python3
import argparse
import pathlib
import struct

DISK_SIZE = 16 * 1024
MAX_DISK_SIZE = 128 * 1024
MAX_FILES = 16
NAME_SIZE = 32
BLOCK_SIZE = 512
HEADER_SIZE = 3 * BLOCK_SIZE
DATA_BLOCKS = (DISK_SIZE - HEADER_SIZE) // BLOCK_SIZE
DIRECT_BLOCKS = 8
MAX_FILE_SIZE = DIRECT_BLOCKS * BLOCK_SIZE
MAGIC = b"RFS3"
FILE_TYPE_REGULAR = 1
FILE_TYPE_DIRECTORY = 2
VIRTUAL_DIRECTORIES = ("dev",)


def build_image(root: pathlib.Path) -> bytes:
    if DISK_SIZE > MAX_DISK_SIZE:
        raise ValueError(f"disk is {DISK_SIZE} bytes; maximum is {MAX_DISK_SIZE}")
    paths = sorted(path for path in root.rglob("*") if path.is_dir() or path.is_file())
    existing = {path.relative_to(root).as_posix() for path in paths}
    entries = [(path.relative_to(root).as_posix(), path) for path in paths]
    entries.extend((name, None) for name in VIRTUAL_DIRECTORIES if name not in existing)
    entries.sort(key=lambda entry: entry[0])
    if len(entries) > MAX_FILES:
        raise ValueError(f"rootfs has {len(entries)} entries; maximum is {MAX_FILES}")

    image = bytearray(DISK_SIZE)
    image[:8] = MAGIC + struct.pack("<I", len(entries))
    block_bitmap = 0
    next_block = 0
    for slot, (relative, path) in enumerate(entries):
        name = ("/" + relative).encode("ascii")
        is_directory = path is None or path.is_dir()
        data = b"" if is_directory else path.read_bytes()
        if len(name) >= NAME_SIZE:
            raise ValueError(f"path too long: {relative}")
        if len(data) > MAX_FILE_SIZE:
            raise ValueError(f"{relative} is {len(data)} bytes; file limit is {MAX_FILE_SIZE}")
        blocks_needed = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE
        if next_block + blocks_needed > DATA_BLOCKS:
            raise ValueError(f"rootfs data exceeds {DATA_BLOCKS} blocks")
        entry = 12 + slot * 76
        image[entry:entry + len(name)] = name
        image[entry + 32:entry + 36] = struct.pack("<I", len(data))
        node_type = FILE_TYPE_DIRECTORY if is_directory else FILE_TYPE_REGULAR
        image[entry + 36:entry + 40] = struct.pack("<I", node_type)
        image[entry + 40:entry + 44] = struct.pack("<I", 1)
        for direct in range(blocks_needed):
            block = next_block
            next_block += 1
            block_bitmap |= 1 << block
            image[entry + 44 + direct * 4:entry + 48 + direct * 4] = struct.pack("<I", block + 1)
            source = direct * BLOCK_SIZE
            offset = HEADER_SIZE + block * BLOCK_SIZE
            image[offset:offset + min(BLOCK_SIZE, len(data) - source)] = data[source:source + BLOCK_SIZE]
    image[8:12] = struct.pack("<I", block_bitmap)
    return bytes(image)


def emit_c(path: pathlib.Path, image: bytes) -> None:
    values = ",".join(f"0x{byte:02x}" for byte in image)
    path.write_text(
        '#include <stdint.h>\n'
        '__attribute__((section(".rodata.disk")))\n'
        f'const uint8_t raptos_disk_image[] = {{{values}}};\n'
        f'const uint32_t raptos_disk_image_size = {len(image)};\n',
        encoding="ascii",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--image", type=pathlib.Path, required=True)
    parser.add_argument("--image-c", type=pathlib.Path, required=True)
    args = parser.parse_args()

    image = build_image(args.root)
    args.image.parent.mkdir(parents=True, exist_ok=True)
    args.image.write_bytes(image)
    emit_c(args.image_c, image)
    print(f"[RaptOS] filesystem: {len(image)} bytes (limit {MAX_DISK_SIZE})")


if __name__ == "__main__":
    main()