"""Host contract tests; no downloads, shared simulator configs or board operations."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from build_linux import build, overlay, verify
from raptor_linux import HOME, kernel, sha


class LinuxTest(unittest.TestCase):
    def test_kernel_source_major_matches_archive_path(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-source-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            (root / 'kernel.config').write_text('CONFIG_MMU=y\n')
            cached = root / 'cache/key'
            cached.mkdir(parents=True)
            (cached / 'built.json').write_text('{}')
            for version in ('6.18.52', '7.2.6'):
                source = root / 'kernel-source.json'
                source.write_text(json.dumps({'version': version, 'sha256': '0' * 64,
                    'archive_url': f'https://cdn.kernel.org/pub/linux/kernel/v{version.split(".")[0]}.x/linux-{version}.tar.xz'}))
                (root / 'manifest.json').write_text(json.dumps({'kernel_version': version,
                    'files': {name: sha(root / name) for name in ('kernel.config', 'kernel-source.json')}}))
                with patch('raptor_linux.run', return_value=b'test compiler'), patch('raptor_linux.identity', return_value='key'):
                    self.assertEqual(kernel(root, root / 'cache', 'test-'), cached)
            data = json.loads(source.read_text())
            data['archive_url'] = data['archive_url'].replace('/v7.x/', '/v6.x/')
            source.write_text(json.dumps(data))
            record = json.loads((root / 'manifest.json').read_text())
            record['files']['kernel-source.json'] = sha(source)
            (root / 'manifest.json').write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'source URL'):
                kernel(root, root / 'cache', 'test-')

    def test_artifact_tamper_and_path_traversal(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-linux-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            (root / 'Image').write_bytes(b'kernel')
            record = {'files': {'Image': sha(root / 'Image')}}
            (root / 'manifest.json').write_text(json.dumps(record))
            verify(root)
            (root / 'Image').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'changed'):
                verify(root)
            record['files'] = {'../outside': '0' * 64}
            (root / 'manifest.json').write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'changed'):
                verify(root)

    def test_rv32_rejects_rv64_distro_before_build(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-linux-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            (root / 'manifest.json').write_text(json.dumps({'bits': 32}))
            with self.assertRaisesRegex(ValueError, 'RV64GC'):
                build(root, 32, 'alpine', 'fpga', root / 'out', root / 'cache', 'no-compiler-')

    def test_kernel_profile_requires_correct_rootfs_contract(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-linux-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            (root / 'manifest.json').write_text('{}')
            for profile, rootfs in (('sim', None), ('fpga', root / 'rootfs.cpio')):
                with self.assertRaisesRegex(ValueError, 'initramfs'):
                    kernel(root, root / 'cache', 'no-compiler-', profile, rootfs)

    def test_fpga_kernel_requests_cache_maintenance_for_both_xlens(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-dma-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            cached = root / 'cache/key'
            cached.mkdir(parents=True)
            (cached / 'built.json').write_text('{}')
            for bits in (32, 64):
                (root / 'kernel.config').write_text(f'CONFIG_{bits}BIT=y\n# CONFIG_RISCV_ISA_ZICBOM is not set\n')
                source = {'version': '6.18.51', 'sha256': '0' * 64,
                          'archive_url': 'https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.51.tar.xz'}
                (root / 'kernel-source.json').write_text(json.dumps(source))
                (root / 'manifest.json').write_text(json.dumps({'kernel_version': source['version'],
                    'files': {name: sha(root / name) for name in ('kernel.config', 'kernel-source.json')}}))
                with patch('raptor_linux.run', return_value=b'compiler'), patch('raptor_linux.identity', return_value='key') as key:
                    kernel(root, root / 'cache', 'test-', 'fpga')
                    options = key.call_args.args[0][3]
                    self.assertIn('RISCV_ALTERNATIVE', options)
                    self.assertIn('RISCV_ISA_ZICBOM', options)
                    self.assertIn('FTRACE', options)
                    self.assertIn('ENABLE_DEFAULT_TRACERS', options)
                    disabled = key.call_args.args[0][4]
                    self.assertNotIn('FTRACE', disabled)
                    self.assertIn('FUNCTION_TRACER', disabled)

    def test_overlay_alignment_and_executable_init(self):
        data = overlay(b'base', {'sbin/raptor-init': b'#!/bin/sh\n'})
        self.assertEqual(data[:4], b'base')
        self.assertEqual(data[4:10], b'070701')
        self.assertEqual(int(data[18:26], 16), 0o100755)
        self.assertEqual(len(data) % 4, 0)
        self.assertIn(b'TRAILER!!!\0', data)

    def test_netboot_rejects_kernel_without_cache_maintenance(self):
        from pack_netboot import pack
        with tempfile.TemporaryDirectory(prefix='raptor-chip-pack-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            options = ('MMC_LITEX', 'MMC_BLOCK', 'EXT4_FS', 'REGULATOR_FIXED_VOLTAGE',
                       'SERIAL_LITEUART_CONSOLE', 'LITEX_LITEETH', 'BLK_DEV_INITRD',
                       'RISCV_DMA_NONCOHERENT')
            (root / 'kernel.config').write_text(''.join(f'CONFIG_{v}=y\n' for v in options))
            for bits in (32, 64):
                with patch('pack_netboot.verify', return_value={'profile': 'fpga', 'bits': bits}), \
                     patch('pack_netboot.run', side_effect=[f'rv{bits}i'.encode(), b'80000000 40000000']):
                    with self.assertRaisesRegex(ValueError, 'RISCV_ISA_ZICBOM'):
                        pack(root, root / 'soc.dtb', root / 'csr.json', root / 'bundle')

    def test_make_architecture_profile_and_output(self):
        for bits, distro in ((32, 'buildroot'), (64, 'alpine')):
            for profile in ('sim', 'fpga'):
                text = subprocess.check_output(['make', '--no-print-directory', '-n',
                                                f'build-rv{bits}-{profile}'], cwd=HOME, text=True)
                self.assertIn(f'--xlen {bits} --distro {distro} --profile {profile}', text)
                self.assertIn(f'rv{bits}-{distro}-{profile}', text)
                self.assertNotIn('build-rv32-linux', text)


if __name__ == '__main__':
    unittest.main()
