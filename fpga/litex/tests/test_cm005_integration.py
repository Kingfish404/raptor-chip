"""Standalone/CPU integration, physical constraints and read-only diagnostics."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX))
sys.path.insert(0, str(LITEX / 'scripts'))
from add_linux_ethernet_dts import ethernet_node
from cm005_bridge import CM005Bridge
from cm005_bridge_probe import mdio_read, probe
from litex.soc.integration.builder import Builder


class CPUBridgeIntegrationTest(unittest.TestCase):
    def generate(self, output, bits, ethernet, bridge=True, board='mlk_cu08_ku15p'):
        rom = output / 'test-rom.bin'
        rom.write_bytes(bytes.fromhex('6f000000'))
        command = [sys.executable, str(LITEX / (board + '.py')),
                   '--cpu-variant=linux'+str(bits), '--sys-clk-freq=50000000',
                   '--with-mig', '--output-dir='+str(output), '--build',
                   '--no-compile-gateware', '--no-compile-software',
                   '--boot-mode=custom', '--integrated-rom-init='+str(rom)]
        if ethernet:
            command.append('--with-ethernet')
        if not bridge:
            command.append('--without-cm005-bridge')
        env = dict(os.environ, RAPT_CONFIG='small', RAPTOR_HOME=str(LITEX.parents[1]))
        run = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertEqual(run.returncode, 0, run.stdout[-3000:] + run.stderr[-3000:])
        return json.loads((output / 'csr.json').read_text())

    def test_default_forwarding_with_and_without_cpu_nic(self):
        for bits, ethernet in ((32, False), (32, True), (64, True)):
            with self.subTest(bits=bits, ethernet=ethernet), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                csr = self.generate(out, bits, ethernet)
                self.assertEqual(csr['constants']['cm005_bridge'], 1)
                self.assertIn('phy_a', csr['csr_bases'])
                self.assertIn('phy_b', csr['csr_bases'])
                self.assertEqual('ethmac' in csr['csr_bases'], ethernet)
                if ethernet:
                    self.assertIn('cm005_switch', csr['csr_bases'])
                    self.assertEqual(csr['constants']['ethmac_rx_slots'], 8)
                    self.assertEqual(csr['memories']['ethmac']['base'], 0x18000000)
                    self.assertIn('interrupts = <4>;', ethernet_node(csr))
                    self.assertIn('ethphy_crg_reset', csr['csr_registers'])
                    self.assertIn('ethmac_preamble_crc', csr['csr_registers'])
                    header = (out / 'software/include/generated/csr.h').read_text()
                    # libliteeth/udp.c uses this exact capability macro to
                    # avoid adding a second preamble/FCS in software.
                    self.assertIn('#define CSR_ETHMAC_PREAMBLE_CRC_ADDR ', header)
                tcl = (out / 'gateware/mlk_cu08_ku15p.tcl').read_text()
                self.assertLess(tcl.index('raptor_retry_timing mlk_cu08_ku15p'),
                                tcl.index('set bridge_methodology'))
                self.assertLess(tcl.index('set bridge_methodology'),
                                tcl.index('cm005_check_sampling_aperture cm005_aperture.rpt'))
                self.assertLess(tcl.index('cm005_check_sampling_aperture cm005_aperture.rpt'),
                                tcl.index('write_bitstream'))
                gateware = (out / 'gateware/mlk_cu08_ku15p.v').read_text()
                self.assertIsNone(re.search(
                    r'\(\* (?:dont_touch|keep)[^\n]*\nwire[^\n]*crg_uspmmcm0_clkin_signal;',
                    gateware))

    def test_explicit_disable_retains_single_port_cpu_mac(self):
        with tempfile.TemporaryDirectory() as tmp:
            csr = self.generate(Path(tmp), 64, True, bridge=False)
            self.assertNotIn('cm005_bridge', csr['constants'])
            self.assertNotIn('phy_b', csr['csr_bases'])
            self.assertIn('ethphy_mdio_w', csr['csr_registers'])
            self.assertIn('interrupts = <4>;', ethernet_node(csr))

    def test_ku5p_shared_entry_point_accepts_unchanged_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            csr = self.generate(Path(tmp), 64, True, board='rk_xcku5p_f')
            self.assertNotIn('cm005_bridge', csr['constants'])
            self.assertIn('ethmac', csr['csr_bases'])
            self.assertIn('interrupts = <3>;', ethernet_node(csr))

    def test_make_identity_separates_forwarding(self):
        extension = ('.PHONY: bridge-config-test\nbridge-config-test:\n'
                     "\t@printf '%s\\n' '$(FPGA_CONFIG_ID)' '$(_FPGA_FLAGS)'\n")
        identities = []
        for enabled in (0, 1):
            result = subprocess.run(['make', '--no-print-directory', '-f', 'Makefile', '-f', '-',
                'bridge-config-test', 'FPGA_BOARD=mlk_cu08_ku15p', 'FPGA_AUTO_DETECT=0',
                'VARIANT=linux64', 'BOOT_MODE=bios', 'WITH_ETHERNET=1',
                'WITH_CM005_BRIDGE='+str(enabled)], cwd=LITEX, input=extension,
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            identities.append(lines[0])
            self.assertEqual('--without-cm005-bridge' in lines[1], enabled == 0)
        self.assertNotEqual(*identities)


class BridgeElaborationTest(unittest.TestCase):
    def test_shared_reset_and_preserved_phy_clock(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            out = Path(tmp)
            soc = CM005Bridge()
            Builder(soc, output_dir=tmp, compile_software=False).build(
                run=False, build_name='cm005_bridge')
            rtl = (out / 'gateware/cm005_bridge.v').read_text()
            xdc = (out / 'gateware/cm005_bridge.xdc').read_text()
            tcl = (out / 'gateware/cm005_bridge.tcl').read_text()
            self.assertIn('foreach cell {cm005_tx_phy_buf cm005_b_tx_phy_buf cm005_tx_word_buf '
                          'cm005_tx_serial_buf cm005_b_tx_serial_buf cm005_b_tx_word_buf} {', tcl)
            self.assertIn('if {[llength [get_cells -quiet $cell]] != 1}', tcl)
            self.assertEqual(xdc.count('set_property LOC E8 '), 1)
            self.assertIn('set_property LOC G9 [get_ports {cm005_b_clocks_rx}]', xdc)
            self.assertIn('USER_CLOCK_ROOT X2Y2 [get_nets eth_b_rx_clk]', xdc)
            # Identical divider functions must survive as separate buffers;
            # otherwise synthesis silently restores the overloaded I/O tree.
            for name in ('cm005_tx_phy_buf', 'cm005_b_tx_phy_buf', 'cm005_tx_word_buf',
                         'cm005_tx_serial_buf', 'cm005_b_tx_serial_buf', 'cm005_b_tx_word_buf'):
                start = rtl.index('// Instance ' + name)
                self.assertIn('(* dont_touch = "true" *)', rtl[max(0, start - 150):start])
            for name, clock in (('cm005_tx_data0_ddr', 'cm005_tx_phy_clk'),
                                ('cm005_b_tx_data0_ddr', 'cm005_b_tx_phy_clk'),
                                ('cm005_tx_clock_ddr', 'cm005_tx_serial_clk'),
                                ('cm005_b_tx_clock_ddr', 'cm005_b_tx_serial_clk')):
                instance = re.search(r'ODDRE1\s+' + name + r'\((.*?)\);', rtl, re.S)
                self.assertIsNotNone(instance)
                self.assertRegex(instance[1], r'\.C\s*\(' + clock + r'\)')
            self.assertIn('USER_CLOCK_ROOT X2Y2 [get_nets {cm005_b_tx_phy_clk cm005_b_tx_serial_clk}]', xdc)
            self.assertIn('CLOCK_DELAY_GROUP cm005_transmit [get_nets {cm005_tx_phy_clk cm005_tx_serial_clk}]', xdc)
            self.assertEqual(xdc.count('-edges {1 3 5} -edge_shift {2 2 2}'), 2)
            self.assertNotIn('CLOCK_DEDICATED_ROUTE FALSE', xdc)
            self.assertNotIn('rapt_top', rtl)


class MDIOReadTest(unittest.TestCase):
    def test_counters_only_does_not_access_mdio(self):
        from types import SimpleNamespace

        class Register:
            def __init__(self, value):
                self.value = value
            def read(self):
                return self.value
            def write(self, value):
                self.value = value

        scratch = Register(0x12345678)
        # Deliberately omit MDIO registers: counters-only must not access them.
        bus = SimpleNamespace(regs=SimpleNamespace(
            ctrl_scratch=scratch, a_to_b_forwarded=Register(12),
            b_to_a_forwarded=Register(8), mac_a_rx_datapath_crc_errors=Register(0)))
        result = probe(bus, counters_only=True)
        self.assertEqual(scratch.value, 0x12345678)
        self.assertEqual(result['counters'], {'a_to_b_forwarded': 12,
            'b_to_a_forwarded': 8, 'mac_a_rx_datapath_crc_errors': 0})
        self.assertEqual(result['phys'], {})

    def test_header_turnaround_and_bit_order(self):
        class Bus:
            def __init__(self):
                self.writes = []
                self.bits = iter([1, 0] + [(0xa53c >> n) & 1 for n in range(15, -1, -1)])
            def write(self, address, data, burst='incr'):
                self.writes.append((address, data, burst))
            def read(self, address):
                self.address = address
                return next(self.bits)
        bus = Bus()
        result = mdio_read(bus, 0x3004, 0x3008, 3, 17)
        self.assertEqual(result, {'value': 0xa53c, 'hex': '0xa53c', 'turnaround': [1, 0]})
        address, waveform, burst = bus.writes[0]
        self.assertEqual((address, burst), (0x3004, 'fixed'))
        self.assertEqual(len(waveform), 92)
        bits = [(value >> 2) & 1 for value in waveform[::2]]
        self.assertEqual(bits[:32], [1]*32)
        self.assertEqual(bits[32:], [0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1])
        self.assertTrue(all(low & 3 == 2 and high == low + 1
                            for low, high in zip(waveform[::2], waveform[1::2])))
        self.assertEqual(bus.writes[1:-1], [(0x3004, [0, 1], 'fixed')]*18)
        self.assertEqual(bus.writes[-1], (0x3004, 0, 'incr'))
        self.assertEqual(bus.address, 0x3008)



if __name__ == "__main__":
    unittest.main()
