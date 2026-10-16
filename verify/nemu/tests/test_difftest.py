"""Architectural state capture, deltas and multi-hart replay fault injection."""

from lib.journal import END, HEADER, STATE, STATE_WORDS, VECTOR_FLAG, VECTOR_WORDS, read_events, write_events
from multihart.rva23 import corrupt_state
from pathlib import Path
import os
import struct
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class StateDeltaTest(unittest.TestCase):
    def test_complete_state(self):
        with tempfile.TemporaryDirectory(prefix='nemu-diff-state-') as temporary:
            binary = Path(temporary) / 'check'
            for sanitizer in (False, True):
                with self.subTest(sanitizer=sanitizer):
                    subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                                    *(['-fsanitize=undefined', '-fno-sanitize-recover=all'] if sanitizer else []),
                                    '-I' + str(ROOT / 'nemu/include'),
                                    str(ROOT / 'app/tests/host/nemu_diff_state.c'), '-o', str(binary)],
                                   check=True, capture_output=True, timeout=30)
                    result = subprocess.run([binary], check=True, capture_output=True, timeout=30,
                                            env=dict(os.environ, UBSAN_OPTIONS='halt_on_error=1'))
                    self.assertEqual(result.stdout, b'NEMU_DIFF_STATE_PASS\n')
                    self.assertEqual(result.stderr, b'')


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


class RVA23MultihartTest(unittest.TestCase):
    def test_corrupts_one_hart_after_the_selected_state_changes(self):
        slots = {'vector': STATE_WORDS + 16, 'fcsr': 65 + 0x003,
                 'hstatus': 65 + 0x600, 'senvcfg': 65 + 0x10a, 'vstart': 65 + 0x008}
        for fault, slot in slots.items():
            for present in (False, True):
                with self.subTest(fault=fault, present=present), tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary)
                    source, destination = directory / 'source.njr', directory / 'bad.njr'
                    state = [0] * (STATE_WORDS + VECTOR_WORDS)
                    state[slot] = 0x10
                    packed = struct.pack('<' + 'Q' * len(state), *state)
                    header = HEADER.pack(b'NMUJNL01', 1 | VECTOR_FLAG, 64, 2, 0x80000000, 4096, 1 << 14, 0)
                    events = [[STATE, hart, 0, packed] for hart in (0, 1)]
                    events += [[END, hart, 0, struct.pack('<6Q', 0x13, 0, 0, 1, 0, 0x80000004)]
                               for hart in (0, 1)]
                    if present:
                        events.append([END, 1, 1, struct.pack('<6Q', 0x13, 0, 0, 1, slot, 0x20)])
                    write_events(source, header, events)
                    original = source.read_bytes()
                    corrupt_state(source, destination, fault)
                    actual_header, actual = read_events(destination)
                    self.assertEqual(source.read_bytes(), original)
                    self.assertEqual(actual_header, header)
                    changed = len(events) - 1
                    for index, event in enumerate(actual):
                        self.assertEqual(event[:3], events[index][:3])
                        if index != changed:
                            self.assertEqual(event[3], events[index][3])
                    fields = struct.unpack('<' + 'Q' * (len(actual[changed][3]) // 8), actual[changed][3])
                    self.assertEqual(dict(zip(fields[4::2], fields[5::2]))[slot], 0x21 if present else 0x11)


if __name__ == '__main__':
    unittest.main()
