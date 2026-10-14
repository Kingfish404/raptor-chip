import struct
import unittest

from lib.block import BlockReplay, BLOCK_BASE, BLOCK_READ, BLOCK_WRITE, BLOCK_IRQ
from lib.rng import DMA_READ, DMA_WRITE


class BlockModelTest(unittest.TestCase):
    def setUp(self):
        self.memory = bytearray(262144)
        self.model = BlockReplay(lambda address, size, write=False: 0 <= address < len(self.memory) and 0 < size <= len(self.memory) - address,
                                 lambda address, size: bytes(self.memory[address:address + size]), self.store)
        self.model.disk_size = 131072
        self.disk = bytes((index * 7 + 3) & 255 for index in range(256)) * 512
        self.model.disk_write(0, self.disk)
        self.configure()

    def store(self, address, data):
        self.memory[address:address + len(data)] = data

    def configure(self, kind=0, sector=0):
        self.access(0x70, 0)
        for offset, value in ((0x38, 8), (0x80, 128), (0x90, 256), (0xa0, 320), (0x44, 1), (0x70, 4)):
            self.access(offset, value)
        struct.pack_into('<QIHH', self.memory, 128, 400, 16, 1, 1)
        struct.pack_into('<QIHH', self.memory, 144, 4096, 512, 1 if kind == 1 else 3, 2)
        struct.pack_into('<QIHH', self.memory, 160, 450, 1, 2, 0)
        struct.pack_into('<IIQ', self.memory, 400, kind, 0, sector)
        struct.pack_into('<HHH', self.memory, 256, 0, 1, 0)
        self.memory[320:388] = bytes(68)
        self.memory[450] = 0xa5

    def drive(self, generator):
        events = []
        while True:
            try:
                events.append(next(generator))
            except StopIteration as finished:
                return finished.value, events

    def access(self, offset, value=0, write=True):
        return self.drive(self.model.access(BLOCK_BASE + offset, value, write))

    def test_read_disk_to_guest(self):
        _, events = self.access(0x50)
        self.assertEqual(self.memory[4096:4608], self.disk[:512])
        self.assertEqual(self.memory[450], 0)
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 320), (0, 1, 0, 513))
        self.assertIn((BLOCK_READ, struct.pack('<2Q', 0, 512) + self.disk[:512]), events)
        self.assertIn((BLOCK_IRQ, struct.pack('<2Q', 1, 1)), events)

    def test_write_readback_survives_reset(self):
        self.configure(1, 4)
        self.memory[4096:4608] = b'\x6c' * 512
        _, events = self.access(0x50)
        self.assertIn((BLOCK_WRITE, struct.pack('<2Q', 2048, 512) + b'\x6c' * 512), events)
        self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1)
        self.configure(0, 4)
        self.memory[4096:4608] = bytes(512)
        self.access(0x50)
        self.assertEqual(self.memory[4096:4608], b'\x6c' * 512)
        self.assertEqual(self.model.disk_read(0, 2048), self.disk[:2048])

    def test_sector_overflow_bounds_and_direction(self):
        for kind, sector, flags in ((0, 1 << 55, 3), (0, 256, 3), (0, 0, 1), (1, 0, 3), (99, 0, 3)):
            self.configure(kind, sector)
            struct.pack_into('<H', self.memory, 156, flags)
            _, events = self.access(0x50)
            self.assertEqual(self.memory[450], 1)
            self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1)
            self.assertFalse(any(kind in (BLOCK_READ, BLOCK_WRITE) for kind, _ in events))

    def test_partial_chunk_preserves_writes(self):
        for kind in (0, 1):
            self.configure(kind)
            struct.pack_into('<QIHH', self.memory, 144, len(self.memory) - 65536, 65568, 1 if kind else 3, 2)
            self.memory[-65536:] = b'\xa5' * 65536
            _, events = self.access(0x50)
            self.assertEqual(self.memory[450], 1)
            self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1 if kind else 65537)
            if kind:
                self.assertEqual(self.model.disk_read(0, 65536), b'\xa5' * 65536)
                self.assertEqual(self.model.disk_read(65536, 32), self.disk[65536:65568])
                self.assertEqual(sum(event == BLOCK_WRITE for event, _ in events), 1)
            else:
                self.assertEqual(self.memory[-65536:], self.disk[:65536])
                self.assertEqual(sum(event == BLOCK_READ for event, _ in events), 2)

    def test_get_id_and_sparse_zero_page(self):
        self.configure(8, (1 << 64) - 1)
        _, events = self.access(0x50)
        self.assertEqual(self.memory[4096:4608], b'NEMU-VIRTIO-BLK'.ljust(512, b'\0'))
        self.assertFalse(any(kind in (BLOCK_READ, BLOCK_WRITE) for kind, _ in events))
        self.configure(0, 8)
        del self.model.disk_pages[1]
        self.access(0x50)
        self.assertEqual(self.memory[4096:4608], bytes(512))

    def test_used_failure_and_wrap(self):
        self.access(0xa0, len(self.memory) - 4)
        _, events = self.access(0x50)
        self.assertEqual(self.memory[450], 0)
        self.assertFalse(any(kind == BLOCK_IRQ for kind, _ in events))
        self.assertEqual(events[-1], (DMA_WRITE, struct.pack('<3Q', len(self.memory), 4, 0) + bytes(4)))
        self.configure()
        struct.pack_into('<H', self.memory, 322, 65535)
        self.access(0x50)
        self.assertEqual(struct.unpack_from('<H', self.memory, 322)[0], 0)
        self.assertEqual(struct.unpack_from('<II', self.memory, 380), (0, 513))

    def test_failed_head_read_and_invalid_header(self):
        self.access(0x90, len(self.memory) - 4)
        struct.pack_into('<H', self.memory, len(self.memory) - 2, 1)
        _, events = self.access(0x50)
        self.assertEqual(events[-1], (DMA_READ, struct.pack('<3Q', len(self.memory), 2, 0)))
        self.assertEqual(self.model.consumed, 0)
        self.configure()
        struct.pack_into('<H', self.memory, 140, 3)
        self.access(0x50)
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 320), (0, 1, 0, 0))
        self.assertEqual(self.memory[450], 0xa5)

    def test_cycles_lengths_and_zero_data(self):
        struct.pack_into('<H', self.memory, 158, 1)
        self.access(0x50)
        self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 7 * 512)
        self.assertEqual(self.memory[450], 0xa5)
        for size, expected in ((0, 0), (0x100001, 1)):
            self.configure()
            struct.pack_into('<I', self.memory, 152, size)
            self.access(0x50)
            self.assertEqual(self.memory[450], expected)
            self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1)

    def test_disabled_image_and_registers(self):
        self.model.disk_size = 0
        self.assertEqual(self.access(8, write=False)[0], 0)
        self.assertEqual(self.access(0x34, write=False)[0], 0)
        self.assertEqual(self.access(0x50)[1], [])
        self.access(0x38, 999)
        self.assertEqual(self.model.queue_size(), 256)
        self.access(0x14, 2)
        self.assertEqual(self.access(0x10, write=False)[0], 6)


if __name__ == '__main__':
    unittest.main()
