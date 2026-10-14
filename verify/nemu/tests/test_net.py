import struct
import unittest

from lib.net import NetReplay, NET_RX, NET_TX, NET_IRQ, NET_RX_RESULT, NET_BASE
from lib.rng import DMA_READ, DMA_WRITE, MASK64


class NetModelTest(unittest.TestCase):
    def setUp(self):
        self.memory = bytearray(131072)
        self.responses = []
        self.model = NetReplay(self.mapped, lambda address, size: bytes(self.memory[address:address + size]), self.store)
        for queue in range(2):
            for offset, value in ((0x30, queue), (0x38, 4), (0x80, 64 + queue * 256),
                                  (0x90, 128 + queue * 256), (0xa0, 192 + queue * 256), (0x44, 1)):
                self.access(offset, value)
            struct.pack_into('<HHH', self.memory, 128 + queue * 256, 0, 1, 0)
        self.access(0x70, 4)
        self.memory[1024:1280] = b'\xa5' * 256
        self.memory[2048:2112] = bytes(12) + bytes(range(52))
        struct.pack_into('<QIHH', self.memory, 64, 1024, 64, 2, 0)
        struct.pack_into('<QIHH', self.memory, 320, 2048, 64, 0, 0)

    def mapped(self, address, size, write=False):
        return 0 <= address < len(self.memory) and 0 < size <= len(self.memory) - address

    def store(self, address, data):
        self.memory[address:address + len(data)] = data

    def drive(self, generator):
        sent, events = None, []
        while True:
            try:
                kind, payload = generator.send(sent)
            except StopIteration as finished:
                return finished.value, events
            sent = None
            if kind == NET_RX and payload is None:
                sent = self.responses.pop(0) if self.responses else None
                if sent is None:
                    continue
                payload = struct.pack('<2Q', len(sent), 1) + sent
            events.append((kind, payload))

    def access(self, offset, value=0, write=True, size=4):
        return self.drive(self.model.access(NET_BASE + offset, value, size, write))

    def test_synchronous_rx_before_tx_used(self):
        self.responses = [bytes(range(52))]
        _, events = self.access(0x50, 1)
        self.assertEqual(self.memory[1024:1088], bytes(12) + bytes(range(52)))
        self.assertEqual(self.memory[1088:1280], b'\xa5' * 192)
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 192), (0, 1, 0, 64))
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 448), (0, 1, 0, 64))
        self.assertIn((NET_TX, struct.pack('<2Q', 52, 1) + bytes(range(52))), events)
        kinds = [kind for kind, _ in events]
        self.assertLess(kinds.index(NET_TX), kinds.index(NET_RX))
        self.assertEqual(kinds.count(NET_IRQ), 2)
        self.assertIn((NET_RX_RESULT, struct.pack('<3Q', 52, 1, 1)), events)
        self.assertEqual(self.access(0x60, write=False)[0], 1)
        self.access(0x64, 1)
        self.assertEqual(self.access(0x60, write=False)[0], 0)

    def test_idle_receive_and_drop(self):
        _, events = self.drive(self.model.receive(b'hello', False))
        self.assertIn((NET_IRQ, struct.pack('<2Q', 2, 0)), events)
        self.assertEqual(events[-1], (NET_RX_RESULT, struct.pack('<3Q', 5, 1, 0)))
        self.assertEqual(self.memory[1024:1041], bytes(12) + b'hello')
        _, events = self.drive(self.model.receive(b'again', False))
        self.assertEqual(events[-1], (NET_RX_RESULT, struct.pack('<3Q', 5, 0, 0)))
        self.assertEqual(len(events), 2)

    def test_empty_packet_and_short_header(self):
        struct.pack_into('<I', self.memory, 328, 12)
        self.responses = [b'']
        _, events = self.access(0x50, 1)
        self.assertIn((NET_TX, struct.pack('<2Q', 0, 1)), events)
        self.assertIn((NET_RX_RESULT, struct.pack('<3Q', 0, 1, 1)), events)
        self.setUp()
        struct.pack_into('<I', self.memory, 328, 11)
        _, events = self.access(0x50, 1)
        self.assertFalse(any(kind == NET_TX for kind, _ in events))
        self.assertEqual(struct.unpack_from('<I', self.memory, 456)[0], 11)

    def test_partial_copy_then_failure(self):
        struct.pack_into('<QIHH', self.memory, 64, 1024, 8, 3, 1)
        struct.pack_into('<QIHH', self.memory, 80, 1 << 32, 8, 2, 0)
        _, events = self.drive(self.model.receive(b'abcd', False))
        self.assertEqual(self.memory[1024:1040], bytes(8) + b'\xa5' * 8)
        self.assertIn((DMA_WRITE, struct.pack('<3Q', 1 << 32, 8, 0) + bytes(4) + b'abcd'), events)
        self.assertEqual(events[-1], (NET_RX_RESULT, struct.pack('<3Q', MASK64, 2, 0)))
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 192), (0, 1, 0, 0))

    def test_used_commit_failure_preserves_prior_writes(self):
        self.access(0x30, 0)
        self.access(0xa0, len(self.memory) - 8)
        _, events = self.drive(self.model.receive(b'abc', True))
        self.assertEqual(self.memory[1024:1039], bytes(12) + b'abc')
        self.assertIn((DMA_WRITE, struct.pack('<3Q', len(self.memory), 4, 0) + struct.pack('<I', 15)), events)
        self.assertFalse(any(kind == NET_IRQ for kind, _ in events))
        self.assertEqual(events[-1], (NET_RX_RESULT, struct.pack('<3Q', MASK64, 2, 1)))

    def test_failed_available_head_read(self):
        self.access(0x30, 1)
        self.access(0x90, len(self.memory) - 4)
        struct.pack_into('<H', self.memory, len(self.memory) - 2, 1)
        _, events = self.access(0x50, 1)
        self.assertEqual(events[-1], (DMA_READ, struct.pack('<3Q', len(self.memory), 2, 0)))
        self.assertEqual(self.model.queues[1]['consumed'], 0)

    def test_cycle_and_oversized_frame(self):
        for length, flags in ((16, 1), (65537, 0)):
            self.setUp()
            struct.pack_into('<QIHH', self.memory, 320, 2048, length, flags, 0)
            _, events = self.access(0x50, 1)
            self.assertFalse(any(kind == NET_TX for kind, _ in events))
            self.assertEqual(struct.unpack_from('<HHII', self.memory, 448), (0, 1, 0, 0))

    def test_zero_descriptor_and_ring_wrap(self):
        struct.pack_into('<QIHH', self.memory, 64, MASK64, 0, 3, 1)
        struct.pack_into('<QIHH', self.memory, 80, 1024, 64, 2, 0)
        self.model.queues[0]['consumed'] = 65535
        struct.pack_into('<H', self.memory, 130, 0)
        struct.pack_into('<H', self.memory, 138, 0)
        struct.pack_into('<H', self.memory, 194, 65535)
        self.drive(self.model.receive(b'abc', True))
        self.assertEqual(self.model.queues[0]['consumed'], 0)
        self.assertEqual(struct.unpack_from('<H', self.memory, 194)[0], 0)
        self.assertEqual(struct.unpack_from('<II', self.memory, 220), (0, 15))
        self.assertEqual(self.memory[1024:1039], bytes(12) + b'abc')

    def test_maximum_frame(self):
        packet = b'\x5a' * 65524
        struct.pack_into('<QIHH', self.memory, 64, 4096, 65536, 2, 0)
        _, events = self.drive(self.model.receive(packet, False))
        self.assertEqual(self.memory[4096:69632], bytes(12) + packet)
        self.assertIn((DMA_WRITE, struct.pack('<3Q', 4096, 65536, 1) + bytes(12) + packet), events)

    def test_register_masks_and_reset(self):
        self.assertEqual(self.access(0x101, write=False, size=1)[0], 0x54)
        self.assertEqual(self.access(0x104, write=False, size=2)[0], 0x5634)
        self.access(0x38, 999)
        self.assertEqual(self.model.queues[1]['size'], 256)
        self.access(0x30, 2)
        self.access(0x38, 1)
        self.assertEqual(self.access(0x34, write=False)[0], 0)
        self.access(0x70, 0)
        self.assertEqual(self.access(0x50, 1)[1], [])
        self.assertEqual(self.model.queues[1]['size'], 0)


if __name__ == '__main__':
    unittest.main()
