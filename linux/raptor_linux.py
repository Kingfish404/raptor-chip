"""Shared Raptor Linux source, kernel and initramfs builders (no board access)."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile

HOME = Path(__file__).resolve().parent


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], stderr=subprocess.STDOUT)


def identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def kernel(package, cache, cross, profile='fpga', rootfs=None, init='/sbin/raptor-init'):
    """Build in an isolated O= directory from the release-pinned source archive."""
    manifest = json.loads((package / 'manifest.json').read_text())
    require(profile in ('sim', 'fpga'), 'unknown kernel profile')
    require((profile == 'sim') == bool(rootfs), 'sim kernel requires an embedded initramfs')
    for name in ('kernel.config',):
        require(sha(package / name) == manifest['files'][name], 'source hash mismatch: ' + name)
    source_file = package / 'kernel-source.json'
    if source_file.exists():
        require(sha(source_file) == manifest['files']['kernel-source.json'], 'kernel source metadata mismatch')
    else:
        source_file = HOME / 'kernel-source.json'
    source = json.loads(source_file.read_text())
    version = source['version']
    require(manifest['kernel_version'].removeprefix('v') == version, 'kernel source/version mismatch')
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'invalid kernel version')
    major = version.split('.')[0]
    require(source['archive_url'] == f'https://cdn.kernel.org/pub/linux/kernel/v{major}.x/linux-{version}.tar.xz',
                   'unexpected kernel source URL')
    compiler = run(cross + 'gcc', '--version').decode()
    options = ['LITEX', 'LITEX_SOC_CONTROLLER', 'SERIAL_LITEUART', 'SERIAL_LITEUART_CONSOLE',
               'LITEX_LITEETH', 'MMC', 'MMC_BLOCK', 'MMC_LITEX', 'EXT4_FS', 'REGULATOR_FIXED_VOLTAGE',
               'BINFMT_SCRIPT', 'DEVTMPFS', 'TMPFS', 'BLK_DEV_INITRD', 'RD_GZIP',
               'NET', 'INET', 'UNIX', 'PACKET', 'NETDEVICES', 'VIRTIO_MENU', 'VIRTIO_MMIO', 'VIRTIO_NET',
               'HW_RANDOM', 'HW_RANDOM_VIRTIO', 'SERIAL_8250', 'SERIAL_8250_CONSOLE', 'SERIAL_OF_PLATFORM']
    if profile == 'fpga':
        # LiteSDCard DMA is noncoherent. Generic DMA support alone cannot
        # clean/invalidate Raptor's cache without the Zicbom implementation.
        options += ['RISCV_ALTERNATIVE', 'RISCV_ISA_ZICBOM',
                    'FTRACE', 'ENABLE_DEFAULT_TRACERS']
    # FPGA network acceptance traces skb drop reasons. Keep event tracing
    # available without instrumenting every function; simulators omit both.
    disabled = ['LEGACY_PTYS', 'BLK_DEV_IO_TRACE', 'BPF_EVENTS',
                'FUNCTION_TRACER', 'FUNCTION_GRAPH_TRACER']
    if profile == 'sim':
        disabled += ['FTRACE']
    build_vars = ['KBUILD_BUILD_USER=raptor', 'KBUILD_BUILD_HOST=netboot',
                  'KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000', 'KBUILD_BUILD_VERSION=1']
    large_rootfs = bool(rootfs and rootfs.stat().st_size > 64 * 1024 * 1024)
    key = identity([source, manifest['files']['kernel.config'], compiler, options, disabled, build_vars,
                    profile, sha(rootfs) if rootfs else None, init, 'cmdline-ramfs-v1' if large_rootfs else 'cmdline-v1'])
    output = cache / key
    if output.exists():
        receipt = json.loads((output / 'built.json').read_text())
        require(all(sha(output / name) == value for name, value in receipt.items()),
                       'cached LiteX kernel changed')
        return output
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'linux-{version}.tar.xz'
    if not archive.exists():
        part = archive.with_suffix('.part')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '-o', str(part), source['archive_url']], check=True)
        require(sha(part) == source['sha256'], 'kernel archive hash mismatch')
        part.replace(archive)
    require(sha(archive) == source['sha256'], 'kernel archive hash mismatch')
    with tempfile.TemporaryDirectory(prefix='raptor-chip-netboot-kernel-', dir='/tmp') as temporary:
        work = Path(temporary)
        with tarfile.open(archive) as tar:
            tar.extractall(work, filter='data')
        tree, obj = work / ('linux-' + version), work / 'obj'
        obj.mkdir()
        shutil.copyfile(package / 'kernel.config', obj / '.config')
        argv = [str(tree / 'scripts/config'), '--file', str(obj / '.config')]
        for option in options:
            argv += ['-e', option]
        for option in disabled:
            argv += ['-d', option]
        argv += ['--set-str', 'INITRAMFS_SOURCE', str(rootfs) if rootfs else '']
        if rootfs:
            # Existing sim/NEMU ROM DTBs describe hardware; use the built userspace's init.
            argv += ['-e', 'INITRAMFS_COMPRESSION_GZIP', '-e', 'CMDLINE_FORCE', '--set-str', 'CMDLINE',
                     'console=ttyS0 earlycon=sbi unaligned_scalar_speed=fast random.trust_bootloader=on '
                     'pty.legacy_count=0 ' + ('rootfstype=ramfs ' if large_rootfs else '') + 'rdinit=' + init]
        else:
            argv += ['-d', 'CMDLINE_FORCE']
        subprocess.run(argv, check=True)
        make = ['make', '-C', str(tree), 'O=' + str(obj), 'ARCH=riscv', 'CROSS_COMPILE=' + cross, *build_vars]
        subprocess.run(make + ['olddefconfig'], check=True)
        config = (obj / '.config').read_text()
        if profile == 'fpga':
            for option in ('RISCV_ISA_ZICBOM', 'RISCV_DMA_NONCOHERENT', 'EVENT_TRACING'):
                require(f'CONFIG_{option}=y\n' in config, 'resolved FPGA kernel lacks ' + option)
        for option in ('BINFMT_SCRIPT', 'LITEX_LITEETH', 'MMC_LITEX', 'EXT4_FS', 'VIRTIO_NET', 'SERIAL_8250_CONSOLE'):
            require(f'CONFIG_{option}=y\n' in config, 'resolved kernel lacks ' + option)
        subprocess.run(make + ['-j8', 'Image'], check=True)
        # Only finished, hashed outputs survive; temporary kernel sources are removed.
        with tempfile.TemporaryDirectory(prefix='.kernel-', dir=cache) as stage:
            staging = Path(stage) / 'result'
            (staging / 'arch/riscv/boot').mkdir(parents=True)
            names = ('.config', 'arch/riscv/boot/Image')
            for name in names:
                shutil.copyfile(obj / name, staging / name)
            (staging / 'built.json').write_text(json.dumps({n: sha(staging / n) for n in names}))
            staging.rename(output)
    return output


def background_services(source):
    """Keep slow first-boot SSH key generation off the serial login path."""
    if '# raptor asynchronous services' in source:
        return source
    start = source.find('# Retry in background if no DHCP server')
    end = source.find("echo 'Raptor distribution ready:", start)
    require(start >= 0 and end > start and 'ssh-keygen -A' in source[start:end],
            'unknown distro network/SSH startup hook')
    return source[:start] + '''# raptor asynchronous services
(
    /bin/busybox udhcpc -b -i eth0 -s /etc/raptor-udhcpc.script
) </dev/null >/run/raptor-network.log 2>&1 &
(
    if command -v sshd >/dev/null; then
        mkdir -p /run/sshd
        # A first-boot RSA key can take minutes on a 50 MHz soft CPU.
        # OpenSSH can serve using a single Ed25519 host key.
        if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
            ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
        fi
        "$(command -v sshd)"
    fi
) </dev/null >/run/raptor-ssh.log 2>&1 &
''' + source[end:]


def export_rootfs(disk, root, work, persistence_runtime=None):
    extraction = run('debugfs', '-R', f'rdump / {root}', disk).decode()
    (work / 'extract.log').write_text(extraction)
    # rdump's chown can fail inside user namespaces. Recover ownership from
    # ext4 directory records, never from the extracting host's uid/gid.
    require(all(line.startswith('debugfs ') or 'while changing ownership of ' in line
                for line in extraction.splitlines()), 'ext4 extraction failed; see extract.log')
    commands = work / 'metadata.commands'
    directories = sorted(Path(base).relative_to(root).as_posix()
                         for base, _, _ in os.walk(root, followlinks=False))
    commands.write_text(''.join('ls -p -l ' + json.dumps('/' if p == '.' else '/' + p) + '\n'
                                for p in directories))
    metadata = run('debugfs', '-f', commands, disk).decode()
    (work / 'metadata.log').write_text(metadata)
    entries = {'.': (stat.S_IFDIR | 0o755, 0, 0)}
    parent = None
    for line in metadata.splitlines():
        if line.startswith('debugfs: ls -p -l '):
            parent = json.loads(line.removeprefix('debugfs: ls -p -l ')).lstrip('/')
        elif line.startswith('/'):
            fields = line.split('/')
            if fields[1] != '0' and fields[5] not in ('', '.', '..'):
                require(parent is not None, 'missing ext4 directory context')
                name = str(Path(parent) / fields[5])
                entries[name] = (int(fields[2], 8), int(fields[3]), int(fields[4]))
        else:
            require(not line.strip() or line.startswith('debugfs '), 'unexpected ext4 metadata output')
    inittab = root / 'etc/inittab'
    inittab.write_text(inittab.read_text().replace('ttyS0::askfirst', '::askfirst'))
    boot = root / 'etc/init.d/raptor-boot'
    if boot.is_file():
        boot.write_text(background_services(boot.read_text()))
    if persistence_runtime:
        sbin = root / 'sbin'
        require(not sbin.is_symlink() or sbin.readlink() == Path('usr/sbin'), 'unexpected /sbin symlink')
        name = 'usr/sbin/raptor-persist' if sbin.is_symlink() else 'sbin/raptor-persist'
        (root / name).write_bytes(persistence_runtime.read_bytes())
        entries[name] = (stat.S_IFREG | 0o755, 0, 0)
        boot = root / 'etc/init.d/raptor-boot'
        source = boot.read_text()
        if '/sbin/raptor-persist' not in source:
            require(source.count('/bin/busybox hostname raptor') == 1, 'unknown distro boot hook')
            boot.write_text(source.replace('/bin/busybox hostname raptor',
                '/sbin/raptor-persist || echo "Persistence setup failed; RAM boot continues" >&2\n'
                '/bin/busybox hostname raptor'))
    # Debian's busybox-static provides these applets without PATH symlinks.
    # Install only absent commands; retain distro-provided full implementations.
    if 'usr/bin/busybox' in entries or 'bin/busybox' in entries:
        for command in ('ip', 'ping', 'wget', 'nc'):
            if not any(directory + '/' + command in entries
                       for directory in ('bin', 'sbin', 'usr/bin', 'usr/sbin')):
                name = 'usr/bin/' + command
                (root / name).symlink_to('/bin/busybox')
                entries[name] = (stat.S_IFLNK | 0o777, 0, 0)
    with (work / 'rootfs.cpio').open('wb') as stream:
        def emit(ino, name, mode, uid, gid, data, device=(0, 0)):
            encoded = name.encode() + b'\0'
            fields = (ino, mode, uid, gid, 1, 0, len(data), 0, 0, *device, len(encoded), 0)
            header = b'070701' + ''.join(f'{v:08x}' for v in fields).encode() + encoded
            stream.write(header + b'\0' * (-len(header) % 4))
            stream.write(data + b'\0' * (-len(data) % 4))
        for ino, (name, (mode, uid, gid)) in enumerate(sorted(entries.items()), 1):
            path = root / name
            require(stat.S_IFMT(path.lstat().st_mode) == stat.S_IFMT(mode), f'extracted type mismatch: {name}')
            if stat.S_ISREG(mode):
                data = path.read_bytes()
            elif stat.S_ISLNK(mode):
                data = os.readlink(path).encode()
            else:
                require(stat.S_ISDIR(mode), f'unsupported rootfs special file: {name}')
                data = b''
            emit(ino, name, mode, uid, gid, data)
        # Embedded initramfs must provide an initial console before userspace
        # mounts devtmpfs. Encode guest device nodes; never create host devices.
        if 'dev' not in entries:
            emit(len(entries) + 1, 'dev', stat.S_IFDIR | 0o755, 0, 0, b'')
        for index, (name, major, minor) in enumerate((('console', 5, 1), ('null', 1, 3)), 2):
            require('dev/' + name not in entries, 'unexpected device in disk rootfs')
            emit(len(entries) + index, 'dev/' + name, stat.S_IFCHR | 0o600, 0, 0, b'', (major, minor))
        emit(0, 'TRAILER!!!', 0, 0, 0, b'')
    with (work / 'rootfs.cpio').open('rb') as source, (work / 'rootfs.cpio.gz').open('wb') as target:
        with gzip.GzipFile(filename='', mode='wb', compresslevel=1, fileobj=target, mtime=0) as compressed:
            shutil.copyfileobj(source, compressed)
