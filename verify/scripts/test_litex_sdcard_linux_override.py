"""Regression checks for per-build Linux BIOS data and legacy patch refresh."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'fpga/litex/scripts/patch_litex_sdcard_linux_override.py'
spec = importlib.util.spec_from_file_location('linux_bios_patch', SCRIPT)
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class LinuxBiosOverrideTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.boot = self.root / 'litex/soc/software/bios/boot.c'
        self.boot.parent.mkdir(parents=True)
        self.original = '// keep local edits\n' + patch.INCLUDE_ANCHOR + '\n' + patch.BOOT_ANCHOR
        self.boot.write_text(self.original)
        (self.boot.parent / 'Makefile').write_text('# private package fixture\n')
        self.stage = self.root / 'stage.bin'
        self.stage.write_bytes(b'stage0-original')
        self.payload = self.root / 'payload.bin'
        self.payload.write_bytes(struct.pack('<III', patch.encode_lui_a1(0x100000),
                                            patch.RISCV_ADD_A0_A0_A1, patch.RISCV_RET))
        self.dtb = self.root / 'linux.dtb'
        self.set_dtb(b'small-cbom16')

    def set_dtb(self, body):
        # The embedder treats DTB contents as opaque bytes after its header checks.
        body = bytes(32) + body
        self.dtb.write_bytes(struct.pack('>II', patch.FDT_MAGIC, len(body) + 8) + body)

    def run_patch(self, output=None, dtb_offset='0x04000000'):
        command = [sys.executable, str(SCRIPT), str(self.root), str(self.stage),
                   str(self.dtb), str(self.payload), '0x00100000', dtb_offset,
                   '0x83f00000', '0x80000000']
        if output is not None:
            command += ['--output-dir', str(output)]
        return subprocess.run(command, text=True, capture_output=True)

    def assert_embedded(self, source):
        self.assertIn(patch.c_array('raptor_linux_dtb', self.dtb.read_bytes()), source)
        self.assertIn(patch.c_array('raptor_linux_stage0', self.stage.read_bytes()), source)
        self.assertEqual(source.count(patch.PATCHED_BOOT), 1)
        self.assertIn('// keep local edits', source)

    def test_private_builds_keep_distinct_payloads_and_upstream_edits(self):
        small = self.root / 'small/bios-src'
        default = self.root / 'default/bios-src'
        self.assertEqual(self.run_patch(small).returncode, 0)
        small_source = (small / 'boot.c').read_text()
        self.assert_embedded(small_source)
        self.set_dtb(b'default-cbom64')
        self.stage.write_bytes(b'stage0-current')
        self.assertEqual(self.run_patch(default).returncode, 0)
        self.assert_embedded((default / 'boot.c').read_text())
        self.assertEqual((small / 'boot.c').read_text(), small_source)
        self.assertEqual(self.boot.read_text(), self.original)
        self.assertEqual((default / 'Makefile').read_text(), '# private package fixture\n')

    def test_refresh_legacy_patch_and_idempotent_regeneration(self):
        self.assertEqual(self.run_patch().returncode, 0)
        # Reproduce an older shared checkout with the previous marker format.
        self.boot.write_text(self.boot.read_text().replace(patch.END_MARKER, ''))
        self.set_dtb(b'default-cbom64')
        self.stage.write_bytes(b'new-stage0')
        self.assertEqual(self.run_patch(dtb_offset='0x02000000').returncode, 0)
        updated = self.boot.read_text()
        self.assert_embedded(updated)
        self.assertIn('MAIN_RAM_BASE_VA + 0x02000000UL', updated)
        self.assertEqual(self.run_patch(dtb_offset='0x02000000').returncode, 0)
        self.assertEqual(self.boot.read_text(), updated)

    def test_incomplete_patch_is_rejected_without_overwriting(self):
        broken = self.original + '\n/* ' + patch.MARKER + ' */\n'
        self.boot.write_text(broken)
        result = self.run_patch(self.root / 'candidate/bios-src')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.boot.read_text(), broken)
        self.assertFalse((self.root / 'candidate/bios-src').exists())

    def test_bios_changes_invalidate_bitstream_and_block_load(self):
        litex_dir = SCRIPT.parent.parent
        makefile = self.root / 'build.mk'
        stamp = self.root / 'stamp'
        loaded = self.root / 'loaded'
        bitstream = self.root / 'image.bit'
        bitstream.write_bytes(b'old bitstream')
        makefile.write_text(f'''SHELL := /bin/bash
LITEX_DIR := {litex_dir}
LITEX_PATH := {self.root}
LITEX_CONFIG_PHASE := fpga
BOOT_MODE := bios
FPGA_BOARD := mlk_cu08_ku15p
VARIANT := linux32
RAPT_CONFIG := default
include {litex_dir}/mk/config.mk
include {litex_dir}/mk/recipes.mk
FPGA_STAMP := {stamp}
FPGA_BITSTREAM := {bitstream}
FPGA_LOAD_TOOL_CHECK := true
FPGA_LOAD_CMD := touch {loaded}
_run_litex_target = true
.PHONY: fingerprint
fingerprint:
\t@$(_FPGA_HASH_COMMAND)
''')

        def run(target):
            return subprocess.run(['make', '--no-print-directory', '-f',
                                   str(makefile), target], cwd=self.root,
                                  text=True, capture_output=True)

        def fingerprint():
            result = run('fingerprint')
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

        original_hash = fingerprint()
        stamp.write_text(original_hash)
        result = run('fpga-load')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(loaded.exists())
        loaded.unlink()
        (self.boot.parent / 'main.c').write_text('// changed boot sequence\n')
        self.assertNotEqual(fingerprint(), original_hash)
        result = run('fpga-load')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Refusing to program', result.stdout)
        self.assertFalse(loaded.exists())

        stamp.write_text(fingerprint())
        result = run('fpga-gen')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stamp.exists())
        self.assertTrue(bitstream.exists())
        self.assertNotEqual(run('fpga-load').returncode, 0)
        self.assertFalse(loaded.exists())

        # A failed rebuild must not leave the previous image marked current.
        stamp.write_text('stale')
        result = subprocess.run(
            ['make', '--no-print-directory', '-f', str(makefile), 'fpga-build',
             'FPGA_VENDOR=vivado', 'VIVADO=true', f'FPGA_DIR={self.root}',
             '_run_litex_target=false'], cwd=self.root,
            text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(stamp.exists())
        self.assertTrue(bitstream.exists())


class SimulationCompileTests(unittest.TestCase):
    def test_compile_parallelism_is_bounded_and_independent_of_threads(self):
        directory = SCRIPT.parent.parent
        def flags(*options):
            return subprocess.run(
                ['make', '-s', '-C', str(directory), 'show-sim-flags',
                 '--eval=show-sim-flags:;@echo $(_BASE_FLAGS)',
                 'RAPT_CONFIG=default', *options], capture_output=True, text=True)
        default = flags('NPROC=64')
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertIn('--jobs=4', default.stdout)
        limited = flags('SIM_JOBS=2', 'SIM_THREADS=1')
        self.assertEqual(limited.returncode, 0, limited.stderr)
        self.assertIn('--jobs=2', limited.stdout)
        self.assertIn('--threads=1', limited.stdout)
        for invalid in ('0', '', '-1', 'invalid'):
            self.assertNotEqual(flags(f'SIM_JOBS={invalid}').returncode, 0)

    def test_failed_build_cannot_publish_or_reuse_success_stamp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            recipes = SCRIPT.parent.parent / 'mk/recipes.mk'
            makefile = root / 'Makefile'
            makefile.write_text(f'''SHELL := /bin/bash
include {recipes}
.PHONY: compile
compile:
\t$(call _compile_if_needed,{root})
''')
            (root / 'sim.v').write_text('module sim; endmodule\n')
            (root / 'obj_dir').mkdir()
            binary = root / 'obj_dir/Vsim'
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            stamp = root / '.sim_v_hash'
            stamp.write_text('previous build')
            build = root / 'build_sim.sh'
            build.write_text('exit 143\n')

            def run():
                return subprocess.run(['make', '-s', '-f', str(makefile), 'compile'],
                                      cwd=root, capture_output=True, text=True)

            failed = run()
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(stamp.exists())
            self.assertNotIn('compilation complete', failed.stdout)
            self.assertNotEqual(run().returncode, 0)
            build.write_text('echo built >> attempts\n')
            self.assertEqual(run().returncode, 0)
            self.assertTrue(stamp.exists())
            cached = run()
            self.assertEqual(cached.returncode, 0)
            self.assertIn('skipping compilation', cached.stdout)
            self.assertEqual((root / 'attempts').read_text(), 'built\n')
            binary.unlink()
            missing = run()
            self.assertNotEqual(missing.returncode, 0)
            self.assertFalse(stamp.exists())


if __name__ == '__main__':
    unittest.main()
