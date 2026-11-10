"""Check ext4 -> newc metadata without root, mounts, or real TFTP writes."""
import gzip
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from netboot_distro import (background_services, export_rootfs, persistence_bootargs,
                           require_linux_ram, require_ram_root)
from netboot_distro_publish import publish


class DistroTest(unittest.TestCase):
    def test_arty_ram_and_existing_rv32_rv64_limits(self):
        for bits, size in ((32, 0x10000000), (64, 0x10000000),
                           (32, 0x40000000), (64, 0x80000000)):
            with self.subTest(bits=bits, size=size), patch(
                    'netboot_distro.run', return_value=f'80000000 {size:x}'.encode()):
                self.assertEqual(require_linux_ram(Path('soc.dtb'), bits), size)
        for bits, value in ((32, b'80000000 80000000'), (64, b'80000000 100000000'),
                            (32, b'80000000 8000000'), (64, b'81000000 10000000')):
            with self.subTest(bits=bits, value=value), patch(
                    'netboot_distro.run', return_value=value), self.assertRaises(ValueError):
                require_linux_ram(Path('soc.dtb'), bits)

    def test_small_ram_root_checks_both_download_and_expansion(self):
        mib = 1024 * 1024
        require_ram_root(256 * mib, 32 * mib, 32 * mib)
        require_ram_root(256 * mib, 30 * mib, 112 * mib)
        with self.assertRaisesRegex(ValueError, 'exceeds FPGA RAM'):
            require_ram_root(256 * mib, 129 * mib, 1 * mib)
        with self.assertRaisesRegex(ValueError, 'headroom'):
            require_ram_root(256 * mib, 100 * mib, 100 * mib)
        require_ram_root(1024 * mib, 349 * mib, 349 * mib)
        with self.assertRaisesRegex(ValueError, 'headroom'):
            require_ram_root(1024 * mib, 350 * mib, 350 * mib)

    def test_console_does_not_wait_for_network_or_host_keys(self):
        source = '''# Retry in background if no DHCP server is currently available; retain leases.
/bin/busybox udhcpc -b -i eth0 -s /etc/raptor-udhcpc.script
if command -v sshd >/dev/null; then
    mkdir -p /run/sshd
    ssh-keygen -A
    "$(command -v sshd)"
fi
echo 'Raptor distribution ready:'
'''
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='raptor-services-') as tmp:
            block = Path(tmp) / 'blocked-service'
            block.write_text('#!/bin/sh\nexec sleep 60\n')
            block.chmod(0o755)
            script = background_services(source)
            self.assertEqual(background_services(script), script)
            script = script.replace('/run/', tmp + '/').replace('/bin/busybox', str(block))
            script = script.replace('/etc/ssh/', tmp + '/keys/')
            script = script.replace('command -v sshd', 'command -v sh').replace('ssh-keygen', str(block))
            child = subprocess.Popen(['/bin/sh', '-c', script], stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
            try:
                out, err = child.communicate(timeout=3)
                self.assertEqual(child.returncode, 0, err)
                self.assertIn(b'Raptor distribution ready:', out)
            finally:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()

    def test_data_selector_cannot_inject_other_kernel_options(self):
        self.assertEqual(persistence_bootargs('LABEL=RAPTOR_DATA'), '')
        self.assertEqual(persistence_bootargs('UUID=abcd-1234', True),
                         ' raptor.data=UUID=abcd-1234 raptor.persist_logs=1')
        for selector in ('/dev/vda', 'LABEL=', 'UUID=abc init=/bin/sh', 'LABEL=../root'):
            with self.assertRaisesRegex(ValueError, 'selector'):
                persistence_bootargs(selector)

    @unittest.skipUnless(shutil.which('mke2fs') and shutil.which('debugfs'), 'requires e2fsprogs')
    def test_ext4_metadata_and_console_survive_ram_conversion(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-distro-test-', dir='/tmp') as tmp:
            work = Path(tmp)
            source = work / 'source'
            (source / 'etc').mkdir(parents=True)
            (source / 'etc/inittab').write_text('ttyS0::askfirst:-/bin/sh\n')
            (source / 'etc/shadow').write_text('fixture\n')
            (source / 'etc/link').symlink_to('/etc/shadow')
            disk = work / 'root.ext4'
            subprocess.run(['mke2fs', '-q', '-t', 'ext4', '-d', str(source), str(disk), '8192'],
                           check=True, capture_output=True)
            for field, value in [('uid', '123'), ('gid', '42'), ('mode', '0104640')]:
                subprocess.run(['debugfs', '-w', '-R', f'set_inode_field /etc/shadow {field} {value}',
                                str(disk)], check=True, capture_output=True)
            root = work / 'root'
            root.mkdir()
            export_rootfs(disk, root, work)
            raw = gzip.decompress((work / 'rootfs.cpio.gz').read_bytes())
            entries = {}
            offset = 0
            while True:
                self.assertEqual(raw[offset:offset + 6], b'070701')
                fields = [int(raw[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
                name = raw[offset + 110:offset + 110 + fields[11] - 1].decode()
                offset = (offset + 110 + fields[11] + 3) & ~3
                data = raw[offset:offset + fields[6]]
                offset = (offset + fields[6] + 3) & ~3
                if name == 'TRAILER!!!':
                    break
                entries[name] = (fields, data)
            fields, data = entries['etc/shadow']
            self.assertEqual(fields[1:4], [0o104640, 123, 42])
            self.assertEqual(data, b'fixture\n')
            self.assertEqual(entries['etc/link'][1], b'/etc/shadow')
            self.assertEqual(entries['etc/inittab'][1], b'::askfirst:-/bin/sh\n')
            # An embedded initramfs needs these before init mounts devtmpfs.
            self.assertEqual(entries['dev/console'][0][1], 0o20600)
            self.assertEqual(entries['dev/console'][0][9:11], [5, 1])
            self.assertEqual(entries['dev/null'][0][9:11], [1, 3])

    def test_wrong_architecture_and_traversal_rejected_before_publication(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-distro-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            record = {'schema': 'raptor-distro-netboot-v1', 'xlen': 16}
            (root / 'bundle.json').write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'RV64'):
                publish(root)
            record.update(xlen=64, distro='alpine', tftp_path='raptor-netboot/rv64/../boot.json')
            (root / 'bundle.json').write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'namespace'):
                publish(root)
            record['tftp_path'] = 'raptor-netboot/rv64/alpine-' + '0' * 20
            (root / 'bundle.json').write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'CMO'):
                publish(root)


if __name__ == '__main__':
    unittest.main()
