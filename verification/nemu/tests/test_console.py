import copy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from multihart.console import assess_output


class UartOutputTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        self.expected = b'NEMU_UART_OUTPUT hart=0\n'
        self.result = dict(status='OK', summaries={role: dict(uart_tx=len(self.expected)) for role in ('dut', 'ref')})

    def fixture(self, stdout):
        for name in ('dut.log', 'dut.stderr', 'ref.log', 'ref.stderr'):
            (self.output / name).write_bytes(b'')
        (self.output / ('dut.log' if stdout else 'dut.stderr')).write_bytes(self.expected)
        if stdout:
            (self.output / 'dut.stderr').write_bytes(b'NEMU_JOURNAL_PROGRESS events=1\n')

    def test_startup_failure_without_logs(self):
        result = dict(status='FAIL', error='[Errno 1] Operation not permitted')
        original = copy.deepcopy(result)
        self.assertEqual(assess_output(result, self.output, self.expected, True), (False, {}))
        self.assertEqual(result, original)

    def test_success_and_missing_logs(self):
        for stdout in (False, True):
            with self.subTest(stdout=stdout):
                self.fixture(stdout)
                passed, hashes = assess_output(self.result, self.output, self.expected, stdout)
                self.assertTrue(passed)
                self.assertEqual(len(hashes), 4)
                (self.output / 'ref.stderr').unlink()
                self.assertFalse(assess_output(self.result, self.output, self.expected, stdout)[0])

    def test_wrong_channel_and_progress(self):
        for stdout in (False, True):
            self.fixture(stdout)
            self.assertFalse(assess_output(self.result, self.output, self.expected, not stdout)[0])
        for name, data in (('dut.log', self.expected + b'NEMU_JOURNAL_PROGRESS'),
                           ('dut.stderr', b''), ('ref.stderr', b'runtime error: invalid access'),
                           ('ref.stderr', b'WARNING: ThreadSanitizer')):
            self.fixture(True)
            (self.output / name).write_bytes(data)
            self.assertFalse(assess_output(self.result, self.output, self.expected, True)[0])

    def test_missing_or_inconsistent_summaries(self):
        self.fixture(True)
        for summaries in (None, {}, dict(dut=None, ref=None),
                           dict(dut=dict(uart_tx=len(self.expected)), ref=dict(uart_tx=0))):
            result = dict(self.result, summaries=summaries)
            self.assertFalse(assess_output(result, self.output, self.expected, True)[0])

    def test_invalid_pipe_size_before_build(self):
        for size in (0, 1024, 1048577):
            process = subprocess.run([sys.executable, Path(__file__).resolve().parents[1] / 'check.py', 'console',
                                      '--pipe-bytes', str(size), '--output', str(self.output / 'unused')],
                                     capture_output=True, timeout=10)
            self.assertEqual(process.returncode, 2)
            self.assertIn(b'--pipe-bytes', process.stderr)
            self.assertFalse((self.output / 'unused').exists())


if __name__ == '__main__':
    unittest.main()
