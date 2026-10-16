"""Boot a private ext4 root repeatedly to verify real Linux disk persistence."""

import json
from pathlib import Path
import shutil
import socket
import subprocess
import time

from lib.build import ROOT, build_dtb
from lib.console import run_console
from lib.harness import Check, parser, sha256


FAIL_MARKERS = (b'NEMU_STORAGE_FAIL', b'Kernel panic', b'Oops:', b'BUG:', b'EXT4-fs error')


def verdict(returncode, output, marker, timed_out=False, network=False):
    return (returncode == 0 and not timed_out and
            all(required in output for required in (marker, b'NEMU_STORAGE_LINUX_PASS', b'Finisher: poweroff')) and
            (not network or b'NEMU_NETWORK_PASS' in output) and
            not any(failure in output for failure in FAIL_MARKERS))


def network_round_trip(port, timeout):
    deadline = time.monotonic() + timeout
    def remaining():
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise TimeoutError('network round trip exceeded boot deadline')
        return seconds
    payload = bytes((index * 37 + 11) & 255 for index in range(8192))
    with socket.create_connection(('127.0.0.1', port), timeout=remaining()) as client:
        client.settimeout(remaining())
        client.sendall(payload)
        received = bytearray()
        while len(received) < len(payload):
            client.settimeout(remaining())
            part = client.recv(len(payload) - len(received))
            if not part:
                raise ValueError('TCP reply ended early')
            received.extend(part)
        if received != bytes(value ^ 0x5a for value in payload):
            raise ValueError('TCP reply mismatch')
        client.settimeout(remaining())
        client.sendall(b'K')


def main():
    arguments = parser(__doc__, repeat=1)
    arguments.set_defaults(xlen=[64])
    arguments.add_argument('--prepared', type=Path, required=True,
                           help='hash-verified RV64 firmware/kernel package from linux/distro_boot.py prepare')
    arguments.add_argument('--harts', type=int, choices=(1, 2, 3, 4), default=2)
    arguments.add_argument('--backend', choices=('rr', 'threaded'), default='rr')
    arguments.add_argument('--timeout', type=int, default=600)
    arguments.add_argument('--launcher', type=Path, help='use an installed nemu launcher instead of building NEMU')
    arguments.add_argument('--network', action='store_true', help='also verify loopback TCP forwarding on each boot')
    args = arguments.parse_args()
    if args.xlen != [64] or args.timeout <= 0:
        arguments.error('requires RV64 and a positive timeout')
    manifest_path = args.prepared / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    for name in ('fw_payload.bin', 'kernel.config'):
        if sha256(args.prepared / name) != manifest['files'][name]:
            arguments.error('prepared artifact hash mismatch: ' + name)
    config = (args.prepared / 'kernel.config').read_text()
    for option in ('64BIT', 'EXT4_FS', 'VIRTIO_BLK', 'DEVTMPFS', 'POWER_RESET_SYSCON_POWEROFF'):
        if f'CONFIG_{option}=y\n' not in config:
            arguments.error('prepared kernel lacks ' + option)
    if args.network:
        for option in ('NET', 'INET', 'VIRTIO_NET'):
            if f'CONFIG_{option}=y\n' not in config:
                arguments.error('prepared kernel lacks ' + option)
    if 'CONFIG_INITRAMFS_SOURCE=""\n' not in config:
        arguments.error('requires an external-rootfs kernel without an embedded initramfs')
    if args.harts > 1 and 'CONFIG_SMP=y\n' not in config:
        arguments.error('prepared kernel lacks SMP')
    check = Check(args, 'storage-linux')
    if args.launcher:
        args.launcher = args.launcher.resolve(strict=True)
        check.xlen = 64
        check.directory = check.session / 'rv64'
        check.directory.mkdir()
        machine = json.loads(subprocess.check_output([str(args.launcher), 'info'], text=True))
        check.hashes = {'launcher_sha256': sha256(args.launcher)}
        check.details = {'machine': machine}
    else:
        check.target(64, reference=False, driver=False)
        check.details = {'native_config_sha256': sha256(check.build / 'nemu/.config')}
    check.timeout = args.timeout
    check.details.update({'prepared_manifest_sha256': sha256(manifest_path),
                     'firmware_sha256': sha256(args.prepared / 'fw_payload.bin'),
                     'kernel_config_sha256': sha256(args.prepared / 'kernel.config'),
                     'harts': args.harts, 'backend': args.backend, 'network': args.network})
    source = check.directory / 'nemu_storage.c'
    shutil.copyfile(ROOT / 'app/tests/linux/nemu_storage.c', source)
    tree = check.directory / 'root'
    (tree / 'dev').mkdir(parents=True)
    with (check.directory / 'build-root.log').open('w') as log:
        subprocess.run(['riscv64-linux-gnu-gcc', '-static', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-march=rv64gc', '-mabi=lp64d', str(source), '-o', str(tree / 'init')],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
        original = check.directory / 'original.ext4'
        with original.open('wb') as image:
            image.truncate(64 * 1024 * 1024)
        subprocess.run(['mkfs.ext4', '-q', '-F', '-d', str(tree), str(original)],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
        commands = check.directory / 'devices.debugfs'
        commands.write_text('cd /dev\nmknod console c 5 1\n')
        subprocess.run(['debugfs', '-w', '-f', str(commands), str(original)],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
    check.details.update(source_sha256=sha256(source), init_sha256=sha256(tree / 'init'),
                         initial_disk_sha256=sha256(original))
    if not args.launcher:
        build_dtb(check.directory, args.harts)
    dtb = check.directory / 'nemu.dtb'
    disk = check.directory / 'disk.ext4'
    shutil.copyfile(original, disk)
    for phase, mode, readonly, marker in (
            ('volatile', 'volatile', False, b'NEMU_STORAGE_WRITE_PASS'),
            ('persistent-write', 'persistent', False, b'NEMU_STORAGE_WRITE_PASS'),
            ('persistent-reopen', 'persistent', False, b'NEMU_STORAGE_READ_PASS'),
            ('readonly-reopen', 'readonly', True, b'NEMU_STORAGE_READONLY_PASS')):
        bootargs = ('console=ttyS0,115200 earlycon=sbi root=/dev/vda rootwait init=/init '
                    'unaligned_scalar_speed=fast random.trust_bootloader=on ' + ('ro' if readonly else 'rw'))
        port, forwards = None, []
        if args.network:
            bootargs += ' -- --network'
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            forwards = [f'--hostfwd=tcp:{port}:19000']
        before = sha256(disk)
        if args.launcher:
            state = check.directory / phase
            dtb = state / 'machine.dtb'
            command = list(map(str, [args.launcher, 'run', '--harts', args.harts, '--backend', args.backend,
                                    '--disk', disk, '--disk-mode', mode, '--append', bootargs,
                                    '--state-dir', state, *forwards, '--firmware', args.prepared / 'fw_payload.bin']))
        else:
            subprocess.run(['fdtput', '-t', 's', str(dtb), '/chosen', 'bootargs', bootargs], check=True)
            command = list(map(str, [check.binary, '-b', '-n', '--smp=' + str(args.harts),
                                '--smp-backend=' + args.backend, '--disk=' + str(disk), '--disk-mode=' + mode,
                                *forwards, '-t', dtb, args.prepared / 'fw_payload.bin']))
        log = check.directory / (phase + '.log')
        network_error = None
        try:
            returncode, timed_out = run_console(command, log, args.timeout, failure_markers=FAIL_MARKERS,
                                               environment=check.environment,
                                               ready_marker=b'NEMU_NETWORK_READY' if args.network else None,
                                               on_ready=(lambda timeout: network_round_trip(port, timeout))
                                               if args.network else None)
        except (OSError, ValueError) as error:
            returncode, timed_out, network_error = None, isinstance(error, TimeoutError), str(error)
        output = log.read_bytes()
        check.save(phase, verdict(returncode, output, marker, timed_out, args.network), command=command,
                   returncode=returncode, timed_out=timed_out, log=str(log), log_sha256=sha256(output),
                   dtb_sha256=sha256(dtb), disk_before_sha256=before, forwarded_port=port,
                   network_error=network_error)
        after = sha256(disk)
        check.save(phase + '-integrity', after == before if mode != 'persistent' else True,
                   disk_after_sha256=after)
    check.finish('STORAGE_LINUX')


if __name__ == '__main__':
    main()
