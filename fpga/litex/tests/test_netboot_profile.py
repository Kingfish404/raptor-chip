"""Fixed-profile command expansion only; never invoke Vivado or the real submake."""
import pathlib
import shlex
import subprocess
import sys
import tempfile
import unittest


LITEX = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / 'scripts'))
from netboot_flow import lock


class NetbootProfileTest(unittest.TestCase):
    def test_help_declarations(self):
        text = (LITEX / "Makefile").read_text()
        for xlen in (32, 64):
            for operation in ("build", "load", "info", "check", "bundle", "serve", "test", "console"):
                self.assertIn(f"fpga-netboot-rv{xlen}-{operation}: ## ", text)

    def test_removed_run_is_rejected_for_both_architectures(self):
        for bits in (32, 64):
            result = subprocess.run(['make', '-n', f'fpga-netboot-rv{bits}-run'],
                                    cwd=LITEX, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Use only fpga-netboot targets', result.stderr)
            result = subprocess.run([sys.executable, str(LITEX / 'scripts/netboot_flow.py'),
                                     'run', '--xlen', str(bits), '--root', '/tmp/unused', '--'],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('invalid choice', result.stderr)

    def expand(self, target, *overrides, with_root=False):
        result = subprocess.run(
            ["make", "--no-print-directory", "-n", "MAKE=echo", target, *overrides],
            cwd=LITEX, text=True, capture_output=True, check=True,
        )
        calls = []
        for line in result.stdout.replace("\\\n", " ").splitlines():
            words = shlex.split(line)
            if len(words) > 2 and words[1].endswith("/scripts/netboot_flow.py"):
                split = words.index("--")
                settings = dict(w.split("=", 1) for w in words[split + 1:])
                if with_root:
                    settings['root'] = words[words.index('--root') + 1]
                    settings['state_root'] = words[words.index('--state-root') + 1]
                calls.append((words[2], settings))
        return calls

    def test_config_isolation(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-netboot-', dir='/tmp') as tmp:
            for xlen in (32, 64):
                locks = []
                for config in ('default', 'small', 'middle'):
                    overrides = (f'RAPT_CONFIG={config}', f'VARIANT=linux{xlen}',
                                 'FPGA_BOARD=mlk_cu08_ku15p')
                    settings = self.expand(f'fpga-netboot-rv{xlen}-build', *overrides,
                                           with_root=True)[0][1]
                    root = LITEX / 'build' / f'netboot-{config}'
                    self.assertEqual(settings['root'], str(root))
                    self.assertEqual(settings['RAPT_CONFIG'], config)
                    self.assertEqual(settings['FPGA_FLAVOR_SUFFIX'], f'{config}-no-ila')
                    self.assertEqual(settings['BUILD_DIR'], str(root / f'rv{xlen}/build'))
                    self.assertEqual(settings['FPGA_DIR'], str(root / f'rv{xlen}/soc'))
                    for operation in ('load', 'info', 'check', 'bundle', 'serve', 'test', 'console'):
                        self.assertEqual(self.expand(f'fpga-netboot-rv{xlen}-{operation}',
                                                     *overrides, with_root=True)[0][1], settings)
                    locks.append(pathlib.Path(tmp) / root.name / f'rv{xlen}/netboot/workflow.lock')
                with lock(locks[0]), lock(locks[1]), lock(locks[2]):
                    with self.assertRaisesRegex(RuntimeError, 'Busy:'):
                        with lock(locks[0]):
                            pass

    def test_invalid_config(self):
        for config in ('', 'missing-preset', 'default small', '../default'):
            with self.subTest(config=config), self.assertRaises(subprocess.CalledProcessError):
                self.expand('fpga-netboot-rv64-build', f'RAPT_CONFIG={config}')

    def test_netboot_build_cannot_enable_autoboot(self):
        for bits in (32, 64):
            target = f'fpga-netboot-rv{bits}-build'
            for config in ('small', 'middle', 'default'):
                with self.subTest(bits=bits, config=config):
                    calls = self.expand(target, f'RAPT_CONFIG={config}')
                    self.assertEqual(len(calls), 1)
                    operation, settings = calls[0]
                    self.assertEqual(operation, 'build')
                    self.assertEqual(settings['BOOT_MODE'], 'bios')
                    self.assertEqual(settings['EXTRA_FLAGS'], '')
                    with self.assertRaises(subprocess.CalledProcessError) as error:
                        self.expand(target, f'RAPT_CONFIG={config}',
                                    'EXTRA_FLAGS=--sdcard-autoboot')
                    self.assertIn('conflicts with netboot', error.exception.stderr)

    def test_conflicting_fixed_settings_fail(self):
        for setting in ('FPGA_BOARD=xilinx_vcu118', 'BOARD=mlk_cu07_ku15p',
                        'VARIANT=linux32', 'VARIANT=', 'SYS_CLK=75000000',
                        'WITH_ETHERNET=0', 'BOOT_MODE=custom',
                        'RAPT_PACK_VFLAGS=-DRAPT_ROB_SIZE=8'):
            with self.subTest(setting=setting), self.assertRaises(subprocess.CalledProcessError) as error:
                self.expand('fpga-netboot-rv64-build', setting)
            self.assertIn('conflicts with netboot', error.exception.stderr)

    def test_custom_roots_isolate_presets_and_share_host_state(self):
        for config in ('default', 'small'):
            settings = self.expand('fpga-netboot-rv64-info', f'RAPT_CONFIG={config}',
                                   'NETBOOT_BUILD_ROOT=/tmp/netboot-custom',
                                   'CROSS=/opt/riscv/bin/riscv64-linux-gnu-',
                                   'VIVADO_JOBS=4', with_root=True)[0][1]
            self.assertEqual(settings['root'], f'/tmp/netboot-custom/{config}')
            self.assertEqual(settings['state_root'], str(LITEX / 'build/netboot-default'))
            self.assertEqual(settings['CROSS'], '/opt/riscv/bin/riscv64-linux-gnu-')
            self.assertEqual(settings['VIVADO_JOBS'], '4')

    def test_host_restore_independent_of_hardware_profile(self):
        self.assertEqual(self.expand('fpga-netboot-host-restore', 'RAPT_CONFIG=removed-preset',
                                     'VARIANT=linux32', 'FPGA_BOARD=removed-board'), [('host-restore', {})])

    def test_build_load_info_same_profile(self):
        for xlen in (32, 64):
            with self.subTest(xlen=xlen):
                prefix = f"fpga-netboot-rv{xlen}-"
                build = self.expand(prefix + "build")
                load = self.expand(prefix + "load")
                info = self.expand(prefix + "info")
                self.assertEqual([c[0] for c in load], ["load"])
                settings = build[0][1]
                self.assertEqual(build[0][0], "build")
                for _, args in load + info:
                    self.assertEqual(args, settings)
                for operation in ("check", "bundle", "serve", "test", "console"):
                    self.assertEqual(self.expand(prefix + operation)[0][1], settings)
                self.assertEqual(settings["VARIANT"], f"linux{xlen}")
                self.assertEqual(settings["WITH_ETHERNET"], "1")
                self.assertEqual(settings["EXTRA_FLAGS"], "")
                self.assertEqual(settings["VIVADO_ROUTE_DIRECTIVE"], "Explore")
                self.assertEqual(settings["SYS_CLK"], "50000000")
                self.assertEqual(settings["RAPT_CONFIG"], "default")
                self.assertEqual(settings["RAPT_PACK_VFLAGS"], "")
                self.assertIn(f"/rv{xlen}/soc", settings["FPGA_DIR"])

    def test_paths_and_fixed_settings(self):
        calls = self.expand("fpga-netboot-rv32-build",
                            "NETBOOT_BUILD_ROOT=/tmp/netboot path",
                            "NETBOOT_PAYLOAD_RV32=/tmp/payload path/fw.bin",
                            "WITH_ETHERNET=1", "VIVADO=/opt/tool path/vivado")
        settings = calls[0][1]
        self.assertEqual(settings["WITH_ETHERNET"], "1")
        self.assertEqual(settings["FPGA_DIR"], "/tmp/netboot path/default/rv32/soc")
        self.assertEqual(settings["LINUX_IMG"], "/tmp/payload path/fw.bin")
        self.assertEqual(settings["VIVADO"], "/opt/tool path/vivado")


if __name__ == "__main__":
    unittest.main()
