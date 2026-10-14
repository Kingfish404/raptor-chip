"""Distribution image geometry and isolated simulator configuration checks."""
import json
import struct
import subprocess
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from distro_boot import build_dtb, build_nemu, check, download, extract_partition, ext4_partition, HOME, SOURCES, verdict


class DistroBootTest(unittest.TestCase):
    def test_check_removes_stale_result_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'debian'
            directory.mkdir()
            result = directory / 'nemu-result.json'
            result.write_text('{"passed": true}')
            (directory / 'manifest.json').write_text(json.dumps({
                'files': {}, 'nemu': str(directory / 'nemu'), 'nemu_sha256': 'digest'}))
            args = SimpleNamespace(work=Path(temporary), distro='debian', action='check', engine='nemu')
            with patch('distro_boot.sha', return_value='digest'), \
                    patch('distro_boot.subprocess.Popen', side_effect=FileNotFoundError):
                with self.assertRaises(FileNotFoundError):
                    check(args)
            self.assertFalse(result.exists())

    def test_verdict_requires_distro_checks_and_clean_shutdown(self):
        log = b'RAPTOR_DISTRO_ID=debian VERSION_ID=13\nRAPTOR_FP_PASS\nRAPTOR_DISTRO_CHECK_PASS\nreboot: Power down\n'
        self.assertTrue(verdict(log, 0, 'debian'))
        self.assertFalse(verdict(log, 1, 'debian'))
        self.assertFalse(verdict(log, 0, 'ubuntu'))
        self.assertFalse(verdict(log.replace(b'reboot: Power down', b''), 0, 'debian'))
        for fault in (b'Kernel panic', b'Oops: trap', b'unhandled signal', b'RAPTOR_DISTRO_CHECK_FAIL',
                      b'Power off not available', b'rcu: INFO: detected stalls'):
            self.assertFalse(verdict(log + fault, 0, 'debian'))
        self.assertFalse(verdict(log, 0, 'debian', 2))
        self.assertTrue(verdict(log + b'RAPTOR_SMP_PASS harts=2 operations=4000\n', 0, 'debian', 2))
        self.assertFalse(verdict(log + b'RAPTOR_SMP_PASS harts=4 operations=8000\n', 0, 'debian', 2))

    def test_smp_dtb_has_matching_cpu_and_interrupt_topology(self):
        for harts in (1, 2, 3, 4):
            with self.subTest(harts=harts), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                build_dtb(directory, harts)
                dtb = directory / 'nemu.dtb'
                def get(node, name, kind='x'):
                    return subprocess.check_output(['fdtget', '-t', kind, dtb, node, name]).split()
                nodes = subprocess.check_output(['fdtget', '-l', dtb, '/cpus']).split()
                self.assertEqual(len(nodes), harts)
                handles = []
                for hartid in range(harts):
                    node = f'/cpus/cpu@{hartid}'
                    self.assertEqual(get(node, 'reg'), [f'{hartid:x}'.encode()])
                    self.assertEqual(get(node, 'riscv,isa', 's'), get('/cpus/cpu@0', 'riscv,isa', 's'))
                    handles.append(get(node + '/interrupt-controller', 'phandle')[0])
                self.assertEqual(len(set(handles)), harts)
                self.assertEqual(get('/soc/clint@2000000', 'interrupts-extended'),
                                 [value for handle in handles for value in (handle, b'3', handle, b'7')])
                self.assertEqual(get('/soc/plic@c000000', 'interrupts-extended'),
                                 [value for handle in handles for value in (handle, b'b', handle, b'9')])

    def test_dtb_matches_ram_disk_irq_and_poweroff_register(self):
        with tempfile.TemporaryDirectory() as temporary:
            dtb = Path(temporary) / 'nemu.dtb'
            subprocess.run(['/usr/bin/dtc', '-I', 'dts', '-O', 'dtb', '-i', HOME / 'dts',
                            '-o', dtb, HOME / 'dts/nemu-distro-rv64.dts'], check=True)
            def get(node, property_name):
                return subprocess.check_output(['fdtget', '-t', 'x', dtb, node, property_name]).strip()
            self.assertEqual(get('/memory@80000000', 'reg'), b'0 80000000 0 40000000')
            self.assertEqual(get('/soc/virtio_blk@10001000', 'interrupts'), b'1')
            self.assertEqual(get('/poweroff', 'regmap'), get('/soc/test@100000', 'phandle'))
            self.assertEqual(get('/poweroff', 'value'), b'5555')

    def image(self, path, partitions):
        data = bytearray(65536)
        data[512:520] = b'EFI PART'
        struct.pack_into('<QII', data, 584, 2, len(partitions), 128)
        for index, (first, last) in enumerate(partitions):
            offset = 1024 + index * 128
            data[offset:offset + 16] = bytes([1]) * 16
            struct.pack_into('<QQ', data, offset + 32, first, last)
            if first * 512 + 1082 <= len(data):
                data[first * 512 + 1080:first * 512 + 1082] = b'\x53\xef'
        path.write_bytes(data)

    def test_partition_extraction_keeps_exact_extent(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            raw = directory / 'cloud.raw'
            disk = directory / 'root.ext4'
            self.image(raw, [(8, 63)])
            self.assertEqual(ext4_partition(raw), (4096, 28672))
            extract_partition(raw, disk)
            self.assertEqual(disk.read_bytes(), raw.read_bytes()[4096:32768])

    def test_rejects_ambiguous_and_out_of_bounds_partitions(self):
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / 'cloud.raw'
            for partitions, message in (([(8, 31), (64, 95)], 'exactly one'),
                                         ([(8, 999)], 'outside')):
                self.image(raw, partitions)
                with self.assertRaisesRegex(ValueError, message):
                    ext4_partition(raw)

    def test_download_rejects_cached_image_with_wrong_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / SOURCES['debian']['url'].rsplit('/', 1)[1]
            archive.write_bytes(b'not the official image')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'), patch('distro_boot.run') as run:
                download('debian', directory)
            run.assert_not_called()

    def test_private_nemu_build_enables_disk_and_matching_ram(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch('distro_boot.run') as run:
                binary = build_nemu(directory)
            config = (directory / 'distro_defconfig').read_text()
            self.assertIn('CONFIG_HAS_DISK=y', config)
            self.assertIn('CONFIG_MSIZE=0x40000000', config)
            self.assertEqual(binary, directory / 'build/riscv64-nemu-interpreter')
            self.assertTrue(all(call.kwargs['cwd'] == directory for call in run.call_args_list))

    def test_private_build_needs_no_smp_kconfig(self):
        for xlen in (32, 64):
            with tempfile.TemporaryDirectory() as temporary, patch('distro_boot.run'):
                directory = Path(temporary)
                binary = build_nemu(directory, xlen=xlen)
                self.assertNotIn('CONFIG_SMP', (directory / 'distro_defconfig').read_text())
                self.assertEqual(binary.name, f'riscv{xlen}-nemu-interpreter')

    def test_runtime_backend_overrides_manifest_without_rebuilding(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'debian'
            directory.mkdir()
            (directory / 'manifest.json').write_text(json.dumps({
                'files': {}, 'nemu': '/prepared/nemu', 'nemu_sha256': 'digest',
                'harts': 4, 'nemu_backend': 'rr'}))
            args = SimpleNamespace(work=Path(temporary), distro='debian', action='check',
                                   engine='nemu', nemu_backend='threaded', nemu_clock_div=32)
            with patch('distro_boot.sha', return_value='digest'), \
                    patch('distro_boot.subprocess.Popen', side_effect=FileNotFoundError) as launch:
                with self.assertRaises(FileNotFoundError):
                    check(args)
            command = launch.call_args.args[0]
            self.assertIn('--smp=4', command)
            self.assertIn('--smp-backend=threaded', command)
            self.assertIn('--smp-clock-div=32', command)

    def test_sanitizer_build_keeps_flags_private(self):
        with tempfile.TemporaryDirectory() as temporary, patch('distro_boot.run') as run:
            build_nemu(Path(temporary), sanitize='thread')
            command = run.call_args.args[0]
            flags = [str(item) for item in command if str(item).startswith('CFLAGS_BUILD=')]
            self.assertEqual(len(flags), 1)
            self.assertTrue(flags[0].startswith(
                'CFLAGS_BUILD=-O1 -g -fsanitize=thread -fno-omit-frame-pointer'))


if __name__ == '__main__':
    unittest.main()
