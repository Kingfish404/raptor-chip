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
from cm005_native import NativeCSRBank, SCOPED_QUERIES, check_dependency_origins, generate
from migen import Module, Record
from migen.sim import run_simulation
from litex.soc.interconnect.csr import CSRStatus, CSRStorage


class NativeCSRTests(unittest.TestCase):
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
