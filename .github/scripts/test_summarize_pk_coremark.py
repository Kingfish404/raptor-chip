"""Regression checks for pk CoreMark timing and CI result validation."""
import importlib.util
from pathlib import Path
import subprocess
import re
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('summarize-pk-coremark.py')
spec = importlib.util.spec_from_file_location('pk_summary', SCRIPT)
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
        return summary.evaluate(log, iterations, allow_short)

    def test_explicit_smoke_accepts_known_crcs(self):
        result = self.check()
        self.assertEqual(result['errors'], [])
        self.assertTrue(result['short'])
        self.assertEqual(result['iterations'], 1)

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
            hello, coremark, report = (root / name for name in ('hello', 'coremark', 'summary'))
            hello.write_text('HIT GOOD TRAP\n')
            command = ['python3', str(SCRIPT), str(hello), str(coremark), str(report),
                       '--expected-iterations', '1', '--allow-short']
            for log, expected in ((SMOKE, 0), (SMOKE.replace('0x1fd7', '0x0000'), 1), ('', 1)):
                coremark.write_text(log)
                self.assertEqual(subprocess.run(command, check=False).returncode, expected)
            hello.unlink()
            coremark.write_text(SMOKE)
            self.assertEqual(subprocess.run(command, check=False).returncode, 1)
            self.assertIn('SMOKE PASS', report.read_text())
            self.assertIn('NOT VALID (less than 10 seconds)', report.read_text())
            self.assertIn('FAIL', report.read_text())


if __name__ == '__main__':
    unittest.main()
