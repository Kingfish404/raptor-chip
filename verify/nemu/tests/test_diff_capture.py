#!/usr/bin/env python3
"""Compare production CPU capture byte-for-byte with a scalar full-state oracle."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class StateCaptureTest(unittest.TestCase):
    def test_full_state_capture(self):
        with tempfile.TemporaryDirectory(prefix='nemu-diff-capture-') as temporary:
            directory = Path(temporary)
            (directory / 'generated').mkdir()
            binary = directory / 'check'
            for xlen in (32, 64):
                for reduced in (False, True):
                    for target in ('NATIVE_ELF', 'SHARE'):
                        for sanitize in (False, True):
                            with self.subTest(xlen=xlen, reduced=reduced, target=target, sanitize=sanitize):
                                config = ['CONFIG_ISA_riscv', 'CONFIG_MODE_SYSTEM', 'CONFIG_DEVICE',
                                          'CONFIG_HAS_TIMER', 'CONFIG_TARGET_' + target]
                                if xlen == 64:
                                    config += ['CONFIG_RV64', 'CONFIG_ISA64']
                                if reduced:
                                    config += ['CONFIG_RVE']
                                (directory / 'generated/autoconf.h').write_text(
                                    ''.join('#define ' + name + ' 1\n' for name in config)
                                    + '#define CONFIG_MBASE 0x80000000ul\n#define CONFIG_MSIZE 0x10000000ul\n'
                                    + '#define CONFIG_RV_ASID_BITS 16\n#define CONFIG_RV_PMPADDR_BITS 54\n')
                                command = ['cc', '-std=gnu11', '-O2', '-Wall', '-Werror',
                                           '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                                           '-D__GUEST_ISA__=riscv', '-I' + str(directory),
                                           '-I' + str(ROOT / 'nemu/include'),
                                           '-I' + str(ROOT / 'nemu/src/isa/riscv/include'),
                                           str(ROOT / 'nemu/src/cpu/difftest/multihart-state.c'),
                                           str(ROOT / 'app/tests/host/nemu_diff_capture.c'), '-o', str(binary)]
                                if sanitize:
                                    command += ['-fsanitize=undefined', '-fno-sanitize-recover=all']
                                built = subprocess.run(command, capture_output=True, timeout=30)
                                self.assertEqual(built.returncode, 0, built.stderr.decode())
                                result = subprocess.run([binary], capture_output=True, timeout=30)
                                self.assertEqual(result.returncode, 0, result.stderr.decode())
                                self.assertEqual(result.stdout, b'NEMU_DIFF_CAPTURE_PASS\n')
                                self.assertEqual(result.stderr, b'')


if __name__ == '__main__':
    unittest.main()
