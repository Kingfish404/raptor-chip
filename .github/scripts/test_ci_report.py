"""Regression checks for CI log parsing, summaries and CoreMark validation."""
import importlib.util
import os
from pathlib import Path
import subprocess
import re
import shlex
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('ci_report.py')
spec = importlib.util.spec_from_file_location('ci_report', SCRIPT)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)

# Relevant lines from a real one-iteration pk run, including the port banner.
SMOKE = '''Iterations: 1
CoreMark timer Hz : 10000000
CoreMark Size    : 666
Total ticks      : 3737
Total time (secs): 0
ERROR! Must execute for at least 10 secs for a valid result!
Iterations       : 1
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0xe714
Errors detected
CoreMark ROI cycles       : 373444
CoreMark ROI instructions : 303763
CoreMark: done.
HIT GOOD TRAP
Iterations    : 1
CoreMark/MHz  : 2.6778
'''


class SummaryTests(unittest.TestCase):
    def check(self, log=SMOKE, allow_short=True, iterations=1):
        return summary.evaluate_pk(log, iterations, allow_short)

    def test_explicit_smoke_accepts_known_crcs(self):
        result = self.check()
        self.assertEqual(result['errors'], [])
        self.assertTrue(result['short'])
        self.assertEqual(result['iterations'], 1)

    def test_reported_ci_smoke_metrics_pass(self):
        log = SMOKE.replace('373444', '268854').replace('3737', '2691')
        result = self.check(log)
        self.assertEqual(result['errors'], [])
        self.assertEqual(result['cycles'], 268854)
        self.assertEqual(result['instructions'], 303763)

    def test_standard_mode_rejects_short_run(self):
        self.assertTrue(self.check(allow_short=False)['errors'])

    def test_valid_standard_run(self):
        log = SMOKE.replace(summary.SHORT_RUN + '\n', '').replace(
            'Errors detected', 'Correct operation validated. See README.md for run and reporting rules.')
        log = log.replace('3737', '100000000').replace('(secs): 0', '(secs): 10')
        result = self.check(log, allow_short=False)
        self.assertEqual(result['errors'], [])
        self.assertFalse(result['short'])

    def test_corrupt_or_missing_crc_never_passes(self):
        for crc in ('0xe9f5', '0xe714', '0x1fd7', '0x8e3a'):
            with self.subTest(crc=crc):
                self.assertTrue(self.check(SMOKE.replace(crc, '0x0000', 1))['errors'])
        self.assertTrue(self.check(SMOKE.replace('[0]crcstate      : 0x8e3a\n', ''))['errors'])

    def test_one_iteration_final_crc(self):
        self.assertTrue(self.check(SMOKE.replace('[0]crcfinal      : 0xe714',
                                                '[0]crcfinal      : 0x0000'))['errors'])

    def test_additional_error_never_passes(self):
        for error in ('[0]ERROR! list crc mismatch', 'ERROR! invalid data type', 'Cannot validate operation'):
            with self.subTest(error=error):
                self.assertTrue(self.check(SMOKE + error + '\n')['errors'])

    def test_wrong_timebase_never_passes(self):
        self.assertTrue(self.check(SMOKE.replace('Hz : 10000000', 'Hz : 1000000'))['errors'])

    def test_stale_iterations_never_pass(self):
        self.assertTrue(self.check(iterations=2)['errors'])

    def test_missing_bad_or_duplicate_trap(self):
        for log in (SMOKE.replace('HIT GOOD TRAP', ''),
                    SMOKE.replace('HIT GOOD TRAP', 'HIT BAD TRAP'),
                    SMOKE + 'HIT GOOD TRAP\n'):
            self.assertTrue(self.check(log)['errors'])

    def test_incomplete_or_inconsistent_run(self):
        for log in (SMOKE.replace('CoreMark: done.\n', ''),
                    SMOKE.replace('373444', '0'),
                    SMOKE.replace('3737', '100000000'),
                    SMOKE.replace(summary.SHORT_RUN + '\n', ''),
                    SMOKE.replace('Errors detected\n', '')):
            self.assertTrue(self.check(log)['errors'])

    def test_actual_port_time_conversion(self):
        source = (SCRIPT.resolve().parents[2] /
                  'app/benchmarks/coremark/portme/core_portme.c').read_text()
        # Compile the actual conversion function without the RISC-V CSR readers.
        function = re.search(r'secs_ret time_in_secs\(CORE_TICKS ticks\)\n\{.*?^\}',
                             source, re.MULTILINE | re.DOTALL).group()
        with tempfile.TemporaryDirectory() as directory:
            for floating in (0, 1):
                code = ('#include <stdint.h>\n#include <assert.h>\n'
                        f'#define HAS_FLOAT {floating}\n'
                        '#define EE_TICKS_PER_SEC 10000000ULL\n'
                        'typedef uint64_t CORE_TICKS;\n'
                        f'typedef {"double" if floating else "uint32_t"} secs_ret;\n'
                        + function + '\nint main(void) {\n')
                if floating:
                    code += 'assert(time_in_secs(5000000ULL) == 0.5);\n'
                else:
                    code += ('assert(time_in_secs(3737ULL) == 0);\n'
                             'assert(time_in_secs(99999999ULL) == 9);\n')
                code += ('assert(time_in_secs(100000000ULL) == 10);\n'
                         'assert(time_in_secs(5000000000ULL) == 500);\nreturn 0; }\n')
                path = Path(directory) / 'time.c'
                binary = Path(directory) / 'time'
                path.write_text(code)
                subprocess.run(['cc', '-Wall', '-Werror', str(path), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)

    def test_cli_returns_failure_and_writes_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hello, coremark = root / 'hello', root / 'coremark'
            hello.write_text('HIT GOOD TRAP\n')
            command = ['python3', str(SCRIPT), 'coremark-pk', str(hello), str(coremark),
                       '--expected-iterations', '1', '--allow-short']
            ci_smoke = SMOKE.replace('373444', '268854').replace('3737', '2691')
            for log, expected in ((SMOKE, 0), (ci_smoke, 0),
                                  (SMOKE.replace('0x1fd7', '0x0000'), 1), ('', 1)):
                coremark.write_text(log)
                run = subprocess.run(command, check=False, capture_output=True, text=True)
                self.assertEqual(run.returncode, expected)
            hello.unlink()
            coremark.write_text(SMOKE)
            run = subprocess.run(command, check=False, capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertIn('SMOKE PASS', run.stdout)
            self.assertIn('NOT VALID (less than 10 seconds)', run.stdout)
            self.assertIn('FAIL', run.stdout)

    def test_coremark_workflow_step_preserves_report_status(self):
        workflow = (SCRIPT.resolve().parents[1] / 'workflows/benchmark.yaml').read_text()
        step = workflow.split('      - name: CoreMark validation and summary\n', 1)[1]
        settings = step.split('\n  app-embench:', 1)[0].splitlines()
        shell = next(line.strip().removeprefix('shell: ') for line in settings
                     if line.strip().startswith('shell: '))
        command = shlex.split(shell)
        self.assertEqual(command.pop(), '{0}')
        run_index = settings.index('        run: |')
        script = '\n'.join(line[10:] for line in settings[run_index + 1:]
                           if line.startswith('          ')) + '\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hello, coremark, report = (root / name for name in ('hello', 'coremark', 'summary'))
            hello.write_text('HIT GOOD TRAP\n')
            script = script.replace('/tmp/app-hello.log', str(hello))
            script = script.replace('/tmp/app-coremark.log', str(coremark))
            environment = dict(os.environ, REPORT=f'python3 {SCRIPT}', GITHUB_STEP_SUMMARY=str(report))
            for log, expected in ((SMOKE, 0), (SMOKE.replace('0xe9f5', '0x0000'), 1)):
                coremark.write_text(log)
                report.write_text('')
                result = subprocess.run([*command, '-c', script],
                                        cwd=SCRIPT.resolve().parents[2], env=environment,
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn('CoreMark functional check', report.read_text())

    def test_embench_workflow_step_preserves_report_status(self):
        workflow = (SCRIPT.resolve().parents[1] / 'workflows/benchmark.yaml').read_text()
        step = workflow.split('      - name: Embench full-suite summary\n', 1)[1]
        settings = step.splitlines()
        shell = next(line.strip().removeprefix('shell: ') for line in settings
                     if line.strip().startswith('shell: '))
        command = shlex.split(shell)
        self.assertEqual(command.pop(), '{0}')
        run_index = settings.index('        run: |')
        script = '\n'.join(line[10:] for line in settings[run_index + 1:]
                           if line.startswith('          ')).replace('${{ matrix.suite }}', 'baremetal') + '\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.bash_logout').write_text('false\n')
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            make = bin_dir / 'make'
            make.write_text('#!/bin/sh\nexit "$MAKE_STATUS"\n')
            make.chmod(0o755)
            report = root / 'sim/build/default/logs/app/embench-baremetal-rv64.md'
            report.parent.mkdir(parents=True)
            report.write_text('# Embench\n')
            step_script = root / 'step.sh'
            step_script.write_text(script)
            summary = root / 'summary.md'
            for expected in (0, 1):
                summary.write_text('')
                environment = dict(os.environ, HOME=str(root),
                                   PATH=f'{bin_dir}:{os.environ["PATH"]}',
                                   MAKE_STATUS=str(expected), RAPT_CONFIG='default',
                                   GITHUB_STEP_SUMMARY=str(summary))
                result = subprocess.run([*command, str(step_script)], cwd=root,
                                        env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn('# Embench', summary.read_text())


# Sim log fragments in the current NPC format, including ANSI colour.
NPC_COREMARK = (
    "\x1b[1;34mcpu_exec.cc:390 cpu_exec \x1b[0mprogress: 0000000000147456 cycles\n"
    "Iterations       : 2\n"
    "CoreMark PASS       1024 Marks\n"
    "\x1b[1;34mpmu.cc:912 perf_compact \x1b[0m#inst: 548059, cycle: 387947, IPC: 1.413\n"
    "\x1b[1;34mpmu.cc:950 perf_compact \x1b[0mRename checkpoints: pool full 10647 cycles\n"
    "\x1b[1;34mpmu.cc:222 operator() \x1b[0mControl latency correct_retire: count 1\n"
    "\x1b[1;34mpmu.cc:1457 statistic \x1b[0m\x1b[1;32mHIT GOOD TRAP\x1b[0m at pc: 0x80000000\n"
    "CoreMark/MHz  : 5.1546\n")

AM_SMOKE = """2K performance run parameters for coremark.
CoreMark Size    : 666
ERROR! Must execute for at least 10 secs for a valid result!
Iterations       : 1
Errors detected
HIT GOOD TRAP
"""


class ReportTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(['python3', str(SCRIPT), *map(str, args)], check=False,
                              capture_output=True, text=True)

    def test_coremark_metrics_from_coloured_log(self):
        m = summary.metrics('coremark', summary.ANSI.sub('', NPC_COREMARK))
        self.assertEqual(m['score'], '1024')
        self.assertEqual(m['iterations'], '2')
        self.assertEqual(m['coremark_per_mhz'], '5.1546')
        self.assertEqual((m['ipc'], m['cycles'], m['insts']), ('1.413', '387947', '548059'))
        self.assertEqual(m['trap'], 'HIT GOOD TRAP')

    def test_coremark_per_mhz_falls_back_to_cycles(self):
        log = 'Iterations : 2\n#inst: 10, cycle: 400000, IPC: 0.5\n'
        self.assertEqual(summary.metrics('coremark', log)['coremark_per_mhz'], '5.0000')

    def test_missing_values_are_not_available(self):
        for kind in ('coremark', 'microbench', 'sta'):
            m = summary.metrics(kind, '')
            self.assertTrue(all(value in ('N/A', 'UNKNOWN') for value in m.values()), m)
        self.assertEqual(summary.metrics('archtest', ''), {'pass': '0', 'fail': '0'})

    def test_microbench_and_sta_metrics(self):
        mb = summary.metrics('microbench', 'MicroBench PASS\n12 Marks\n345 Marks\n')
        self.assertEqual((mb['result'], mb['score']), ('PASS', '345'))
        sta = summary.metrics('sta', "core_clock period_min = 13.83 fmax = 72.28\n"
                              "Chip area for module '\\rapt': 533288.77\n"
                              "Total  2.67e+00  2.56e+00  1.23e-02  5.25e+00 100.0%\n")
        self.assertEqual(sta, {'freq_mhz': '72.28', 'area': '533288.77', 'power': '5.25e+00'})

    def test_pmu_keeps_every_counter_line(self):
        block = summary.pmu_block('CoreMark', summary.ANSI.sub('', NPC_COREMARK))
        for text in ('#inst: 548059', 'Rename checkpoints', 'Control latency', 'HIT GOOD TRAP'):
            self.assertIn(text, block)
        self.assertNotIn('pmu.cc', block)
        self.assertEqual(summary.pmu_block('none', 'no counters'), '')

    def test_am_coremark_smoke(self):
        self.assertEqual(summary.evaluate_am(AM_SMOKE), [])
        for broken in (AM_SMOKE.replace('HIT GOOD TRAP', 'HIT BAD TRAP'),
                       AM_SMOKE.replace('Iterations       : 1', 'Iterations       : 2'),
                       AM_SMOKE.replace('2K performance', '2K validation'),
                       AM_SMOKE + 'ERROR! list crc mismatch\n',
                       AM_SMOKE.replace('Errors detected\n', '')):
            with self.subTest(broken=broken):
                self.assertTrue(summary.evaluate_am(broken))

    def test_cli_tables_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'coremark.log'
            log.write_text(NPC_COREMARK)
            run = self.run_cli('bench', 'Benchmarks', f'CoreMark=coremark:{log}')
            self.assertEqual(run.returncode, 0)
            self.assertIn('| CoreMark | 1024 | 5.1546 (2 iterations) | 1.413 |', run.stdout)
            boot = self.run_cli('boot', 'Boot', log, 'Trap=HIT GOOD TRAP', 'Init=Run /init')
            self.assertEqual(boot.returncode, 1)
            self.assertIn('| Trap | PASS |', boot.stdout)
            self.assertIn('| Init | FAIL |', boot.stdout)
            am = Path(directory) / 'am.log'
            am.write_text(AM_SMOKE)
            self.assertEqual(self.run_cli('coremark-am', am).returncode, 0)
            am.write_text(AM_SMOKE.replace('GOOD', 'BAD'))
            self.assertEqual(self.run_cli('coremark-am', am).returncode, 1)
            self.assertEqual(self.run_cli('bench', 'x', 'bad-row').returncode, 1)


if __name__ == '__main__':
    unittest.main()
