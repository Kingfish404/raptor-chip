import struct
import tempfile
import unittest
from pathlib import Path

from lib.journal import (ACCESS, ACCESS_KIND, BEGIN, COMPLETE, END, HEADER,
                          JournalError, LOCK, MEMORY, RECORD, STATE, STATE_WORDS,
                          UNLOCK, INTERRUPT, CLOCK, IO_REQUEST, PLIC_SOURCE, PLIC_BASE,
                          UART_RX, UART_IRQ, UART_TX, UART_BASE, check_journal)
from lib.net import NET_RX, NET_RX_RESULT
from lib.block import BLOCK_IMAGE, BLOCK_PAGE, BLOCK_MAX_IMAGE


class JournalTest(unittest.TestCase):
    def fixture(self, threaded=False):
        state = [0] * STATE_WORDS
        state[0] = 0x80000000
        events = [
            [MEMORY, 0, 0, struct.pack('<Q', 0x80000000) + b'\x13'],
            [STATE, 0, 0, struct.pack(f'<{STATE_WORDS}Q', *state)],
            [BEGIN, 0, 0, struct.pack('<Q', state[0])],
            [ACCESS_KIND, 0, 0, ACCESS.pack(state[0], 0x13, 4, 0)],
            [ACCESS_KIND, 0, 0, ACCESS.pack(0x100000, 0x5555, 4, 1)],
            [END, 0, 0, struct.pack('<6Q', 0x13, 0, 0, 1, 0, state[0] + 4)],
            [COMPLETE, 0, 1, struct.pack('<6Q', 2, 0, 1, 0, 0, 0)],
        ]
        if threaded:
            events.insert(2, [LOCK, 0, 0, b''])
            events.insert(-1, [UNLOCK, 0, 1, b''])
        return events

    def encoded(self, events, threaded=False, version=1):
        data = HEADER.pack(b'NMUJNL01', version, 64, 1, 0x80000000, 4096, 0, threaded)
        for sequence, (kind, hart, instruction, payload) in enumerate(events):
            data += RECORD.pack(kind, sequence, hart, instruction, len(payload)) + payload
        return data

    def check(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.njr'
            path.write_bytes(data)
            return check_journal(path)

    def test_round_trip(self):
        for threaded in (False, True):
            with self.subTest(threaded=threaded):
                result = self.check(self.encoded(self.fixture(threaded), threaded))
                self.assertEqual(result['instructions'], [1])
                self.assertEqual(result['status'], 'memory-consistent')

    def test_finisher_read(self):
        for threaded in (False, True):
            events = self.fixture(threaded)
            position = next(index for index, event in enumerate(events) if event[0] == END)
            events.insert(position - 1, [ACCESS_KIND, 0, 0, ACCESS.pack(0x100000, 0, 4, 0)])
            self.assertEqual(self.check(self.encoded(events, threaded))['status'], 'memory-consistent')
            for address, value, width, write in ((0x100000, 1, 4, 0), (0x100004, 0, 4, 0),
                                                (0x100000, 0, 1, 0), (0x100000, 0, 8, 0),
                                                (0x100000, 1, 4, 1)):
                events[position - 1][3] = ACCESS.pack(address, value, width, write)
                with self.assertRaises(JournalError):
                    self.check(self.encoded(events, threaded))

    def test_rng_policy_version(self):
        events = self.fixture(True)
        state = list(struct.unpack(f'<{STATE_WORDS}Q', events[1][3]))
        state[4162] = (1 << 64) - 1
        events[1][3] = struct.pack(f'<{STATE_WORDS}Q', *state)
        result = self.check(self.encoded(events, True, version=7))
        self.assertTrue(result['tlb_retain'])
        self.assertEqual(result['version'], 7)
        self.assertEqual(result['dma_reads'], 0)
        with self.assertRaisesRegex(JournalError, 'retained TLB requires threaded'):
            self.check(self.encoded(events, False, version=7))

    def test_tlb_policy_version(self):
        for threaded in (False, True):
            events = self.fixture(threaded)
            state = list(struct.unpack(f'<{STATE_WORDS}Q', events[1][3]))
            state[4162] = (1 << 64) - 1
            events[1][3] = struct.pack(f'<{STATE_WORDS}Q', *state)
            if threaded:
                result = self.check(self.encoded(events, threaded, version=6))
                self.assertTrue(result['tlb_retain'])
                self.assertEqual(result['version'], 6)
            else:
                with self.assertRaisesRegex(JournalError, 'retained TLB requires threaded'):
                    self.check(self.encoded(events, threaded, version=6))

    def net_poll_fixture(self):
        events = self.fixture(True)
        state = list(struct.unpack(f'<{STATE_WORDS}Q', events[1][3]))
        state[4162] = (1 << 64) - 1
        events[1][3] = struct.pack(f'<{STATE_WORDS}Q', *state)
        events[3:3] = [[CLOCK, 0, 0, struct.pack('<3Q', 10, 1, 0)],
                       [NET_RX, 0, 0, struct.pack('<2Q', 0, 0)],
                       [NET_RX_RESULT, 0, 0, struct.pack('<3Q', 0, 0, 0)]]
        end = next(event for event in events if event[0] == END)
        end[3] += struct.pack('<2Q', 65 + 0xc01, 10)
        return events

    def test_net_idle_poll_and_policy(self):
        events = self.net_poll_fixture()
        result = self.check(self.encoded(events, True, 8))
        self.assertEqual(result['net_rx'], 1)
        self.assertEqual(result['net_rx_drops'], 1)
        self.assertTrue(result['tlb_retain'])
        for version, threaded in ((7, True), (8, False)):
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, threaded, version))

    def test_net_poll_context_and_result(self):
        for index in (4, 5):
            events = self.net_poll_fixture()
            payload = bytearray(events[index][3])
            payload[-8] ^= 1
            events[index][3] = bytes(payload)
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, True, 8))
        events = self.net_poll_fixture()
        del events[5]
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, True, 8))

    def test_net_poll_phase_order(self):
        for kind, value in ((PLIC_SOURCE, 1), (UART_RX, 65)):
            events = self.net_poll_fixture()
            events.insert(6, [kind, 0, 0, struct.pack('<2Q', value, 0)])
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, True, 8))
        events = self.net_poll_fixture()
        events[6:6] = events[4:6]
        self.assertEqual(self.check(self.encoded(events, True, 8))['net_rx'], 2)

    def block_fixture(self):
        return [[BLOCK_IMAGE, 0, 0, struct.pack('<2Q', 8195, 2)],
                [BLOCK_PAGE, 0, 0, struct.pack('<Q', 0) + b'a' * 4096],
                [BLOCK_PAGE, 0, 0, struct.pack('<Q', 8192) + b'xyz']] + self.net_poll_fixture()

    def test_block_snapshot_and_policy(self):
        events = self.block_fixture()
        result = self.check(self.encoded(events, True, 9))
        self.assertEqual(result['block_image_size'], 8195)
        self.assertEqual(result['block_pages'], 2)
        self.assertEqual(result['block_reads'], 0)
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, True, 8))

    def test_block_snapshot_rejects_bad_geometry(self):
        for size, count in ((BLOCK_MAX_IMAGE + 1, 2), (8195, 4), (8195, 1), (8195, 0), (0, 2)):
            events = self.block_fixture()
            events[0][3] = struct.pack('<2Q', size, count)
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, True, 9))

    def test_block_snapshot_page_order_and_extent(self):
        for fault in ('missing', 'duplicate', 'reorder', 'short', 'offset'):
            events = self.block_fixture()
            if fault == 'missing':
                del events[1]
            elif fault == 'duplicate':
                events.insert(1, events[1])
            elif fault == 'reorder':
                events[1], events[2] = events[2], events[1]
            elif fault == 'short':
                events[2][3] = events[2][3][:-1]
            else:
                events[2][3] = struct.pack('<Q', 8193) + b'xyz'
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, True, 9))

    def test_interrupt_version(self):
        for threaded in (False, True):
            events = self.fixture(threaded)
            index = next(index for index, event in enumerate(events) if event[0] == ACCESS_KIND)
            events.insert(index, [INTERRUPT, 0, 0, struct.pack('<2Q', (1 << 63) | 9, 0x80000000)])
            result = self.check(self.encoded(events, threaded, version=2))
            self.assertEqual(result['interrupts'], [1])
            self.assertEqual(result['version'], 2)
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, threaded))

    def test_interrupt_order(self):
        for position in (2, 4, 5, 6, 7):
            events = self.fixture()
            events.insert(position, [INTERRUPT, 0, 0, struct.pack('<2Q', (1 << 63) | 1, 0x80000000)])
            with self.subTest(position=position), self.assertRaises(JournalError):
                self.check(self.encoded(events, version=2))
        events = self.fixture()
        entry = [INTERRUPT, 0, 0, struct.pack('<2Q', (1 << 63) | 1, 0x80000000)]
        events[3:3] = [entry, entry]
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, version=2))

    def test_interrupt_payload(self):
        for payload in (b'', struct.pack('<2Q', 9, 0x80000000),
                        struct.pack('<2Q', (1 << 63) | 12, 0x80000000),
                        struct.pack('<2Q', (1 << 63) | 1, 0x80000004)):
            events = self.fixture()
            events.insert(3, [INTERRUPT, 0, 0, payload])
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, version=2))

    def clint_fixture(self):
        events = self.fixture()
        state = list(struct.unpack(f'<{STATE_WORDS}Q', events[1][3]))
        state[4162] = (1 << 64) - 1
        state[65 + 0x14d] = (1 << 64) - 1
        events[1][3] = struct.pack(f'<{STATE_WORDS}Q', *state)
        events[2:2] = [[CLOCK, 0, 0, struct.pack('<3Q', 10, 1, 0)]]
        events[5:5] = [
            [IO_REQUEST, 0, 0, ACCESS.pack(0x02000000, 1, 4, 1)],
            [CLOCK, 0, 0, struct.pack('<3Q', 20, 1, 1)],
            [ACCESS_KIND, 0, 0, ACCESS.pack(0x02000000, 1, 4, 1)],
            [IO_REQUEST, 0, 0, ACCESS.pack(0x02000000, 0, 4, 0)],
            [CLOCK, 0, 0, struct.pack('<3Q', 30, 2, 1)],
            [ACCESS_KIND, 0, 0, ACCESS.pack(0x02000000, 1, 4, 0)],
        ]
        events[-2][3] += struct.pack('<4Q', 65 + 0x344, 8, 65 + 0xc01, 20)
        return events

    def test_clint_register_replay(self):
        result = self.check(self.encoded(self.clint_fixture(), version=3))
        self.assertEqual(result['clocks'], 3)
        self.assertEqual(result['idle_clocks'], 1)
        self.assertEqual(result['io_requests'], 2)
        for version in (1, 2):
            with self.assertRaises(JournalError):
                self.check(self.encoded(self.clint_fixture(), version=version))

    def test_clint_clock_contract(self):
        for replacement in ((9, 1, 1), (20, 2, 1), (20, 1, 0), (20, 3, 1)):
            events = self.clint_fixture()
            events[6][3] = struct.pack('<3Q', *replacement)
            with self.subTest(replacement=replacement), self.assertRaises(JournalError):
                self.check(self.encoded(events, version=3))
        events = self.clint_fixture()
        events.insert(7, events[6])
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, version=3))

    def test_clint_request_contract(self):
        for index in (5, 6, 7, 8, 9, 10):
            events = self.clint_fixture()
            del events[index]
            with self.subTest(index=index), self.assertRaises(JournalError):
                self.check(self.encoded(events, version=3))
        for address, width in ((0x1fffffc, 4), (0x02000004, 4), (0x02000000, 8), (0x02004004, 8), (0x02000000, 2)):
            events = self.clint_fixture()
            events[5][3] = ACCESS.pack(address, 1, width, 1)
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, version=3))

    def test_clint_values_and_time(self):
        events = self.clint_fixture()
        events[10][3] = ACCESS.pack(0x02000000, 0, 4, 0)
        with self.assertRaisesRegex(JournalError, 'independent CLINT value mismatch'):
            self.check(self.encoded(events, version=3))
        for slot, value in ((4162, 0), (65 + 0x344, 0), (65 + 0xc01, 30)):
            events = self.clint_fixture()
            fields = list(struct.unpack('<' + 'Q' * (len(events[-2][3]) // 8), events[-2][3]))
            delta = dict(zip(fields[4::2], fields[5::2]))
            delta[slot] = value
            fields = fields[:4] + [item for pair in sorted(delta.items()) for item in pair]
            events[-2][3] = struct.pack('<' + 'Q' * len(fields), *fields)
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, version=3))

    def test_truncation(self):
        data = self.encoded(self.fixture())
        for length in (0, 63, 65, len(data) - 1, len(data) - 48):
            with self.subTest(length=length), self.assertRaises(JournalError):
                self.check(data[:length])

    def plic_fixture(self):
        events = self.clint_fixture()
        events[3:3] = [[PLIC_SOURCE, 0, 0, struct.pack('<2Q', source, 0)] for source in (10, 32)]
        operations = []
        for offset, value, write in ((12, 2, 1), (40, 1, 1), (128, 1, 1),
                                     (0x2000, 0x408, 1), (0x2004, 1, 1), (0x1000, 9, 1),
                                     (0x200004, 3, 0), (0x200004, 10, 0),
                                     (0x200004, 32, 0), (0x200004, 0, 0)):
            operations.extend([
                [IO_REQUEST, 0, 0, ACCESS.pack(PLIC_BASE + offset, value if write else 0, 4, write)],
                [ACCESS_KIND, 0, 0, ACCESS.pack(PLIC_BASE + offset, value, 4, write)],
            ])
        events[-3:-3] = operations
        return events

    def test_plic_register_replay(self):
        for threaded in (False, True):
            events = self.plic_fixture()
            if threaded:
                events.insert(2, [LOCK, 0, 0, b''])
                events.insert(-1, [UNLOCK, 0, 1, b''])
            result = self.check(self.encoded(events, threaded, version=4))
            self.assertEqual(result['plic_sources'], 2)
            self.assertEqual(result['io_requests'], 12)
        with self.assertRaises(JournalError):
            self.check(self.encoded(self.plic_fixture(), version=3))
        events = self.plic_fixture()
        events.insert(3, events[3])
        result = self.check(self.encoded(events, version=4))
        self.assertEqual(result['plic_sources'], 3)

    def test_plic_source_contract(self):
        for source, executing in ((0, 0), (33, 0), (10, 1)):
            events = self.plic_fixture()
            events[3][3] = struct.pack('<2Q', source, executing)
            with self.subTest(source=source, executing=executing), self.assertRaises(JournalError):
                self.check(self.encoded(events, version=4))
        events = self.plic_fixture()
        events.insert(-3, events.pop(3))
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, version=4))

    def test_plic_io_contract(self):
        for address, width in ((PLIC_BASE - 4, 4), (PLIC_BASE, 8), (PLIC_BASE + 0x200008, 4),
                               (PLIC_BASE + 0x202000, 4), (PLIC_BASE + 0x2100, 4)):
            events = self.plic_fixture()
            event = next(event for event in events if event[0] == IO_REQUEST and ACCESS.unpack(event[3])[0] >= PLIC_BASE)
            event[3] = ACCESS.pack(address, 2, width, 1)
            with self.subTest(address=address, width=width), self.assertRaises(JournalError):
                self.check(self.encoded(events, version=4))
        events = self.plic_fixture()
        index = next(index for index, event in enumerate(events)
                     if event[0] == IO_REQUEST and ACCESS.unpack(event[3])[0] >= PLIC_BASE)
        events.insert(index + 1, [CLOCK, 0, 0, struct.pack('<3Q', 40, 1, 1)])
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, version=4))

    def test_plic_claim_side_effects(self):
        events = self.plic_fixture()
        event = next(event for event in events if event[0] == ACCESS_KIND and ACCESS.unpack(event[3]) == (PLIC_BASE + 0x200004, 10, 4, 0))
        event[3] = ACCESS.pack(PLIC_BASE + 0x200004, 3, 4, 0)
        with self.assertRaisesRegex(JournalError, 'independent PLIC value mismatch'):
            self.check(self.encoded(events, version=4))

    def uart_fixture(self, overflow=False):
        events = self.clint_fixture()
        values = list(range(256)) if overflow else [65, 66]
        events[3:3] = [[UART_RX, 0, 0, struct.pack('<2Q', value, 0)] for value in values]
        operations = []

        def operation(offset, value, write, effects=()):
            operations.append([IO_REQUEST, 0, 0, ACCESS.pack(UART_BASE + offset, value if write else 0, 1, write)])
            operations.extend([kind, 0, 0, struct.pack('<2Q', data, 1)] for kind, data in effects)
            operations.append([ACCESS_KIND, 0, 0, ACCESS.pack(UART_BASE + offset, value, 1, write)])

        operation(1, 3, 1, [(UART_IRQ, 10)])
        operation(0, 65, 1, [(UART_TX, 65), (UART_IRQ, 10), (UART_IRQ, 10)])
        operation(2, 4, 0)
        for value in values[:255]:
            operation(0, value, 0)
        operation(2, 2, 0)
        operation(2, 1, 0)
        operation(0, 0, 0)
        operation(5, 0x60, 0)
        events[-3:-3] = operations
        return events

    def test_uart_state_and_fifo(self):
        for overflow in (False, True):
            result = self.check(self.encoded(self.uart_fixture(overflow), version=5))
            self.assertEqual(result['uart_rx'], 256 if overflow else 2)
            self.assertEqual(result['uart_tx'], 1)
            self.assertEqual(result['uart_irqs'], 3)
        with self.assertRaises(JournalError):
            self.check(self.encoded(self.uart_fixture(), version=4))

    def test_uart_effect_contract(self):
        for kind in (UART_TX, UART_IRQ):
            for mutation in ('drop', 'duplicate', 'value', 'context'):
                events = self.uart_fixture()
                index = next(index for index, event in enumerate(events) if event[0] == kind)
                if mutation == 'drop':
                    del events[index]
                elif mutation == 'duplicate':
                    events.insert(index, events[index])
                else:
                    value, executing = struct.unpack('<2Q', events[index][3])
                    events[index][3] = struct.pack('<2Q', value ^ (mutation == 'value'), executing ^ (mutation == 'context'))
                with self.subTest(kind=kind, mutation=mutation), self.assertRaises(JournalError):
                    self.check(self.encoded(events, version=5))

    def test_uart_input_contract(self):
        for value, executing in ((256, 0), (65, 1)):
            events = self.uart_fixture()
            events[3][3] = struct.pack('<2Q', value, executing)
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, version=5))
        events = self.uart_fixture()
        index = next(index for index, event in enumerate(events) if event[0] == BEGIN)
        events.insert(index + 1, events.pop(3))
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, version=5))

    def test_uart_mmio_contract(self):
        for address, width in ((UART_BASE, 4), (UART_BASE + 8, 1), (UART_BASE - 1, 1)):
            events = self.uart_fixture()
            event = next(event for event in events if event[0] == IO_REQUEST and ACCESS.unpack(event[3])[0] >= UART_BASE)
            event[3] = ACCESS.pack(address, 3, width, 1)
            with self.assertRaises(JournalError):
                self.check(self.encoded(events, version=5))

    def test_invalid_headers(self):
        original = bytearray(self.encoded(self.fixture()))
        for offset, value in ((8, 99), (16, 16), (24, 0), (24, 5), (40, 0), (56, 2), (72, 10), (96, 1 << 40)):
            data = bytearray(original)
            struct.pack_into('<Q', data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(JournalError):
                self.check(data)

    def test_invalid_accesses(self):
        for access in ((0x80000000, 0x12, 4, 0), (0x80001000, 0, 4, 0),
                       (0x1000, 1, 4, 1), (0x80000000, 0, 3, 0),
                       (0x80000000, 0, 4, 2), (0x80000000, 256, 1, 0)):
            events = self.fixture()
            events[3][3] = ACCESS.pack(*access)
            with self.subTest(access=access), self.assertRaises(JournalError):
                self.check(self.encoded(events))

    def test_store_then_load(self):
        events = self.fixture()
        events.insert(4, [ACCESS_KIND, 0, 0, ACCESS.pack(0x80000001, 0xabcd, 2, 1)])
        events.insert(5, [ACCESS_KIND, 0, 0, ACCESS.pack(0x80000000, 0xabcd13, 4, 0)])
        self.check(self.encoded(events))
        events[4][3] = ACCESS.pack(0x80000001, 0xabce, 2, 1)
        with self.assertRaisesRegex(JournalError, 'load mismatch'):
            self.check(self.encoded(events))

    def test_bad_state_delta(self):
        for suffix in (struct.pack('<2Q', STATE_WORDS, 0), struct.pack('<2Q', 0, 0), b'!'):
            events = self.fixture()
            events[-2][3] += suffix
            with self.subTest(suffix=suffix), self.assertRaises(JournalError):
                self.check(self.encoded(events))

    def test_rejects_structure_faults(self):
        for index in range(len(self.fixture())):
            events = self.fixture()
            events[index][1] = 1
            with self.subTest(index=index), self.assertRaises(JournalError):
                self.check(self.encoded(events))
        for index in (2, 3, 5, 6):
            events = self.fixture()
            events[index][2] += 1
            with self.subTest(sequence=index), self.assertRaises(JournalError):
                self.check(self.encoded(events))

    def test_bus_boundaries(self):
        events = self.fixture(True)
        for index in (2, len(events) - 2):
            broken = [event for number, event in enumerate(events) if number != index]
            with self.subTest(index=index), self.assertRaises(JournalError):
                self.check(self.encoded(broken, True))
        events.insert(3, [LOCK, 0, 0, b''])
        with self.assertRaises(JournalError):
            self.check(self.encoded(events, True))

    def test_missing_footer_or_trailing_records(self):
        events = self.fixture()
        for broken in (events[:-1], events + [events[-1]]):
            with self.assertRaises(JournalError):
                self.check(self.encoded(broken))

    def test_failed_guest_or_unsupported_event(self):
        events = self.fixture()
        events[-1][3] = struct.pack('<6Q', 3, 1, 1, 0, 0, 0)
        with self.assertRaises(JournalError):
            self.check(self.encoded(events))
        events = self.fixture()
        events[-2][3] = struct.pack('<4Q', 0x13, 0, 1, 0)
        with self.assertRaises(JournalError):
            self.check(self.encoded(events))


if __name__ == '__main__':
    unittest.main()
