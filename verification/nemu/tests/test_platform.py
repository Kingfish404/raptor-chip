"""Host/guest clocks and the RVA23 Linux platform contract."""

from isa.rva23_linux import FAIL_MARKERS, PASS_MARKERS, run_console, verdict
from isa.rva23_linux import build_dtb
from pathlib import Path
import ctypes
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[3]


class HostTimerTest(unittest.TestCase):
    def test_production_host_clock_is_independent_of_guest_clock(self):
        for timer in ('CYCLE', 'GETTIMEOFDAY', 'CLOCK_GETTIME'):
            with self.subTest(timer=timer), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                (directory / 'generated').mkdir()
                flags = ('ISA_riscv', 'TARGET_NATIVE_ELF', 'DEVICE', 'HAS_TIMER', 'TIMER_' + timer)
                (directory / 'generated/autoconf.h').write_text(''.join(
                    f'#define CONFIG_{flag} 1\n' for flag in flags))
                fixture = directory / 'clock.c'
                fixture.write_text('''#include <common.h>
bool nemu_threaded;
NEMU_TLS uint64_t g_nr_guest_inst;
uint64_t cpu_thread_time_us(void) { return 7654321; }
void set_guest_instructions(uint64_t count) { g_nr_guest_inst = count; }
''')
                binary = directory / 'timer.so'
                subprocess.run(['cc', '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror',
                                '-shared', '-fPIC', '-I' + str(directory),
                                '-I' + str(ROOT / 'nemu/include'),
                                str(ROOT / 'nemu/src/utils/timer.c'), str(fixture), '-o', str(binary)],
                               check=True, capture_output=True)
                library = ctypes.CDLL(str(binary))
                host_time = library.get_host_time
                host_time.restype = ctypes.c_uint64
                guest_time = library.get_time
                guest_time.restype = ctypes.c_uint64
                set_count = library.set_guest_instructions
                set_count.argtypes = [ctypes.c_uint64]
                threaded = ctypes.c_bool.in_dll(library, 'nemu_threaded')
                for backend in (False, True):
                    threaded.value = backend
                    start = time.monotonic_ns() // 1000
                    host_start = host_time()
                    set_count(9_000_000_000_000)
                    time.sleep(0.01)
                    host_end = host_time()
                    end = time.monotonic_ns() // 1000
                    self.assertLessEqual(start, host_start)
                    self.assertLessEqual(host_end, end)
                    self.assertGreater(host_end - host_start, 1000)
                    if backend:
                        self.assertEqual(guest_time(), 7654321)
                    elif timer == 'CYCLE':
                        self.assertEqual(guest_time(), 9_000_000_000)


class RVA23ClockTest(unittest.TestCase):
    def test_production_profile_selection_and_clock_contract(self):
        for timer in ('CYCLE', 'GETTIMEOFDAY', 'CLOCK_GETTIME'):
            with self.subTest(timer=timer), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                (directory / 'generated').mkdir()
                flags = ('ISA_riscv', 'RV64', 'ISA64', 'MODE_SYSTEM', 'RV_F', 'RV_D', 'RV_SVADE',
                         'TIMER_' + timer)
                (directory / 'generated/autoconf.h').write_text(''.join(
                    f'#define CONFIG_{flag} 1\n' for flag in flags))
                binary = directory / 'extensions.so'
                subprocess.run(['cc', '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror',
                                '-shared', '-fPIC', '-I' + str(directory),
                                '-I' + str(ROOT / 'nemu/include'),
                                '-I' + str(ROOT / 'nemu/src/isa/riscv/include'),
                                str(ROOT / 'nemu/src/isa/riscv/extensions.c'), '-o', str(binary)],
                               check=True, capture_output=True)
                library = ctypes.CDLL(str(binary))
                clock_supported = library.riscv_isa_profile_clock_supported
                clock_supported.argtypes = [ctypes.c_bool]
                clock_supported.restype = ctypes.c_bool
                self.assertEqual(clock_supported(False), timer == 'CYCLE')
                self.assertFalse(clock_supported(True))
                select = library.riscv_isa_configure_names
                select.argtypes = [ctypes.c_char_p]
                select.restype = ctypes.c_int
                self.assertEqual(select(b'none'), 0)
                self.assertEqual(select(b'rva23'), 0 if timer == 'CYCLE' else -1)
                mask = ctypes.c_uint64.in_dll(library, 'riscv_isa_extensions')
                self.assertEqual(mask.value, 0x7ff if timer == 'CYCLE' else 0)
                self.assertEqual(select(b'none'), 0)
                self.assertEqual(mask.value, 0)


@unittest.skipUnless(shutil.which('dtc') and shutil.which('fdtget'), 'requires device-tree tools')
class RVA23PlatformTest(unittest.TestCase):
    def test_profile_smp_cpu_and_interrupt_topology(self):
        for harts in (2, 3, 4):
            with self.subTest(harts=harts), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                build_dtb(directory, harts, source_name='spike-rva23-nemu.dts')
                tree = directory / 'nemu.dtb'
                nodes = subprocess.check_output(['fdtget', '-l', str(tree), '/cpus'], text=True).split()
                self.assertEqual(set(nodes), {f'cpu@{hart}' for hart in range(harts)})
                handles = []
                for hart in range(harts):
                    node = f'/cpus/cpu@{hart}'
                    self.assertEqual(self.property(tree, node, 'reg', 'u'), [str(hart)])
                    for name in ('riscv,isa', 'riscv,isa-extensions', 'mmu-type'):
                        self.assertEqual(self.property(tree, node, name),
                                         self.property(tree, '/cpus/cpu@0', name))
                    for operation in ('cbom', 'cbop', 'cboz'):
                        self.assertEqual(self.property(tree, node, f'riscv,{operation}-block-size', 'u'),
                                         ['64'])
                    handles += self.property(tree, node + '/interrupt-controller', 'phandle', 'u')
                self.assertEqual(len(set(handles)), harts)
                for device, interrupts in (('clint@2000000', ('3', '7')),
                                           ('plic@c000000', ('11', '9'))):
                    self.assertEqual(self.property(tree, '/soc/' + device, 'interrupts-extended', 'u'),
                                     [value for handle in handles for irq in interrupts for value in (handle, irq)])

    def compile_tree(self, name, directory):
        output = directory / (name + '.dtb')
        subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', str(output),
                        str(ROOT / 'linux/dts' / (name + '.dts'))], check=True, capture_output=True)
        return output

    def property(self, tree, node, name, kind='s'):
        return subprocess.check_output(['fdtget', '-t', kind, str(tree), node, name], text=True).split()

    def test_profile_properties_and_legacy_isolation(self):
        with tempfile.TemporaryDirectory(prefix='nemu-rva23-dtb-') as temporary:
            directory = Path(temporary)
            profile = self.compile_tree('spike-rva23-nemu', directory)
            legacy = self.compile_tree('spike-rv64gc-nemu', directory)
            cpu = '/cpus/cpu@0'
            extensions = self.property(profile, cpu, 'riscv,isa-extensions')
            required = {'i', 'm', 'a', 'f', 'd', 'c', 'b', 'v', 'h', 'zicsr', 'zifencei',
                        'zicntr', 'zihpm', 'zba', 'zbb', 'zbs', 'zicbom', 'zicbop', 'zicboz',
                        'zihintpause', 'zihintntl', 'zfhmin', 'zfa', 'zicond', 'zimop', 'zcmop',
                        'zcb', 'zawrs', 'zvbb', 'zvfhmin', 'zkt', 'zvkt', 'svade', 'svpbmt', 'svinval',
                        'svnapot', 'sstc', 'sscofpmf', 'ssnpm', 'ssstateen', 'smstateen'}
            self.assertTrue(required <= set(extensions))
            self.assertEqual(len(extensions), len(set(extensions)))
            legacy_extensions = self.property(legacy, cpu, 'riscv,isa-extensions')
            self.assertNotIn('v', legacy_extensions)
            self.assertNotIn('h', legacy_extensions)
            isa, = self.property(profile, cpu, 'riscv,isa')
            base, *named = isa.removeprefix('rv64').split('_')
            self.assertEqual(set(base) | set(named), set(extensions))
            for operation in ('cbom', 'cbop', 'cboz'):
                self.assertEqual(self.property(profile, cpu, f'riscv,{operation}-block-size', 'u'), ['64'])
            self.assertEqual(self.property(profile, cpu, 'riscv,pmpregions', 'u'), ['8'])
            self.assertEqual(self.property(profile, cpu, 'mmu-type'), ['riscv,sv39'])
            self.assertEqual(self.property(profile, '/memory@80000000', 'reg', 'x'),
                             self.property(legacy, '/memory@80000000', 'reg', 'x'))
            self.assertEqual(subprocess.check_output(['fdtget', '-l', str(profile), '/cpus'], text=True).split(),
                             ['cpu@0'])
            self.assertEqual(self.property(profile, '/poweroff', 'compatible'), ['syscon-poweroff'])
            self.assertEqual(self.property(profile, '/poweroff', 'regmap', 'x'),
                             self.property(profile, '/soc/test@100000', 'phandle', 'x'))
            self.assertEqual(self.property(profile, '/poweroff', 'value', 'x'), ['5555'])


class RVA23LinuxTest(unittest.TestCase):
    def test_requires_every_marker_and_clean_exit(self):
        output = b'\n'.join(PASS_MARKERS)
        self.assertTrue(verdict(0, output))
        for marker in PASS_MARKERS:
            self.assertFalse(verdict(0, output.replace(marker, b'')))
        for marker in FAIL_MARKERS:
            self.assertFalse(verdict(0, output + b'\n' + marker))
        for returncode in (None, -9, 1):
            self.assertFalse(verdict(returncode, output))
        self.assertFalse(verdict(0, output, timed_out=True))

    def test_stops_on_failure_and_timeout(self):
        for script, timed_out in (("print('Kernel panic', flush=True)", False), ('', True)):
            with self.subTest(timed_out=timed_out), tempfile.TemporaryDirectory() as temporary:
                command = [sys.executable, '-c', script + ';import time;time.sleep(30)'
                           if script else 'import time;time.sleep(30)']
                returncode, actual_timeout = run_console(command, Path(temporary) / 'log',
                                                         2 if script else 0.1)
                self.assertNotEqual(returncode, 0)
                self.assertEqual(actual_timeout, timed_out)

    def test_smp_requires_exact_worker_completion(self):
        output = b'\n'.join(PASS_MARKERS)
        for harts in (2, 3, 4):
            self.assertFalse(verdict(0, output, harts=harts))
            marker = f'\nRVA23_SMP_PASS harts={harts} workers={2 * harts}\r\n'.encode()
            self.assertTrue(verdict(0, output + marker, harts=harts))
            self.assertFalse(verdict(0, output + marker, harts=5 - harts if harts < 4 else 2))
            self.assertFalse(verdict(0, output + marker + b'RVA23_LINUX_FAIL', harts=harts))

    def test_clean_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'log'
            result = run_console([sys.executable, '-c', "print('done')"], log, 5)
            self.assertEqual(result, (0, False))
            self.assertEqual(log.read_bytes(), b'done\n')


if __name__ == '__main__':
    unittest.main()
