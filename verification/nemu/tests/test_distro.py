import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from multihart.distro import accepted, read_output
from distro_boot import SOURCES


class DistroDiffTestAcceptance(unittest.TestCase):
    def test_console_on_either_stream(self):
        result, output = self.fixture()
        with tempfile.TemporaryDirectory(prefix='nemu-distro-output-') as temporary:
            directory = Path(temporary)
            (directory / 'dut.log').write_bytes(output)
            self.assertTrue(accepted('debian', 2, result, read_output(directory)))
            (directory / 'dut.log').write_bytes(b'NEMU_THREADED harts=2 wall_us=100\n')
            (directory / 'dut.stderr').write_bytes(output.replace(b'NEMU_THREADED', b'legacy-console'))
            self.assertTrue(accepted('debian', 2, result, read_output(directory)))
            (directory / 'dut.stderr').write_bytes(output + b'Kernel panic\n')
            self.assertFalse(accepted('debian', 2, result, read_output(directory)))

    def test_invalid_runtime_options_fail_before_preparation(self):
        script = [Path(__file__).resolve().parents[1] / 'check.py', 'distro']
        for name, value in (('timeout', 'nan'), ('timeout', '0'), ('pipe-bytes', '1024'),
                            ('pipe-bytes', '1048577'), ('progress', '-1'), ('progress', '1099511627777'),
                            ('clock-div', '0'), ('clock-div', '1001')):
            result = subprocess.run([sys.executable, *script, '--prepared=/nonexistent', '--' + name, value],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn(('--' + name).encode(), result.stderr)
            self.assertNotIn(b'Traceback', result.stderr)

    def test_incomplete_endpoint_evidence_keeps_failure_receipt(self):
        script = [Path(__file__).resolve().parents[1] / 'check.py', 'distro']
        cases = (
            (dict(status='FAIL', error='[Errno 1] Operation not permitted', commands={}), {}),
            (dict(status='FAIL', error='native launch failed', commands=dict(ref=['driver', 'reference', '--fd=3'])),
             {'ref.log': b'reference started\n'}),
            (dict(status='OK', commands=dict(dut=['native', '-b'], ref=['driver', 'reference', '--fd=3'])),
             {'dut.log': b'RAPTOR_DISTRO_CHECK_PASS\n'}),
            (dict(status='OK', stderr_separate=True,
                  commands=dict(dut=['native', '-b'], ref=['driver', 'reference', '--fd=3'])),
             {'dut.log': b'RAPTOR_DISTRO_CHECK_PASS\n', 'ref.log': b'NEMU_REPLAY status=OK\n'}),
        )
        for result, logs in cases:
            with self.subTest(result=result), tempfile.TemporaryDirectory(prefix='nemu-distro-failure-') as temporary:
                directory = Path(temporary)
                (directory / 'manifest.json').write_text(json.dumps(dict(distro='debian', harts=2, files={})))
                result_path = directory / 'result.json'
                result_path.write_text(json.dumps(result))
                for name, data in logs.items():
                    (directory / name).write_bytes(data)
                process = subprocess.run([sys.executable, *script, '--prepared', directory, '--inspect', result_path],
                                         capture_output=True, timeout=10)
                self.assertEqual(process.returncode, 1)
                self.assertNotIn(b'Traceback', process.stderr)
                self.assertIn(b'NEMU_DISTRO_DIFFTEST FAIL', process.stdout)
                receipt = json.loads((directory / 'distro-difftest-result.json').read_text())
                self.assertFalse(receipt['passed'])
                self.assertEqual(receipt['error'], result.get('error', 'incomplete endpoint evidence'))
                self.assertEqual(receipt['result_sha256'], hashlib.sha256(result_path.read_bytes()).hexdigest())
                self.assertEqual(receipt['available_logs_sha256'],
                                 {name: hashlib.sha256(data).hexdigest() for name, data in logs.items()})

    def fixture(self, distro='debian', harts=2):
        counters = dict.fromkeys(('events', 'bytes', 'interrupts', 'clocks', 'io_requests', 'plic_sources',
                                  'uart_rx', 'uart_irqs', 'uart_tx', 'dma_reads', 'dma_writes', 'dma_bytes',
                                  'rng_inputs', 'rng_irqs', 'net_rx', 'net_tx', 'net_irqs', 'net_rx_bytes',
                                  'net_tx_bytes', 'net_rx_drops', 'block_reads', 'block_writes', 'block_bytes',
                                  'block_irqs', 'block_image_size', 'block_pages'), 1)
        counters.update(harts=harts, status='OK')
        result = dict(status='OK', returncodes=dict(dut=0, ref=0),
                      summaries=dict(dut=counters, ref=dict(counters, checked=100, maximum_active=harts)))
        output = (f'RAPTOR_DISTRO_ID={distro} VERSION_ID={SOURCES[distro]["release"]}\n'
                  f'RAPTOR_DISTRO_CHECK_PASS\nRAPTOR_FP_PASS\nRAPTOR_SMP_PASS harts={harts} workers=ok\n'
                  f'reboot: Power down\nNEMU_THREADED harts={harts} wall_us=100\n').encode()
        return result, output

    def test_inspect_complete_fixture_and_changed_binary(self):
        result, output = self.fixture()
        script = [Path(__file__).resolve().parents[1] / 'check.py', 'distro']
        with tempfile.TemporaryDirectory(prefix='nemu-distro-inspect-') as temporary:
            root = Path(temporary)
            directory = root / 'stream'
            directory.mkdir()
            files = ('rootfs.ext4', 'nemu.dtb', 'fw_payload.bin', 'native', 'driver', 'reference')
            for name in files:
                (root / name).write_bytes(('synthetic inspection fixture ' + name).encode())
            hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}
            artifacts = {name: hashes[name] for name in files[:3]}
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps(dict(distro='debian', harts=2, files=artifacts)))
            launch = dict(prepared=str(root), manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
                          artifacts_sha256=artifacts, binaries_sha256={name: hashes[name] for name in files[3:]})
            (root / 'launch.json').write_text(json.dumps(launch))
            result['commands'] = dict(dut=[str(root / 'native'), '-b', '--diff-block', '--diff-tlb=retain',
                                           '--smp-backend=threaded', '--smp=2', '--disk=' + str(root / 'rootfs.ext4'),
                                           '-t', str(root / 'nemu.dtb'), str(root / 'fw_payload.bin')],
                                      ref=[str(root / 'driver'), str(root / 'reference'), '--fd=3'])
            result_path = directory / 'result.json'
            result_path.write_text(json.dumps(result))
            (directory / 'dut.log').write_bytes(output)
            (directory / 'ref.log').write_bytes(b'synthetic reference log\n')
            for changed in (False, True):
                if changed:
                    (root / 'reference').write_bytes(b'changed after launch')
                process = subprocess.run([sys.executable, *script, '--prepared', root, '--inspect', result_path],
                                         capture_output=True, timeout=10)
                self.assertEqual(process.returncode, int(changed), process.stderr)
                receipt = json.loads((directory / 'distro-difftest-result.json').read_text())
                self.assertEqual(receipt['passed'], not changed)
                self.assertEqual(receipt['artifacts_sha256'], artifacts)
                self.assertIn('launch_sha256', receipt)

    def test_successful_distribution_and_reference_required(self):
        for distro in ('debian', 'ubuntu'):
            for harts in (1, 2, 4):
                result, output = self.fixture(distro, harts)
                self.assertTrue(accepted(distro, harts, result, output))

    def test_missing_guest_milestones(self):
        result, output = self.fixture()
        for marker in (b'RAPTOR_DISTRO_CHECK_PASS', b'RAPTOR_FP_PASS', b'RAPTOR_SMP_PASS', b'reboot: Power down', b'NEMU_THREADED'):
            self.assertFalse(accepted('debian', 2, result, output.replace(marker, b'absent')))
        self.assertFalse(accepted('ubuntu', 2, result, output))
        self.assertFalse(accepted('debian', 4, result, output))
        self.assertFalse(accepted('debian', 2, result, output + b'Kernel panic'))

    def test_missing_or_failed_reference(self):
        result, output = self.fixture()
        for change in (dict(status='FAIL'), dict(returncodes=dict(dut=0, ref=1)), dict(summaries=None),
                       dict(summaries=dict(dut=result['summaries']['dut'], ref=None))):
            modified = dict(result, **change)
            self.assertFalse(accepted('debian', 2, modified, output))

    def test_counters_checked_on_both_sides(self):
        result, output = self.fixture()
        for field in ('block_reads', 'block_writes', 'block_irqs', 'block_image_size', 'events', 'bytes', 'harts', 'net_tx', 'dma_bytes'):
            modified = copy.deepcopy(result)
            modified['summaries']['ref'][field] += 1
            self.assertFalse(accepted('debian', 2, modified, output))
            modified = copy.deepcopy(result)
            del modified['summaries']['dut'][field]
            self.assertFalse(accepted('debian', 2, modified, output))

    def test_no_disk_work_is_not_userspace_acceptance(self):
        result, output = self.fixture()
        for role in ('dut', 'ref'):
            result['summaries'][role]['block_writes'] = 0
        self.assertFalse(accepted('debian', 2, result, output))


if __name__ == '__main__':
    unittest.main()
