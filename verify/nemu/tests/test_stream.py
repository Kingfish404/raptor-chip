import json
import errno
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from lib.stream import supervise


ENDPOINT = '''#!/usr/bin/env python3
import os, signal, sys, time
from pathlib import Path
role = 'dut' if '-b' in sys.argv else 'ref'
mode = os.environ.get('MODE', 'ok')
Path(os.environ['READY'], role).write_text(str(os.getpid()))
print('diagnostic-' + role, file=sys.stderr, flush=True)
descriptor = int(next(arg.split('=')[1] for arg in sys.argv if arg.startswith('--diff-stream-fd=' if role == 'dut' else '--fd=')))
if mode == 'hang':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
if mode == role + '-fail':
    if role == 'ref': time.sleep(0.05)
    sys.exit(3)
if role == 'dut':
    os.write(descriptor, b'hello')
    if mode in ('blocked', 'ref-fail'):
        while True: os.write(descriptor, b'x' * 65536)
    os.close(descriptor)
    if mode == 'prefixed-summary': print('UART', end='')
    print('NEMU_JOURNAL events=10 bytes=256 harts=2 buffer_bytes=65536 status=OK')
else:
    if mode == 'blocked': time.sleep(60)
    if mode == 'descendant':
        child = os.fork()
        if child == 0:
            time.sleep(60)
            sys.exit(0)
        Path(os.environ['READY'], 'descendant.pid').write_text(str(child))
    while os.read(descriptor, 4096): pass
    if mode == 'late':
        time.sleep(0.1)
        sys.exit(4)
    if mode == 'missing': sys.exit(0)
    size = 257 if mode == 'mismatch' else 256
    interrupts = 1 if mode == 'irq-mismatch' else 0
    clocks = 1 if mode == 'clock-mismatch' else 0
    io_requests = 1 if mode == 'io-mismatch' else 0
    plic_sources = 1 if mode == 'plic-mismatch' else 0
    uart = 'uart_rx=1' if mode == 'rx-mismatch' else ('uart_irqs=1' if mode == 'uart-irq-mismatch' else ('uart_tx=1' if mode == 'tx-mismatch' else ''))
    dma = mode.removesuffix('-mismatch') + '=1' if mode in ('dma_reads-mismatch', 'dma_writes-mismatch', 'dma_bytes-mismatch', 'rng_inputs-mismatch', 'rng_irqs-mismatch', 'net_rx-mismatch', 'net_tx-mismatch', 'net_irqs-mismatch', 'net_rx_bytes-mismatch', 'net_tx_bytes-mismatch', 'net_rx_drops-mismatch', 'block_reads-mismatch', 'block_writes-mismatch', 'block_bytes-mismatch', 'block_irqs-mismatch', 'block_image_size-mismatch', 'block_pages-mismatch') else ''
    print(f'NEMU_REPLAY checked=2 events=10 bytes={size} harts=2 buffer_bytes=65536 maximum_active=2 interleaved=1 interrupts={interrupts} clocks={clocks} io_requests={io_requests} plic_sources={plic_sources} {uart} {dma} status=OK')
'''


class StreamSupervisorTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.endpoint = self.root / 'endpoint'
        self.endpoint.write_text(ENDPOINT)
        self.endpoint.chmod(0o700)

    def run_case(self, mode='ok', timeout=5, **kwargs):
        environment = dict(os.environ, MODE=mode, READY=str(self.root))
        result = supervise(self.endpoint, self.endpoint, self.endpoint, [], self.root / mode,
                           timeout=timeout, pipe_bytes=4096, environment=environment, **kwargs)
        for pid in result['pids'].values():
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        return result

    def test_success(self):
        result = self.run_case()
        self.assertEqual(result['status'], 'OK')
        self.assertEqual(result['stdio_pipe_capacity_bytes'], 135168)
        self.assertFalse(result['transcript_saved'])
        self.assertEqual(result['pipe_bytes_requested'], 4096)

    def test_pipe_sizing_failure(self):
        with patch('lib.stream.fcntl.fcntl', side_effect=PermissionError(errno.EPERM, 'pipe quota')) as sizing:
            result = self.run_case()
        self.assertEqual(result['status'], 'FAIL')
        self.assertIn('pipe quota', result['error'])
        self.assertEqual(result['pipe_bytes_requested'], 4096)
        self.assertEqual(result['pids'], {})
        self.assertEqual(result['commands'], {})
        sizing.assert_called_once()
        self.assertEqual(sizing.call_args.args[1:], (fcntl.F_SETPIPE_SZ, 4096))

    def test_separate_diagnostics(self):
        result = self.run_case(separate_stderr=True)
        self.assertEqual(result['status'], 'OK')
        self.assertTrue(result['stderr_separate'])
        for role in ('dut', 'ref'):
            self.assertNotIn('diagnostic-', (self.root / 'ok' / (role + '.log')).read_text())
            self.assertEqual((self.root / 'ok' / (role + '.stderr')).read_text(), 'diagnostic-' + role + '\n')

    def test_separate_diagnostics_failure(self):
        result = self.run_case('ref-fail', separate_stderr=True)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['returncodes']['ref'], 3)
        self.assertIn('diagnostic-ref', (self.root / 'ref-fail/ref.stderr').read_text())

    def test_failures(self):
        for mode in ('dut-fail', 'ref-fail', 'late', 'missing', 'mismatch', 'irq-mismatch',
                     'clock-mismatch', 'io-mismatch', 'plic-mismatch', 'rx-mismatch', 'uart-irq-mismatch', 'tx-mismatch',
                     'dma_reads-mismatch', 'dma_writes-mismatch', 'dma_bytes-mismatch', 'rng_inputs-mismatch', 'rng_irqs-mismatch',
                     'net_rx-mismatch', 'net_tx-mismatch', 'net_irqs-mismatch', 'net_rx_bytes-mismatch',
                     'net_tx_bytes-mismatch', 'net_rx_drops-mismatch',
                     'block_reads-mismatch', 'block_writes-mismatch', 'block_bytes-mismatch', 'block_irqs-mismatch',
                     'block_image_size-mismatch', 'block_pages-mismatch',
                     'prefixed-summary'):
            with self.subTest(mode=mode):
                result = self.run_case(mode)
                self.assertEqual(result['status'], 'FAIL')
                if mode in ('late', 'missing', 'mismatch'):
                    self.assertEqual(result['returncodes']['dut'], 0)

    def test_rng_requires_explicit_counters(self):
        result = supervise(self.endpoint, self.endpoint, self.endpoint, ['--diff-rng'], self.root / 'rng-counters',
                           environment=dict(os.environ, READY=str(self.root)))
        self.assertEqual(result['status'], 'FAIL')

    def test_net_requires_explicit_counters(self):
        result = supervise(self.endpoint, self.endpoint, self.endpoint, ['--diff-net'], self.root / 'net-counters',
                           environment=dict(os.environ, READY=str(self.root)))
        self.assertEqual(result['status'], 'FAIL')

    def test_block_requires_explicit_counters(self):
        result = supervise(self.endpoint, self.endpoint, self.endpoint, ['--diff-block'], self.root / 'block-counters',
                           environment=dict(os.environ, READY=str(self.root)))
        self.assertEqual(result['status'], 'FAIL')

    def test_timeout(self):
        popen = subprocess.Popen

        def launch(*args, **kwargs):
            return popen(*args, **kwargs, preexec_fn=lambda: signal.signal(signal.SIGTERM, signal.SIG_IGN))

        with patch('lib.stream.subprocess.Popen', side_effect=launch):
            result = self.run_case('hang', timeout=0.3)
        self.assertEqual(result['error'], 'timeout')
        self.assertEqual(len(result['returncodes']), 2)
        self.assertTrue(all(code == -signal.SIGKILL for code in result['returncodes'].values()))
        self.assertLess(result['elapsed_seconds'], 4)

    def test_cancel_during_startup(self):
        result = self.run_case(cancelled=lambda: True)
        self.assertEqual(result['error'], 'cancelled')
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(len(result['returncodes']), 2)

    def test_backpressure_timeout(self):
        result = self.run_case('blocked', timeout=0.3)
        self.assertEqual(result['error'], 'timeout')
        self.assertLess(result['elapsed_seconds'], 4)

    def test_launch_failure(self):
        result = supervise(self.root / 'absent', self.endpoint, self.endpoint, [], self.root / 'launch',
                           environment=dict(os.environ, READY=str(self.root)))
        self.assertEqual(result['status'], 'FAIL')
        self.assertIsNotNone(result['returncodes']['ref'])

    def test_descendant_cleanup(self):
        self.assertEqual(self.run_case('descendant')['status'], 'OK')
        pid = int((self.root / 'descendant.pid').read_text())
        status = Path(f'/proc/{pid}/stat')
        deadline = time.monotonic() + 2
        while True:
            try:
                if status.read_text().split(')')[1].split()[0] == 'Z':
                    break
            except (FileNotFoundError, ProcessLookupError):
                break
            if time.monotonic() > deadline:
                self.fail('endpoint descendant survived cleanup')
            time.sleep(0.01)

    def test_refuses_overwrite(self):
        self.run_case()
        with self.assertRaises(FileExistsError):
            self.run_case()

    def test_invalid_options(self):
        for timeout in (0, -1, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                self.run_case(timeout=timeout)
        with self.assertRaises(ValueError):
            supervise(self.endpoint, self.endpoint, self.endpoint, ['--diff-record=x'], self.root / 'bad')
        for capacity in (0, 1024, 1048577):
            with self.assertRaises(ValueError):
                supervise(self.endpoint, self.endpoint, self.endpoint, [], self.root / 'bad', pipe_bytes=capacity)

    def test_cancel(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            output = self.root / str(signum)
            for role in ('dut', 'ref'):
                (self.root / role).unlink(missing_ok=True)
            command = [sys.executable, str(Path(__file__).resolve().parents[1] / 'check.py'), 'supervise',
                       '--nemu', str(self.endpoint), '--reference', str(self.endpoint),
                       '--replayer', str(self.endpoint), '--output', str(output)]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       env=dict(os.environ, MODE='hang', READY=str(self.root)))
            try:
                deadline = time.monotonic() + 5
                while not all((self.root / role).exists() for role in ('dut', 'ref')):
                    if time.monotonic() > deadline:
                        self.fail('endpoints did not start')
                    time.sleep(0.01)
                process.send_signal(signum)
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 1)
                result = json.loads((output / 'result.json').read_text())
                self.assertEqual(result['error'], 'cancelled')
                for pid in result['pids'].values():
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == '__main__':
    unittest.main()
