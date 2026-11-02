"""Portable SRAM restore images and exact page deltas for FPGA replay."""
from __future__ import annotations

import base64
import hashlib
import mmap
from pathlib import Path
import struct

PAGE = 4096
RAM = 0x80000000
SRAM = 0x0F000000
TRAMPOLINE_OFFSET = 2048


def read_state(path):
    state = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if key in state:
            raise ValueError(f"duplicate checkpoint field: {key}")
        state[key] = int(value, 0)
    if state.get("xlen") != 64 or state.get("priv") not in (0, 1, 3):
        raise ValueError("FPGA replay requires an RV64 scalar checkpoint")
    for key in ("plic_pending", "plic_gateway_busy", "plic_ext_irq", "clint_msip"):
        if state.get(key, 0):
            raise ValueError(f"checkpoint has an active device: {key}")
    if state["csr_mstatus"] & (1 << 17):
        raise ValueError("MPRV snapshots require a different restore trampoline")
    if state.get("uart_tx_pending", 0) and state.get("uart_ier", 0) & 2:
        raise ValueError("checkpoint has a pending UART transmit interrupt")
    return state


def restore_image(state, trampoline):
    if len(trampoline) != 4096:
        raise ValueError("expected the simulator's 4 KiB trampoline export")
    mret = [i for i in range(0, 2048, 4) if trampoline[i:i + 4] == b"\x73\x00\x20\x30"]
    if len(mret) != 1:
        raise ValueError("cannot identify the trampoline's final mret")
    writes = []
    for source in range(1, 32):
        writes.append((0x0C000000 + 4 * source, state[f"plic_priority{source}"], 4))
    for context in range(2):
        writes += [(0x0C002000 + 0x80 * context, state[f"plic_enable{context}"], 4),
                   (0x0C200000 + 0x1000 * context, state[f"plic_threshold{context}"], 4)]
    uart = 0x10000000
    lcr = state["uart_lcr"]
    writes += [(uart + 1, 0, 1), (uart + 3, lcr | 0x80, 1),
               (uart, state["uart_dll"], 1), (uart + 1, state["uart_dlm"], 1),
               (uart + 3, lcr & ~0x80, 1), (uart + 4, state["uart_mcr"], 1),
               (uart + 7, state["uart_scr"], 1), (uart + 2, state["uart_fcr"] | 6, 1),
               (uart + 1, state["uart_ier"], 1), (uart + 3, lcr, 1)]
    code = [0x00000297, 0]  # auipc t0,0; addi t0,t0,data_offset
    slots = []
    for address, value, width in writes:
        slots += [address, value]
        # ld t1,addr(t0); ld t2,value(t0); sb/sw t2,0(t1)
        offset = (len(slots) - 2) * 8
        code += [(offset << 20) | (5 << 15) | (3 << 12) | (6 << 7) | 3,
                 ((offset + 8) << 20) | (5 << 15) | (3 << 12) | (7 << 7) | 3,
                 (7 << 20) | (6 << 15) | ((2 if width == 4 else 0) << 12) | 0x23]
    code += [0x0330000F]  # fence rw,rw, including device stores
    displacement = TRAMPOLINE_OFFSET - len(code) * 4
    jal = (((displacement >> 20) & 1) << 31) | (((displacement >> 1) & 0x3FF) << 21)
    jal |= (((displacement >> 11) & 1) << 20) | (((displacement >> 12) & 0xFF) << 12) | 0x6F
    code.append(jal)  # jal zero, trampoline
    data_offset = (len(code) * 4 + 7) & ~7
    code[1] = (data_offset << 20) | (5 << 15) | (5 << 7) | 0x13
    prefix = b"".join(struct.pack("<I", instruction) for instruction in code)
    prefix = prefix.ljust(data_offset, b"\0")
    prefix += b"".join(struct.pack("<Q", value) for value in slots)
    if len(prefix) > TRAMPOLINE_OFFSET:
        raise ValueError("device restore prefix exceeds SRAM budget")
    image = prefix.ljust(TRAMPOLINE_OFFSET, b"\0") + trampoline
    return image, SRAM + TRAMPOLINE_OFFSET + mret[0]


class SparseRam:
    def __init__(self, directory):
        self.path = directory / "mem_pmem.bin"
        header, offsets = {}, []
        for line in (directory / "mem_pmem.bin.meta").read_text().splitlines():
            key, value = line.split("=", 1)
            if key == "chunk":
                offsets.append(int(value, 0))
            elif key in header:
                raise ValueError("duplicate sparse RAM header")
            else:
                header[key] = int(value, 0)
        self.size, self.chunk = header["size"], header["chunk_size"]
        if (not self.size or self.size % PAGE or not self.chunk or self.chunk % PAGE or
                len(offsets) != header["chunks"] or len(set(offsets)) != len(offsets) or
                any(n < 0 or n % self.chunk or n + self.chunk > self.size for n in offsets) or
                self.path.stat().st_size != len(offsets) * self.chunk):
            raise ValueError("invalid sparse RAM layout")
        self.offsets = {offset: i * self.chunk for i, offset in enumerate(offsets)}
        self.file = self.path.open("rb")
        self.data = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ) if offsets else None

    def close(self):
        if self.data is not None:
            self.data.close()
        self.file.close()

    def page(self, index):
        offset = index * PAGE
        if not 0 <= offset < self.size:
            raise ValueError("RAM page is out of range")
        chunk_offset = offset // self.chunk * self.chunk
        if chunk_offset not in self.offsets:
            return bytes(PAGE)
        begin = self.offsets[chunk_offset] + offset - chunk_offset
        return self.data[begin:begin + PAGE]

    def difference(self, other):
        if (self.size, self.chunk) != (other.size, other.chunk):
            raise ValueError("RAM images have different layouts")
        changed = set()
        for offset in self.offsets.keys() | other.offsets.keys():
            left, right = self.offsets.get(offset), other.offsets.get(offset)
            a = bytes(self.chunk) if left is None else self.data[left:left + self.chunk]
            b = bytes(self.chunk) if right is None else other.data[right:right + self.chunk]
            if a != b:
                for i in range(0, self.chunk, PAGE):
                    if a[i:i + PAGE] != b[i:i + PAGE]:
                        changed.add((offset + i) // PAGE)
        return changed

    def segments(self, pages=None, *, zero_file=None):
        if pages is None:
            return [(RAM + offset, pos, self.chunk, self.path)
                    for offset, pos in sorted(self.offsets.items())]
        result = []
        for page in sorted(pages):
            offset = page * PAGE
            if not 0 <= offset < self.size:
                raise ValueError("dirty page lies outside RAM")
            chunk_offset = offset // self.chunk * self.chunk
            if chunk_offset in self.offsets:
                position = self.offsets[chunk_offset] + offset - chunk_offset
                result.append((RAM + offset, position, PAGE, self.path))
            elif zero_file is not None:
                result.append((RAM + offset, 0, PAGE, zero_file))
            else:
                raise ValueError("zero page source was not supplied")
        return result


def write_segments(path, segments):
    with path.open("x") as stream:
        for address, offset, size, source in segments:
            if address % 8 or offset < 0 or size <= 0 or size % 8:
                raise ValueError("unaligned transfer segment")
            encoded = base64.b64encode(str(source.resolve()).encode()).decode()
            stream.write(f"{address:x} {offset} {size} {encoded}\n")


def segment_digest(segments):
    checksum = hashlib.sha256()
    for _address, offset, size, source in segments:
        with source.open("rb") as stream:
            stream.seek(offset)
            while size:
                data = stream.read(min(size, 1024 * 1024))
                if not data:
                    raise ValueError("short segment input")
                checksum.update(data)
                size -= len(data)
    return checksum.hexdigest()


def dirty_pages(bitmap, ram_bytes):
    if len(bitmap) != ram_bytes // PAGE // 8:
        raise ValueError("dirty bitmap has the wrong size")
    return {byte * 8 + bit for byte, value in enumerate(bitmap)
            for bit in range(8) if value & (1 << bit)}
