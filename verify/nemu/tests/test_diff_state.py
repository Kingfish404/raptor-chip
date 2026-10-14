#!/usr/bin/env python3
"""Check complete journal state deltas against a scalar oracle."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class StateDeltaTest(unittest.TestCase):
    def test_complete_state(self):
        with tempfile.TemporaryDirectory(prefix='nemu-diff-state-') as temporary:
            binary = Path(temporary) / 'check'
            for sanitizer in (False, True):
                with self.subTest(sanitizer=sanitizer):
                    subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                                    *(['-fsanitize=undefined', '-fno-sanitize-recover=all'] if sanitizer else []),
                                    '-I' + str(ROOT / 'nemu/include'),
                                    str(ROOT / 'app/tests/host/nemu_diff_state.c'), '-o', str(binary)],
                                   check=True, capture_output=True, timeout=30)
                    result = subprocess.run([binary], check=True, capture_output=True, timeout=30,
                                            env=dict(os.environ, UBSAN_OPTIONS='halt_on_error=1'))
                    self.assertEqual(result.stdout, b'NEMU_DIFF_STATE_PASS\n')
                    self.assertEqual(result.stderr, b'')


if __name__ == '__main__':
    unittest.main()
