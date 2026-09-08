#!/usr/bin/env python3
"""Report-auditing tests, not RTL equivalence proofs."""
import unittest
import json
import subprocess
import sys
import tempfile
from unittest.mock import patch

from rnu_equivalence import REQUIRED, STATE_FAMILIES, audit, script
import rnu_equivalence as proof
from pathlib import Path


def fixture():
    points = sorted(REQUIRED) + [f'{name}[0]' for name in STATE_FAMILIES]
    return ('\n'.join(f'Presumably equivalent wires: g, n -> {p}' for p in points)
            + '\nExecuting EQUIV_STATUS pass.\n'
            + 'Found 100 $equiv cells in equiv:\n'
            + 'Of those cells 100 are proven and 0 are unproven.\n'
            + 'Equivalence successfully proven!\n')


class AuditTest(unittest.TestCase):
    def test_complete(self):
        self.assertEqual(audit(fixture())['proven_cells'], 100)

    def test_truncated(self):
        with self.assertRaises(ValueError):
            audit(fixture().split('Executing EQUIV_STATUS')[0])

    def test_unproven(self):
        with self.assertRaises(ValueError):
            audit(fixture().replace('100 are proven and 0', '99 are proven and 1'))

    def test_vacuous(self):
        with self.assertRaises(ValueError):
            audit(fixture().replace('100', '0'))

    def test_missing_observation(self):
        with self.assertRaises(ValueError):
            audit(fixture().replace('-> checkpoint_allocate_free\n', '-> wrong\n'))

    def test_missing_state(self):
        with self.assertRaises(ValueError):
            audit(fixture().replace('-> rnq.storage[0]\n', '-> wrong\n'))

    def test_error_with_success_tail(self):
        with self.assertRaises(ValueError):
            audit('ERROR: failure\n' + fixture())

    def test_script_requires_all_points_and_undef(self):
        text = script(Path('/tmp/before.sv'), 64)
        self.assertIn('-DRAPT_RV64', text)
        self.assertIn('equiv_simple -undef -short', text)
        self.assertTrue(text.endswith('equiv_status -assert\n'))
        self.assertLess(text.index('check -assert'), text.index('memory_map'))

    def test_independent_widths_reach_both_designs(self):
        text = script(Path('/tmp/before.sv'), 32, decode_width=2, rename_width=4, commit_width=1)
        for flag in ('-DRAPT_DECODE_WIDTH=2', '-DRAPT_RENAME_WIDTH=4', '-DRAPT_COMMIT_WIDTH=1'):
            self.assertEqual(text.count(flag), 2)
        self.assertNotIn('-DRAPT_RV64', text)

    def test_nonpositive_widths_rejected(self):
        for widths in ((0, 3, 4), (4, -1, 4), (4, 3, 0)):
            with self.subTest(widths=widths), self.assertRaises(ValueError):
                script(Path('/tmp/before.sv'), 32, *widths)

    def test_bad_width_invalidates_old_report_before_tool(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / 'results.json'
            report.write_text('{"complete": true}')
            argv = ['proof', '--baseline-rnu', '/tmp/before.sv', '--output', tmp, '--rename-width', '0']
            with patch.object(sys, 'argv', argv), patch.object(proof.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'positive'):
                    proof.main()
            run.assert_not_called()
            result = json.loads(report.read_text())
            self.assertFalse(result['complete'])
            self.assertEqual(result['widths']['rename_width'], 0)
            self.assertEqual(result['cases'], [])

    def failed_run(self, reason):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / 'results.json'
            report.write_text('{"complete": true}')
            calls = 0

            def execute(*args, **kwargs):
                nonlocal calls
                calls += 1
                kwargs['stdout'].write(fixture())
                if reason == 'timeout':
                    raise subprocess.TimeoutExpired('yosys', 300)
                return subprocess.CompletedProcess([], 1 if reason == 'tool' else 0)

            argv = ['proof', '--baseline-rnu', '/tmp/before.sv', '--output', tmp]
            hashes = [{'rnu.sv': 'before'}, {'rnu.sv': 'after'}]
            with patch.object(sys, 'argv', argv), patch.object(
                    proof, 'manifest', side_effect=hashes), patch.object(
                    proof.subprocess, 'run', side_effect=execute):
                with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)):
                    proof.main()
            result = json.loads(report.read_text())
            self.assertFalse(result['complete'])
            self.assertFalse(result['cases'][0]['proven'])
            self.assertEqual(result['source_sha256'], hashes[0])
            self.assertEqual(calls, 1)
            self.assertTrue((Path(tmp) / 'rv32.log').read_text())
            if reason == 'timeout':
                self.assertTrue(result['cases'][0]['timeout'])

    def test_timeout_invalidates_old_report_and_keeps_log(self):
        self.failed_run('timeout')

    def test_tool_failure_cannot_use_success_log(self):
        self.failed_run('tool')

    def test_changed_sources_cannot_finish_report(self):
        self.failed_run('sources')


if __name__ == '__main__':
    unittest.main()
