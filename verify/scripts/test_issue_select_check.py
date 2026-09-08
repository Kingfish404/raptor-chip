#!/usr/bin/env python3
"""Evidence lifecycle tests; not proofs of selector hardware."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import issue_select_check as checker


class EvidenceTest(unittest.TestCase):
    def test_first_tool_failure_invalidates_old_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / 'results.json'
            report.write_text('{"complete": true}\n')
            args = ['issue_select_check.py', '--mode', 'synth', '--output', tmp]
            with patch.object(sys, 'argv', args), patch.object(
                    checker.subprocess, 'check_output', return_value='test yosys'), patch.object(
                    checker.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'yosys')):
                with self.assertRaises(subprocess.CalledProcessError):
                    checker.main()
            result = json.loads(report.read_text())
            self.assertFalse(result['complete'])
            self.assertEqual(result['generic_synthesis'], [])
            self.assertIn('hdl/common/rapt_issue_select.sv', result['source_sha256'])

    def test_scaling_matrix_holds_entries_fixed(self):
        with tempfile.TemporaryDirectory() as tmp:
            commands = []

            def fake_run(command, *, stdout, **kwargs):
                commands.append(command[-1])
                stdout.write(' 10 cells\nLongest topological path (length=3)\n')

            args = ['issue_select_check.py', '--mode', 'synth', '--matrix', 'port-scaling',
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


if __name__ == '__main__':
    unittest.main()
