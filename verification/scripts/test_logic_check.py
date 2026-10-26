#!/usr/bin/env python3
"""Evidence lifecycle tests; not proofs of selector hardware."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import logic_check as checker


class EvidenceTest(unittest.TestCase):
    def test_first_tool_failure_invalidates_old_result(self):
        for kind, (source, _) in checker.CONFIGS.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                report = Path(tmp) / 'results.json'
                report.write_text('{"complete": true}\n')
                args = ['logic_check.py', kind, '--mode', 'prove', '--output', tmp]
                with patch.object(sys, 'argv', args), patch.object(
                        checker.subprocess, 'check_output', return_value='test yosys'), patch.object(
                        checker.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'yosys')):
                    with self.assertRaises(subprocess.CalledProcessError):
                        checker.main()
                result = json.loads(report.read_text())
                self.assertFalse(result['complete'])
                self.assertEqual(result['generic_synthesis'], [])
                self.assertIn(source, result['source_sha256'])

    def test_zero_exit_without_proof_marker_is_rejected(self):
        for kind in checker.CONFIGS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                args = ['logic_check.py', kind, '--mode', 'prove', '--output', tmp]
                with patch.object(sys, 'argv', args), patch.object(
                        checker.subprocess, 'check_output', return_value='test yosys'), patch.object(
                        checker, 'run_yosys', return_value='tool exited without proving the contract'):
                    with self.assertRaisesRegex(RuntimeError, 'missing proof success marker'):
                        checker.main()
                result = json.loads((Path(tmp) / 'results.json').read_text())
                self.assertFalse(result['complete'])
                self.assertEqual(result.get('cases', result['proofs']), [])

    def test_scaling_matrix_holds_entries_fixed(self):
        with tempfile.TemporaryDirectory() as tmp:
            commands = []

            def fake_run(command, *, stdout, **kwargs):
                commands.append(command[-1])
                stdout.write(' 10 cells\nLongest topological path (length=3)\n')

            args = ['logic_check.py', 'issue-select', '--mode', 'synth', '--matrix', 'port-scaling',
                    '--output', tmp]
            with patch.object(sys, 'argv', args), patch.object(
                    checker.subprocess, 'check_output', return_value='test yosys'), patch.object(
                    checker.subprocess, 'run', side_effect=fake_run):
                checker.main()
            result = json.loads((Path(tmp) / 'results.json').read_text())
            self.assertTrue(result['complete'])
            self.assertEqual(len(commands), 12)
            self.assertTrue(all('-GEntries=16 ' in c for c in commands))
            self.assertEqual({(r['ports'], r['rebalance']) for r in result['generic_synthesis']},
                             {(p, r) for p in (1, 2, 3, 4, 6, 8) for r in (0, 1)})

    def test_changed_source_cannot_publish_complete_result(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(checker, 'ROOT', Path(tmp)):
            for path in checker.sources('rank-select'):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original input')
            source = checker.sources('rank-select')[0]
            output = Path(tmp) / 'output'

            def changed_source(*args):
                source.write_text('changed during proof')
                return checker.SAT_SUCCESS

            args = ['logic_check.py', 'rank-select', '--mode', 'prove', '--output', str(output)]
            with patch.object(sys, 'argv', args), patch.object(
                    checker.subprocess, 'check_output', return_value='test yosys'), patch.object(
                    checker, 'run_yosys', side_effect=changed_source):
                with self.assertRaisesRegex(RuntimeError, 'source changed'):
                    checker.main()
            self.assertFalse(json.loads((output / 'results.json').read_text())['complete'])


if __name__ == '__main__':
    unittest.main()
