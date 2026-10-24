"""Frame queues, three-port arbitration and physical MAC/CDC forwarding."""
import random
import sys
import unittest
from pathlib import Path

from migen import Module, ResetInserter
from migen.sim import passive, run_simulation

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_bridge import buffer_slow_cm005_tx
from cm005_bridge_queue import EthernetFrameQueue
from cm005_switch import CM005Switch
from liteeth.mac.core import LiteEthMACCore
from test_cm005_mac_receive import PHY, framed, simulation_fragment


def payload(length, seed):
    rng = random.Random(seed)
    return bytes(rng.randrange(256) for _ in range(length))


def send(sink, data, error_word=None):
    for offset in range(0, len(data), 4):
        word = data[offset:offset + 4]
        last = offset + 4 >= len(data)
        yield sink.valid.eq(1)
        yield sink.data.eq(int.from_bytes(word, "little"))
        yield sink.last.eq(last)
        yield sink.last_be.eq(1 << (len(word) - 1) if last else 0)
        yield sink.error.eq(1 if offset // 4 == error_word else 0)
        yield
        while not (yield sink.ready):
            yield
    yield sink.valid.eq(0)
    yield sink.error.eq(0)
    yield sink.last.eq(0)
    for _ in range(3):
        yield


class FrameQueueTest(unittest.TestCase):
    def run_queue(self, frames, *, error_words=None, slots=8, stall_until=0):
        dut = EthernetFrameQueue(slots=slots)
        received, partial, stats = [], bytearray(), {}
        cycles = [0]
        rng = random.Random(0x5c005)

        @passive
        def receiver():
            while True:
                ready = cycles[0] >= stall_until and rng.randrange(4) != 0
                yield dut.source.ready.eq(ready)
                yield
                if (yield dut.source.valid) and ready:
                    last = (yield dut.source.last)
                    count = (yield dut.source.last_be).bit_length() if last else 4
                    partial.extend((yield dut.source.data).to_bytes(4, "little")[:count])
                    self.assertEqual((yield dut.source.error), 0)
                    if last:
                        received.append(bytes(partial))
                        partial.clear()
                cycles[0] += 1

        def driver():
            for i, data in enumerate(frames):
                yield from send(dut.sink, data,
                                None if error_words is None else error_words[i])
            for _ in range(stall_until + sum(map(len, frames)) + 200):
                yield
            for name in ("received", "forwarded", "dropped", "errors", "queued"):
                stats[name] = (yield getattr(dut, name).status)

        run_simulation(simulation_fragment(dut), [driver(), receiver()])
        self.assertFalse(partial)
        return received, stats

    def test_lengths_order_and_backpressure(self):
        frames = [payload(n, n) for n in [60, 61, 62, 63, 64, 65, 1514, 1518, 1522, 1536]]
        # Sustained source faster than output is allowed to overflow; pace
        # this correctness case with enough buffering for every test frame.
        output, stats = self.run_queue(frames, slots=16)
        self.assertEqual(output, frames)
        self.assertEqual(stats, dict(received=10, forwarded=10, dropped=0, errors=0, queued=0))

    def test_error_and_oversize_drop_no_prefix(self):
        frames = [payload(n, i) for i, n in enumerate([60, 1518, 1537, 64, 1536, 65])]
        output, stats = self.run_queue(frames, error_words=[None, 3, None, None, 383, None])
        self.assertEqual(output, [frames[i] for i in (0, 3, 5)])
        self.assertEqual(stats["errors"], 3)
        self.assertEqual(stats["dropped"], 3)

    def test_overflow_preserves_occupied_slots(self):
        frames = [payload(64, i) for i in range(8)]
        output, stats = self.run_queue(frames, slots=2, stall_until=500)
        self.assertEqual(output, frames[:2])
        self.assertEqual(stats["dropped"], 6)
        self.assertEqual(stats["errors"], 0)

    def test_reset_flushes_inflight_and_queued_frames(self):
        dut = ResetInserter()(EthernetFrameQueue(slots=2))
        before, after = payload(64, 1), payload(65, 2)
        output, current = [], bytearray()

        @passive
        def monitor():
            while True:
                if (yield dut.source.valid) and (yield dut.source.ready):
                    last = (yield dut.source.last)
                    count = (yield dut.source.last_be).bit_length() if last else 4
                    current.extend((yield dut.source.data).to_bytes(4, "little")[:count])
                    if last:
                        output.append(bytes(current))
                        current.clear()
                yield

        def driver():
            yield dut.source.ready.eq(0)
            yield from send(dut.sink, before)
            for _ in range(10):
                yield
            yield dut.reset.eq(1)
            for _ in range(3):
                yield
            yield dut.reset.eq(0)
            yield dut.source.ready.eq(1)
            yield
            yield from send(dut.sink, after)
            for _ in range(100):
                yield
            self.assertEqual((yield dut.forwarded.status), 1)

        run_simulation(simulation_fragment(dut), [driver(), monitor()])
        self.assertEqual(output, [after])


class BridgeMACPipelineTest(unittest.TestCase):
    def exercise(self, cpu_port=False):
        from migen import ClockDomainsRenamer, Module
        from liteeth.mac.core import LiteEthMACCore
        from test_cm005_mac_receive import PHY, framed

        dut = Module()
        dut.submodules.phy_a = a = PHY()
        rename = {"eth_rx": "eth_b_rx", "eth_tx": "eth_b_tx"}
        dut.submodules.phy_b = b = ClockDomainsRenamer(rename)(PHY())
        dut.submodules.mac_a = ma = LiteEthMACCore(a, 32, rx_cdc_depth=512, tx_cdc_depth=512)
        dut.submodules.mac_b = mb = ClockDomainsRenamer(rename)(LiteEthMACCore(
            b, 32, rx_cdc_depth=512, tx_cdc_depth=512))
        if cpu_port:
            from cm005_switch import CM005Switch
            dut.submodules.switch = switch = CM005Switch()
            ab, ba = switch.q0_to_1, switch.q1_to_0
            dut.comb += [ma.source.connect(switch.sinks[0]), switch.sources[0].connect(ma.sink),
                         mb.source.connect(switch.sinks[1]), switch.sources[1].connect(mb.sink),
                         switch.sources[2].ready.eq(0), switch.sinks[2].valid.eq(0)]
        else:
            dut.submodules.ab = ab = EthernetFrameQueue()
            dut.submodules.ba = ba = EthernetFrameQueue()
            dut.comb += [ma.source.connect(ab.sink), ab.source.connect(mb.sink),
                         mb.source.connect(ba.sink), ba.source.connect(ma.sink)]
        dut.comb += [a.sink.ready.eq(1), b.sink.ready.eq(1)]
        good_a = [payload(n, n) for n in [60, 61, 1518, 1522, 63]]
        good_b = [payload(n, n + 1) for n in [1514, 64, 65, 60, 1518]]
        if cpu_port:
            good_a *= 2
            good_b *= 2
        # Interleave a bad FCS and a valid-FCS frame carrying physical RX_ER.
        bad = bytearray(framed(payload(100, 7)))
        bad[-1] ^= 1
        inputs_a = [(framed(x, 1 if i % 2 else 7), None) for i, x in enumerate(good_a)]
        inputs_a.insert(2, (bytes(bad), None))
        inputs_a.insert(4, (framed(payload(80, 8)), 15))
        inputs_b = [(framed(x), None) for x in good_b]
        outputs_a, outputs_b, underflows, stats = [], [], [], {}

        def drive(phy, frames, oversampled):
            for _ in range(24):
                yield
            for frame, error_at in frames:
                for index, byte in enumerate(frame):
                    yield phy.rx_input.valid.eq(1)
                    yield phy.rx_input.data.eq(byte)
                    yield phy.rx_input.last.eq(index == len(frame) - 1)
                    yield phy.rx_input.error.eq(index == error_at)
                    yield
                    self.assertTrue((yield phy.rx_input.ready), "Physical RX backpressured")
                    if oversampled and index % 4 == 3:
                        yield phy.rx_input.valid.eq(0)
                        yield
                yield phy.rx_input.valid.eq(0)
                yield phy.rx_input.last.eq(0)
                yield phy.rx_input.error.eq(0)
                for _ in range(15 if oversampled else 12):
                    yield
            for _ in range(5000):
                yield

        @passive
        def monitor(phy, output):
            current = bytearray()
            while True:
                if (yield phy.sink.valid):
                    self.assertFalse((yield phy.sink.error))
                    current.append((yield phy.sink.data))
                    if (yield phy.sink.last):
                        output.append(bytes(current))
                        current.clear()
                elif current:
                    underflows.append(len(current))
                yield

        @passive
        def status():
            while True:
                stats["ab_drop"] = (yield ab.dropped.status)
                stats["ba_drop"] = (yield ba.dropped.status)
                yield

        run_simulation(simulation_fragment(dut),
            {"eth_rx": drive(a, inputs_a, True), "eth_b_rx": drive(b, inputs_b, False),
             "eth_tx": monitor(a, outputs_a), "eth_b_tx": monitor(b, outputs_b), "sys": status()},
            clocks={"sys": 20000, "eth_rx": 6400, "eth_b_rx": 8000,
                    "eth_tx": 8000, "eth_b_tx": 8000})
        self.assertEqual(outputs_a, [framed(x) for x in good_b])
        self.assertEqual(outputs_b, [framed(x) for x in good_a])
        self.assertEqual(stats, {"ab_drop": 2, "ba_drop": 0})
        self.assertFalse(underflows)

    def test_bidirectional_crc_error_isolation_and_line_rate(self):
        self.exercise()

    def test_cpu_stall_preserves_bidirectional_physical_mac_pipeline(self):
        self.exercise(cpu_port=True)


class SwitchTest(unittest.TestCase):
    def exercise(self, frames, *, blocked=None, errors=None, slots=8):
        dut = CM005Switch(slots=slots)
        output = [[], [], []]
        partial = [bytearray(), bytearray(), bytearray()]
        stats = {}

        def driver(port):
            for index, frame in enumerate(frames[port]):
                yield from send(dut.sinks[port], frame,
                                None if errors is None else errors[port][index])
                # Allow two simultaneous ingress frames to share one egress.
                for _ in range(len(frame) // 2 + 20):
                    yield
            for _ in range(1200):
                yield
            for origin in range(3):
                for destination in range(3):
                    if origin != destination:
                        queue = getattr(dut, f'q{origin}_to_{destination}')
                        stats[origin, destination] = (yield queue.dropped.status)

        @passive
        def receiver(port):
            rng = random.Random(50 + port)
            while True:
                ready = port != blocked and rng.randrange(4) != 0
                yield dut.sources[port].ready.eq(ready)
                yield
                source = dut.sources[port]
                if (yield source.valid) and ready:
                    last = (yield source.last)
                    count = (yield source.last_be).bit_length() if last else 4
                    self.assertEqual((yield source.error), 0)
                    partial[port].extend((yield source.data).to_bytes(4, 'little')[:count])
                    if last:
                        output[port].append(bytes(partial[port]))
                        partial[port].clear()
        run_simulation(simulation_fragment(dut),
                       [driver(p) for p in range(3)] + [receiver(p) for p in range(3)])
        self.assertFalse(any(partial))
        return output, stats

    def test_simultaneous_ports_and_odd_lengths(self):
        frames = [[payload(n, 100*p+n) for n in (60, 61, 62, 63, 1518, 1536)]
                  for p in range(3)]
        output, stats = self.exercise(frames)
        for destination in range(3):
            expected = [f for origin in range(3) if origin != destination for f in frames[origin]]
            self.assertCountEqual(output[destination], expected)
            for origin in range(3):
                if origin != destination:
                    self.assertEqual([f for f in output[destination] if f in frames[origin]], frames[origin])
        self.assertFalse(any(stats.values()))

    def test_blocked_output_does_not_block_other_copies(self):
        for blocked in (0, 2):  # Physical output, then idle CPU receiver.
            with self.subTest(blocked=blocked):
                frames = [[] if p == blocked else
                          [payload(64 + p, 100*p+n) for n in range(12)] for p in range(3)]
                output, stats = self.exercise(frames, blocked=blocked, slots=2)
                for destination in range(3):
                    expected = [] if destination == blocked else [
                        f for origin in range(3) if origin != destination for f in frames[origin]]
                    self.assertEqual(output[destination], expected)
                for (origin, destination), dropped in stats.items():
                    self.assertEqual(dropped, 10 if destination == blocked else 0)

    def test_error_and_oversize_never_escape(self):
        frames = [[payload(n, p*100+i) for i, n in enumerate((64, 65, 1537, 66))]
                  for p in range(3)]
        output, stats = self.exercise(frames, errors=[[None, 3, None, None]]*3)
        for d in range(3):
            self.assertCountEqual(output[d], [frames[o][i] for o in range(3) if o != d for i in (0, 3)])
        self.assertTrue(all(n == 2 for n in stats.values()))

    def test_reset_flushes_partial_frames_and_packet_arbitration(self):
        dut = ResetInserter()(CM005Switch(slots=2))
        after = [payload(65, 500 + p) for p in range(3)]
        output = [[], [], []]
        enabled = [False]

        @passive
        def monitor(port):
            partial = bytearray()
            while True:
                yield dut.sources[port].ready.eq(enabled[0])
                yield
                source = dut.sources[port]
                if enabled[0] and (yield source.valid) and (yield source.ready):
                    last = (yield source.last)
                    count = (yield source.last_be).bit_length() if last else 4
                    partial.extend((yield source.data).to_bytes(4, 'little')[:count])
                    if last:
                        output[port].append(bytes(partial))
                        partial.clear()

        def driver():
            yield from send(dut.sinks[0], payload(64, 99))
            yield dut.sinks[1].valid.eq(1)
            yield dut.sinks[1].data.eq(0xdeadbeef)
            for _ in range(5):
                yield
            yield dut.reset.eq(1)
            yield dut.sinks[1].valid.eq(0)
            for _ in range(4):
                yield
            yield dut.reset.eq(0)
            enabled[0] = True
            for port, frame in enumerate(after):
                yield from send(dut.sinks[port], frame)
            for _ in range(400):
                yield
        run_simulation(simulation_fragment(dut), [driver()] + [monitor(p) for p in range(3)])
        for port in range(3):
            self.assertCountEqual(output[port], [frame for p, frame in enumerate(after) if p != port])


class SlowTXTest(unittest.TestCase):
    def test_complete_frames_at_10_and_30mhz(self):
        for frequency in (10_000_000, 30_000_000):
            with self.subTest(frequency=frequency):
                dut = Module()
                dut.submodules.phy = phy = PHY()
                dut.submodules.mac = mac = LiteEthMACCore(phy, 32, tx_cdc_depth=512)
                buffer_slow_cm005_tx(mac)
                dut.comb += [phy.sink.ready.eq(1), phy.rx_input.valid.eq(0), mac.source.ready.eq(1)]
                frames = [payload(1518, 1), payload(65, 2)]
                output, underflows, gaps = [], [], []

                def driver():
                    for _ in range(10):
                        yield
                    for frame in frames:
                        yield from send(mac.sink, frame)
                    for _ in range(500):
                        yield

                @passive
                def monitor():
                    current = bytearray()
                    gap = 0
                    while True:
                        if (yield phy.sink.valid):
                            if not current and output:
                                gaps.append(gap)
                            gap = 0
                            current.append((yield phy.sink.data))
                            self.assertEqual((yield phy.sink.error), 0)
                            if (yield phy.sink.last):
                                output.append(bytes(current))
                                current.clear()
                        else:
                            gap += 1
                            if current:
                                underflows.append(len(current))
                        yield
                run_simulation(simulation_fragment(dut),
                    {'sys': driver(), 'eth_tx': monitor()},
                    clocks={'sys': round(1e12/frequency), 'eth_tx': 8000, 'eth_rx': 8000})
                self.assertEqual(output, [framed(frame) for frame in frames])
                self.assertFalse(underflows)
                self.assertTrue(gaps and all(gap >= 12 for gap in gaps))



if __name__ == "__main__":
    unittest.main()
