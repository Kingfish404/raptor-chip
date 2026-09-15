"""Digital 1G receive checks, independent of the physical primitive test."""
import bisect
from pathlib import Path
import random
import sys
import unittest

from migen import ResetInserter
from migen.sim import passive, run_simulation

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_oversample import CM005RX1000Samples


def sample_words(payload, phase=0, clock_offset=460, period=8000, duty=0.5,
                 seed=8531, idle_tail=8):
    """Independent RGMII DDR transmitter; +/-800 ps stable at each PHY edge.

    Clock phase is unrelated to the FPGA sampling word. Every data/control
    lane changes independently within the allowed eye, including both halves.
    """
    rng = random.Random(seed)
    events = [[] for _ in range(6)]
    stream = [(0, 0, 0)] * 8 + payload + [(0, 0, 0)] * idle_tail
    high_time = round(period * duty)
    for index, (byte, dv, er) in enumerate(stream):
        rising = period * (index + 1) + phase
        falling = rising + high_time
        events[0] += [(rising + clock_offset, 1), (falling + clock_offset, 0)]
        for edge, half, nibble, ctl in ((rising, period - high_time, byte & 15, dv),
                                      (falling, high_time, byte >> 4, dv ^ er)):
            events[1].append((edge - rng.randint(800, half - 800), ctl))
            for bit in range(4):
                events[bit + 2].append((edge - rng.randint(800, half - 800), (nibble >> bit) & 1))
    for lane in events:
        lane.sort()
    end = period * (len(stream) + 1) + phase
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


def drive(dut, words):
    for word in words:
        yield dut.clock.eq(word[0])
        yield dut.control.eq(word[1])
        for i in range(4):
            yield dut.data[i].eq(word[i + 2])
        yield


class GigabitSamplesTest(unittest.TestCase):
    def test_partial_first_iserdes_word_does_not_start_a_frame(self):
        dut = CM005RX1000Samples()
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
            # The first nonzero primitive word can begin in the middle of a
            # high phase even though the reset history contains zero.
            yield from drive(dut, [[0xc1, 0, 0, 0, 0, 0],
                                   [0x07, 0, 0, 0, 0, 0],
                                   [0x1f, 0, 0, 0, 0, 0]])
            yield from drive(dut, sample_words([(0xa5, 1, 0)]))
            for _ in range(10):
                yield
            self.assertEqual((yield dut.fault), 0)

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(received, [(0xa5, 1, 0)])

    def check_stream(self, stream, expected, **options):
        dut = CM005RX1000Samples()
        received = []

        @passive
        def monitor():
            while True:
                if (yield dut.source.valid) and (yield dut.source.ready):
                    received.append(((yield dut.source.data), (yield dut.source.last),
                                     (yield dut.source.error)))
                yield

        def stimulus():
            yield dut.source.ready.eq(1)
            yield from drive(dut, sample_words(stream, **options))
            for _ in range(10):
                yield
            self.assertEqual((yield dut.fault), 0)

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(received, expected)

    def test_phase_skew_frequency_and_duty_cycle(self):
        rng = random.Random(8531)
        stream, expected = [], []
        for length in (1, 2, 3, 60):
            packet = bytes(rng.randrange(256) for _ in range(length))
            stream += [(b, 1, int(i == 3)) for i, b in enumerate(packet)]
            expected += [(b, int(i == length - 1), int(i == 3)) for i, b in enumerate(packet)]
            stream += [(0, 0, 0)] * 12
        for phase in range(0, 6400, 400):
            for offset in (25, 460, 775):
                for period, duty in ((7999, 0.45), (8000, 0.50), (8001, 0.55)):
                    with self.subTest(phase=phase, offset=offset, period=period, duty=duty):
                        self.check_stream(stream, expected, phase=phase,
                                          clock_offset=offset, period=period, duty=duty)

    def test_full_size_back_to_back_frames(self):
        stream, expected = [], []
        for length in (1518, 64, 1518):
            packet = bytes((i * 37 + length) & 255 for i in range(length))
            stream += [(b, 1, 0) for b in packet] + [(0, 0, 0)] * 12
            expected += [(b, int(i == length - 1), 0) for i, b in enumerate(packet)]
        self.check_stream(stream, expected, phase=6375, period=7999)

    def test_clock_stop_and_glitch_end_bad_frame_then_recover(self):
        for glitch in (False, True):
            with self.subTest(glitch=glitch):
                dut = CM005RX1000Samples()
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
                    yield from drive(dut, sample_words([(0xa5, 1, 0)], idle_tail=0))
                    if glitch:
                        yield dut.clock.eq(0x55)
                        yield
                    yield dut.clock.eq(0)
                    for _ in range(180):
                        yield
                    self.assertEqual((yield dut.fault), 1)
                    yield from drive(dut, sample_words([(0xb6, 1, 0)], phase=375))
                    for _ in range(10):
                        yield

                run_simulation(dut, [stimulus(), monitor()])
                self.assertEqual(received, [(0xa5, 1, 1), (0xb6, 1, 0)])

    def test_reset_discards_partial_frame(self):
        dut = ResetInserter()(CM005RX1000Samples())
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
            yield from drive(dut, sample_words([(0xa5, 1, 0)], idle_tail=0))
            yield dut.reset.eq(1)
            for _ in range(4):
                yield
            yield dut.reset.eq(0)
            yield from drive(dut, sample_words([(0xb6, 1, 0)], phase=625))
            for _ in range(10):
                yield
            self.assertEqual((yield dut.fault), 0)

        run_simulation(dut, [stimulus(), monitor()])
        self.assertEqual(received, [(0xb6, 1, 0)])

    def test_backpressure_reports_error_and_holds_output(self):
        dut = CM005RX1000Samples()
        received, held = [], []

        @passive
        def monitor():
            while True:
                if (yield dut.source.valid):
                    item = ((yield dut.source.data), (yield dut.source.last),
                            (yield dut.source.error))
                    if (yield dut.source.ready):
                        received.append(item)
                    else:
                        held.append(item)
                yield

        def stimulus():
            yield dut.source.ready.eq(0)
            yield from drive(dut, sample_words([(i, 1, 0) for i in range(32)]))
            self.assertEqual((yield dut.fault), 1)
            yield dut.source.ready.eq(1)
            for _ in range(12):
                yield
            yield from drive(dut, sample_words([(0xa5, 1, 0)]))
            for _ in range(10):
                yield

        run_simulation(dut, [stimulus(), monitor()])
        self.assertTrue(held)
        self.assertEqual(len(set(held)), 1)
        self.assertEqual(received[-1], (0xa5, 1, 0))
        self.assertTrue(any(last and error for _, last, error in received[:-1]))


if __name__ == "__main__":
    unittest.main()
