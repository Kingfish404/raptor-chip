"""The generated primitive must identify the actual UltraScale+ architecture."""
import sys
import unittest
from pathlib import Path

from migen import ClockDomain, Module

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from usp_clock import USPIDELAYCTRL


class USPClockTest(unittest.TestCase):
    def test_generated_architecture_and_reset_ports(self):
        dut = Module()
        dut.clock_domains.cd_ref = ClockDomain('ref')
        dut.clock_domains.cd_ready = ClockDomain('ready')
        dut.submodules.delay = USPIDELAYCTRL(dut.cd_ref, dut.cd_ready)
        # The synchronizer implementation is platform-specific. Inspect the
        # actual controller primitive, before the platform lowers resets.
        from migen import Instance
        cells = [s for s in dut.delay._fragment.specials
                 if isinstance(s, Instance) and s.of == 'IDELAYCTRL']
        self.assertEqual(len(cells), 1)
        cell = cells[0]
        parameters = {p.name: p.value for p in cell.items if isinstance(p, Instance.Parameter)}
        self.assertEqual(parameters['SIM_DEVICE'], 'ULTRASCALE_PLUS')
        self.assertIs(cell.get_io('REFCLK'), dut.cd_ref.clk)
        self.assertIsNotNone(cell.get_io('RDY'))
        self.assertIsNotNone(cell.get_io('RST'))


if __name__ == '__main__':
    unittest.main()
