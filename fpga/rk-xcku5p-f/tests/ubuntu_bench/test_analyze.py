import struct
import unittest

from analyze import containing_symbol, records


class PerfRecordsTest(unittest.TestCase):
    def test_sample_and_lost(self):
        stream = struct.pack("<IHHQQ", 9, 2, 24, 0x1234, 99)
        stream += struct.pack("<IHHQQ", 2, 0, 24, 7, 13)
        parsed = list(records(stream))
        self.assertEqual(parsed[0][:2], (9, 2))
        self.assertEqual(struct.unpack("<QQ", parsed[0][2]), (0x1234, 99))
        self.assertEqual(struct.unpack("<QQ", parsed[1][2]), (7, 13))

    def test_rejects_incomplete_and_wrong_layout(self):
        for stream in (b"\0", struct.pack("<IHH", 9, 2, 0),
                       struct.pack("<IHH", 9, 2, 24),
                       struct.pack("<IHHQ", 9, 2, 16, 0),
                       struct.pack("<IHHQ", 2, 0, 16, 0)):
            with self.subTest(stream=stream), self.assertRaises(ValueError):
                list(records(stream))

    def test_empty_and_unknown(self):
        self.assertEqual(list(records(b"")), [])
        self.assertEqual(list(records(struct.pack("<IHH", 123, 0, 8))), [(123, 0, b"")])

    def test_symbol_requires_containment(self):
        symbols = [(0x100, 0x20, "first"), (0x200, 0x10, "second")]
        self.assertEqual(containing_symbol(0x100, symbols), "first")
        self.assertEqual(containing_symbol(0x11f, symbols), "first")
        self.assertEqual(containing_symbol(0x120, symbols), "[unresolved text]")
        self.assertEqual(containing_symbol(0x1ff, symbols), "[unresolved text]")


if __name__ == "__main__":
    unittest.main()
