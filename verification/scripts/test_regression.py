import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import regression as r

GOOD = '''seedcrc : 0xe9f5
[0]crclist : 0xe714
[0]crcmatrix : 0x1fd7
[0]crcstate : 0x8e3a
Correct operation validated
HIT GOOD TRAP
'''


class RegressionTest(unittest.TestCase):
    def setUp(self):
        checkout = tempfile.TemporaryDirectory(prefix='rapt-regression-test-')
        self.addCleanup(checkout.cleanup)
        root = Path(checkout.name)
        subprocess.run(['git', 'init', '-q', root], check=True)
        subprocess.run(['git', '-C', root, '-c', 'user.name=Regression Test',
                        '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
                        'commit', '-q', '--allow-empty', '-m', 'Fixture'], check=True)
        patcher = patch.object(r, 'ROOT', root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_validation(self):
        self.assertEqual(r.validate('coremark', GOOD), '')
        short = GOOD.replace('Correct operation validated',
                             'ERROR! Must execute for at least 10 secs for a valid result!\nErrors detected')
        self.assertEqual(r.validate('coremark', short), '')
        for bad in (GOOD.replace('e714', '0000'), GOOD.replace('HIT GOOD TRAP', ''),
                    short + 'ERROR! list crc mismatch', GOOD + 'Errors detected',
                    GOOD.replace('e9f5', 'ffff')):
            self.assertTrue(r.validate('coremark', bad))
        self.assertTrue(r.validate('sta', 'fmax Summary\nslack (VIOLATED)'))
        self.assertTrue(r.validate('sta', 'fmax Summary\nError: missing liberty'))
        self.assertEqual(r.validate('sta', 'fmax Summary\nslack (MET)'), '')
        self.assertTrue(r.validate('fpga-timing', 'Timing status is unverified; skipping'))
        self.assertEqual(r.validate('fpga-timing', '[INFO] Vivado timing constraints are met: x'), '')

    def test_plan_is_read_only(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as tmp:
            output = Path(tmp) / 'absent'
            with contextlib.redirect_stdout(io.StringIO()) as stream:
                self.assertEqual(r.main(['--plan', '--output', str(output)]), 0)
            self.assertFalse(output.exists())
            plan = json.loads(stream.getvalue())
            self.assertEqual([s['name'] for s in plan['format_barrier']], ['format'])
            steps = {s['name']: s for s in plan['steps']}
            for xlen in (32, 64):
                sta = steps[f'sta-rv{xlen}']
                self.assertIn('RAPT_CONFIG=small', sta['command'])
                self.assertIn('STA_REPORT_ONLY=1', sta['command'])
                self.assertIn(f'STA_WORK_DIR={output}/sta-rv{xlen}', sta['command'])
                self.assertEqual(sta['requires'], ['rtl-decoders', 'sta-prepare'])
                native = steps[f'coremark-nemu{xlen}']
                self.assertIn(f'O={output}/nemu/rv{xlen}', native['command'])
                self.assertEqual(native['requires'], ['coremark-prepare'])
            self.assertEqual(steps['fpga-timing-ok']['requires'], ['fpga-build'])

    def test_failed_prerequisite_skips_only_dependents(self):
        def runner(step, *_):
            status = 'FAIL' if step.name in ('fpga-build', 'sta-prepare') else 'PASS'
            return {'name': step.name, 'status': status}

        steps = [r.Step('fpga-build', []), r.Step('fpga-timing-ok', [], requires=('fpga-build',)),
                 r.Step('sta-prepare', []), r.Step('sta-rv32', [], requires=('sta-prepare',)),
                 r.Step('sta-rv64', [], requires=('sta-prepare',)), r.Step('coremark-rv32', [])]
        results = r.run_steps(steps, None, 1, 3, runner)
        self.assertEqual([s['status'] for s in results], ['FAIL', 'SKIP', 'FAIL', 'SKIP', 'SKIP', 'PASS'])
        self.assertIn('fpga-build', results[1]['reason'])
        self.assertIn('sta-prepare', results[4]['reason'])

    def test_subprocess_failure_and_timeout(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as tmp:
            work = Path(tmp)
            (work / 'logs').mkdir()
            for name, code, timeout, expected in [('fail', 'raise SystemExit(7)', 2, 7),
                                                  ('slow', 'import time; time.sleep(10)', 0.05, None)]:
                result = r.run_step(r.Step(name, [sys.executable, '-c', code]), work, timeout)
                self.assertEqual(result['status'], 'FAIL')
                self.assertEqual(result['exit_code'], expected)
                self.assertTrue(Path(result['log']).exists())

    def test_format_barrier_and_summary(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as tmp:
            work = Path(tmp) / 'run'
            fake = Path(tmp) / 'make'
            fake.write_text('#!/bin/sh\necho formatter-failed\nexit 9\n')
            fake.chmod(0o755)
            self.assertEqual(r.main(['--make', str(fake), '--output', str(work)]), 1)
            summary = json.loads((work / 'summary.json').read_text())
            self.assertEqual([x['status'] for x in summary['results'][:1]], ['FAIL'])
            self.assertTrue(all(x['status'] == 'SKIP' for x in summary['results'][1:]))

    def test_successful_fake_end_to_end(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as tmp:
            work = Path(tmp) / 'run'
            fake = Path(tmp) / 'make'
            fake.write_text('#!/bin/sh\ncat <<\'EOF\'\n' + GOOD +
                            'fmax Summary\n[INFO] Vivado timing constraints are met: fake\nEOF\n')
            fake.chmod(0o755)
            self.assertEqual(r.main(['--make', str(fake), '--output', str(work)]), 0)
            summary = json.loads((work / 'summary.json').read_text())
            self.assertEqual(len(summary['results']), 12)
            self.assertTrue(all(x['status'] == 'PASS' for x in summary['results']))

    def test_ready_checks_overlap_after_their_prerequisites(self):
        simultaneous = {'fpga-build', 'sta-rv32', 'sta-rv64', 'coremark-nemu32',
                        'coremark-nemu64', 'coremark-rv32', 'coremark-rv64'}
        barrier = threading.Barrier(len(simultaneous), timeout=5)
        finished = set()
        state_lock = threading.Lock()

        def runner(step, *_):
            with state_lock:
                if step.name != 'format':
                    self.assertIn('format', finished)
                self.assertLessEqual(set(step.requires), finished)
            if step.name in simultaneous:
                barrier.wait()
            with state_lock:
                finished.add(step.name)
            return dict(r.asdict(step), status='PASS', exit_code=0, seconds=0,
                        reason='', log=None)

        with tempfile.TemporaryDirectory(dir='/tmp') as tmp, patch.object(r, 'run_step', runner):
            self.assertEqual(r.main(['--jobs', str(len(simultaneous)),
                                     '--output', str(Path(tmp) / 'run')]), 0)
        self.assertLessEqual(simultaneous | {'fpga-timing-ok'}, finished)

    def test_job_limit(self):
        barrier = threading.Barrier(2, timeout=3)
        lock = threading.Lock()
        active = set()

        def runner(step, *_):
            with lock:
                active.add(step.name)
                self.assertLessEqual(len(active), 2)
            if step.name != 'third':
                barrier.wait()
            with lock:
                active.remove(step.name)
            return {'name': step.name, 'status': 'PASS'}

        steps = [r.Step(name, []) for name in ('first', 'second', 'third')]
        self.assertEqual([x['status'] for x in r.run_steps(steps, None, 1, 2, runner)], ['PASS'] * 3)



if __name__ == '__main__':
    unittest.main()
