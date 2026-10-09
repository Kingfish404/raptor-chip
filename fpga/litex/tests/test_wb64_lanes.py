"""Exercise LiteX's 32-to-64-bit AXI-Lite adapter and Wishbone CSR lanes."""

import unittest

from migen import Memory, Module, Mux, Signal
from migen.sim import passive, run_simulation
from litex.soc.interconnect import axi, wishbone


class Bridge(Module):
    def __init__(self):
        self.cpu = axi.AXILiteInterface(data_width=32, address_width=32)
        wide = axi.AXILiteInterface(data_width=64, address_width=32)
        self.wb = wb = wishbone.Interface(data_width=64, address_width=32,
                                         addressing="word")
        self.submodules.up = axi.AXILiteConverter(self.cpu, wide)
        self.submodules.bridge = axi.AXILite2Wishbone(wide, wb)
        self.comb += [
            wb.ack.eq(wb.cyc & wb.stb),
            # Lane-accurate slave: each 32-bit half answers only if selected.
            wb.dat_r.eq(Mux(wb.sel[4], 0xaabbccdd00000000, 0)
                        | Mux(wb.sel[0], 0x0000000011223344, 0)),
        ]


class FullBridge(Module):
    def __init__(self):
        self.cpu = axi.AXIInterface(data_width=32, address_width=32, id_width=4)
        wide = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.wb = wb = wishbone.Interface(data_width=64, address_width=32,
                                         addressing="word")
        self.submodules.up = axi.AXIConverter(self.cpu, wide)
        self.submodules.bridge = axi.AXI2Wishbone(wide, wb)
        self.comb += [
            wb.ack.eq(wb.cyc & wb.stb),
            # Lane-accurate slave: each 32-bit half answers only if selected.
            wb.dat_r.eq(Mux(wb.sel[4], 0xaabbccdd00000000, 0)
                        | Mux(wb.sel[0], 0x0000000011223344, 0)),
        ]


class FullBridge64(Module):
    """RV64 CPU: a 64-bit AXI master straight onto the 64-bit Wishbone bus."""
    def __init__(self):
        self.cpu = cpu = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.wb = wb = wishbone.Interface(data_width=64, address_width=32,
                                         addressing="word")
        self.submodules.bridge = axi.AXI2Wishbone(cpu, wb)
        self.comb += [
            wb.ack.eq(wb.cyc & wb.stb),
            wb.dat_r.eq(Mux(wb.sel[4], 0xaabbccdd00000000, 0)
                        | Mux(wb.sel[0], 0x0000000011223344, 0)),
        ]


def _fix_memories(dut):
    # Migen's simulator assumes even write-only FIFO ports have dat_r.
    fragment = dut.get_fragment()
    for memory in fragment.specials:
        if isinstance(memory, Memory):
            for port in memory.ports:
                if port.dat_r is None:
                    port.dat_r = Signal(memory.width)
    return fragment


def _axi_read(test, cpu, addr, size):
    yield cpu.ar.addr.eq(addr)
    yield cpu.ar.len.eq(0)
    yield cpu.ar.size.eq(size)
    yield cpu.ar.burst.eq(1)
    yield cpu.ar.valid.eq(1)
    yield cpu.r.ready.eq(1)
    for _ in range(100):
        if (yield cpu.ar.ready):
            break
        yield
    else:
        raise AssertionError("AXI read address stalled")
    yield
    yield cpu.ar.valid.eq(0)
    for _ in range(100):
        if (yield cpu.r.valid):
            data = yield cpu.r.data
            yield
            return data
        yield
    raise AssertionError("AXI read response stalled")


class WB64LaneTest(unittest.TestCase):
    def test_rv64_doubleword_read_selects_both_lanes(self):
        # Linux memcpy_fromio uses 64-bit loads on device SRAM (LiteEth RX).
        dut = FullBridge64()
        results = {}

        def exercise():
            for _ in range(4):
                yield
            results["dword"] = yield from _axi_read(self, dut.cpu, 0x18000000, 3)
            results["low"] = yield from _axi_read(self, dut.cpu, 0x11001800, 2)
            results["high"] = yield from _axi_read(self, dut.cpu, 0x11001804, 2)

        run_simulation(_fix_memories(dut), [exercise()])
        self.assertEqual(results["dword"], 0xaabbccdd11223344)
        self.assertEqual(results["low"] & 0xffffffff, 0x11223344)
        self.assertEqual(results["high"] >> 32, 0xaabbccdd)

    def test_rv32_axi_full_writes_upper_wishbone_lane(self):
        dut = FullBridge()
        cpu = dut.cpu
        seen = []

        @passive
        def observe():
            while True:
                if (yield dut.wb.cyc) and (yield dut.wb.stb):
                    seen.append(((yield dut.wb.we), (yield dut.wb.adr),
                                 (yield dut.wb.sel), (yield dut.wb.dat_w)))
                yield

        def exercise():
            for _ in range(4):
                yield
            yield cpu.aw.addr.eq(0x11001804)
            yield cpu.aw.len.eq(0)
            yield cpu.aw.size.eq(2)
            yield cpu.aw.burst.eq(1)
            yield cpu.aw.valid.eq(1)
            yield cpu.w.data.eq(0xdeadbeef)
            yield cpu.w.strb.eq(0xf)
            yield cpu.w.last.eq(1)
            yield cpu.w.valid.eq(1)
            yield cpu.b.ready.eq(1)
            yield
            aw_done = w_done = b_done = False
            for _ in range(150):
                if not aw_done and (yield cpu.aw.ready):
                    aw_done = True
                    yield cpu.aw.valid.eq(0)
                if not w_done and (yield cpu.w.ready):
                    w_done = True
                    yield cpu.w.valid.eq(0)
                if aw_done and w_done and (yield cpu.b.valid):
                    b_done = True
                    break
                yield
            self.assertTrue((aw_done, w_done, b_done) == (True, True, True),
                            (aw_done, w_done, b_done))
            yield

        fragment = dut.get_fragment()
        for memory in fragment.specials:
            if isinstance(memory, Memory):
                for port in memory.ports:
                    if port.dat_r is None:
                        port.dat_r = Signal(memory.width)
        run_simulation(fragment, [exercise(), observe()])
        self.assertIn((1, 0x11001800 >> 3, 0xf0, 0xdeadbeef00000000), seen)

    def test_rv32_axi_full_reads_upper_wishbone_lane(self):
        dut = FullBridge()
        cpu = dut.cpu
        seen = []

        @passive
        def observe():
            while True:
                if (yield dut.wb.cyc) and (yield dut.wb.stb):
                    seen.append(((yield dut.wb.we), (yield dut.wb.adr),
                                 (yield dut.wb.sel), (yield dut.wb.dat_w)))
                yield

        def exercise():
            for _ in range(4):
                yield
            yield cpu.ar.addr.eq(0x11001804)
            yield cpu.ar.len.eq(0)
            yield cpu.ar.size.eq(2)
            yield cpu.ar.burst.eq(1)
            yield cpu.ar.valid.eq(1)
            yield cpu.r.ready.eq(1)
            for _ in range(100):
                if (yield cpu.ar.ready):
                    break
                yield
            else:
                raise AssertionError("AXI-full read address stalled")
            yield
            yield cpu.ar.valid.eq(0)
            for _ in range(100):
                if (yield cpu.r.valid):
                    self.assertEqual((yield cpu.r.data), 0xaabbccdd)
                    break
                yield
            else:
                raise AssertionError("AXI-full read response stalled")
            yield
            for _ in range(5):
                yield

        # Migen's simulator assumes even write-only FIFO ports have dat_r.
        # Give those unused ports a dummy signal; synthesized RTL is untouched.
        fragment = dut.get_fragment()
        for memory in fragment.specials:
            if isinstance(memory, Memory):
                for port in memory.ports:
                    if port.dat_r is None:
                        port.dat_r = Signal(memory.width)
        run_simulation(fragment, [exercise(), observe()])
        base_word = 0x11001800 >> 3
        self.assertIn((0, base_word, 0xf0, 0), seen)

    def test_rv32_lower_upper_and_byte(self):
        dut = Bridge()
        cpu = dut.cpu
        seen = []

        @passive
        def observe():
            while True:
                if (yield dut.wb.cyc) and (yield dut.wb.stb):
                    seen.append(((yield dut.wb.we), (yield dut.wb.adr),
                                 (yield dut.wb.sel), (yield dut.wb.dat_w)))
                yield

        def read(address):
            yield cpu.ar.addr.eq(address)
            yield cpu.ar.valid.eq(1)
            yield cpu.r.ready.eq(1)
            for _ in range(100):
                if (yield cpu.ar.ready):
                    break
                yield
            else:
                raise AssertionError("AXI read address stalled")
            yield
            yield cpu.ar.valid.eq(0)
            for _ in range(100):
                if (yield cpu.r.valid):
                    value = (yield cpu.r.data)
                    yield
                    return value
                yield
            raise AssertionError("AXI read response stalled")

        def write(address, data, strb):
            yield cpu.aw.addr.eq(address)
            yield cpu.aw.valid.eq(1)
            yield cpu.w.data.eq(data)
            yield cpu.w.strb.eq(strb)
            yield cpu.w.valid.eq(1)
            yield cpu.b.ready.eq(1)
            aw_done = w_done = False
            for _ in range(100):
                if not aw_done and (yield cpu.aw.ready):
                    aw_done = True
                    yield cpu.aw.valid.eq(0)
                if not w_done and (yield cpu.w.ready):
                    w_done = True
                    yield cpu.w.valid.eq(0)
                if aw_done and w_done and (yield cpu.b.valid):
                    yield
                    return
                yield
            raise AssertionError("AXI write stalled")

        def exercise():
            for _ in range(4):
                yield
            low = yield from read(0x11001800)
            high = yield from read(0x11001804)
            byte = yield from read(0x11001805)
            self.assertEqual(low, 0x11223344)
            self.assertEqual(high, 0xaabbccdd)
            self.assertEqual(byte, 0xaabbccdd)
            yield from write(0x11001804, 0xdeadbeef, 0xf)
            yield from write(0x11001805, 0x0000aa00, 0x2)
            for _ in range(8):
                yield

        run_simulation(dut, [exercise(), observe()])
        base_word = 0x11001800 >> 3
        reads = [entry for entry in seen if entry[0] == 0]
        writes = [entry for entry in seen if entry[0] == 1]
        self.assertEqual([entry[1:3] for entry in reads[:3]],
                         # An aligned read selects all lanes (AXI-Lite has no size);
                         # an upper-half read selects only the upper CSR slot.
                         [(base_word, 0xff), (base_word, 0xf0), (base_word, 0xf0)])
        self.assertEqual([(entry[1], entry[2], entry[3]) for entry in writes[:2]],
                         [(base_word, 0xf0, 0xdeadbeef00000000),
                          (base_word, 0x20, 0x0000aa0000000000)])


if __name__ == "__main__":
    unittest.main()
