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
            self.assertEqual(len(plan['parallel_lanes']['coremark']), 4)
            sta = plan['parallel_lanes']['sta']
            self.assertNotEqual(sta[0]['command'], sta[1]['command'])
            self.assertIn(f'STA_WORK_DIR={output}/sta-rv64', sta[1]['command'])

    def test_lane_failure_dependencies(self):
        def runner(step, *_):
            return {'status': 'FAIL', 'name': step.name}
        steps = [r.Step('fpga-build', []), r.Step('fpga-timing-ok', [])]
        self.assertEqual(r.run_lane(steps, None, 1, runner)[1]['status'], 'SKIP')
        steps = [r.Step('sta-rv32', []), r.Step('sta-rv64', [])]
        self.assertEqual(len(r.run_lane(steps, None, 1, runner)), 2)

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
            self.assertEqual(len(summary['results']), 9)
            self.assertTrue(all(x['status'] == 'PASS' for x in summary['results']))

    def test_lanes_overlap_only_after_format(self):
        barrier = threading.Barrier(3, timeout=3)
        finished = []
        first = {'coremark-nemu32', 'sta-rv32', 'fpga-build'}

        def runner(step, *_):
            if step.name in first:
                self.assertEqual(finished[:1], ['format'])
                barrier.wait()  # All three lanes must be running concurrently.
            finished.append(step.name)
            return dict(r.asdict(step), status='PASS', exit_code=0, seconds=0,
                        reason='', log=None)

        with tempfile.TemporaryDirectory(dir='/tmp') as tmp, patch.object(r, 'run_step', runner):
            self.assertEqual(r.main(['--output', str(Path(tmp) / 'run')]), 0)
        self.assertLess(finished.index('coremark-rv32'), finished.index('coremark-nemu64'))
        self.assertLess(finished.index('fpga-build'), finished.index('fpga-timing-ok'))



if __name__ == '__main__':
    unittest.main()
