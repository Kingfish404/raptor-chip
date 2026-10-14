"""Real LiteEth RX SRAM/FIFO event contract used by the PLIC network regression.

Run with fpga/litex/.venv/bin/python3 fpga/litex/tests/test_liteeth_rx_irq.py.
No board, kernel module, or network connection is used.
"""
import unittest

from migen import Memory, Module, Signal
from migen.sim import run_simulation
from liteeth.mac.sram import LiteEthMACSRAMWriter
from litex.soc.interconnect import csr_bus


def simulation_fragment(dut):
    fragment = dut.get_fragment()
    # Match the existing MAC tests' compatibility shim for write-only ports.
    for memory in fragment.specials:
        if isinstance(memory, Memory):
            for port in memory.ports:
                if port.dat_r is None:
                    port.dat_r = Signal(memory.width)
    return fragment


class LiteEthRXIRQTest(unittest.TestCase):
    def exercise(self, mask_between_packets):
        writer = LiteEthMACSRAMWriter(32, 512, nslots=8, endianness="little")
        # Normally the parent Wishbone interface adds the shared SRAM memories;
        # this test instantiates only the writer and must register them itself.
        writer.specials += writer.mems
        dut = Module()
        dut.submodules.writer = writer
        bus = csr_bus.Interface(data_width=32)
        # Include the actual CSR bank: field packing and registered W1C strobes
        # are part of the event path, not substitutes driven by the test.
        registers = writer.get_csrs()
        offsets = {register.name: index for index, register in enumerate(registers)}
        dut.submodules.bank = csr_bus.CSRBank(registers, 0, bus=bus)

        def write_csr(name, value):
            yield bus.adr.eq(offsets[name])
            yield bus.dat_w.eq(value)
            yield bus.we.eq(1)
            yield
            yield bus.we.eq(0)
            for _ in range(4):
                yield

        def run():
            yield from write_csr("ev_enable", 1)
            yield writer.sink.error.eq(0)
            yield writer.crc_error.eq(0)
            for _ in range(4):
                yield
            # Repeated slot wraparound, with eight frames queued before service.
            for batch in range(8):
                for packet in range(8):
                    for word in range(16):
                        yield writer.sink.valid.eq(1)
                        yield writer.sink.data.eq((batch << 16) | (packet << 8) | word)
                        yield writer.sink.last.eq(word == 15)
                        yield writer.sink.last_be.eq(8)
                        yield
                        self.assertEqual((yield writer.sink.ready), 1)
                    yield writer.sink.valid.eq(0)
                    yield writer.sink.last.eq(0)
                    for _ in range(4):
                        yield
                self.assertEqual((yield writer._errors.status), 0)
                for packet in range(8):
                    self.assertEqual((yield writer.ev.irq), 1)
                    self.assertEqual((yield writer.ev.pending.status), 1)
                    self.assertEqual((yield writer._slot.status), packet)
                    self.assertEqual((yield writer._length.status), 64)
                    if mask_between_packets:
                        yield from write_csr("ev_enable", 0)
                        self.assertEqual((yield writer.ev.irq), 0)
                        self.assertEqual((yield writer.ev.pending.status), 1)
                        yield from write_csr("ev_enable", 1)
                        self.assertEqual((yield writer.ev.irq), 1)
                    # A W1C acknowledges exactly one RX descriptor. If another
                    # frame is queued, the level must never be lost.
                    yield from write_csr("ev_pending", 1)
                    for _ in range(5):
                        yield
                        self.assertEqual((yield writer.ev.irq), int(packet != 7))
                self.assertEqual((yield writer.ev.pending.status), 0)

        run_simulation(simulation_fragment(dut), run())

    def test_queued_packets_keep_level_until_drained(self):
        self.exercise(False)

    def test_irq_mask_preserves_queued_packets(self):
        self.exercise(True)


if __name__ == "__main__":
    unittest.main()
