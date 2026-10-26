"""Native CM005 MMIO protocol, deterministic export and physical integration."""
import contextlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cm005_native import (NativeCPUFrameMAC, NativeCSRBank, SCOPED_QUERIES,
                          check_dependency_origins, generate)
from migen import Module, Record
from migen.sim import run_simulation
from litex.soc.interconnect.csr import CSRStatus, CSRStorage
from migen.sim import passive
from test_cm005_bridge import payload, send
from test_cm005_mac_receive import simulation_fragment
from cm005_switch import CM005Switch


class NativeCSRTests(unittest.TestCase):
    def test_cpu_rx_overflow_and_virtual_phy_reset_preserve_both_forwarding_directions(self):
        profile = Path(__file__).resolve().parents[2] / 'mlk-cu08-ku15p/board.json'
        dut = Module()
        dut.submodules.cpu = cpu = NativeCPUFrameMAC(
            json.loads(profile.read_text())['cm005_cpu_ethernet'])
        dut.submodules.switch = switch = CM005Switch()
        dut.comb += [cpu.source.connect(switch.sinks[2]),
                     switch.sources[2].connect(cpu.sink)]
        frames = [[payload(65, origin * 100 + i) for i in range(24)] for origin in range(2)]
        outputs = [[], []]

        def driver(origin):
            for frame in frames[origin]:
                yield from send(switch.sinks[origin], frame)
                for _ in range(50):
                    yield
            for _ in range(200):
                yield

        @passive
        def receiver(port):
            current = bytearray()
            yield switch.sources[port].ready.eq(1)
            while True:
                if (yield switch.sources[port].valid):
                    source = switch.sources[port]
                    last = (yield source.last)
                    count = (yield source.last_be).bit_length() if last else 4
                    current.extend((yield source.data).to_bytes(4, 'little')[:count])
                    if last:
                        outputs[port].append(bytes(current))
                        current.clear()
                yield

        def control():
            # Exercise the virtual PHY reset ABI used by LiteEth boot software.
            # Leave RX slots unread so the real CPU MAC also reaches overflow.
            for value in (1, 0, 1, 0):
                for _ in range(200):
                    yield
                yield cpu.bus.waddr.eq(0x1000)
                yield cpu.bus.wdata.eq(value)
                yield cpu.bus.wstrb.eq(15)
                yield cpu.bus.wr.eq(1)
                yield
                yield cpu.bus.wr.eq(0)
            for _ in range(1200):
                yield
            self.assertGreater((yield cpu.mac.interface.sram.writer._errors.status), 0)
            self.assertEqual(outputs[0], frames[1])
            self.assertEqual(outputs[1], frames[0])
        run_simulation(simulation_fragment(dut),
                       [driver(0), driver(1), control(), receiver(0), receiver(1)])

    def test_packet_sram_independent_addresses_byte_writes_irq_and_read_hold(self):
        profile = Path(__file__).resolve().parents[2] / 'mlk-cu08-ku15p/board.json'
        dut = NativeCPUFrameMAC(json.loads(profile.read_text())['cm005_cpu_ethernet'])
        bus, mac = dut.bus, dut.mac
        incoming, outgoing = payload(65, 41), payload(63, 42)
        output = bytearray()

        def access(read=None, write=None, data=0, strobe=15):
            yield bus.rd.eq(read is not None)
            yield bus.raddr.eq(read or 0)
            yield bus.wr.eq(write is not None)
            yield bus.waddr.eq(write or 0)
            yield bus.wdata.eq(data)
            yield bus.wstrb.eq(strobe)
            yield
            yield bus.rd.eq(0)
            yield bus.wr.eq(0)
            for _ in range(3):
                yield
            return (yield bus.rdata)

        @passive
        def monitor():
            cycle = 0
            while True:
                ready = cycle % 3 != 0
                yield mac.source.ready.eq(ready)
                yield
                if ready and (yield mac.source.valid):
                    last = (yield mac.source.last)
                    count = (yield mac.source.last_be).bit_length() if last else 4
                    output.extend((yield mac.source.data).to_bytes(4, 'little')[:count])
                cycle += 1

        def driver():
            yield from access(write=0x2014, data=1)
            yield from send(mac.sink, incoming)
            for _ in range(8):
                yield
            self.assertEqual((yield dut.irq), 1)
            # W1C must not merge the read value into an unselected byte.
            yield from access(write=0x2010, data=0, strobe=2)
            self.assertEqual((yield dut.irq), 1)
            body = bytearray()
            for offset in range(0, len(incoming), 4):
                word = yield from access(read=0x4000 + offset)
                body.extend(word.to_bytes(4, 'little'))
            self.assertEqual(body[:len(incoming)], incoming)
            held = yield from access(read=0x4000)
            yield bus.raddr.eq(0xffff)
            for _ in range(4):
                yield
                self.assertEqual((yield bus.rdata), held)
            # Read an RX slot while writing another address in TX slot 1.
            word = yield from access(read=0x4000, write=0x8800, data=0x12345678)
            self.assertEqual(word, int.from_bytes(incoming[:4], 'little'))
            yield from access(write=0x8800, data=0xaabbccdd, strobe=2)
            self.assertEqual((yield from access(read=0x8800)), 0x1234cc78)
            word = yield from access(read=0x8800, write=0x8804, data=0x01020304)
            self.assertEqual(word, 0x1234cc78)
            self.assertEqual((yield from access(read=0x8804)), 0x01020304)
            yield from access(write=0x8dfc, data=0x76543210)
            self.assertEqual((yield from access(read=0x8dfc)), 0x76543210)
            self.assertEqual((yield from access(read=0x4600)), 0)
            self.assertEqual((yield from access(read=0x8801)), 0)
            yield from access(write=0x2010, data=1)
            self.assertEqual((yield dut.irq), 0)
            boundary = payload(1536, 43)
            yield from send(mac.sink, boundary)
            for _ in range(8):
                yield
            self.assertEqual((yield from access(read=0x2004)), len(boundary))
            self.assertEqual((yield from access(read=0x4dfc)),
                             int.from_bytes(boundary[-4:], 'little'))
            self.assertEqual((yield from access(read=0x4e00)), 0)
            yield from access(write=0x2010, data=1)
            for offset in range(0, len(outgoing), 4):
                yield from access(write=0x8800 + offset,
                                  data=int.from_bytes(outgoing[offset:offset + 4], 'little'))
            yield from access(write=0x2024, data=1)
            yield from access(write=0x2028, data=len(outgoing))
            yield from access(write=0x2034, data=1)
            yield from access(write=0x2018, data=1)
            for _ in range(160):
                yield
            self.assertEqual(output, outgoing)
            self.assertEqual((yield dut.irq), 1)
            yield from access(write=0x2030, data=1)
            self.assertEqual((yield dut.irq), 0)
        run_simulation(simulation_fragment(dut), [driver(), monitor()])

    def test_external_editable_dependency_is_rejected(self):
        external = SimpleNamespace(__file__='/outside-checkout/migen/build/tools.py')
        with patch.dict(sys.modules, {'migen.external_probe': external}):
            with self.assertRaisesRegex(RuntimeError, 'Unfingerprinted dependency migen.external_probe'):
                check_dependency_origins()

    def test_async_sampling_coverage_exception_fails_closed(self):
        # Exercise the actual Tcl report parser and the exact 2 ns bound guard.
        script = SCOPED_QUERIES + r'''
proc get_ports {args} {return $args}
proc get_pins {args} {return $args}
proc get_timing_paths {args} {return sampler_path}
proc get_property {args} {global requirement; return $requirement}
set requirement 2.0
set report {
10. checking partial_input_delay (6)
------------------------------------
 There are 6 input ports with partial input delay specified. (HIGH)

cm005_clocks_rx
cm005_rx_ctl
cm005_rx_data[0]
cm005_rx_data[1]
cm005_rx_data[2]
cm005_rx_data[3]

11. checking partial_output_delay (0)
}
cm005_native_check_partial_inputs $report 6
if {![catch {cm005_native_check_partial_inputs $report 5}]} {error "accepted wrong count"}
set wrong [string map {cm005_rx_ctl unrelated_port} $report]
if {![catch {cm005_native_check_partial_inputs $wrong 6}]} {error "accepted unrelated port"}
set requirement 3.0
if {![catch {cm005_native_check_partial_inputs $report 6}]} {error "accepted relaxed bound"}
puts PASS
'''
        result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(result.stdout.strip(), 'PASS')

    def test_independent_addresses_partial_write_and_read_hold(self):
        dut = Module()
        bus = Record([('rd', 1), ('wr', 1), ('raddr', 16), ('waddr', 16),
                      ('wdata', 32), ('wstrb', 4), ('rdata', 32)])
        storage = CSRStorage(32, reset=0x12345678, name='storage')
        status = CSRStatus(32, name='status')
        dut.submodules.bank = NativeCSRBank([('test', [storage, status])], bus)

        def driver():
            yield status.status.eq(0xabcdef00)
            yield bus.rd.eq(1)
            yield bus.raddr.eq(4)
            yield bus.wr.eq(1)
            yield bus.waddr.eq(0)
            yield bus.wstrb.eq(2)
            yield bus.wdata.eq(0xffffaaee)
            yield
            yield bus.rd.eq(0)
            yield bus.wr.eq(0)
            yield
            self.assertEqual((yield storage.storage), 0x1234aa78)
            self.assertEqual((yield bus.rdata), 0xabcdef00)
            yield status.status.eq(0)
            yield bus.raddr.eq(0)
            for _ in range(4):
                yield
                self.assertEqual((yield bus.rdata), 0xabcdef00)
            yield bus.rd.eq(1)
            yield
            yield bus.rd.eq(0)
            yield
            self.assertEqual((yield bus.rdata), 0x1234aa78)
            yield bus.rd.eq(1)
            yield bus.raddr.eq(0x1000)
            yield
            yield bus.rd.eq(0)
            yield
            self.assertEqual((yield bus.rdata), 0)
        run_simulation(dut, driver())

    def test_export_is_reproducible_and_pins_do_not_overlap(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()):
            a, b = Path(temp) / 'a', Path(temp) / 'b'
            # Migen's process-global object IDs must not affect emitted bytes.
            generate(a)
            generate(b)
            for name in ('rapt_cm005_bridge.v', 'cm005_pins.xdc', 'cm005_timing.tcl',
                         'cm005_aperture.tcl', 'cm005_registers.json'):
                self.assertEqual((a / name).read_bytes(), (b / name).read_bytes(), name)
            pins = (a / 'cm005_pins.xdc').read_text()
            mapping = re.findall(r'set_property LOC (\w+) \[get_ports \{([^}]+)\}\]', pins)
            self.assertEqual(len(mapping), 29)
            self.assertEqual(len({p for p, _ in mapping}), 29)
            board = Path(__file__).resolve().parents[2] / 'mlk-cu08-ku15p'
            other = '\n'.join((board / 'constraints' / name).read_text()
                              for name in ('board.xdc', 'ddr4.xdc'))
            reserved = set(re.findall(r'set_property PACKAGE_PIN (\w+)', other))
            self.assertFalse(reserved & {p for p, _ in mapping})
            rtl = (a / 'rapt_cm005_bridge.v').read_text()
            self.assertNotIn('uartbone', rtl.lower())
            self.assertNotIn('rapt_top', rtl)
            self.assertIn('native_raddr', rtl)
            self.assertIn('native_waddr', rtl)
            self.assertEqual(pins.count('LOC E8 '), 1)
            timing = (a / 'cm005_timing.tcl').read_text()
            self.assertNotIn('CLOCK_DEDICATED_ROUTE FALSE', timing)
            self.assertEqual(timing.count('-edges {1 3 5} -edge_shift {2 2 2}'), 2)
            regs = json.loads((a / 'cm005_registers.json').read_text())['registers']
            self.assertEqual(len({r['offset'] for r in regs}), len(regs))
            self.assertEqual(regs[0]['name'], 'bridge_id')


if __name__ == '__main__':
    unittest.main()
