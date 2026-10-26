"""Independent split-queue network model; raw RX is external, TX/DMA/IRQs derived."""
import struct

from lib.rng import DMA_READ, DMA_WRITE, MASK64

NET_RX, NET_TX, NET_IRQ, NET_RX_RESULT = 20, 21, 22, 23
NET_BASE = 0x10002000


class NetReplay:
    def __init__(self, mapped, read, store):
        self.mapped, self.read, self.store = mapped, read, store
        self.reset()

    def reset(self):
        self.queues = [dict(size=0, ready=0, descriptors=0, available=0, used=0, consumed=0) for _ in range(2)]
        self.feature_select = self.driver_select = self.queue_select = self.status = self.interrupt_status = 0
        self.driver_features = [0, 0]

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

    def pop(self, queue):
        if not self.status & 4 or not all(queue[field] for field in ('size', 'ready', 'descriptors', 'available', 'used')):
            return None
        raw = yield from self.read_dma(queue['available'] + 2, 2)
        if raw is None or int.from_bytes(raw, 'little') == queue['consumed']:
            return None
        raw = yield from self.read_dma(queue['available'] + 4 + 2 * (queue['consumed'] % queue['size']), 2)
        if raw is None:
            return None
        queue['consumed'] = (queue['consumed'] + 1) & 0xffff
        head = int.from_bytes(raw, 'little')
        return head if head < queue['size'] else None

    def push(self, queue, head, length, executing):
        raw = yield from self.read_dma(queue['used'] + 2, 2)
        if raw is None:
            return False
        used = int.from_bytes(raw, 'little')
        element = queue['used'] + 4 + 8 * (used % queue['size'])
        for address, data in ((element, struct.pack('<I', head)), (element + 4, struct.pack('<I', length)),
                              (queue['used'] + 2, struct.pack('<H', (used + 1) & 0xffff))):
            if not (yield from self.write_dma(address, data)):
                return False
        self.interrupt_status |= 1
        yield NET_IRQ, struct.pack('<2Q', 2, executing)
        return True

    def descriptor(self, queue, head):
        if head >= queue['size']:
            return None
        raw = yield from self.read_dma(queue['descriptors'] + 16 * head, 16)
        return struct.unpack('<QIHH', raw) if raw is not None else None

    def copy_from(self, queue, head):
        result = bytearray()
        for _ in range(queue['size']):
            descriptor = yield from self.descriptor(queue, head)
            if descriptor is None:
                return b''
            address, length, flags, head = descriptor
            if flags & 2 or length > 65536 - len(result):
                return b''
            raw = yield from self.read_dma(address, length)
            if raw is None:
                return b''
            result.extend(raw)
            if not flags & 1:
                return bytes(result)
        return b''

    def copy_to(self, queue, head, data):
        copied = 0
        for _ in range(queue['size']):
            if copied == len(data):
                break
            descriptor = yield from self.descriptor(queue, head)
            if descriptor is None:
                return 0
            address, length, flags, head = descriptor
            if not flags & 2:
                return 0
            chunk = data[copied:copied + length]
            if not (yield from self.write_dma(address, chunk)):
                return 0
            copied += len(chunk)
            if not flags & 1:
                break
        return copied if copied == len(data) else 0

    def receive(self, packet, executing):
        head = yield from self.pop(self.queues[0])
        result, disposition = len(packet), 0
        if head is not None:
            written = yield from self.copy_to(self.queues[0], head, bytes(12) + packet)
            committed = yield from self.push(self.queues[0], head, written, executing)
            result, disposition = (len(packet), 1) if written and committed else (MASK64, 2)
        yield NET_RX_RESULT, struct.pack('<3Q', result, disposition, executing)

    def transmit(self):
        while True:
            head = yield from self.pop(self.queues[1])
            if head is None:
                return
            frame = yield from self.copy_from(self.queues[1], head)
            if len(frame) >= 12:
                yield NET_TX, struct.pack('<2Q', len(frame) - 12, 1) + frame[12:]
                while True:
                    packet = yield NET_RX, None
                    if packet is None:
                        break
                    yield from self.receive(packet, True)
            if not (yield from self.push(self.queues[1], head, len(frame), True)):
                return

    def access(self, address, value, size, write):
        offset = (address - NET_BASE) & ~3
        queue = self.queues[self.queue_select] if self.queue_select < 2 else None
        if write:
            if offset == 0x14:
                self.feature_select = value
            elif offset == 0x20:
                self.driver_features[self.driver_select & 1] = value
            elif offset == 0x24:
                self.driver_select = value
            elif offset == 0x30:
                self.queue_select = value
            elif offset == 0x38 and queue is not None:
                queue['size'] = min(value, 256)
            elif offset == 0x44 and queue is not None:
                queue['ready'] = value & 1
            elif offset == 0x50 and value == 1:
                yield from self.transmit()
            elif offset == 0x64:
                self.interrupt_status &= ~value
            elif offset == 0x70:
                self.status = value
                if not value:
                    self.reset()
            elif offset in (0x80, 0x84, 0x90, 0x94, 0xa0, 0xa4) and queue is not None:
                field = {0x80: 'descriptors', 0x90: 'available', 0xa0: 'used'}[offset & ~4]
                queue[field] = ((queue[field] & 0xffffffff) | value << 32 if offset & 4 else
                                (queue[field] & ~0xffffffff) | value)
            return 0
        value = {0: 0x74726976, 4: 2, 8: 1, 12: 0x554d4551, 0x100: 0x12005452, 0x104: 0x5634}.get(offset, 0)
        if offset == 0x10:
            value = {0: 32, 1: 1}.get(self.feature_select, 0)
        elif offset == 0x34:
            value = 256 if queue is not None else 0
        elif offset == 0x44:
            value = queue['ready'] if queue is not None else 0
        elif offset == 0x60:
            value = self.interrupt_status
        elif offset == 0x70:
            value = self.status
        return (value >> ((address & 3) * 8)) & ((1 << (size * 8)) - 1)
