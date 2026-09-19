#!/usr/bin/env python3
"""Exercise production Assert and Capstone startup without building/changing RTL."""
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CAPSTONE = ROOT / 'nemu/tools/capstone/repo'


def no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class SimulatorAssertTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='raptor-chip-assert-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        (self.work / 'generated').mkdir()
        (self.work / 'generated/autoconf.h').write_text('')

    def compile(self, source, bits, release, *extra):
        path = self.work / 'test.cc'
        path.write_text(source)
        binary = self.work / 'test'
        command = ['c++', '-std=c++17', '-Wall', '-Wextra',
                   '-I' + str(self.work), '-I' + str(ROOT / 'sim/include')]
        if bits == 64:
            command += ['-DCONFIG_ISA64']
        if release:
            command += ['-DNDEBUG']
        result = subprocess.run(command + [str(path), *extra, '-o', str(binary)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return binary

    def run_binary(self, binary, *args):
        return subprocess.run([str(binary), *args], cwd=self.work,
                              capture_output=True, text=True, preexec_fn=no_core_dump)

    def test_assert_evaluation_and_control_flow(self):
        source = r'''
#include <common.h>
int main(int argc, char **) {
  int checks = 0, arguments = 0;
  if (argc > 1) {
    Assert(++checks == 0, "intentional failure checks=%d args=%d", checks, ++arguments);
    return 9;
  }
  if (true)
    Assert(++checks == 1, "must not be printed %d", ++arguments);
  else
    return 1;
  if (false)
    Assert(false, "unreachable");
  else
    ++checks;
  return checks == 2 && arguments == 0 ? 0 : 2;
}
'''
        for bits in (32, 64):
            for release in (False, True):
                with self.subTest(bits=bits, ndebug=release):
                    binary = self.compile(source, bits, release)
                    success = self.run_binary(binary)
                    self.assertEqual(success.returncode, 0, success.stdout + success.stderr)
                    self.assertEqual(success.stdout + success.stderr, '')
                    failure = self.run_binary(binary, 'fail')
                    self.assertEqual(failure.returncode, -signal.SIGABRT)
                    self.assertIn('intentional failure checks=1 args=1',
                                  failure.stdout + failure.stderr)

    def test_capstone_startup_and_missing_library_diagnostic(self):
        suffix = '5.dylib' if sys.platform == 'darwin' else 'so.5'
        library = CAPSTONE / ('libcapstone.' + suffix)
        self.assertTrue(library.is_file(), 'Build dependency first: make -C nemu/tools/capstone')
        source = r'''
#include <common.h>
void init_disasm();
void disassemble(char *, int, uint64_t, uint8_t *, int);
int main() {
  init_disasm();
  uint8_t instruction[] = {0x13, 0, 0, 0};
  char text[128] = {};
  disassemble(text, sizeof(text), 0x80000000, instruction, sizeof(instruction));
  return strcmp(text, "nop") != 0;
}
'''
        for bits in (32, 64):
            for release in (False, True):
                for present in (True, False):
                    with self.subTest(bits=bits, ndebug=release, library_present=present):
                        path = library if present else self.work / 'missing-capstone.so'
                        binary = self.compile(source, bits, release,
                            '-DCONFIG_ITRACE', '-DRAPT_CAPSTONE_PATH=' + str(path),
                            '-I' + str(CAPSTONE / 'include'),
                            str(ROOT / 'sim/csrc/utils/disasm.cc'), '-ldl')
                        result = self.run_binary(binary)
                        output = result.stdout + result.stderr
                        if present:
                            self.assertEqual(result.returncode, 0, output)
                            self.assertEqual(output, '')
                        else:
                            self.assertEqual(result.returncode, -signal.SIGABRT)
                            self.assertIn('Cannot load Capstone ' + str(path) + ':', output)
                            self.assertNotIn('(null)', output)


if __name__ == '__main__':
    unittest.main()
