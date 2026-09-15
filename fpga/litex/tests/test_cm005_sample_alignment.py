"""Cycle-accurate lane deskew checks, including optional raw ILA replay.

Replay format: the eleven hex probes emitted by the RX diagnostic ILA,
with raw clock/control/data0..3 first. Captures remain external artifacts.
"""
import argparse
import csv
import hashlib
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import zlib

from migen.sim import passive, run_simulation

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_oversample import CM005RX1000Samples
import test_cm005_gigabit as baseline


def delayed_words(words, delays, control_delay=0):
    """Independent serial lane delays; never rotate within individual words."""
    delays = (control_delay, *delays)
    history = [[0] * d for d in delays]
    for word in words:
        result = word[:1]
        for lane, delay in enumerate(delays):
            bits = history[lane] + [(word[lane + 1] >> b) & 1 for b in range(8)]
            result.append(sum(value << b for b, value in enumerate(bits[:8])))
            history[lane] = bits[8:]
        yield result


class AlignedGigabitSamplesTest(baseline.GigabitSamplesTest):
    """Run every protocol test with delayed odd lanes and the deskew enabled."""
    def setUp(self):
        original_words = baseline.sample_words
        self.decoder_patch = patch.object(baseline, 'CM005RX1000Samples',
            lambda: CM005RX1000Samples((0, 2, 0, 2)))
        self.words_patch = patch.object(baseline, 'sample_words',
            lambda *a, **kw: delayed_words(original_words(*a, **kw), (0, 2, 0, 2)))
        self.decoder_patch.start()
        self.words_patch.start()
        self.addCleanup(self.decoder_patch.stop)
        self.addCleanup(self.words_patch.stop)


class ControlAlignedGigabitSamplesTest(baseline.GigabitSamplesTest):
    """Exercise DV/RX_ER/end-of-frame with independently delayed control."""
    control_advance = 1

    def setUp(self):
        original_words = baseline.sample_words
        decoder_patch = patch.object(baseline, 'CM005RX1000Samples',
            lambda: CM005RX1000Samples((0, 2, 0, 2), self.control_advance))
        words_patch = patch.object(baseline, 'sample_words',
            lambda *a, **kw: delayed_words(original_words(*a, **kw), (0, 2, 0, 2), self.control_advance))
        decoder_patch.start()
        words_patch.start()
        self.addCleanup(decoder_patch.stop)
        self.addCleanup(words_patch.stop)


class ControlTwoAlignedGigabitSamplesTest(ControlAlignedGigabitSamplesTest):
    control_advance = 2


class AlignmentParametersTest(unittest.TestCase):
    def test_invalid_offsets(self):
        for offsets in ((0, 0), (0, -1, 0, 0), (0, 8, 0, 0), (0, 1.0, 0, 0)):
            with self.subTest(offsets=offsets), self.assertRaises(ValueError):
                CM005RX1000Samples(offsets)
        for offset in (-1, 8, 1.0, True):
            with self.subTest(control=offset), self.assertRaises(ValueError):
                CM005RX1000Samples(control_sample_advance=offset)

    def test_control_only_and_word_boundary(self):
        payload = [(0xa5, 1, 0), (0x5a, 1, 1), (0xff, 1, 0)]
        expected = [(0xa5, 0, 0), (0x5a, 0, 1), (0xff, 1, 0)]
        for control in (1, 2, 7):
            for phase in range(0, 6400, 400):
                with self.subTest(control=control, phase=phase):
                    words = delayed_words(baseline.sample_words(payload, phase=phase),
                                          (0, 0, 0, 0), control)
                    output, fault = simulate(words, (0, 0, 0, 0), control)
                    self.assertEqual(output, expected)
                    self.assertEqual(fault, 0)

    def test_every_lane_and_word_boundary(self):
        payload = bytes((i * 37) & 255 for i in range(64))
        for offsets in ((1, 2, 3, 4), (7, 6, 5, 0), (0, 2, 0, 2)):
            for phase in range(0, 6400, 400):
                with self.subTest(offsets=offsets, phase=phase):
                    words = delayed_words(baseline.sample_words(
                        [(b, 1, 0) for b in payload], phase=phase), offsets)
                    output, fault = simulate(words, offsets)
                    self.assertEqual(output, [(b, int(i == 63), 0)
                                             for i, b in enumerate(payload)])
                    self.assertEqual(fault, 0)


def simulate(words, offsets, control_offset=0):
    dut = CM005RX1000Samples(offsets, control_offset)
    output, faults = [], []

    @passive
    def monitor():
        while True:
            if (yield dut.source.valid) and (yield dut.source.ready):
                output.append(((yield dut.source.data), (yield dut.source.last),
                               (yield dut.source.error)))
            yield

    def stimulus():
        yield dut.source.ready.eq(1)
        yield from baseline.drive(dut, words)
        # Advance one final constant sample word to drain the lookahead.
        # A complete captured frame already contains idle cycles after DV.
        for _ in range(3):
            yield
        faults.append((yield dut.fault))

    run_simulation(dut, [stimulus(), monitor()])
    return output, faults[0]


def replay(path, require_one_step_failure=False, control_offset=0):
    with path.open(newline='') as stream:
        reader = csv.reader(stream)
        header, radix = next(reader), next(reader)
        assert len(header) == 14 and radix[3:] == ['HEX'] * 11
        assert 'samples_clock' in header[3] and 'samples_control' in header[4]
        words = [[int(v, 16) for v in row[3:9]] for row in reader]
    print(f'CAPTURE {path} sha256={hashlib.sha256(path.read_bytes()).hexdigest()}')
    results = []
    for offsets in ((0, 0, 0, 0), (0, 1, 0, 1), (0, 2, 0, 2)):
        output, fault = simulate(words, offsets, control_offset)
        packets, packet, errors = [], [], 0
        for byte, last, error in output:
            packet.append(byte)
            errors |= error
            if last:
                data = bytes(packet)
                preamble = data[:8] == b'\x55' * 7 + b'\xd5'
                body = data[8:]
                crc = len(body) >= 18 and zlib.crc32(body[:-4]) == int.from_bytes(body[-4:], 'little')
                known = None
                if len(body) == 1518 and body[12:14] == b'\x88\xb6':
                    sequence = int.from_bytes(body[14:18], 'big')
                    known = body[18:22] == b'\x33' * 4 and all(
                        value == ((i + sequence * 37) & 255)
                        for i, value in enumerate(body[22:-4], 22))
                elif len(body) == 1518 and body[12:14] == b'\x88\xb7':
                    expected = hashlib.shake_256(b'raptor-rx-random-v1' + body[14:18]).digest(1492)
                    known = body[18:22] == b'\x33' * 4 and body[22:-4] == expected
                packets.append(preamble and crc and not errors and known is not False)
                print(f'  {offsets} control={control_offset}: bytes={len(data)} preamble={preamble} CRC={crc} '
                      f'known={known} errors={errors} fault={fault}')
                packet, errors = [], 0
        assert packets, 'No complete frame in capture'
        results.append(all(packets))
    assert results[-1], f'Two-step candidate failed: {results}'
    # Narrower-margin settings may pass an individual capture. Only require
    # their failure when replaying an explicitly identified regression vector.
    if require_one_step_failure:
        assert not results[1], 'Expected one-step regression failure did not occur'
    print(f'REPLAY PASS: two-step RTL recovers complete frames; '
          f'baseline_good={results[0]} one_step_good={results[1]}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture', type=Path, action='append')
    parser.add_argument('--control-offset', type=int, default=0, choices=range(8))
    parser.add_argument('--require-one-step-failure', action='store_true',
                        help='Require the one-step control to fail for a known regression capture')
    args, remaining = parser.parse_known_args()
    if args.capture:
        for path in args.capture:
            replay(path, args.require_one_step_failure, args.control_offset)
    else:
        unittest.main(argv=[sys.argv[0], *remaining])
