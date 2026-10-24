"""CPU packet SRAM bus, CSR and RX/TX interrupt ABI on the virtual segment."""
from pathlib import Path
import sys
import unittest

from migen import Module, ResetInserter
from migen.sim import passive, run_simulation
from litex.soc.interconnect import csr_bus

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_switch import CPUFrameMAC
from test_cm005_bridge import payload, send
from test_cm005_mac_receive import simulation_fragment


class CPUMACTest(unittest.TestCase):
    def test_wishbone_bytes_and_csr_irq(self):
        dut = Module()
        dut.submodules.mac = mac = CPUFrameMAC('little')
        bus = csr_bus.Interface(data_width=32)
        registers = mac.get_csrs()
        offsets = {r.name: n for n, r in enumerate(registers)}
        dut.submodules.bank = csr_bus.CSRBank(registers, 0, bus=bus)
        output = bytearray()
        received = payload(65, 10)
        transmitted = payload(63, 11)
        done = []

        def csr_write(name, value):
            yield bus.adr.eq(offsets[name])
            yield bus.dat_w.eq(value)
            yield bus.we.eq(1)
            yield
            yield bus.we.eq(0)
            for _ in range(3):
                yield

        def wb_access(bus, address, data=None):
            yield bus.adr.eq(address)
            yield bus.cyc.eq(1)
            yield bus.stb.eq(1)
            yield bus.we.eq(data is not None)
            yield bus.sel.eq(15)
            if data is not None:
                yield bus.dat_w.eq(data)
            yield
            for _ in range(20):
                if (yield bus.ack):
                    value = (yield bus.dat_r)
                    break
                yield
            else:
                self.fail('Packet SRAM Wishbone access timed out')
            yield bus.cyc.eq(0)
            yield bus.stb.eq(0)
            yield
            return value

        @passive
        def monitor():
            cycle = 0
            while True:
                ready = cycle % 3 != 0
                yield mac.source.ready.eq(ready)
                yield
                if (yield mac.source.valid) and ready:
                    last = (yield mac.source.last)
                    count = (yield mac.source.last_be).bit_length() if last else 4
                    output.extend((yield mac.source.data).to_bytes(4, 'little')[:count])
                    if last:
                        done.append(True)
                cycle += 1

        def driver():
            yield bus.adr.eq(offsets['preamble_crc'])
            for _ in range(3):
                yield
            self.assertEqual((yield bus.dat_r), 1)
            yield from csr_write('sram_writer_ev_enable', 1)
            yield from csr_write('sram_reader_ev_enable', 1)
            yield from send(mac.sink, received)
            for _ in range(8):
                yield
            writer = mac.interface.sram.writer
            self.assertEqual((yield writer._length.status), len(received))
            self.assertEqual((yield writer._slot.status), 0)
            self.assertEqual((yield mac.ev.irq), 1)
            body = bytearray()
            for address in range((len(received)+3)//4):
                word = yield from wb_access(mac.bus_rx, address)
                body.extend(word.to_bytes(4, 'little'))
            self.assertEqual(body[:len(received)], received)
            yield from csr_write('sram_writer_ev_pending', 1)
            self.assertEqual((yield mac.ev.irq), 0)
            for offset in range(0, len(transmitted), 4):
                yield from wb_access(mac.bus_tx, offset//4,
                    int.from_bytes(transmitted[offset:offset+4], 'little'))
            yield from csr_write('sram_reader_slot', 0)
            yield from csr_write('sram_reader_length', len(transmitted))
            yield from csr_write('sram_reader_start', 1)
            for _ in range(150):
                yield
            self.assertEqual(done, [True])
            self.assertEqual(output, transmitted)
            self.assertEqual((yield mac.ev.irq), 1)
            yield from csr_write('sram_reader_ev_pending', 1)
            self.assertEqual((yield mac.ev.irq), 0)

        run_simulation(simulation_fragment(dut), [driver(), monitor()])

    def test_phy_restart_flushes_cpu_packet_state(self):
        mac = ResetInserter(["sys"])(CPUFrameMAC('little'))
        before, after = payload(64, 20), payload(65, 21)
        output = bytearray()
        capture = [False]
        completed = []

        def transmit(frame):
            for offset in range(0, len(frame), 4):
                yield from mac.bus_tx.write(offset // 4,
                    int.from_bytes(frame[offset:offset + 4], 'little'))
            reader = mac.interface.sram.reader
            yield reader._slot.storage.eq(0)
            yield reader._length.storage.eq(len(frame))
            yield reader._start.wr_stb.eq(1)
            yield
            yield reader._start.wr_stb.eq(0)

        @passive
        def monitor():
            while True:
                if capture[0] and (yield mac.source.valid) and (yield mac.source.ready):
                    last = (yield mac.source.last)
                    count = (yield mac.source.last_be).bit_length() if last else 4
                    output.extend((yield mac.source.data).to_bytes(4, 'little')[:count])
                    if last:
                        completed.append(True)
                yield

        def driver():
            # Leave both an unread RX frame and a partially emitted TX frame.
            yield from send(mac.sink, before)
            yield from transmit(before)
            for _ in range(12):
                yield
            self.assertEqual((yield mac.source.valid), 1)
            yield mac.source.ready.eq(1)
            for _ in range(4):
                yield
            yield mac.source.ready.eq(0)
            yield mac.reset_sys.eq(1)
            for _ in range(4):
                yield
            yield mac.reset_sys.eq(0)
            for _ in range(12):
                yield
            self.assertEqual((yield mac.source.valid), 0)
            self.assertEqual((yield mac.interface.sram.reader._level.status), 0)
            self.assertEqual((yield mac.interface.sram.writer.stat_fifo.source.valid), 0)
            capture[0] = True
            yield mac.source.ready.eq(1)
            yield from transmit(after)
            for _ in range(100):
                yield
            self.assertEqual(completed, [True])
            self.assertEqual(output, after)
        run_simulation(simulation_fragment(mac), [driver(), monitor()])


if __name__ == '__main__':
    unittest.main()
