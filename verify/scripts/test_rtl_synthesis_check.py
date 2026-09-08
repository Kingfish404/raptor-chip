#!/usr/bin/env python3
"""Test fail-closed evidence handling, independently of RTL correctness."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from rtl_synthesis_check import contract_rejected, main, source_manifest, flow_manifest


class EvidenceTest(unittest.TestCase):
    def test_integrated_structure_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = ['rtl_synthesis_check.py', '--only', 'integration',
                    '--check-structure', '--output', tmp]
            with patch.object(sys, 'argv', args), patch(
                    'rtl_synthesis_check.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 0)) as run:
                main()
            self.assertEqual(run.call_count, 4)
            report = json.loads((Path(tmp) / 'results.json').read_text())
            self.assertTrue(report['complete'])
            self.assertEqual(report['scope'], 'integration')
            self.assertEqual({c['name'] for c in report['cases']}, {
                'core-default', 'core-rv64', 'core-scaled', 'core-scaled-rv64'})
            for case in report['cases']:
                self.assertTrue(case['structure_checked'])
                self.assertIn('structure-check', case['command'])
                self.assertIn('MODULE=core', case['command'])
                defines = next(c for c in case['command'] if c.startswith('EXTRA_DEFINES='))
                self.assertEqual('-DRAPT_RV64' in defines, 'rv64' in case['name'])
                if 'scaled' in case['name']:
                    for flag in ('-DRAPT_DISPATCH_WIDTH=3', '-DRAPT_INTEGER_ISSUE_PORTS=4',
                                 '-DRAPT_INTEGER_SYSTEM_PORT=2'):
                        self.assertIn(flag, defines)

    def test_lsu_structure_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = ['rtl_synthesis_check.py', '--only', 'lsu', '--check-structure',
                    '--output', tmp]
            with patch.object(sys, 'argv', args), patch(
                    'rtl_synthesis_check.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 0)) as run:
                main()
            self.assertEqual(run.call_count, 3)
            report = json.loads((Path(tmp) / 'results.json').read_text())
            self.assertTrue(report['complete'])
            self.assertTrue(report['check_structure'])
            self.assertEqual({c['name'] for c in report['cases']}, {
                'lsu-default', 'lsu-rv64', 'lsu-scaled'})
            for case in report['cases']:
                self.assertIn('structure-check', case['command'])
                self.assertTrue(case['structure_checked'])

    def test_structure_failure_is_not_elaboration_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = ['rtl_synthesis_check.py', '--only', 'lsu', '--check-structure',
                    '--output', tmp]
            with patch.object(sys, 'argv', args), patch(
                    'rtl_synthesis_check.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaisesRegex(RuntimeError, 'lsu-default failed'):
                    main()
            report = json.loads((Path(tmp) / 'results.json').read_text())
            self.assertFalse(report['complete'])
            self.assertEqual(report['cases'], [])

    def test_execution_scope_detects_wrapper_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            args = ['rtl_synthesis_check.py', '--only', 'execution', '--output', str(out)]
            before = flow_manifest()
            after = dict(before, changed='new wrapper bytes')
            with patch.object(sys, 'argv', args), patch(
                    'rtl_synthesis_check.flow_manifest', side_effect=[before, after]), patch(
                    'rtl_synthesis_check.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 0)) as run:
                with self.assertRaisesRegex(RuntimeError, 'flow or wrappers changed'):
                    main()
            self.assertEqual(run.call_count, 6)
            result = json.loads((out / 'results.json').read_text())
            self.assertFalse(result['complete'])
            self.assertEqual(result['flow_sha256'], before)
            self.assertEqual({c['name'] for c in result['cases']}, {
                'ieu-default', 'ieu-rv64', 'ieu-scaled',
                'feu-default', 'feu-rv64', 'feu-scaled'})

    def test_first_failure_preserves_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            hdl = root / 'hdl'
            hdl.mkdir()
            (hdl / 'rapt_pkg.sv').write_text('package rapt_pkg; endpackage\n')
            out = root / 'out'
            args = ['rtl_synthesis_check.py', '--hdl-root', str(hdl), '--output', str(out)]
            with patch.object(sys, 'argv', args), patch(
                    'rtl_synthesis_check.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 1)) as run:
                with self.assertRaisesRegex(RuntimeError, 'soc-default failed'):
                    main()
            run.assert_called_once()
            result = json.loads((out / 'results.json').read_text())
            self.assertFalse(result['complete'])
            self.assertEqual(result['cases'], [])
            self.assertEqual(result['source_sha256'], source_manifest(hdl))

    def test_diagnostic_with_reason(self):
        self.assertTrue(contract_rejected(1,
            'queue.sv:36:5: error: $error encountered: Invalid rapt_rename_checkpoint configuration: insufficient index width\n',
            'rapt_rename_checkpoint'))

    def test_real_diagnostic(self):
        self.assertTrue(contract_rejected(1,
            'queue.sv:36:5: error: $error encountered: Invalid rapt_stream_queue configuration\n',
            'rapt_stream_queue'))

    def test_echo_is_not_diagnostic(self):
        self.assertFalse(contract_rejected(1,
            'error: syntax error\n $error("Invalid rapt_stream_queue configuration");',
            'rapt_stream_queue'))

    def test_success_is_not_rejection(self):
        self.assertFalse(contract_rejected(0,
            'error: $error encountered: Invalid rapt_stream_queue configuration',
            'rapt_stream_queue'))

    def test_crash_is_not_rejection(self):
        self.assertFalse(contract_rejected(-11,
            'error: $error encountered: Invalid rapt_stream_queue configuration',
            'rapt_stream_queue'))

    def test_other_contract_is_not_rejection(self):
        self.assertFalse(contract_rejected(1,
            'error: $error encountered: Invalid rapt_rank_select configuration',
            'rapt_stream_queue'))

    def test_manifest_detects_add_remove_modify(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / 'rapt_pkg.sv'
            pkg.write_text('package rapt_pkg; endpackage\n')
            before = source_manifest(root)
            extra = root / 'extra.svh'
            extra.write_text('// added\n')
            added = source_manifest(root)
            self.assertNotEqual(before, added)
            extra.unlink()
            self.assertEqual(before, source_manifest(root))
            self.assertNotEqual(added, source_manifest(root))
            pkg.write_text('// changed\n')
            self.assertNotEqual(before, source_manifest(root))

    def test_missing_tree_invalidates_old_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / 'out'
            out.mkdir()
            report = out / 'results.json'
            report.write_text('{"complete": true}\n')
            run = subprocess.run([sys.executable,
                str(Path(__file__).with_name('rtl_synthesis_check.py')),
                '--hdl-root', str(root / 'missing'), '--output', str(out)],
                capture_output=True, text=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse(json.loads(report.read_text())['complete'])


if __name__ == '__main__':
    unittest.main()
