"""Controller attributes must match the Vivado used to build the netlist."""
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from migen import ClockDomain, Module

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from usp_clock import USPIDELAYCTRL, idelayctrl_sim_device


class USPClockTest(unittest.TestCase):
    @patch('usp_clock.shutil.which', return_value='/tools/vivado')
    @patch('usp_clock.subprocess.check_output')
    def test_generated_architecture_and_reset_ports(self, version, which):
        for release, architecture in (('2025.2', 'ULTRASCALE'), ('2026.1', 'ULTRASCALE_PLUS')):
            with self.subTest(release=release):
                version.return_value = f'vivado v{release} (64-bit)\nSW Build 1234567\n'
                self.check_controller(architecture)
                version.assert_called_with(['/tools/vivado', '-version'], text=True)
                which.assert_called_with('vivado')

    def check_controller(self, architecture):
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
        self.assertEqual(parameters['SIM_DEVICE'], architecture)
        self.assertIs(cell.get_io('REFCLK'), dut.cd_ref.clk)
        self.assertIsNotNone(cell.get_io('RDY'))
        self.assertIsNotNone(cell.get_io('RST'))

    @patch('usp_clock.shutil.which', return_value=None)
    @patch('usp_clock.subprocess.check_output')
    def test_source_only_elaboration_without_vivado(self, version, which):
        self.check_controller('ULTRASCALE')
        version.assert_not_called()

    @patch('usp_clock.shutil.which', return_value='/tools/vivado')
    @patch('usp_clock.subprocess.check_output', return_value='unknown tool version')
    def test_unknown_version_does_not_guess_an_architecture(self, version, which):
        with self.assertRaisesRegex(RuntimeError, 'Cannot determine Vivado'):
            idelayctrl_sim_device()


if __name__ == '__main__':
    unittest.main()
