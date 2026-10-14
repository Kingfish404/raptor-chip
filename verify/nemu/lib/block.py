"""Independent virtio-blk split-queue model with a private sparse disk image."""
import struct

from lib.rng import DMA_READ, DMA_WRITE, MASK64

BLOCK_IMAGE, BLOCK_PAGE, BLOCK_READ, BLOCK_WRITE, BLOCK_IRQ = range(24, 29)
BLOCK_BASE = 0x10001000
BLOCK_MAX_IMAGE = 16 << 30


class BlockReplay:
    def __init__(self, mapped, read, store):
        self.mapped, self.read, self.store = mapped, read, store
        self.disk_size = 0
        self.disk_pages = {}
        self.reset()

    def reset(self):
        self.registers = dict.fromkeys((0x14, 0x24, 0x30, 0x38, 0x44, 0x60, 0x70, 0x80, 0x84, 0x90, 0x94, 0xa0, 0xa4), 0)
        self.driver_features = [0, 0]
        self.consumed = 0

    def address(self, register):
        return self.registers[register] | self.registers[register + 4] << 32

    def queue_size(self):
        return self.registers[0x38] or 256

    def disk_read(self, offset, size):
        result = bytearray()
        while size:
            page, start = divmod(offset, 4096)
            length = min(size, 4096 - start)
            result.extend(self.disk_pages.get(page, bytes(4096))[start:start + length])
            offset += length
            size -= length
        return bytes(result)

    def disk_write(self, offset, data):
        done = 0
        while done < len(data):
            page, start = divmod(offset + done, 4096)
            length = min(len(data) - done, 4096 - start)
            self.disk_pages.setdefault(page, bytearray(4096))[start:start + length] = data[done:done + length]
            done += length

    def read_dma(self, address, size):
        if not size:
            return b''
        address &= MASK64
        success = self.mapped(address, size)
        data = self.read(address, size) if success else b''
        yield DMA_READ, struct.pack('<3Q', address, size, success) + data
        return data if success else None

    def write_dma(self, address, data):
        if not data:
            return True
        address &= MASK64
        success = self.mapped(address, len(data), True)
        yield DMA_WRITE, struct.pack('<3Q', address, len(data), success) + data
        if success:
            self.store(address, data)
        return success

    def descriptor(self, index):
        if index >= self.queue_size():
            return None
        data = yield from self.read_dma(self.address(0x80) + 16 * index, 16)
        return struct.unpack('<QIHH', data) if data is not None else None

    def transfer(self, kind, address, size, offset):
        written = 0
        if size > 0x100000 or (kind != 8 and (offset > self.disk_size or size > self.disk_size - offset)):
            return False, offset, written
        identity = b'NEMU-VIRTIO-BLK'.ljust(20, b'\0')
        for done in range(0, size, 65536):
            length = min(size - done, 65536)
            if kind == 1:
                data = yield from self.read_dma(address + done, length)
                if data is None:
                    return False, offset, written
                yield BLOCK_WRITE, struct.pack('<2Q', offset, length) + data
                self.disk_write(offset, data)
            else:
                if kind == 0:
                    data = self.disk_read(offset, length)
                    yield BLOCK_READ, struct.pack('<2Q', offset, length) + data
                else:
                    data = identity[done:done + length].ljust(length, b'\0')
                if not (yield from self.write_dma(address + done, data)):
                    return False, offset, written
                written += length
            if kind != 8:
                offset += length
        return True, offset, written

    def finish(self, head, length):
        base = self.address(0xa0)
        raw = yield from self.read_dma(base + 2, 2)
        if raw is None:
            return
        used = int.from_bytes(raw, 'little')
        element = base + 4 + 8 * (used % self.queue_size())
        for address, data in ((element, struct.pack('<I', head)), (element + 4, struct.pack('<I', length)),
                              (base + 2, struct.pack('<H', (used + 1) & 0xffff))):
            if not (yield from self.write_dma(address, data)):
                return
        self.registers[0x60] |= 1
        yield BLOCK_IRQ, struct.pack('<2Q', 1, 1)

    def request(self, head):
        first = yield from self.descriptor(head)
        raw = None
        if first is not None and first[1] >= 16 and first[2] & 1 and not first[2] & 2:
            raw = yield from self.read_dma(first[0], 16)
        if raw is None:
            yield from self.finish(head, 0)
            return
        kind, _, sector = struct.unpack('<IIQ', raw)
        offset = sector * 512 if sector <= MASK64 // 512 and sector * 512 < self.disk_size else None
        success = offset is not None or kind == 8
        offset = offset or 0
        written, index = 0, first[3]
        supported = kind in (0, 1, 8)
        for _ in range(1, self.queue_size()):
            descriptor = yield from self.descriptor(index)
            if descriptor is None:
                break
            address, length, flags, index = descriptor
            if not flags & 1:
                if length and flags & 2 and (yield from self.write_dma(address, bytes([0 if success and supported else 1]))):
                    written += 1
                break
            if not supported or bool(flags & 2) != (kind != 1):
                success = False
            if success:
                success, offset, added = yield from self.transfer(kind, address, length, offset)
                written += added
        yield from self.finish(head, written)

    def notify(self):
        if not self.disk_size or self.registers[0x30] or not self.registers[0x44] or not self.registers[0x70] & 4:
            return
        if not all(self.address(offset) for offset in (0x80, 0x90, 0xa0)):
            return
        raw = yield from self.read_dma(self.address(0x90) + 2, 2)
        if raw is None:
            return
        available = int.from_bytes(raw, 'little')
        while self.consumed != available:
            raw = yield from self.read_dma(self.address(0x90) + 4 + 2 * (self.consumed % self.queue_size()), 2)
            if raw is None:
                return
            head = int.from_bytes(raw, 'little')
            if head < self.queue_size():
                yield from self.request(head)
            self.consumed = (self.consumed + 1) & 0xffff

    def access(self, address, value, write):
        offset = address - BLOCK_BASE
        if write:
            if offset == 0x50:
                yield from self.notify()
            elif offset == 0x20:
                self.driver_features[self.registers[0x24] & 1] = value
            elif offset == 0x64:
                self.registers[0x60] &= ~value
            elif offset != 0x60 and offset in self.registers:
                self.registers[offset] = min(value, 256) if offset == 0x38 else value & 1 if offset == 0x44 else value
                if offset == 0x70 and not value:
                    self.reset()
            return 0
        if offset == 0x10:
            return 1 if self.registers[0x14] == 1 else 6
        if offset == 0x34:
            return 256 if self.disk_size and not self.registers[0x30] else 0
        if offset in (0x44, 0x60, 0x70):
            return self.registers[offset]
        return {0: 0x74726976, 4: 2, 8: 2 if self.disk_size else 0, 12: 0x554d4551,
                0x100: (self.disk_size // 512) & 0xffffffff, 0x104: self.disk_size // 512 >> 32,
                0x108: 0x100000, 0x10c: 128}.get(offset, 0)
