import binascii
import json
import os
from pathlib import Path
import struct
import tempfile
import threading
import unittest

from tools.bringup.client import (BinaryTransport, Board, BringupError, bootrom, decode,
                                  packet, write_result)


class EchoBoard:
    def __init__(self):
        self.calls = []
        self.memory = {0: 0x52504231, 4: 0, 0x3C: 524288}

    def exchange(self, raw):
        _, op, seq, _, addr, data, aux, _ = decode(raw)
        self.calls.append((op, addr, data, aux))
        if op == 2:
            self.memory[addr] = data
        result = self.memory.get(addr, 0) if op == 1 else 0
        return packet(0x5A, op, seq, addr, result, aux)


class HostTests(unittest.TestCase):
    def test_crc_known_vector(self):
        self.assertEqual(binascii.crc_hqx(b"123456789", 0xFFFF), 0x29B1)
        raw = packet(0xA5, 2, 17, 0x80000000, 0x12345678, 9)
        self.assertEqual(decode(raw)[1:3], (2, 17))
        self.assertEqual(raw[8:12], b"\x78\x56\x34\x12")

    def test_corruption_and_short_packet(self):
        raw = bytearray(packet(0x5A, 1, 0))
        for bit in range(128):
            corrupt = bytearray(raw)
            corrupt[bit // 8] ^= 1 << (bit % 8)
            with self.assertRaises(BringupError):
                decode(corrupt)
        with self.assertRaises(BringupError):
            decode(b"short")

    def test_reply_sequence_and_error(self):
        class Wrong:
            def exchange(self, raw):
                return packet(0x5A, 1, 7)
        with self.assertRaisesRegex(BringupError, "identity"):
            Board(Wrong()).read(0)
        class Error:
            def exchange(self, raw):
                _, op, seq, _, addr, _, aux, _ = decode(raw)
                return packet(0x5A, op, seq, addr, aux=aux, status=3)
        with self.assertRaisesRegex(BringupError, "status 3"):
            Board(Error()).write(8, 9)

    def test_load_holds_reset_and_verifies_partial_word(self):
        transport = EchoBoard()
        transport.memory[4] = 7
        board = Board(transport)
        board.load(0x80000000, b"abcde")
        self.assertEqual(transport.calls[:2], [(1, 4, 0, 0), (2, 4, 5, 0)])
        self.assertEqual(transport.memory[0x80000004], ord("e"))
        self.assertEqual(transport.memory[4], 5)

    def test_reset_clears_irq_request_and_release(self):
        transport = EchoBoard()
        transport.memory[4] = 0x1F
        Board(transport).reset()
        self.assertEqual(transport.memory[4], 0x15)
        self.assertEqual(transport.calls, [(1, 4, 0, 0), (2, 4, 0x15, 0)])

    def test_clock_clears_irq_before_external_reset_release(self):
        transport = EchoBoard()
        transport.memory[4] = 0x1F
        Board(transport).clock(2)
        self.assertEqual(transport.calls[:3],
                         [(1, 4, 0, 0), (2, 4, 0x14, 0), (2, 8, 2, 0)])
        self.assertTrue(all(not data & 8 for op, addr, data, _ in transport.calls
                            if op == 2 and addr == 4))

    def test_irq_is_an_ordinary_input(self):
        transport = EchoBoard()
        board = Board(transport)
        board.irq(1)
        self.assertEqual(transport.memory[4] & 8, 8)
        board.irq(0)
        self.assertEqual(transport.memory[4] & 8, 0)
        with self.assertRaises(ValueError):
            board.irq(2)

    def test_load_detects_corrupt_memory(self):
        class Broken(EchoBoard):
            def exchange(self, raw):
                result = super().exchange(raw)
                if decode(raw)[1] == 2 and decode(raw)[4] >= 0x80000000:
                    self.memory[decode(raw)[4]] ^= 1
                return result
        with self.assertRaisesRegex(BringupError, "verify"):
            Board(Broken()).load(0x80000000, b"abcd")

    def test_clock_changes_only_with_clock_off_and_reset_held(self):
        transport = EchoBoard()
        transport.memory[4] = 0x17
        Board(transport).clock(2)
        self.assertEqual(transport.calls[0:3],
                         [(1, 4, 0, 0), (2, 4, 0x14, 0), (2, 8, 2, 0)])
        self.assertIn((2, 4, 1, 0), transport.calls)

    def test_missing_clock_keeps_reset_held(self):
        class StoppedClock(Board):
            def clock_frequency(self):
                return 0
        transport = EchoBoard()
        with self.assertRaisesRegex(BringupError, "Clock 0"):
            StoppedClock(transport).power_on(external=True)
        self.assertEqual(transport.memory[4] & 2, 0)

    def test_bounds(self):
        board = Board(EchoBoard())
        for half in (0, 7):
            with self.assertRaises(ValueError):
                board.clock(half)
        with self.assertRaises(ValueError):
            board.load(1, b"a")
        with self.assertRaises(ValueError):
            board.wait(-1)
        with self.assertRaises(ValueError):
            board.jtag([1], [])
        with self.assertRaises(ValueError):
            bootrom(1)

    def test_bootrom_sets_frozen_local_link_register(self):
        words = struct.unpack("<6I", bootrom(9))
        base = words[0] & 0xFFFFF000
        immediate = words[1] >> 20
        immediate -= 4096 if immediate & 2048 else 0
        self.assertEqual(base + immediate, 0x00100800)
        self.assertEqual(words[2] >> 20, 9)
        self.assertEqual(words[4] & 0xFFFFF000, 0x80000000)

    def test_dmi_establishes_idle_after_external_reset(self):
        class TapBoard(Board):
            def __init__(self):
                self.events = []
            def tap_reset(self):
                self.events.append("reset")
            def scan(self, value, width, instruction=False):
                self.events.append(("scan", width, instruction))
                return 0
            def jtag(self, tms, tdi):
                self.events.append("idle")
                return [0]
        board = TapBoard()
        self.assertEqual(board.dmi(0x10, 1), 0)
        self.assertEqual(board.events[0:2], ["reset", ("scan", 5, True)])
        self.assertEqual(board.events[-1], ("scan", 41, False))

    def test_sequence_wrap(self):
        board = Board(EchoBoard())
        for _ in range(257):
            board.read(0)
        self.assertEqual(board.sequence, 1)

    def test_shmoo_records_each_axis_and_recovers(self):
        class SweepBoard(Board):
            def reset(self):
                pass
            def run(self, image, half, clock, timeout, sample, delay, tap):
                if half == 2:
                    raise BringupError("expected margin failure")
                return {"pass": True}
        results = SweepBoard(EchoBoard()).shmoo(b"", [2, 3], [0, 1], [2, 5], taps=[0, 64])
        self.assertEqual(len(results), 16)
        self.assertEqual(sum(row["pass"] for row in results), 8)
        self.assertEqual({row["input_taps"] for row in results}, {0, 64})

    def test_finisher_drains_console_tail_after_a_full_poll(self):
        class StreamingBoard(Board):
            def __init__(self):
                self.chunks = [bytearray(b"A" * 4096), bytearray(b"tail\n")]
            def reset(self):
                pass
            def load(self, address, data, verify=True):
                pass
            def write(self, address, data):
                pass
            def wait(self, cycles):
                pass
            def power_on(self, half_ticks=5, external=False):
                return {"clock_hz": 10_000_000, "diag_core_hz": 10_000_000}
            def console(self, limit=4096):
                return self.chunks.pop(0) if self.chunks else bytearray()
            def read(self, address):
                return 0x5555 if address == 0x40 else 0
            def stats(self):
                return dict.fromkeys(("frames", "bytes", "status_polls", "timeouts",
                                      "error_responses", "console_overflow"), 0)
        result = StreamingBoard().run(b"program")
        self.assertTrue(result["pass"])
        self.assertEqual(result["console"], "A" * 4096 + "tail\n")

    def test_fragmented_transport_and_eof(self):
        request_r, request_w = os.pipe()
        reply_r, reply_w = os.pipe()
        expected = packet(0x5A, 1, 0)
        def server():
            os.read(request_r, 16)
            for byte in expected:
                os.write(reply_w, bytes([byte]))
            os.close(reply_w)
        worker = threading.Thread(target=server)
        worker.start()
        try:
            transport = BinaryTransport(reply_r, request_w, 1)
            self.assertEqual(transport.exchange(packet(0xA5, 1, 0)), expected)
            with self.assertRaisesRegex(BringupError, "closed"):
                transport.exchange(packet(0xA5, 1, 1))
        finally:
            worker.join()
            for fd in (request_r, request_w, reply_r):
                os.close(fd)

    def test_result_serial_conditions_and_failure(self):
        with tempfile.TemporaryDirectory(prefix="bringup-test-") as directory:
            path = Path(directory) / "chip.json"
            record = write_result(path, "example-001", {"temperature_c": 25},
                                  [{"pass": True}, {"pass": False}])
            self.assertFalse(record["pass"])
            self.assertEqual(json.loads(path.read_text())["conditions"], {"temperature_c": 25})
            self.assertFalse(path.with_name(path.name + ".tmp").exists())
            with self.assertRaises(ValueError):
                write_result(path, "", {}, [])


if __name__ == "__main__":
    unittest.main()
