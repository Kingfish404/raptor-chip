"""Check that the independent vector comparators retain architectural differences."""

import unittest

from isa.vector_memory_spike import cases
from isa.vector_spike import comparable_registers


class VectorComparisonTest(unittest.TestCase):
    def test_arithmetic_keeps_every_byte(self):
        original = bytes(512)
        for offset in (0, 127, 383, 384, 399, 400, 511):
            changed = bytearray(original)
            changed[offset] = 1
            self.assertNotEqual(comparable_registers('vadd.vv', original, 32, 3),
                                comparable_registers('vadd.vv', changed, 32, 3))

    def test_mask_ignores_only_destination_tail(self):
        original = bytes(512)
        changed = bytearray(original)
        changed[385:400] = bytes([255]) * 15
        changed[384] = 0xf8
        self.assertEqual(comparable_registers('vmseq.vv', original, 32, 3),
                         comparable_registers('vmseq.vv', changed, 32, 3))
        for offset, value in ((384, 1), (383, 255), (400, 255)):
            with self.subTest(offset=offset):
                changed[offset] = value
                self.assertNotEqual(comparable_registers('vmseq.vv', original, 32, 3),
                                    comparable_registers('vmseq.vv', changed, 32, 3))
                changed[offset] = 0

    def test_reduction_preserves_result_and_other_registers(self):
        for name, result_size in (('vredsum.vs', 4), ('vfredosum.vs', 4),
                                  ('vwredsum.vs', 8), ('vfwredusum.vs', 8)):
            with self.subTest(name=name):
                original = bytes(512)
                changed = bytearray(original)
                changed[384 + result_size:400] = bytes([255]) * (16 - result_size)
                self.assertEqual(comparable_registers(name, original, 32, 3),
                                 comparable_registers(name, changed, 32, 3))
                changed[384 + result_size - 1] = 1
                self.assertNotEqual(comparable_registers(name, original, 32, 3),
                                    comparable_registers(name, changed, 32, 3))
                changed[384 + result_size - 1] = 0
                changed[400] = 1
                self.assertNotEqual(comparable_registers(name, original, 32, 3),
                                    comparable_registers(name, changed, 32, 3))

    def test_memory_matrix(self):
        rows = list(cases())
        self.assertEqual(len(rows), 9722)
        self.assertEqual({row['mode'] for row in rows},
                         {'unit', 'strided', 'negative-stride', 'indexed', 'ordered',
                          'fof', 'whole', 'mask'})
        self.assertEqual({row['lmul'] for row in rows}, {0, 1, 2, 3, 5, 6, 7})
        self.assertEqual({row['width'] for row in rows}, {0, 1, 2, 3})
        for row in rows:
            self.assertGreater(row['vl'], 0)
            self.assertEqual(row['opcode'] & 0x7f, 0x27 if row['store'] else 0x07)


if __name__ == '__main__':
    unittest.main()
