"""Default distro selection, console handoff and immutable hardware boundaries."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / 'scripts'))
import netboot_flow as flow
from netboot_distro_publish import verify


class DefaultTest(unittest.TestCase):
    def test_make_default_and_debian_override(self):
        for xlen, overrides, expected in ((64, [], 'alpine'), (64, ['NETBOOT_DISTRO=debian'], 'debian'),
                                         (32, [], 'buildroot')):
            output = subprocess.check_output(['make', '-n', '--no-print-directory',
                                              f'fpga-netboot-rv{xlen}-bundle', *overrides], cwd=LITEX, text=True)
            self.assertIn("--distro '" + expected + "'", output)
            self.assertIn("--version 'v6.18.51'", output)
            self.assertNotIn('v6.18.50', output)

    def test_distro_console_and_buildroot_login(self):
        for prompt, sent in (('Please press Enter to activate this console.', ''), ('buildroot login: ', 'root')):
            port = Mock()
            flow.enter_linux(port, prompt)
            port.send.assert_called_once_with(sent)

    def test_manual_boot_identity_requires_guest_uuid(self):
        port = Mock()
        boot_id = '12345678-1234-1234-1234-123456789abc'
        port.command.return_value = '\r\n' + boot_id + '\r\n'
        self.assertEqual(flow.running_boot_id(port), boot_id)
        port.command.return_value = 'litex> '
        with self.assertRaisesRegex(RuntimeError, 'manually netboot'):
            flow.running_boot_id(port)

    def test_no_trace_kernel_does_not_hide_drops(self):
        port = Mock()
        port.command.return_value = '\nRAPT_TRACE_ABSENT\n'
        observer = flow.DropTrace(port)
        observer.start()
        port.command.return_value = 'eth0: 123 1 0 1 0 0 0 0 321 1 0 0 0 0 0 0\n'
        after, exempt = observer.sample()
        self.assertEqual(exempt, 0)
        with self.assertRaisesRegex(RuntimeError, 'Unexplained RX drops'):
            flow.validate_network_delta(dict(after, rx_dropped=0), after, exempt)

    def test_hardware_reference_pins_archived_bytes_and_dtb(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-hardware-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            firmware, soc = root / 'fw', root / 'soc'
            firmware.mkdir(); soc.mkdir()
            (firmware / 'litex-soc-seeded.dtb').write_bytes(b'dtb')
            (soc / 'csr.json').write_bytes(b'csr')
            files = {'mlk_cu08_ku15p.bit': b'old accepted bit',
                     'mlk_cu08_ku15p_timing.rpt': b'checking no_clock (0)\nchecking unconstrained_internal_endpoints (0)\nTiming constraints are met'}
            record = {'xlen': 64, 'context': {'firmware': str(firmware), 'soc': str(soc)},
                      'files': {n: flow.netboot.digest(v) for n, v in files.items()}}
            generation = flow.netboot.digest(json.dumps(record, sort_keys=True).encode())
            archive = root / 'bitstreams' / generation
            archive.mkdir(parents=True)
            for name, content in files.items():
                (archive / name).write_bytes(content)
            (archive / 'manifest.json').write_text(json.dumps(record))
            # Another session can select a newer generation; the explicit reference still selects this one.
            (root / 'ready.json').write_text(json.dumps({'generation': 'newer'}))
            item = object.__new__(flow.Flow)
            item.args = argparse.Namespace(xlen=64)
            item.work, item.context = root, record['context']
            item.reference = {'bitstream_manifest': record, 'bundle': {
                'source_dtb_sha256': flow.netboot.digest(b'dtb'), 'sd_csr_sha256': flow.netboot.digest(b'csr')}}
            item.verify_reference()
            (soc / 'csr.json').write_bytes(b'changed by another session')
            with self.assertRaisesRegex(RuntimeError, 'DTB/CSR changed'):
                item.verify_reference()
            (soc / 'csr.json').write_bytes(b'csr')
            (archive / 'mlk_cu08_ku15p.bit').write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'artifact changed'):
                item.verify_reference()


if __name__ == '__main__':
    unittest.main()
