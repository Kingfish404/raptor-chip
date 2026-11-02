#!/usr/bin/env python3
"""Check formal evidence lifecycle and bounded tool process cleanup."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import logic_check as checker
import prf_formal
import yosys_common as proof_tools
from yosys_common import run_bounded, run_yosys


class EvidenceTest(unittest.TestCase):
    def test_first_tool_failure_invalidates_old_result(self):
        for kind, (source, _) in checker.CONFIGS.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                report = Path(tmp) / 'results.json'
                report.write_text('{"complete": true}\n')
                args = ['logic_check.py', kind, '--mode', 'prove', '--output', tmp]
                with patch.object(sys, 'argv', args), patch.object(
                        checker.subprocess, 'check_output', return_value='test yosys'), patch.object(
                        checker, 'run_yosys', side_effect=subprocess.CalledProcessError(1, 'yosys')):
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

            def fake_run(command, log, timeout):
                commands.append(command)
                text = ' 10 cells\nLongest topological path (length=3)\n'
                log.write_text(text)
                return text

            args = ['logic_check.py', 'issue-select', '--mode', 'synth', '--matrix', 'port-scaling',
                    '--output', tmp]
            with patch.object(sys, 'argv', args), patch.object(
                    checker.subprocess, 'check_output', return_value='test yosys'), patch.object(
                    checker, 'run_yosys', side_effect=fake_run):
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


class SbyEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='raptor-sby-evidence-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.count = 0
        executable = self.root / 'third_party/oss-cad-suite/bin/sby'
        executable.parent.mkdir(parents=True)
        executable.write_text(f'#!{sys.executable}\n' + r'''
import json, os, pathlib, sys
pathlib.Path('invocation.json').write_text(json.dumps(dict(
    arguments=sys.argv[1:], yosys=os.environ.get('RAPTOR_YOSYS_REAL'),
    smtbmc=os.environ.get('RAPTOR_SMTBMC_REAL'))))
for task in ('prove', 'cover'):
    folder = pathlib.Path('contract_' + task)
    (folder / 'engine_0').mkdir(parents=True)
    status = os.environ.get('TEST_' + task.upper(), 'PASS')
    if status != 'missing':
        (folder / 'status').write_text(status + '\n')
    trace = os.environ.get('TEST_TRACE', 'waveform')
    if trace != 'missing':
        (folder / 'engine_0/trace0.vcd').write_text(trace)
if os.environ.get('TEST_PROVE') == 'FAIL':
    print('Assert failed in fixture')
if os.environ.get('TEST_ERROR'):
    print('ERROR: engine failed')
sys.exit(int(os.environ.get('TEST_EXIT', 2 if os.environ.get('TEST_PROVE') == 'FAIL' else 0)))
''')
        executable.chmod(0o755)

    def check(self, *, negative=False, **settings):
        self.count += 1
        directory = self.root / str(self.count)
        directory.mkdir()
        with patch.object(proof_tools, 'ROOT', self.root), patch.dict(os.environ, settings):
            return proof_tools.run_sby(directory, 5, negative=negative)

    def test_pass_status_requires_cover_and_nonempty_waveform(self):
        row, traces = self.check()
        self.assertTrue(row['passed'])
        self.assertEqual(len(traces), 1)
        for settings in (dict(TEST_TRACE=''), dict(TEST_TRACE='missing'),
                         dict(TEST_COVER='ERROR'), dict(TEST_PROVE='missing'),
                         dict(TEST_PROVE=''), dict(TEST_COVER=''), dict(TEST_COVER='missing')):
            with self.subTest(settings=settings):
                row, _ = self.check(**settings)
                self.assertFalse(row['passed'])

    def test_shared_runner_preserves_tool_overrides_and_force_option(self):
        for force in (False, True):
            with self.subTest(force=force):
                directory = self.root / f'override-{force}'
                directory.mkdir()
                wrapper = directory / 'smtbmc-wrapper'
                with patch.object(proof_tools, 'ROOT', self.root):
                    result = proof_tools.run_sby_task(
                        directory, 5, '/configured/yosys', smtbmc=wrapper, force=force)
                self.assertEqual(result.returncode, 0)
                invocation = json.loads((directory / 'invocation.json').read_text())
                arguments = ['--yosys', str(self.root / 'verification/formal/yosys-rvfi-compat.sh'),
                             '--smtbmc', str(wrapper)]
                arguments += ['-f', 'contract.sby'] if force else ['contract.sby']
                self.assertEqual(invocation['arguments'], arguments)
                self.assertEqual(invocation['yosys'], '/configured/yosys')
                self.assertEqual(invocation['smtbmc'],
                                 str(self.root / 'third_party/oss-cad-suite/bin/yosys-smtbmc'))

    def test_prf_counterexample_requires_status_failure_and_nonempty_trace(self):
        folder = self.root / 'history_prove'
        (folder / 'engine_0').mkdir(parents=True)
        log = self.root / 'history.log'
        log.write_text('Assert failed in fixture\n')
        trace = folder / 'engine_0/trace0.vcd'
        trace.write_text('waveform')
        self.assertFalse(prf_formal.counterexample(folder, log))
        for status in ('', ' \n', 'PASS', 'TIMEOUT', 'FAIL'):
            with self.subTest(status=status):
                (folder / 'status').write_text(status)
                self.assertEqual(prf_formal.counterexample(folder, log), status == 'FAIL')
        trace.write_text('')
        self.assertFalse(prf_formal.counterexample(folder, log))
        trace.write_text('waveform')
        log.write_text('Assert failed in fixture\nERROR: engine failed\n')
        self.assertFalse(prf_formal.counterexample(folder, log))

    def test_counterexample_is_distinct_from_tool_failure_or_empty_trace(self):
        row, _ = self.check(negative=True, TEST_PROVE='FAIL')
        self.assertTrue(row['passed'])
        for settings in (dict(TEST_TRACE=''), dict(TEST_ERROR='1'), dict(TEST_EXIT='8'),
                         dict(TEST_EXIT='16'), dict(TEST_COVER='ERROR')):
            # Negative controls have no cover task; its status is irrelevant.
            row, _ = self.check(negative=True, TEST_PROVE='FAIL', **settings)
            self.assertEqual(row['passed'], settings == dict(TEST_COVER='ERROR'))


class ToolTimeoutTest(unittest.TestCase):
    def test_timeout_allows_controllers_to_clean_separate_engine_groups(self):
        for driver in ('bounded', 'yosys', 'sby'):
            with self.subTest(driver=driver), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                executable = root / ('third_party/oss-cad-suite/bin/sby'
                                     if driver == 'sby' else 'yosys')
                executable.parent.mkdir(parents=True, exist_ok=True)
                pid_file = root / 'engine.pid'
                executable.write_text(f'#!{sys.executable}\n' + r'''
import os, pathlib, signal, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'],
                         start_new_session=True)
def stop(signum, frame):
    os.killpg(child.pid, signal.SIGTERM)
    child.wait()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
pathlib.Path(os.environ['TEST_ENGINE_PID']).write_text(str(child.pid))
time.sleep(30)
''')
                executable.chmod(0o755)
                log = root / 'run.log'
                try:
                    env = dict(RAPTOR_YOSYS_REAL=str(executable), TEST_ENGINE_PID=str(pid_file))
                    with patch.dict(os.environ, env), patch.object(proof_tools, 'ROOT', root):
                        if driver == 'bounded':
                            result = run_bounded([str(executable)], capture_output=True,
                                                 text=True, timeout=1)
                            self.assertEqual(result.returncode, 124)
                            self.assertIn('TIMEOUT:', result.stderr)
                        else:
                            with self.assertRaises(subprocess.TimeoutExpired):
                                if driver == 'yosys':
                                    run_yosys('check -assert', log, 1)
                                else:
                                    proof_tools.run_sby(root, 1, grace=0)
                            self.assertIn('TIMEOUT:', log.read_text())
                    self.assertFalse((Path('/proc') / pid_file.read_text()).exists())
                finally:
                    if pid_file.exists():
                        try:
                            os.killpg(int(pid_file.read_text()), 15)
                        except ProcessLookupError:
                            pass

    def test_timeout_terminates_solver_descendants(self):
        with tempfile.TemporaryDirectory(prefix='raptor-tool-timeout-') as name:
            pid_file = Path(name) / 'child.pid'
            program = ("import pathlib, subprocess, sys, time; "
                       "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                       "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); time.sleep(30)")
            result = run_bounded([sys.executable, '-c', program, str(pid_file)],
                                 capture_output=True, text=True, timeout=1)
            self.assertEqual(result.returncode, 124)
            self.assertIn('TIMEOUT:', result.stderr)
            child = Path('/proc') / pid_file.read_text()
            try:
                state = (child / 'stat').read_text().split()[2]
            except (FileNotFoundError, ProcessLookupError):
                pass
            else:
                self.assertEqual(state, 'Z', 'Timed-out solver descendant is still running')


if __name__ == '__main__':
    unittest.main()
