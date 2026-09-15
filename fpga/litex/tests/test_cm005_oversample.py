"""Digital sampling-window checks; not an analog/MTBF or routed-IO proof."""
import bisect
from pathlib import Path
import random
import sys
import unittest

from migen.sim import run_simulation, passive
from migen import ResetInserter

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_oversample import CM005RX100Samples


def sample_words(nibbles, phase, seed=8531, clock_offset=460, idle_tail=8):
    """Build 800 ps samples from signals stable +/-800 ps around PHY edges.

    Lane transitions are independently positioned in the allowed interval.
    RX_CTL uses DV on rising edges and DV xor ER on falling edges.
    """
    rng = random.Random(seed)
    events = [[] for _ in range(6)]
    stream = [(0, 0, 0)] * 4 + nibbles + [(0, 0, 0)] * idle_tail
    for index, (data, dv, er) in enumerate(stream):
        rising = 40000 * index + 20000 + phase
        falling = rising + 20000
        events[0] += [(rising + clock_offset, 1), (falling + clock_offset, 0)]
        events[1] += [(rising - rng.randint(800, 19200), dv),
                      (falling - rng.randint(800, 19200), dv ^ er)]
        for bit in range(4):
            events[bit + 2].append((rising - rng.randint(800, 19200), (data >> bit) & 1))
    for lane in events:
        lane.sort()
    end = (len(stream) + 1) * 40000
    for base in range(0, end, 6400):
        words = []
        for lane in events:
            word = 0
            for bit in range(8):
                pos = bisect.bisect_right(lane, (base + bit * 800, 2)) - 1
                if pos >= 0:
                    word |= lane[pos][1] << bit
            words.append(word)
        yield words


class OversampleTest(unittest.TestCase):
    @staticmethod
    def drive(dut, words):
        for word in words:
            yield dut.clock.eq(word[0])
            yield dut.control.eq(word[1])
            for i in range(4):
                yield dut.data[i].eq(word[i + 2])
            yield

    def test_clock_stop_flushes_error_and_recovers(self):
        dut = CM005RX100Samples()
        received = []

        @passive
        def monitor():
            while True:
                if (yield dut.source.valid):
                    received.append(((yield dut.source.data), (yield dut.source.last),
                                     (yield dut.source.error)))
                yield

        def stimulus():
            yield dut.source.ready.eq(1)
            yield from self.drive(dut, sample_words([(5, 1, 0), (10, 1, 0)], 250, idle_tail=0))
            for _ in range(180):
                yield
            self.assertEqual((yield dut.fault), 1)
            yield from self.drive(dut, sample_words([(6, 1, 0), (10, 1, 0)], 625))
            for _ in range(10):
                yield

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(received, [(0xa5, 1, 1), (0xa6, 1, 0)])

    def test_reset_discards_partial_byte(self):
        dut = ResetInserter()(CM005RX100Samples())
        received = []

        @passive
        def monitor():
            while True:
                if not (yield dut.reset) and (yield dut.source.valid):
                    received.append(((yield dut.source.data), (yield dut.source.last),
                                     (yield dut.source.error)))
                yield

        def stimulus():
            yield dut.source.ready.eq(1)
            yield from self.drive(dut, sample_words([(5, 1, 0)], 250, idle_tail=0))
            yield dut.reset.eq(1)
            for _ in range(4):
                yield
            yield dut.reset.eq(0)
            yield from self.drive(dut, sample_words([(6, 1, 0), (10, 1, 0)], 625))
            for _ in range(10):
                yield
            self.assertEqual((yield dut.fault), 0)

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(received, [(0xa6, 1, 0)])

    def check_stream(self, nibbles, expected, phase, clock_offset=460):
        dut = CM005RX100Samples()
        received = []

        @passive
        def monitor():
            while True:
                if (yield dut.source.valid):
                    received.append(((yield dut.source.data), (yield dut.source.last),
                                     (yield dut.source.error)))
                yield

        def stimulus():
            yield dut.source.ready.eq(1)
            for words in sample_words(nibbles, phase, clock_offset=clock_offset):
                yield dut.clock.eq(words[0])
                yield dut.control.eq(words[1])
                for i in range(4):
                    yield dut.data[i].eq(words[i + 2])
                yield
            for _ in range(10):
                yield
            self.assertEqual((yield dut.fault), 0)

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(received, expected)

    def test_phase_and_delay_mismatch_sweep(self):
        rng = random.Random(8531)
        packets = [bytes(rng.randrange(256) for _ in range(length)) for length in (1, 2, 3, 60)]
        nibbles, expected = [], []
        for packet in packets:
            for i, byte in enumerate(packet):
                nibbles.extend([(byte & 15, 1, 0), (byte >> 4, 1, 0)])
                expected.append((byte, int(i == len(packet) - 1), 0))
            nibbles.extend([(0, 0, 0)] * 24)
        for phase in (*range(0, 800, 100), 5700, 6000, 6375):
            for offset in (25, 460, 775):
                with self.subTest(phase_ps=phase, clock_offset_ps=offset):
                    self.check_stream(nibbles, expected, phase, offset)

    def test_error_and_odd_nibble(self):
        self.check_stream([(5, 1, 0), (10, 1, 1), (3, 1, 0)],
                          [(0xa5, 0, 1), (3, 1, 1)], phase=375)

    def test_full_size_frame(self):
        packet = bytes((i * 37 + 83) & 255 for i in range(1518))
        nibbles = [(n, 1, 0) for byte in packet for n in (byte & 15, byte >> 4)]
        self.check_stream(nibbles, [(b, int(i == 1517), 0) for i, b in enumerate(packet)], 875)


if __name__ == "__main__":
    unittest.main()
