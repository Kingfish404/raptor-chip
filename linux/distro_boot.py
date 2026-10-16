#!/usr/bin/env python3
"""Prepare and boot official RV64 Debian/Ubuntu userspace with systemd on NEMU."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import selectors
import shutil
import struct
import subprocess
import time

from build_linux import opensbi, verify
from raptor_linux import HOME, require, sha

ROOT = HOME.parent
ASSETS = HOME / 'distro-boot'
SOURCES = {
    'debian': {
        'release': '13', 'build': '20261001-2618', 'format': 'qcow2',
        'url': 'https://cloud.debian.org/images/cloud/trixie/20261001-2618/debian-13-nocloud-riscv64-20261001-2618.qcow2',
        'algorithm': 'sha512',
        'digest': '00dc9a49ee349881841ced3c8a3d07353866e19ffb70fb93cd07f02089d5829ee4ccb608b4a2edf5302ff2c380708185d2e9c59ce4ac376d252b35df52a7d479',
    },
    'ubuntu': {
        'release': '24.04', 'build': '20260926', 'format': 'tar',
        'url': 'https://cloud-images.ubuntu.com/noble/20260926/noble-server-cloudimg-riscv64-root.tar.xz',
        'algorithm': 'sha256',
        'digest': '2790aa289412517d1aedb81417bc03a3da3d21eb7778d4dbf701295e10cc4b15',
    },
}
FAULTS = (rb'Kernel panic|Oops[: \[]|Unable to handle kernel|unhandled signal|segfault at|SIGSEGV|'
          rb'RAPTOR_DISTRO_CHECK_FAIL|Power off not available|rcu:.*detected stalls')


def run(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), check=True, **kwargs)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def verdict(output, returncode, distro, harts=1):
    return (returncode == 0 and b'RAPTOR_DISTRO_CHECK_PASS' in output
            and b'RAPTOR_FP_PASS' in output
            and ('RAPTOR_DISTRO_ID=' + distro + ' VERSION_ID=' + SOURCES[distro]['release']).encode() in output
            and (harts == 1 or f'RAPTOR_SMP_PASS harts={harts} '.encode() in output)
            and b'reboot: Power down' in output and not re.search(FAULTS, output))


def download(distro, directory):
    source = SOURCES[distro]
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / source['url'].rsplit('/', 1)[1]
    if not archive.exists():
        partial = archive.with_suffix(archive.suffix + '.part')
        run(['curl', '-fL', '--retry', '3', '--connect-timeout', '30',
             '--max-time', '1800', source['url'], '-o', partial])
        partial.rename(archive)
    with archive.open('rb') as stream:
        require(hashlib.file_digest(stream, source['algorithm']).hexdigest() == source['digest'],
                'official image checksum mismatch: ' + str(archive))
    return archive


def ext4_partition(raw):
    with raw.open('rb') as stream:
        stream.seek(512)
        header = stream.read(92)
        require(header[:8] == b'EFI PART', 'expected a GPT cloud disk')
        table, count, entry_size = struct.unpack_from('<QII', header, 72)
        require(0 < count <= 4096 and 128 <= entry_size <= 4096, 'invalid GPT geometry')
        candidates = []
        for index in range(count):
            stream.seek(table * 512 + index * entry_size)
            entry = stream.read(entry_size)
            if entry[:16] == bytes(16):
                continue
            first, last = struct.unpack_from('<QQ', entry, 32)
            require(first <= last and (last + 1) * 512 <= raw.stat().st_size,
                    'partition outside cloud disk')
            stream.seek(first * 512 + 1024 + 56)
            if stream.read(2) == b'\x53\xef':
                candidates.append((first * 512, (last - first + 1) * 512))
    require(len(candidates) == 1, 'expected exactly one ext4 root partition')
    return candidates[0]


def extract_partition(raw, disk):
    offset, length = ext4_partition(raw)
    with raw.open('rb') as source, disk.open('xb') as target:
        source.seek(offset)
        remaining = length
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            require(bool(chunk), 'short cloud disk')
            if chunk.strip(b'\0'):
                target.write(chunk)
            else:
                target.seek(len(chunk), 1)
            remaining -= len(chunk)
        target.truncate(length)


def make_tar_disk(archive, directory):
    tree = directory / 'tree'
    tree.mkdir()
    run(['/usr/bin/tar', '--extract', '--file', archive, '--directory', tree,
         '--numeric-owner', '--same-owner', '--same-permissions'])
    disk = directory / 'rootfs.ext4'
    with disk.open('xb') as stream:
        stream.truncate(4 * 1024**3)
    run(['/usr/sbin/mke2fs', '-q', '-t', 'ext4', '-F', '-m', '0', '-d', tree, disk])
    shutil.rmtree(tree)


def customize(disk, directory, harts=1):
    run(['riscv64-linux-gnu-gcc', '-O2', '-static', '-pthread', '-march=rv64gc', '-mabi=lp64d',
         ASSETS / 'smp_check.c', '-o', directory / 'smp-check'])
    files = {
        '/etc/raptor-harts': str(harts) + '\n',
        '/etc/fstab': '/dev/vda / ext4 defaults 0 1\n',
        '/etc/hostname': 'raptor-' + directory.name + '\n',
        '/etc/locale.conf': 'LANG=C.UTF-8\n',
        '/etc/vconsole.conf': 'KEYMAP=us\n',
        '/etc/systemd/network/10-raptor.network': '[Match]\nName=eth* en*\n\n[Network]\nDHCP=yes\n',
        '/etc/systemd/system/serial-getty@ttyS0.service.d/raptor.conf':
            '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,38400,9600 - $TERM\n',
        '/etc/cloud/cloud-init.disabled': '',
        '/etc/systemd/system/raptor-distro-check.service': (ASSETS / 'check.service').read_text(),
        '/etc/systemd/system/raptor-distro-check.timer': (ASSETS / 'check.timer').read_text(),
        '/usr/local/lib/raptor-distro-check': (ASSETS / 'check.sh').read_text(),
    }
    commands = []
    directories = sorted({str(parent) for name in files for parent in Path(name).parents
                          if str(parent) != '/'}, key=lambda name: len(Path(name).parts))
    commands.extend('mkdir ' + name for name in directories)
    commands.append('mkdir /etc/systemd/system/timers.target.wants')
    for index, (name, content) in enumerate(files.items()):
        local = directory / ('overlay-' + str(index))
        local.write_text(content)
        commands.extend(['rm ' + name, f'write {local} {name}',
                         f'set_inode_field {name} uid 0', f'set_inode_field {name} gid 0',
                         f'set_inode_field {name} mode 0100644'])
    commands.extend([
        'rm /usr/local/lib/raptor-smp-check',
        f'write {directory / "smp-check"} /usr/local/lib/raptor-smp-check',
        'set_inode_field /usr/local/lib/raptor-smp-check mode 0100755',
        'set_inode_field /usr/local/lib/raptor-smp-check uid 0',
        'set_inode_field /usr/local/lib/raptor-smp-check gid 0',
        'rm /etc/systemd/system/timers.target.wants/raptor-distro-check.timer',
        'symlink /etc/systemd/system/timers.target.wants/raptor-distro-check.timer ../raptor-distro-check.timer',
        'rm /etc/systemd/system/default.target',
        'symlink /etc/systemd/system/default.target /usr/lib/systemd/system/multi-user.target',
        'rm /etc/localtime',
        'symlink /etc/localtime /usr/share/zoneinfo/Etc/UTC',
    ])
    for unit in ('systemd-firstboot.service', 'multipathd.service', 'multipathd.socket',
                 'snapd.service', 'snapd.socket', 'snapd.seeded.service', 'pollinate.service'):
        commands.extend(['rm /etc/systemd/system/' + unit,
                         'symlink /etc/systemd/system/' + unit + ' /dev/null'])
    command_file = directory / 'debugfs.commands'
    command_file.write_text('\n'.join(commands) + '\n')
    with (directory / 'customize.log').open('w') as log:
        run(['debugfs', '-w', '-f', command_file, disk], stdout=log, stderr=subprocess.STDOUT)
    run(['e2fsck', '-fn', disk], stdout=subprocess.DEVNULL)


def nemu_build_flags(sanitize=None):
    # 1 GiB of RAM plus the 1 GiB flash window exceed the 2 GiB static data
    # reachable with the default x86-64 code model. Move only those arrays to
    # large sections; smaller (including thread-local) data stays put.
    build = (['-O1', '-g', '-fsanitize=' + sanitize, '-fno-omit-frame-pointer']
             if sanitize else [])
    if platform.machine() == 'x86_64':
        build += ['-mcmodel=medium', '-mlarge-data-threshold=16777216']
    return ['CFLAGS_BUILD=' + ' '.join(build)] if build else []


def build_nemu(directory, xlen=64, sanitize=None):
    nemu = ROOT / 'nemu'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ('src', 'configs'):
        if not (directory / name).exists():
            (directory / name).symlink_to(nemu / name, target_is_directory=True)
    config = (nemu / f'configs/riscv{xlen}gc_linux_defconfig').read_text()
    config = config.replace('CONFIG_MSIZE=0x10000000', 'CONFIG_MSIZE=0x40000000')
    config = config.replace('# CONFIG_HAS_DISK is not set', 'CONFIG_HAS_DISK=y')
    private = directory / 'distro_defconfig'
    private.write_text(config)
    environment = dict(os.environ, NEMU_HOME=str(nemu))
    with (directory / 'build.log').open('w') as log:
        # A fresh checkout has neither the Kconfig/fixdep host tools nor the
        # generated DTBs that the private build and the test payloads use.
        kconfig = nemu / 'tools/kconfig'
        for tool, name in ((kconfig, 'conf'), (nemu / 'tools/fixdep', 'fixdep')):
            run(['make', '-s', '-C', tool, 'BUILD_DIR=' + str(tool / 'build'), 'NAME=' + name],
                cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT)
        run(['make', '-s', '-C', nemu / 'src/memory/rom',
             'spike-rv32gc-nemu.dtb', 'spike-rv64gc-nemu.dtb'],
            cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT)
        for operation in ('--defconfig=' + str(private), '--syncconfig'):
            run([kconfig / 'build/conf', '-s', operation, nemu / 'Kconfig'],
                cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT)
        flags = nemu_build_flags(sanitize)
        run(['make', '-f', nemu / 'Makefile', '-j4', 'app',
             'BUILD_DIR=' + str(directory / 'build'), *flags],
            cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT)
    return directory / f'build/riscv{xlen}-nemu-interpreter'


def build_dtb(directory, harts, source_name='nemu-distro-rv64.dts'):
    require(1 <= harts <= 4, 'requires 1..4 harts')
    dtb = directory / 'nemu.dtb'
    run(['/usr/bin/dtc', '-I', 'dts', '-O', 'dtb', '-i', HOME / 'dts',
         '-o', dtb, HOME / 'dts' / source_name])
    if harts == 1:
        return
    properties = run(['fdtget', '-p', dtb, '/cpus/cpu@0'], capture_output=True).stdout.decode().split()
    template = []
    for name in properties:
        if name not in ('reg', 'phandle', 'linux,phandle'):
            value = run(['fdtget', '-t', 'bx', dtb, '/cpus/cpu@0', name],
                        capture_output=True).stdout.decode().split()
            template.append(f'{name} = [' + ' '.join(f'{int(byte, 16):02x}' for byte in value) + '];')
    nodes = []
    for hartid in range(1, harts):
        nodes.append(f'cpu@{hartid:x} {{ reg = <{hartid}>; ' + '\n'.join(template) +
                     f' cpu{hartid}_intc: interrupt-controller {{ #address-cells = <2>; '
                     '#interrupt-cells = <1>; interrupt-controller; compatible = "riscv,cpu-intc"; }; };')
    clint = ' '.join(f'&cpu{hartid}_intc 3 &cpu{hartid}_intc 7' for hartid in range(harts))
    plic = ' '.join(f'&cpu{hartid}_intc 11 &cpu{hartid}_intc 9' for hartid in range(harts))
    source = directory / 'nemu-smp.dts'
    source.write_text('/include/ "' + source_name + '"\n/ { cpus {\n' + '\n'.join(nodes) +
                      '\n}; soc { clint@2000000 { interrupts-extended = <' + clint +
                      '>; }; plic@c000000 { interrupts-extended = <' + plic + '>; }; }; };\n')
    run(['/usr/bin/dtc', '-I', 'dts', '-O', 'dtb', '-i', HOME / 'dts', '-o', dtb, source])


def prepare(args):
    directory = args.work / args.distro
    require(not directory.exists(), 'output already exists; use a new work directory')
    require((args.kernel_artifacts / 'manifest.json').is_file(),
            'build an RV64 FPGA-profile kernel first; select it with --kernel-artifacts')
    kernel_record = verify(args.kernel_artifacts)
    require(kernel_record['bits'] == 64 and kernel_record['profile'] == 'fpga',
            'requires an RV64 external-rootfs kernel artifact directory')
    config = (args.kernel_artifacts / 'kernel.config').read_text()
    for option in ('VIRTIO_BLK', 'EXT4_FS', 'DEVTMPFS_MOUNT', 'CGROUPS', 'FHANDLE',
                   'SERIAL_8250_CONSOLE', 'FPU'):
        require(f'CONFIG_{option}=y\n' in config, 'kernel lacks ' + option)
    require('CONFIG_INITRAMFS_SOURCE=""\n' in config and 'CONFIG_CMDLINE_FORCE=y' not in config,
            'kernel must accept the platform command line and external disk root')
    archive = download(args.distro, args.downloads)
    directory.mkdir(parents=True)
    disk = directory / 'rootfs.ext4'
    if SOURCES[args.distro]['format'] == 'qcow2':
        raw = directory / 'cloud.raw'
        run(['qemu-img', 'convert', '-O', 'raw', archive, raw])
        extract_partition(raw, disk)
        raw.unlink()
    else:
        run(['fakeroot', 'python3', Path(__file__).resolve(), 'tar-disk',
             '--archive', archive, '--work', directory])
    if args.harts > 1:
        require('CONFIG_SMP=y\n' in config, 'kernel lacks SMP')
        count = re.search(r'^CONFIG_NR_CPUS=(\d+)$', config, re.M)
        require(count and int(count[1]) >= args.harts, 'kernel has too few CPU slots')
    customize(disk, directory, args.harts)
    for name in ('Image', 'kernel.config'):
        shutil.copyfile(args.kernel_artifacts / name, directory / name)
    with (directory / 'opensbi.log').open('w') as log:
        run(['python3', Path(__file__).resolve(), 'firmware', '--work', directory],
            stdout=log, stderr=subprocess.STDOUT)
    build_dtb(directory, args.harts)
    binary = build_nemu(directory / 'nemu')
    record = {'distro': args.distro, 'source': SOURCES[args.distro],
              'builder_sha256': sha(Path(__file__)),
              'overlay_sha256': {path.name: sha(path) for path in sorted(ASSETS.iterdir())},
              'kernel_manifest': kernel_record, 'nemu': str(binary), 'nemu_sha256': sha(binary),
              'nemu_config_sha256': sha(directory / 'nemu/.config'),
              'memory_mib': 1024, 'harts': args.harts, 'nemu_backend': args.nemu_backend or 'rr',
              'nemu_clock_div': args.nemu_clock_div or 16,
              'disk_writes_persist': False,
              'files': {name: sha(directory / name) for name in
                        ('rootfs.ext4', 'Image', 'kernel.config', 'fw_payload.bin', 'nemu.dtb')}}
    save(directory / 'manifest.json', record)
    print('PREPARED=' + str(directory), flush=True)


def check(args):
    directory = args.work / args.distro
    record = json.loads((directory / 'manifest.json').read_text())
    harts = record.get('harts', 1)
    backend = getattr(args, 'nemu_backend', None) or record.get('nemu_backend', 'rr')
    clock_div = getattr(args, 'nemu_clock_div', None) or record.get('nemu_clock_div', 16)
    require(all(sha(directory / name) == digest for name, digest in record['files'].items()),
            'prepared artifact changed')
    binary = Path(record['nemu'])
    require(sha(binary) == record['nemu_sha256'], 'NEMU binary changed; prepare a new manifest')
    interactive = args.action == 'run'
    dtb = directory / 'nemu.dtb'
    if interactive:
        dtb = directory / 'interactive.dtb'
        shutil.copyfile(directory / 'nemu.dtb', dtb)
        bootargs = run(['fdtget', '-t', 's', dtb, '/chosen', 'bootargs'],
                       capture_output=True).stdout.decode().strip()
        run(['fdtput', '-t', 's', dtb, '/chosen', 'bootargs',
             bootargs + ' systemd.mask=raptor-distro-check.timer'])
    if args.engine == 'nemu':
        command = [str(binary), '-b', '-n', '-t', str(dtb),
                   '--disk=' + str(directory / 'rootfs.ext4'),
                   '--log=' + str(directory / ('interactive-monitor.log' if interactive else 'nemu-monitor.log')),
                   str(directory / 'fw_payload.bin')]
        if harts > 1:
            command.insert(1, '--smp=' + str(harts))
        if backend == 'threaded':
            command.insert(1, '--smp-backend=threaded')
            command.insert(1, '--smp-clock-div=' + str(clock_div))
    else:
        command = ['qemu-system-riscv64', '-M', 'virt', '-cpu', 'rv64,h=false,sstc=false,svadu=false',
                   '-m', '1024M', '-smp', str(harts), '-nographic', '-no-reboot', '-snapshot',
                   '-bios', str(directory / 'fw_payload.bin'),
                   '-drive', f'file={directory / "rootfs.ext4"},format=raw,if=none,id=root',
                   '-device', 'virtio-blk-device,drive=root', '-netdev', 'user,id=net',
                   '-device', 'virtio-net-device,netdev=net', '-append',
                   'console=ttyS0 root=/dev/vda rw rootwait init=/sbin/init random.trust_bootloader=on',
                   '-kernel', str(directory / 'Image')]
        if interactive:
            command[command.index('-append') + 1] += ' systemd.mask=raptor-distro-check.timer'
    environment = dict(os.environ, NEMU_HOME=str(ROOT / 'nemu'), NEMU_STATUS_DIR=str(directory),
                       TMPDIR=str(directory))
    if interactive:
        run(command, env=environment)
        return
    manifest_digest = sha(directory / 'manifest.json')
    resultpath = directory / (args.engine + '-result.json')
    resultpath.unlink(missing_ok=True)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, env=environment)
    poll = selectors.DefaultSelector()
    poll.register(process.stdout, selectors.EVENT_READ)
    start = time.monotonic()
    output = bytearray()
    passed = False
    logpath = directory / (args.engine + '-boot.log')
    print('BOOT_LOG=' + str(logpath), flush=True)
    try:
        with logpath.open('wb') as log:
            while time.monotonic() - start < args.timeout:
                for key, _ in poll.select(1):
                    chunk = os.read(key.fd, 65536)
                    if chunk:
                        output.extend(chunk)
                        log.write(chunk)
                        log.flush()
                if re.search(FAULTS, output):
                    process.terminate()
                    break
                if process.poll() is not None:
                    tail = process.stdout.read()
                    output.extend(tail)
                    log.write(tail)
                    break
            else:
                process.terminate()
            process.wait(timeout=10)
        passed = verdict(output, process.returncode, args.distro, harts)
        if args.engine == 'nemu' and backend == 'threaded':
            passed = passed and f'NEMU_THREADED harts={harts} '.encode() in output
    finally:
        poll.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        save(resultpath, {
            'passed': passed, 'command': command, 'returncode': process.returncode,
            'elapsed_seconds': round(time.monotonic() - start, 2),
            'manifest_sha256': manifest_digest, 'log': str(logpath),
            'log_sha256': sha(logpath), 'engine': args.engine, 'harts': harts,
            'nemu_backend': backend, 'nemu_clock_div': clock_div})
    require(passed, 'boot acceptance failed; see ' + str(logpath))
    print('PASS ' + args.distro + ' ' + args.engine + ': ' + str(logpath))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('download', 'prepare', 'check', 'run', 'tar-disk', 'firmware'))
    parser.add_argument('--distro', choices=SOURCES, default='debian')
    parser.add_argument('--work', type=Path, default=HOME / 'build/distro-boot')
    parser.add_argument('--downloads', type=Path, default=HOME / 'build/distro-boot/downloads')
    parser.add_argument('--kernel-artifacts', type=Path,
                        default=HOME / 'build/raptor/v6.18.51/rv64-debian-fpga')
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--engine', choices=('nemu', 'qemu'), default='nemu')
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--harts', type=int, choices=range(1, 5), default=1)
    parser.add_argument('--nemu-backend', choices=('rr', 'threaded'))
    parser.add_argument('--nemu-clock-div', type=int, choices=range(1, 1001), metavar='1..1000')
    args = parser.parse_args()
    args.work = args.work.resolve()
    args.downloads = args.downloads.resolve()
    args.kernel_artifacts = args.kernel_artifacts.resolve()
    if args.action == 'download':
        download(args.distro, args.downloads)
    elif args.action == 'prepare':
        prepare(args)
    elif args.action in ('check', 'run'):
        check(args)
    elif args.action == 'tar-disk':
        make_tar_disk(args.archive, args.work)
    else:
        opensbi(args.work / 'Image', 64, args.work / 'fw_payload.bin', 'riscv64-linux-gnu-')


if __name__ == '__main__':
    main()
