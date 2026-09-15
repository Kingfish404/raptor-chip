"""CM005 byte stream through the real LiteEth MAC, including CDC and width conversion."""
from pathlib import Path
import argparse
import csv
import sys
import unittest
import zlib

from migen import ClockDomainsRenamer, Memory, Module, Signal
from migen.sim import passive, run_simulation
from litex.soc.interconnect import stream
from liteeth.common import eth_phy_description
from liteeth.mac.core import LiteEthMACCore

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005 import CM005RXFrameError


class PHY(Module):
    dw = 8

    def __init__(self, retain_errors=True):
        self.sink = stream.Endpoint(eth_phy_description(8))
        self.rx_input = stream.Endpoint(eth_phy_description(8))
        self.source = self.rx_input
        if retain_errors:
            self.submodules.rx_frame_error = latch = ClockDomainsRenamer("eth_rx")(CM005RXFrameError())
            self.comb += self.rx_input.connect(latch.sink)
            self.source = latch.source
        self.comb += self.rx_input.last_be.eq(self.rx_input.last)


def simulation_fragment(dut):
    fragment = dut.get_fragment()
    # Migen's array simulator predates write-only Memory ports used by the
    # current LiteX FIFO. Give those ports an unobserved read signal solely
    # for simulator lowering; write address/data/enable and read ports stay
    # unchanged. This does not replace the FIFO or its CDC control logic.
    for special in fragment.specials:
        if isinstance(special, Memory):
            for port in special.ports:
                if port.dat_r is None:
                    port.dat_r = Signal(special.width)
    return fragment


def receive(packets, sys_datapath, error_positions=None, retain_errors=True):
    dut = Module()
    dut.submodules.phy = phy = PHY(retain_errors)
    dut.submodules.mac = mac = LiteEthMACCore(phy, 32, with_sys_datapath=sys_datapath)
    frames, current, faults = [], bytearray(), []

    @passive
    def monitor():
        errors = 0
        while True:
            if (yield mac.source.valid) and (yield mac.source.ready):
                last = (yield mac.source.last)
                count = (yield mac.source.last_be).bit_length() if last else 4
                assert 1 <= count <= 4
                current.extend((yield mac.source.data).to_bytes(4, 'little')[:count])
                errors |= (yield mac.source.error)
                if last:
                    frames.append((bytes(current), errors))
                    current.clear()
                    errors = 0
            yield

    @passive
    def sys_driver():
        yield mac.source.ready.eq(1)
        yield mac.sink.valid.eq(0)
        while True:
            yield

    def rx_driver():
        yield phy.sink.ready.eq(1)
        for _ in range(16):
            yield
        for packet_index, packet in enumerate(packets):
            for index, byte in enumerate(packet):
                yield phy.rx_input.valid.eq(1)
                yield phy.rx_input.data.eq(byte)
                yield phy.rx_input.last.eq(index == len(packet)-1)
                yield phy.rx_input.error.eq(
                    error_positions is not None and
                    index in error_positions[packet_index])
                yield
                if not (yield phy.rx_input.ready):
                    faults.append(index)
                # Four bytes in five 6.4ns cycles: native 1Gb/s input rate.
                if index % 4 == 3:
                    yield phy.rx_input.valid.eq(0)
                    yield
            yield phy.rx_input.valid.eq(0)
            yield phy.rx_input.last.eq(0)
            for _ in range(15):
                yield
        for _ in range(300):
            yield

    run_simulation(simulation_fragment(dut), {'sys': [monitor(), sys_driver()], 'eth_rx': rx_driver()},
                   clocks={'sys': 20000, 'eth_rx': 6400, 'eth_tx': 8000})
    assert not faults, f'Physical receive was backpressured at {faults[:8]}'
    return frames


def framed(body, preamble=7):
    return b'\x55'*preamble + b'\xd5' + body + zlib.crc32(body).to_bytes(4, 'little')


def transmit(bodies):
    dut = Module()
    dut.submodules.phy = phy = PHY()
    dut.submodules.mac = mac = LiteEthMACCore(phy, 32, with_sys_datapath=False)
    frames, gaps = [], []

    @passive
    def tx_monitor():
        packet = bytearray()
        while True:
            if (yield phy.sink.valid) and (yield phy.sink.ready):
                assert not (yield phy.sink.error)
                packet.append((yield phy.sink.data))
                if (yield phy.sink.last):
                    frames.append(bytes(packet))
                    packet.clear()
            elif packet:
                gaps.append(len(packet))
            yield

    def sys_driver():
        yield phy.sink.ready.eq(1)
        yield phy.source.valid.eq(0)
        yield mac.source.ready.eq(1)
        for _ in range(16):
            yield
        for body in bodies:
            for offset in range(0, len(body), 4):
                word = body[offset:offset+4]
                yield mac.sink.valid.eq(1)
                yield mac.sink.data.eq(int.from_bytes(word, 'little'))
                yield mac.sink.last.eq(offset+4 >= len(body))
                yield mac.sink.last_be.eq((1 << (len(word)-1)) if offset+4 >= len(body) else 0)
                yield
                while not (yield mac.sink.ready):
                    yield
            yield mac.sink.valid.eq(0)
            yield
        for _ in range(500):
            yield

    run_simulation(simulation_fragment(dut), {'sys': sys_driver(), 'eth_tx': tx_monitor()},
                   clocks={'sys': 20000, 'eth_rx': 6400, 'eth_tx': 8000})
    assert not gaps, f'TX underrun inside a physical frame: {gaps[:8]}'
    return frames


class MACReceiveTest(unittest.TestCase):
    def test_byte_datapath_transmit(self):
        bodies = [bytes((i*37+size)&255 for i in range(size))
                  for size in (1, 60, 61, 62, 63, 64, 1514)]
        self.assertEqual(transmit(bodies), [framed(body.ljust(60, b'\0')) for body in bodies])

    def test_short_preamble_and_frame_lengths(self):
        bodies = [bytes((i*37+size)&255 for i in range(size))
                  for size in (60, 61, 62, 63, 64, 1514)]
        packets = [framed(body, preamble) for preamble in (7, 6, 1) for body in bodies]
        self.assertEqual(receive(packets, False), [(body, 0) for _ in (7, 6, 1) for body in bodies])

    def test_word_preamble_checker_reproduces_loss(self):
        body = bytes(range(60))
        self.assertEqual(receive([framed(body)], True), [(body, 0)])
        self.assertEqual(receive([framed(body, 6)], True), [])

    def test_crc_corruption_still_errors(self):
        packet = bytearray(framed(bytes(range(60)), 6))
        packet[-10] ^= 1
        received = receive([bytes(packet)], False)
        self.assertEqual(len(received), 1)
        self.assertNotEqual(received[0][1], 0)

    def test_phy_error_survives_mac(self):
        body = bytes(range(60))
        packet = framed(body)
        # Keep a valid FCS: this checks PHY error propagation independently
        # of the CRC mismatch detector, including the initial CRC FIFO fill.
        positions = (8, 9, 10, 11, 12, 37, len(packet)-1)
        # Follow each errored packet by a clean one to check frame reset.
        errors = [value for position in positions for value in ({position}, set())]
        received = receive([packet]*len(errors), False, errors)
        self.assertEqual(len(received), len(errors))
        for positions_in_frame, (data, error) in zip(errors, received):
            with self.subTest(positions=positions_in_frame):
                self.assertEqual(data, body)
                self.assertEqual(bool(error), bool(positions_in_frame))

    def test_without_error_retention_reproduces_loss(self):
        body = bytes(range(60))
        self.assertEqual(receive([framed(body)], False, [{8}],
                                 retain_errors=False), [(body, 0)])


def replay(path):
    with path.open(newline='') as f:
        reader = csv.reader(f)
        header, radix = next(reader), next(reader)
        assert len(header) == 14 and radix[3:] == ['HEX']*11
        rows = [[int(value, 16) for value in row[3:]] for row in reader]
    packets, packet = [], bytearray()
    for row in rows:
        if row[7]:
            assert not row[9], 'This replay expects a non-RX_ER PHY frame'
            packet.append(row[6])
            if row[8]:
                packets.append(bytes(packet))
                packet.clear()
    assert len(packets) == 1 and not packet
    physical = packets[0]
    sfd = len(physical) - len(physical.lstrip(b'\x55'))
    assert physical[sfd] == 0xd5 and sfd > 0
    frame = physical[sfd+1:]
    assert zlib.crc32(frame[:-4]) == int.from_bytes(frame[-4:], 'little')
    result = receive(packets, False)
    assert result == [(frame[:-4], 0)], (len(result), result[:1])
    old_result = receive(packets, True)
    print(f'CAPTURE {path} preamble={sfd} body={len(frame)-4} byte_MAC_PASS=True word_MAC_frames={len(old_result)}')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--capture', type=Path, action='append')
    args, remaining = ap.parse_known_args()
    if args.capture:
        for path in args.capture:
            replay(path)
    else:
        unittest.main(argv=[sys.argv[0], *remaining])
