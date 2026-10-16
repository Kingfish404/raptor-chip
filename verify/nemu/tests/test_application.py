"""Standalone builds, staged installs and VM launch lifecycle."""

from pathlib import Path
import copy
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[3]


class CheckDispatcherTest(unittest.TestCase):
    def test_vector_aliases_keep_independent_command_lines(self):
        from isa.vector_units_rtl import UNITS
        spec = importlib.util.spec_from_file_location('nemu_checks', ROOT / 'verify/nemu/check.py')
        dispatcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dispatcher)
        aliases = dispatcher.SUITES['isa.vector_units_rtl']
        self.assertEqual(set(aliases.values()), set(UNITS))
        for name in aliases:
            self.assertEqual(dispatcher.modules()[name], 'isa.vector_units_rtl')
            result = subprocess.run([sys.executable, str(ROOT / 'verify/nemu/check.py'), name, '--help'],
                                    capture_output=True, text=True, timeout=10, check=True)
            self.assertIn(name, result.stdout)
            self.assertIn('--reference', result.stdout)
            self.assertIn('--xlen', result.stdout)


class StandaloneBuildTest(unittest.TestCase):
    def test_detached_private_configuration_and_headless_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / 'nemu'
            output = directory / 'output'
            source.mkdir()
            shutil.copy(ROOT / 'nemu/Makefile', source)
            shutil.copytree(ROOT / 'nemu/scripts', source / 'scripts')
            for name in ('src', 'include', 'configs', 'tools', 'Kconfig'):
                (source / name).symlink_to(ROOT / 'nemu' / name)
            (directory / 'Makefile').write_text('$(error parent Makefile was loaded)\n')
            sentinel = directory / 'sdl-invoked'
            sdl = directory / 'sdl-config'
            sdl.write_text(f'#!/bin/sh\ntouch "{sentinel}"\nexit 1\n')
            sdl.chmod(0o755)
            environment = dict(os.environ)
            environment.pop('NEMU_HOME', None)
            original_config = (ROOT / 'nemu/.config').read_bytes() if (ROOT / 'nemu/.config').exists() else None
            command = ['make', '-C', str(source), 'O=' + str(output), 'SDL_CONFIG=' + str(sdl)]

            def run(*arguments, success=True):
                result = subprocess.run([*command, *arguments], env=environment,
                                        text=True, capture_output=True, timeout=120)
                if success:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                return result

            run('riscv64_ref_defconfig')
            self.assertIn('CONFIG_RV64=y', (output / '.config').read_text())
            self.assertTrue((output / 'include/generated/autoconf.h').is_file())
            self.assertTrue((output / 'tools/fixdep/build/fixdep').is_file())
            result = run('-n', 'app')
            self.assertNotIn('-lSDL', result.stdout)
            self.assertFalse(sentinel.exists())
            run('riscv64_defconfig')
            self.assertIn('O=DIR', run('help').stdout)
            run('riscv32_ref_defconfig')
            self.assertFalse(sentinel.exists())
            self.assertIn('# CONFIG_RV64 is not set', (output / '.config').read_text())
            self.assertIn('O=DIR', run('help').stdout)
            run('O=' + str(source), 'help', success=False)
            run('reference', success=False)
            run('distclean')
            self.assertFalse((output / '.config').exists())
            self.assertFalse((output / 'include/generated').exists())
            current_config = (ROOT / 'nemu/.config').read_bytes() if (ROOT / 'nemu/.config').exists() else None
            self.assertEqual(original_config, current_config)
            self.assertFalse((source / '.config').exists())
            self.assertTrue((source / 'src/nemu-main.c').is_file())

    def test_output_refuses_existing_unrelated_source_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'src').mkdir()
            sentinel = directory / 'src/keep'
            sentinel.write_text('keep')
            environment = dict(os.environ)
            environment.pop('NEMU_HOME', None)
            result = subprocess.run(['make', '-C', str(ROOT / 'nemu'), 'O=' + str(directory), 'help'],
                                    env=environment, text=True, capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Refusing to replace', result.stderr)
            self.assertEqual(sentinel.read_text(), 'keep')


class InstallLayoutTest(unittest.TestCase):
    def test_native_reference_staging_and_configuration_guards(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / 'build'
            source.mkdir()
            (source / '.config').write_text('test build configuration\n')
            (source / 'include/generated').mkdir(parents=True)
            (source / 'include/generated/autoconf.h').write_text('#define CONFIG_RV64 1\n')
            binary = source / 'binary'
            binary.write_text('test binary\n')
            staging = directory / 'staged files'
            prefix = staging / 'opt/nemu'
            command = ['make', '-f', str(ROOT / 'nemu/scripts/install.mk'), 'install',
                       'NEMU_HOME=' + str(ROOT / 'nemu'), 'BINARY=' + str(binary),
                       'NAME=riscv64-nemu-interpreter', 'PREFIX=/opt/nemu', 'DESTDIR=' + str(staging)]

            def install(*options, success=True):
                result = subprocess.run([*command, *options], cwd=source, capture_output=True,
                                        text=True, timeout=30)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                return result

            install('CONFIG_TARGET_NATIVE_ELF=y')
            executable = prefix / 'libexec/nemu/riscv64-nemu-interpreter'
            self.assertEqual(executable.read_text(), binary.read_text())
            self.assertEqual((prefix / 'bin/nemu').stat().st_mode & 0o777, 0o755)
            install('CONFIG_TARGET_SHARE=y', 'SO=-so')
            reference = prefix / 'lib/nemu/riscv64-nemu-interpreter-so'
            include = prefix / 'include/nemu/riscv64-nemu-interpreter-so'
            self.assertEqual(reference.read_text(), binary.read_text())
            self.assertTrue((include / 'difftest-multi.h').is_file())
            self.assertEqual((include / 'generated/autoconf.h').read_text(), '#define CONFIG_RV64 1\n')
            self.assertEqual((prefix / 'share/nemu/configs/riscv64-nemu-interpreter-so.config').read_text(),
                             (source / '.config').read_text())
            self.assertTrue((prefix / 'share/doc/nemu/README.md').is_file())
            empty = directory / 'rejected'
            for options in (['CONFIG_TARGET_NATIVE_ELF=y', 'CONFIG_ITRACE=y'],
                            ['CONFIG_TARGET_AM=y'], ['CONFIG_TARGET_NATIVE_ELF=y', 'PREFIX=relative']):
                install('DESTDIR=' + str(empty), *options, success=False)
                self.assertFalse(empty.exists())
            self.assertEqual(executable.read_text(), binary.read_text())
            self.assertEqual(reference.read_text(), binary.read_text())


SPEC = importlib.util.spec_from_file_location('nemu_launcher', ROOT / 'nemu/tools/nemu.py')
LAUNCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LAUNCHER)
MACHINE = {
    'schema': 1, 'isa': 'riscv', 'xlen': 64, 'max_harts': 4,
    'vm_boot': True, 'threaded': True, 'cycle_timer': True, 'profiles': ['none', 'rva23'],
    'memory': {'base': 0x80000000, 'size': 0x40000000},
    'rom': {'base': 0x1000, 'dtb_max_size': 61407},
    'devices': {'timebase_hz': 10000000,
                'uart': {'base': 0x10000000, 'size': 0x100, 'irq': 10},
                'clint': {'base': 0x2000000, 'size': 0xc0000},
                'plic': {'base': 0xc000000, 'size': 0x1000000, 'sources': 32},
                'finisher': {'base': 0x100000, 'size': 0x1000},
                'block': {'base': 0x10001000, 'size': 0x1000, 'irq': 1},
                'net': {'base': 0x10002000, 'size': 0x1000, 'irq': 2, 'hostfwd_max': 16},
                'rng': {'base': 0x10003000, 'size': 0x1000, 'irq': 3}},
}


class VmLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.prefix = self.directory / 'installed prefix'
        self.binary = self.prefix / 'libexec/nemu/riscv64-nemu-interpreter'
        self.binary.parent.mkdir(parents=True)
        self.launcher = self.prefix / 'bin/nemu'
        self.launcher.parent.mkdir()
        shutil.copyfile(SPEC.origin, self.launcher)
        self.machine = copy.deepcopy(MACHINE)
        self.write_binary()
        self.firmware = self.directory / 'fw payload.bin'
        self.firmware.write_bytes(bytes(16))
        self.disk = self.directory / 'disk.img'
        self.disk.write_bytes(bytes(1024))
        self.state = self.directory / 'state'
        self.command = [sys.executable, str(self.launcher), 'run', '--firmware', str(self.firmware),
                        '--state-dir', str(self.state)]

    def write_binary(self, body='sys.exit(7)'):
        self.binary.write_text('#!' + sys.executable + '\nimport json, os, sys, time\n'
                               'from pathlib import Path\n'
                               'if sys.argv[1:] == ["--describe"]:\n'
                               f'    print({json.dumps(json.dumps(self.machine))})\n    sys.exit(0)\n'
                               'Path("child.json").write_text(json.dumps({"argv":sys.argv,"pid":os.getpid()}))\n'
                               + body + '\n')
        self.binary.chmod(0o755)

    def invoke(self, *options, success=True):
        result = subprocess.run([*self.command, *options], cwd=self.directory,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0 if success else 2, result.stdout + result.stderr)
        return result

    def test_info_is_relocatable_and_has_no_guest_side_effects(self):
        renamed = self.directory / 'relocated'
        self.prefix.rename(renamed)
        result = subprocess.run([sys.executable, str(renamed / 'bin/nemu'), 'info'],
                                cwd='/', capture_output=True, text=True, timeout=10, check=True)
        self.assertEqual(json.loads(result.stdout), self.machine)
        self.assertFalse(self.state.exists())

    def test_rejects_incompatible_capabilities_and_inputs_before_creating_state(self):
        for options in (('--harts', '0'), ('--harts', '5'), ('--xlen', '32'),
                        ('--backend', 'threaded', '--isa-profile', 'rva23'),
                        ('--disk-mode', 'persistent'), ('--append', 'bad\ncommand')):
            with self.subTest(options=options):
                self.invoke(*options, success=False)
                self.assertFalse(self.state.exists())
        for field, value in (('vm_boot', False), ('profiles', ['none']), ('threaded', False)):
            self.machine = copy.deepcopy(MACHINE)
            self.machine[field] = value
            self.write_binary()
            options = ['--isa-profile', 'rva23'] if field == 'profiles' else ['--backend', 'threaded']
            self.invoke(*options, success=False)
            self.assertFalse(self.state.exists())

    def test_requires_devices_and_rejects_unsupported_image_formats(self):
        del self.machine['devices']['block']
        self.write_binary()
        self.invoke('--disk', str(self.disk), success=False)
        del self.machine['devices']['uart']
        self.write_binary()
        self.invoke(success=False)
        self.machine = copy.deepcopy(MACHINE)
        self.write_binary()
        for data in (b'\x7fELF' + bytes(12), b''):
            self.firmware.write_bytes(data)
            self.invoke(success=False)
        self.firmware.write_bytes(bytes(16))
        for data in (b'QFI\xfb' + bytes(508), bytes(513)):
            self.disk.write_bytes(data)
            self.invoke('--disk', str(self.disk), success=False)
        self.firmware.write_bytes(bytes(512))
        self.disk.unlink()
        os.link(self.firmware, self.disk)
        self.invoke('--disk', str(self.disk), success=False)
        self.assertFalse(self.state.exists())

    def test_rejects_fifo_without_waiting_and_oversize_firmware(self):
        self.firmware.unlink()
        os.mkfifo(self.firmware)
        self.invoke(success=False)
        self.firmware.unlink()
        with self.firmware.open('wb') as stream:
            stream.truncate(self.machine['memory']['size'] + 1)
        self.invoke(success=False)

    def test_host_forwarding_validation(self):
        for rule in ('tcp:0:22', 'udp:1:65536', 'tcp:000001:22', 'tcp:1:+22', 'tcp:1:22x',
                     'tcp:0.0.0.0:2222:22', 'TCP:2222:22', 'tcp: 1:22', 'udp:2222:22'):
            self.invoke('--hostfwd', rule, success=False)
        self.invoke('--hostfwd=tcp:02222:22', '--hostfwd=tcp:2222:80', success=False)
        self.invoke(*[f'--hostfwd=tcp:{2000 + index}:22' for index in range(17)], success=False)
        del self.machine['devices']['net']['hostfwd_max']
        self.write_binary()
        self.invoke('--hostfwd=tcp:2222:22', success=False)
        self.assertFalse(self.state.exists())

    @unittest.skipUnless(shutil.which('dtc'), 'requires device-tree-compiler')
    def test_forwarding_dry_run_passes_canonical_rules_without_starting_guest(self):
        result = self.invoke('--dry-run', '--hostfwd=tcp:02222:00022', '--hostfwd=tcp:2223:80')
        command = json.loads(result.stdout)['command']
        self.assertIn('--hostfwd=tcp:2222:22', command)
        self.assertIn('--hostfwd=tcp:2223:80', command)
        self.assertFalse((self.state / 'child.json').exists())

    @unittest.skipUnless(shutil.which('dtc') and shutil.which('fdtget'), 'requires device-tree-compiler')
    def test_dry_run_generated_tree_matches_machine_and_does_not_launch(self):
        append = 'console=ttyS0 root=/dev/vda ro init="/init" test=\\path'
        result = self.invoke('--dry-run', '--harts', '4', '--isa-profile', 'rva23',
                             '--disk', str(self.disk), '--disk-mode', 'readonly', '--append', append)
        plan = json.loads(result.stdout)
        self.assertTrue(plan['dry_run'])
        self.assertFalse((self.state / 'child.json').exists())
        self.assertEqual(self.disk.read_bytes(), bytes(1024))
        self.assertEqual(stat_mode(self.state), 0o700)

        def prop(node, name, kind='s'):
            return subprocess.check_output(['fdtget', '-t', kind, str(self.state / 'machine.dtb'),
                                            node, name], text=True).strip()

        self.assertEqual(prop('/chosen', 'bootargs'), append)
        self.assertEqual(prop('/memory@80000000', 'reg', 'x'), '0 80000000 0 40000000')
        self.assertEqual(prop('/cpus/cpu@3', 'reg', 'i'), '3')
        self.assertEqual(len(prop('/soc/clint@2000000', 'interrupts-extended', 'i').split()), 16)
        self.assertIn('zvbb', prop('/cpus/cpu@3', 'riscv,isa-extensions'))
        self.assertEqual(prop('/soc/virtio@10001000', 'interrupts', 'i'), '1')
        self.assertEqual(prop('/poweroff', 'compatible'), 'syscon-poweroff')

    @unittest.skipUnless(shutil.which('dtc'), 'requires device-tree-compiler')
    def test_child_return_code_private_cwd_and_no_overwrite(self):
        result = subprocess.run(self.command, cwd=self.directory, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(json.loads((self.state / 'result.json').read_text()), {'returncode': 7})
        child = json.loads((self.state / 'child.json').read_text())
        self.assertEqual(child['argv'][-1], str(self.firmware))
        self.assertNotIn('virtio@10001000', (self.state / 'machine.dts').read_text())
        original = (self.state / 'run.json').read_bytes()
        self.invoke('--dry-run', success=False)
        self.assertEqual((self.state / 'run.json').read_bytes(), original)

    @unittest.skipUnless(shutil.which('dtc'), 'requires device-tree-compiler')
    def test_termination_is_forwarded_to_child(self):
        self.write_binary('time.sleep(60)')
        process = subprocess.Popen(self.command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not (self.state / 'child.json').exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.state / 'child.json').exists())
            child = json.loads((self.state / 'child.json').read_text())
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(child['pid'], 0)
            self.assertEqual(json.loads((self.state / 'result.json').read_text()), {'returncode': 143})
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_profile_extensions_track_the_existing_rva23_platform(self):
        import re
        source = (ROOT / 'linux/dts/spike-rva23-nemu.dts').read_text()
        extensions = re.search(r'riscv,isa-extensions\s*=([^;]+);', source).group(1)
        self.assertEqual(re.findall(r'"([^"]+)"', extensions), LAUNCHER.RVA23_EXTENSIONS)


def stat_mode(path):
    return path.stat().st_mode & 0o777


if __name__ == '__main__':
    unittest.main()
