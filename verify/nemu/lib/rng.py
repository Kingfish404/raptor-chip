"""Independent virtio-rng transaction model for version-7 journal inspection."""
import struct

DMA_READ, DMA_WRITE, RNG_INPUT, RNG_IRQ = 16, 17, 18, 19
RNG_BASE = 0x10003000
MASK64 = (1 << 64) - 1


class RngReplay:
    def __init__(self, mapped, read, store):
        self.mapped = mapped
        self.read = read
        self.store = store
        self.registers = {}
        self.features = [0, 0]
        self.available_index = 0

    def address(self, offset):
        return self.registers.get(offset, 0) | self.registers.get(offset + 4, 0) << 32

    def read_dma(self, address, length):
        address &= MASK64
        success = self.mapped(address, length)
        data = self.read(address, length) if success else b''
        yield DMA_READ, struct.pack('<3Q', address, length, success) + data
        return data if success else None

    def write_dma(self, address, data):
        address &= MASK64
        success = self.mapped(address, len(data), True)
        yield DMA_WRITE, struct.pack('<3Q', address, len(data), success) + data
        if success:
            self.store(address, data)
        return success

    def fill(self, head):
        written = 0
        for _ in range(self.registers[0x38]):
            if head >= self.registers[0x38]:
                break
            descriptor = yield from self.read_dma(self.address(0x80) + 16 * head, 16)
            if descriptor is None:
                break
            address, remaining, flags, following = struct.unpack('<QIHH', descriptor)
            if not flags & 2:
                break
            while remaining:
                chunk = min(remaining, 256)
                entropy = yield RNG_INPUT, struct.pack('<Q', chunk)
                if entropy is None or not (yield from self.write_dma(address, entropy)):
                    return written
                address += chunk
                remaining -= chunk
                written = (written + chunk) & 0xffffffff
            if not flags & 1:
                break
            head = following
        return written

    def notify(self):
        count = self.registers.get(0x38, 0)
        available, used = self.address(0x90), self.address(0xa0)
        if (self.registers.get(0x30, 0) or not count or not self.registers.get(0x44, 0) or
                not self.registers.get(0x70, 0) & 4 or not self.address(0x80) or not available or not used):
            return
        while True:
            data = yield from self.read_dma(available + 2, 2)
            if data is None or int.from_bytes(data, 'little') == self.available_index:
                return
            data = yield from self.read_dma(available + 4 + 2 * (self.available_index % count), 2)
            if data is None:
                return
            head = int.from_bytes(data, 'little')
            self.available_index = (self.available_index + 1) & 0xffff
            if head >= count:
                return
            length = yield from self.fill(head)
            data = yield from self.read_dma(used + 2, 2)
            if data is None:
                return
            used_index = int.from_bytes(data, 'little')
            element = used + 4 + 8 * (used_index % count)
            if not (yield from self.write_dma(element, struct.pack('<I', head))):
                return
            if not (yield from self.write_dma(element + 4, struct.pack('<I', length))):
                return
            if not (yield from self.write_dma(used + 2, struct.pack('<H', (used_index + 1) & 0xffff))):
                return
            self.registers[0x60] = self.registers.get(0x60, 0) | 1
            yield RNG_IRQ, struct.pack('<2Q', 3, 1)

    def access(self, address, value, write):
        offset = address - RNG_BASE
        if write:
            if offset in (0x14, 0x24, 0x30, 0x80, 0x84, 0x90, 0x94, 0xa0, 0xa4):
                self.registers[offset] = value
            elif offset == 0x20:
                self.features[self.registers.get(0x24, 0) & 1] = value
            elif offset == 0x38:
                self.registers[offset] = min(value, 8)
            elif offset == 0x44:
                self.registers[offset] = value & 1
            elif offset == 0x50 and value == 0:
                yield from self.notify()
            elif offset == 0x64:
                self.registers[0x60] = self.registers.get(0x60, 0) & ~value
            elif offset == 0x70:
                self.registers[offset] = value
                if not value:
                    self.registers.clear()
                    self.features = [0, 0]
                    self.available_index = 0
            return 0
        if offset == 0x10:
            return int(self.registers.get(0x14, 0) == 1)
        if offset == 0x34:
            return 0 if self.registers.get(0x30, 0) else 8
        if offset in (0x44, 0x60, 0x70):
            return self.registers.get(offset, 0)
        return {0: 0x74726976, 4: 2, 8: 4, 12: 0x554d4551}.get(offset, 0)
