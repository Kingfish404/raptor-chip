import struct
import unittest

from lib.rng import RngReplay, DMA_READ, DMA_WRITE, RNG_INPUT, RNG_IRQ, RNG_BASE


class RngModelTest(unittest.TestCase):
    def setUp(self):
        self.memory = bytearray(4096)
        self.entropy = bytes(range(256)) * 8
        self.position = 0
        self.model = RngReplay(lambda address, length, write=False: 0 <= address < 4096 and 0 < length <= 4096 - address,
                               lambda address, length: bytes(self.memory[address:address + length]), self.store)
        for offset, value in ((0x38, 4), (0x80, 64), (0x90, 128), (0xa0, 192), (0x44, 1), (0x70, 4)):
            self.access(offset, value)
        self.memory[512:1024] = b'\xa5' * 512
        struct.pack_into('<QIHH', self.memory, 64, 512, 300, 2, 0)
        struct.pack_into('<HHH', self.memory, 128, 0, 1, 0)

    def store(self, address, data):
        self.memory[address:address + len(data)] = data

    def drive(self, generator):
        sent = None
        events = []
        while True:
            try:
                kind, payload = generator.send(sent)
            except StopIteration as finished:
                return finished.value, events
            sent = None
            if kind == RNG_INPUT:
                length, = struct.unpack('<Q', payload)
                raw = self.entropy[self.position:self.position + length]
                self.position += len(raw)
                success = len(raw) == length
                payload += struct.pack('<Q', success) + (raw if success else b'')
                sent = raw if success else None
            events.append((kind, payload))

    def access(self, offset, value=0, write=True):
        return self.drive(self.model.access(RNG_BASE + offset, value, write))

    def test_chunks_and_ring(self):
        _, events = self.access(0x50)
        self.assertEqual(self.memory[512:812], self.entropy[:300])
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 192), (0, 1, 0, 300))
        self.assertEqual([len(data) - 16 for kind, data in events if kind == RNG_INPUT], [256, 44])
        self.assertEqual(sum(kind == RNG_IRQ for kind, _ in events), 1)
        self.assertEqual(self.access(0x60, write=False)[0], 1)
        self.assertEqual(len(self.access(0x50)[1]), 1)
        self.access(0x64, 1)
        self.assertEqual(self.access(0x60, write=False)[0], 0)

    def test_partial_entropy_eof(self):
        self.entropy = self.entropy[:270]
        _, events = self.access(0x50)
        self.assertEqual(self.memory[512:768], self.entropy[:256])
        self.assertEqual(self.memory[768:812], b'\xa5' * 44)
        self.assertEqual(struct.unpack_from('<I', self.memory, 200)[0], 256)
        self.assertIn((RNG_INPUT, struct.pack('<2Q', 44, 0)), events)

    def test_failed_available_read(self):
        self.access(0x94, 1)
        _, events = self.access(0x50)
        self.assertEqual(events, [(DMA_READ, struct.pack('<3Q', (1 << 32) + 130, 2, 0))])
        self.assertEqual(self.model.available_index, 0)
        self.assertEqual(self.memory[512:1024], b'\xa5' * 512)

    def test_failed_used_update(self):
        self.access(0xa0, 4092)
        _, events = self.access(0x50)
        self.assertEqual(events[-1], (DMA_WRITE, struct.pack('<3Q', 4096, 4, 0) + bytes(4)))
        self.assertEqual(sum(kind == RNG_IRQ for kind, _ in events), 0)
        self.assertEqual(self.memory[512:812], self.entropy[:300])
        self.assertEqual(self.model.available_index, 1)

    def test_descriptor_chain_and_wrap(self):
        struct.pack_into('<QIHH', self.memory, 64, 512, 4, 3, 1)
        struct.pack_into('<QIHH', self.memory, 80, 516, 3, 2, 0)
        self.model.available_index = 65535
        struct.pack_into('<H', self.memory, 130, 0)
        struct.pack_into('<H', self.memory, 138, 0)
        struct.pack_into('<H', self.memory, 194, 65535)
        self.access(0x50)
        self.assertEqual(self.memory[512:519], self.entropy[:7])
        self.assertEqual(self.model.available_index, 0)
        self.assertEqual(struct.unpack_from('<H', self.memory, 194)[0], 0)
        self.assertEqual(struct.unpack_from('<II', self.memory, 220), (0, 7))

    def test_reset_and_masks(self):
        self.access(0x50)
        self.access(0x38, 255)
        self.assertEqual(self.model.registers[0x38], 8)
        self.access(0x44, 2)
        self.assertEqual(self.access(0x44, write=False)[0], 0)
        self.access(0x70, 0)
        self.assertEqual(self.model.available_index, 0)
        self.assertEqual(self.access(0x50)[1], [])
        self.assertEqual(self.access(0x60, write=False)[0], 0)


if __name__ == '__main__':
    unittest.main()
