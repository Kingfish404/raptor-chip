#!/usr/bin/env python3
"""Prepare and boot official RV64 Debian, Ubuntu, and Alpine userspace on NEMU, RTL sim, or QEMU."""
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
import sys
import tarfile
import tempfile
import time

from build_linux import opensbi, verify
from raptor_linux import HOME, require, sha

ROOT = HOME.parent
sys.path.insert(0, str(ROOT / 'sim/gsim'))
from raptor_dse import parse_rapt_config  # noqa: E402
ASSETS = HOME / 'distro-boot'
SOURCES = {
    'debian': {
        'os_id': 'debian', 'release': '13', 'build': '20261123-2671',
        'format': 'raw-tar',
        'url': ('https://cloud.debian.org/images/cloud/trixie/20261123-2671/'
                'debian-13-generic-riscv64-20261123-2671.tar.xz'),
        'algorithm': 'sha512',
        'digest': ('eafad734b0efda27e85aa6e4036c19a385ca1c2ca6ff2f845ff849b17b16f5f'
                   '0c0531daeb8976804fa9917cff6dc6578cf3ba35ba31dad8e1c92944cbde74130'),
    },
    'alpine': {
        'os_id': 'alpine', 'release': '3.24.4', 'build': '20261105',
        'format': 'alpine',
        'url': ('https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64/'
                'alpine-minirootfs-3.24.4-riscv64.tar.gz'),
        'algorithm': 'sha256',
        'digest': '010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3',
        'packages_url': ('https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64/'
                         'alpine-uboot-3.24.4-riscv64.tar.gz'),
        'packages_algorithm': 'sha256',
        'packages_digest': 'f7367d1f4e1f41fb289caff7dcdb1f029308784781ada4c702597d7f843f7e9e',
    },
    'ubuntu': {
        'os_id': 'ubuntu', 'release': '26.10', 'build': '20261105',
        'format': 'tar', 'isa_profile': 'rva23',
        'url': ('https://cloud-images.ubuntu.com/releases/stonking/release-20261105/'
                'ubuntu-26.10-server-cloudimg-riscv64-root.tar.xz'),
        'algorithm': 'sha256',
        'digest': '522ed2f958fa0edb70fcda2b0600ac54bab3cdd6ad53f4fd4ddf2b7dd419a80c',
    },
    'ubuntu-lts': {
        'os_id': 'ubuntu', 'release': '26.04', 'build': '20261108',
        'format': 'tar', 'isa_profile': 'rva23',
        'url': ('https://cloud-images.ubuntu.com/releases/26.04/release-20261108/'
                'ubuntu-26.04-server-cloudimg-riscv64-root.tar.xz'),
        'algorithm': 'sha256',
        'digest': '1ddcbc7b740ea4da8db9e4d79590e24d92850f1c10344afa8a7c7dfbdca58909',
    },
}
FAULTS = (rb'Kernel panic|Oops[: \[]|Unable to handle kernel|unhandled signal|segfault at|'
          rb'SIGSEGV|RAPTOR_DISTRO_CHECK_FAIL|Power off not available|rcu:.*detected stalls')
ALPINE_REPOSITORIES = (
    'https://dl-cdn.alpinelinux.org/alpine/v3.24/main\n'
    'https://dl-cdn.alpinelinux.org/alpine/v3.24/community\n'
)


def run(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), check=True, **kwargs)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def verdict(output, returncode, distro, harts=1):
    os_id = SOURCES[distro].get('os_id', distro)
    expected_id = f'RAPTOR_DISTRO_ID={os_id} VERSION_ID={SOURCES[distro]["release"]}'.encode()
    return (returncode == 0 and b'RAPTOR_DISTRO_CHECK_PASS' in output
            and b'RAPTOR_FP_PASS' in output
            and expected_id in output
            and (harts == 1 or f'RAPTOR_SMP_PASS harts={harts} '.encode() in output)
            and b'reboot: Power down' in output and not re.search(FAULTS, output))


def _fetch_verified(url, algorithm, expected_digest, directory):
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / url.rsplit('/', 1)[1]
    if not archive.exists():
        partial = archive.with_suffix(archive.suffix + '.part')
        run(['curl', '-fL', '--retry', '3', '--connect-timeout', '30',
             '--max-time', '1800', url, '-o', partial])
        partial.rename(archive)
    with archive.open('rb') as stream:
        require(hashlib.file_digest(stream, algorithm).hexdigest() == expected_digest,
                'official image checksum mismatch: ' + str(archive))
    return archive


def download(distro, directory):
    source = SOURCES[distro]
    archive = _fetch_verified(source['url'], source['algorithm'], source['digest'], directory)
    if 'packages_url' in source:
        _fetch_verified(source['packages_url'], source['packages_algorithm'],
                        source['packages_digest'], directory)
    return archive


def download_packages(distro, directory):
    source = SOURCES[distro]
    require('packages_url' in source, f'distro {distro} has no separate packages archive')
    return _fetch_verified(source['packages_url'], source['packages_algorithm'],
                           source['packages_digest'], directory)


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


def _install_apks_python(repo_dir, tree, root_packages):
    """Fallback offline APKv2 resolver/extractor when qemu-riscv64 is unavailable."""
    with tarfile.open(repo_dir / 'APKINDEX.tar.gz') as idx_tar:
        raw_index = idx_tar.extractfile('APKINDEX').read().decode()
    packages = {}
    provides = {}
    for block in raw_index.strip().split('\n\n'):
        fields = {}
        for line in block.splitlines():
            if len(line) >= 2 and line[1] == ':':
                fields[line[0]] = line[2:]
        name = fields.get('P')
        if not name:
            continue
        deps = [tok.split('=')[0].split('<')[0].split('>')[0].lstrip('!')
                for tok in fields.get('D', '').split()
                if not tok.startswith('!')]
        packages[name] = {'version': fields['V'], 'deps': deps, 'raw': block}
        provides.setdefault(name, name)
        for prov in fields.get('p', '').split():
            provides.setdefault(prov.split('=')[0], name)
    ordered = []
    seen = set()

    def visit(pkg_token):
        real = provides.get(pkg_token)
        if not real or real in seen:
            return
        seen.add(real)
        for dep in packages[real]['deps']:
            visit(dep)
        ordered.append(real)

    for req in root_packages:
        visit(req)
    tar_bin = shutil.which('tar') or '/usr/bin/tar'
    for pkg in ordered:
        apk_file = repo_dir / f'{pkg}-{packages[pkg]["version"]}.apk'
        require(apk_file.is_file(), f'missing offline APK: {apk_file}')
        run([tar_bin, '-xzf', apk_file, '-C', tree,
             '--exclude=.SIGN.*', '--exclude=.PKGINFO',
             '--exclude=.pre-*', '--exclude=.post-*', '--exclude=.trigger'],
            stderr=subprocess.DEVNULL)


def populate_alpine_tree(mini_archive, packages_archive, tree,
                         extra_packages=('alpine-base', 'openrc', 'openssh'),
                         preserve_owner=True):
    tar_bin = shutil.which('tar') or '/usr/bin/tar'
    owner_flags = ['--numeric-owner', '--same-owner'] if preserve_owner else ['--no-same-owner']
    run([tar_bin, '--extract', '--file', mini_archive, '--directory', tree,
         *owner_flags, '--same-permissions'])
    with tempfile.TemporaryDirectory(prefix='.alpine-apks-', dir=tree.parent) as temp:
        apks_root = Path(temp)
        run([tar_bin, '--extract', '--file', packages_archive, '--directory', apks_root,
             '--no-same-owner', './apks'])
        qemu_rv = shutil.which('qemu-riscv64') or shutil.which('qemu-riscv64-static')
        if qemu_rv:
            run([qemu_rv, '-U', 'LD_PRELOAD,LD_LIBRARY_PATH', '-L', tree,
                 tree / 'sbin/apk', '--arch', 'riscv64', '--root', tree,
                 '--repository', apks_root / 'apks', '--no-network', '--no-scripts',
                 'add', *extra_packages])
        else:
            _install_apks_python(apks_root / 'apks/riscv64', tree, extra_packages)


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


def make_alpine_disk(mini_archive, packages_archive, directory):
    tree = directory / 'tree'
    tree.mkdir()
    populate_alpine_tree(mini_archive, packages_archive, tree, preserve_owner=False)
    run(['ssh-keygen', '-q', '-A', '-f', tree])
    disk = directory / 'rootfs.ext4'
    with disk.open('xb') as stream:
        stream.truncate(256 * 1024**2)
    run(['/usr/sbin/mke2fs', '-q', '-t', 'ext4', '-F', '-m', '0', '-d', tree, disk])
    shutil.rmtree(tree)


def customize(disk, directory, harts=1):
    run(['riscv64-linux-gnu-gcc', '-O2', '-static', '-pthread', '-march=rv64gc', '-mabi=lp64d',
         ASSETS / 'smp_check.c', '-o', directory / 'smp-check'])
    key_stage = directory / 'ssh-keys'
    key_stage.mkdir(exist_ok=True)
    (key_stage / 'etc/ssh').mkdir(parents=True, exist_ok=True)
    run(['ssh-keygen', '-q', '-A', '-f', key_stage])
    files = {
        '/etc/raptor-harts': str(harts) + '\n',
        '/etc/fstab': '/dev/vda / ext4 defaults 0 1\n',
        '/etc/hostname': 'raptor-' + directory.name + '\n',
        '/etc/locale.conf': 'LANG=C.UTF-8\n',
        '/etc/vconsole.conf': 'KEYMAP=us\n',
        '/etc/systemd/network/10-raptor.network': '[Match]\nName=eth* en*\n\n[Network]\nDHCP=yes\n',
        '/etc/systemd/system/serial-getty@ttyS0.service.d/raptor.conf':
            ('[Service]\nExecStart=\nExecStart=-/usr/sbin/agetty --autologin root '
             '--noclear --keep-baud 115200,38400,9600 - $TERM\n'),
        '/etc/cloud/cloud-init.disabled': '',
        '/etc/systemd/system/raptor-distro-check.service': (ASSETS / 'check.service').read_text(),
        '/etc/systemd/system/raptor-distro-check.timer': (ASSETS / 'check.timer').read_text(),
        '/usr/local/lib/raptor-distro-check': (ASSETS / 'check.sh').read_text(),
    }
    commands = []
    directories = sorted({str(parent) for name in files for parent in Path(name).parents
                          if str(parent) != '/'} | {'/etc/ssh'},
                         key=lambda name: len(Path(name).parts))
    commands.extend('mkdir ' + name for name in directories)
    commands.append('mkdir /etc/systemd/system/timers.target.wants')
    for index, (name, content) in enumerate(files.items()):
        local = directory / ('overlay-' + str(index))
        local.write_text(content)
        commands.extend(['rm ' + name, f'write {local} {name}',
                         f'set_inode_field {name} uid 0', f'set_inode_field {name} gid 0',
                         f'set_inode_field {name} mode 0100644'])
    for key_file in sorted((key_stage / 'etc/ssh').iterdir()):
        guest_path = '/etc/ssh/' + key_file.name
        mode = '0100644' if key_file.name.endswith('.pub') else '0100600'
        commands.extend(['rm ' + guest_path, f'write {key_file} {guest_path}',
                         f'set_inode_field {guest_path} uid 0',
                         f'set_inode_field {guest_path} gid 0',
                         f'set_inode_field {guest_path} mode {mode}'])
    commands.extend([
        'rm /usr/local/lib/raptor-smp-check',
        f'write {directory / "smp-check"} /usr/local/lib/raptor-smp-check',
        'set_inode_field /usr/local/lib/raptor-smp-check mode 0100755',
        'set_inode_field /usr/local/lib/raptor-smp-check uid 0',
        'set_inode_field /usr/local/lib/raptor-smp-check gid 0',
        'rm /etc/systemd/system/timers.target.wants/raptor-distro-check.timer',
        'symlink /etc/systemd/system/timers.target.wants/raptor-distro-check.timer '
        '../raptor-distro-check.timer',
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
    debugfs_bin = shutil.which('debugfs') or '/usr/sbin/debugfs'
    e2fsck_bin = shutil.which('e2fsck') or '/usr/sbin/e2fsck'
    with (directory / 'customize.log').open('w') as log:
        run([debugfs_bin, '-w', '-f', command_file, disk], stdout=log, stderr=subprocess.STDOUT)
    run([e2fsck_bin, '-fn', disk], stdout=subprocess.DEVNULL)


def customize_alpine(disk, directory, harts=1):
    run(['riscv64-linux-gnu-gcc', '-O2', '-static', '-pthread', '-march=rv64gc', '-mabi=lp64d',
         ASSETS / 'smp_check.c', '-o', directory / 'smp-check'])
    inittab = (
        '::sysinit:/sbin/openrc sysinit\n'
        '::sysinit:/sbin/openrc boot\n'
        '::wait:/sbin/openrc default\n'
        'ttyS0::respawn:/sbin/getty -n -l /usr/local/sbin/raptor-autologin 115200 ttyS0 vt100\n'
        '::ctrlaltdel:/sbin/reboot\n'
        '::shutdown:/sbin/openrc shutdown\n'
    )
    local_hook = (
        '#!/bin/sh\n'
        'if grep -Eq "(^| )(raptor\\.interactive=1|systemd\\.mask=raptor-distro-check\\.timer)'
        '( |$)" /proc/cmdline; then\n'
        '    exit 0\n'
        'fi\n'
        '(sleep 2; /bin/sh /usr/local/lib/raptor-distro-check >/dev/console 2>&1) &\n'
    )
    files = {
        '/etc/raptor-harts': (str(harts) + '\n', '0100644'),
        '/etc/fstab': ('/dev/vda / ext4 defaults 0 1\n', '0100644'),
        '/etc/hostname': ('raptor-' + directory.name + '\n', '0100644'),
        '/etc/apk/repositories': (ALPINE_REPOSITORIES, '0100644'),
        '/etc/network/interfaces': (
            'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n', '0100644'),
        '/etc/inittab': (inittab, '0100644'),
        '/usr/local/sbin/raptor-autologin': ('#!/bin/sh\nexec /bin/login -f root\n', '0100755'),
        '/usr/local/lib/raptor-distro-check': ((ASSETS / 'check-alpine.sh').read_text(), '0100755'),
        '/etc/local.d/raptor-distro-check.start': (local_hook, '0100755'),
    }
    runlevels = {
        'sysinit': ('devfs', 'dmesg', 'mdev'),
        'boot': ('bootmisc', 'hostname', 'networking', 'sysctl', 'urandom'),
        'default': ('sshd', 'local'),
        'shutdown': ('killprocs', 'mount-ro', 'savecache'),
    }
    commands = []
    dirs = {str(parent) for name in files for parent in Path(name).parents if str(parent) != '/'}
    dirs.update({'/etc/runlevels', *[f'/etc/runlevels/{lvl}' for lvl in runlevels]})
    for dname in sorted(dirs, key=lambda item: len(Path(item).parts)):
        commands.append('mkdir ' + dname)
    for index, (name, (content, mode)) in enumerate(files.items()):
        local = directory / ('overlay-' + str(index))
        local.write_text(content)
        commands.extend(['rm ' + name, f'write {local} {name}',
                         f'set_inode_field {name} uid 0', f'set_inode_field {name} gid 0',
                         f'set_inode_field {name} mode {mode}'])
    commands.extend([
        'rm /usr/local/lib/raptor-smp-check',
        f'write {directory / "smp-check"} /usr/local/lib/raptor-smp-check',
        'set_inode_field /usr/local/lib/raptor-smp-check mode 0100755',
        'set_inode_field /usr/local/lib/raptor-smp-check uid 0',
        'set_inode_field /usr/local/lib/raptor-smp-check gid 0',
        'set_inode_field /etc/shadow mode 0100600',
    ])
    for lvl, svcs in runlevels.items():
        for svc in svcs:
            link = f'/etc/runlevels/{lvl}/{svc}'
            commands.extend(['rm ' + link, f'symlink {link} /etc/init.d/{svc}'])
    command_file = directory / 'debugfs.commands'
    command_file.write_text('\n'.join(commands) + '\n')
    debugfs_bin = shutil.which('debugfs') or '/usr/sbin/debugfs'
    e2fsck_bin = shutil.which('e2fsck') or '/usr/sbin/e2fsck'
    with (directory / 'customize.log').open('w') as log:
        run([debugfs_bin, '-w', '-f', command_file, disk], stdout=log, stderr=subprocess.STDOUT)
    run([e2fsck_bin, '-fn', disk], stdout=subprocess.DEVNULL)


def nemu_build_flags(sanitize=None):
    # 1 GiB of RAM plus the 1 GiB flash window exceed the 2 GiB static data
    # reachable with the default x86-64 code model. Move only those arrays to
    # large sections; smaller (including thread-local) data stays put.
    build = (['-O1', '-g', '-fsanitize=' + sanitize, '-fno-omit-frame-pointer']
             if sanitize else ['-O2'])
    if platform.machine() == 'x86_64':
        build += ['-mcmodel=medium', '-mlarge-data-threshold=16777216']
    build += ['-Wno-unused-function']
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


def rtl_preset_info(preset):
    cfg_path = ROOT / 'rtl/configs' / preset / 'rapt_config.svh'
    require(cfg_path.is_file(), 'unknown RTL preset: ' + str(preset))
    defs = parse_rapt_config(cfg_path, True)
    vec = bool(defs.get('RAPT_V_EXTENSION'))
    return {
        'nharts': int(defs.get('RAPT_NHARTS', 1)),
        'vector': vec,
        'rva23': vec and not bool(defs.get('RAPT_NO_RVA23U64')),
    }


def resolve_sim_preset(requested, harts, rva23=False):
    if requested not in (None, '', 'auto'):
        return requested
    if harts == 1:
        return 'default'
    if harts == 2:
        return 'default-smp2'
    if harts == 4 and not rva23:
        return 'middle-smp4'
    require(False, f'no default RTL preset for harts={harts} (rva23={rva23}); pass --sim-preset')


def ensure_sim_binary(preset='default', explicit=None):
    if explicit:
        binary = Path(explicit).resolve()
        require(binary.is_file(), 'RTL simulator binary not found: ' + str(binary))
        return binary
    fast_bin = ROOT / 'sim/build' / f'{preset}-pmem2g/riscv64-npc-sim-t4'
    if not fast_bin.is_file():
        run(['make', '-C', ROOT / 'sim', 'all', 'XLEN=64', 'VFLAGS=-DRAPT_RV64',
             f'RAPT_CONFIG={preset}', 'SIM_MEM_PROFILE=large', 'DIFFTEST=0',
             'SIM_FAST=1', 'SIM_TRACE=0', 'RAPT_SIM_ASSERT=0'])
    require(fast_bin.is_file(), 'failed to build fast 2 GiB RTL simulator: ' + str(fast_bin))
    return fast_bin


def prepare_sim_mrom(directory, interactive=False, memory_mib=256, harts=1, preset='default'):
    require(128 <= memory_mib <= 2048, 'RTL sim memory_mib must be 128..2048')
    info = rtl_preset_info(preset)
    base_dts = 'raptor-rva23-io.dts' if info['rva23'] else 'raptor-rv64gc-io.dts'
    tag = f'{preset}-h{harts}' + ('-interactive' if interactive else '')
    mem_bytes = memory_mib * 1024 * 1024
    dtb = directory / f'sim-{tag}.dtb'
    build_dtb(directory, harts, source_name=base_dts, output_dtb=dtb)
    run(['fdtput', '-t', 'x', dtb, '/memory@80000000', 'reg', '0', '80000000',
         f'{(mem_bytes >> 32) & 0xffffffff:x}', f'{mem_bytes & 0xffffffff:x}'])
    run(['fdtput', '-t', 'bx', dtb, '/chosen', 'rng-seed',
         *[f'{b:02x}' for b in os.urandom(64)]])
    vec_arg = 'unaligned_vector_speed=fast ' if info['vector'] else ''
    bootargs = ('console=ttyS0,115200 earlycon=sbi root=/dev/vda rw rootwait init=/sbin/init '
                f'unaligned_scalar_speed=fast {vec_arg}swiotlb=1024 cryptomgr.notests=1 '
                'initcall_blacklist=jent_mod_init,brd_init random.trust_bootloader=on '
                'lpj=50000 systemd.show_status=yes')
    if interactive:
        bootargs += ' systemd.mask=raptor-distro-check.timer raptor.interactive=1'
    run(['fdtput', '-t', 's', dtb, '/chosen', 'bootargs', bootargs])
    mrom_dir = directory / f'sim-mrom-{tag}'
    cross = ('riscv64-linux-gnu-' if shutil.which('riscv64-linux-gnu-gcc')
             else 'riscv64-unknown-elf-')
    isa_ext = 'zicbom zicboz svpbmt sstc' if info['rva23'] else ''
    run(['make', '-s', '-C', ROOT / 'sim/csrc/mem/mrom-data', 'ISA64=1',
         'CROSS_COMPILE=' + cross,
         'BUILD_DIR=' + str(mrom_dir), 'DT_SOURCE=' + str(dtb),
         'ISA_EXTENSIONS=' + isa_ext])
    return mrom_dir / 'mrom-data.bin'


def build_dtb(directory, harts, source_name='nemu-distro-rv64.dts', output_dtb=None):
    require(1 <= harts <= 16, 'requires 1..16 harts')
    dtb = output_dtb or (directory / 'nemu.dtb')
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
        nodes.append(
            f'cpu@{hartid:x} {{ reg = <{hartid}>; ' + '\n'.join(template) +
            f' cpu{hartid}_intc: interrupt-controller {{ #address-cells = <2>; '
            '#interrupt-cells = <1>; interrupt-controller; compatible = "riscv,cpu-intc"; }; };')
    clint = ' '.join(f'&cpu{hartid}_intc 3 &cpu{hartid}_intc 7' for hartid in range(harts))
    plic = ' '.join(f'&cpu{hartid}_intc 11 &cpu{hartid}_intc 9' for hartid in range(harts))
    source = directory / (dtb.stem + '-smp.dts')
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
    ubuntu_kernel = kernel_record.get('schema') in (
        'raptor-ubuntu-kernel-v1', 'raptor-native-ubuntu-kernel-v1')
    require((kernel_record.get('bits') == 64 and kernel_record.get('profile') == 'fpga')
            or ubuntu_kernel,
            'requires an RV64 external-rootfs kernel artifact directory')
    rva23 = SOURCES[args.distro].get('isa_profile') == 'rva23'
    config = (args.kernel_artifacts / 'kernel.config').read_text()
    required = ['VIRTIO_BLK', 'EXT4_FS', 'DEVTMPFS_MOUNT', 'CGROUPS', 'FHANDLE',
                'SERIAL_8250_CONSOLE', 'FPU']
    if rva23:
        required += ['RISCV_ISA_V', 'RISCV_ISA_SUPM', 'RISCV_ISA_SVNAPOT',
                     'RISCV_ISA_SVPBMT', 'RISCV_ISA_ZICBOZ', 'KVM']
    for option in required:
        require(f'CONFIG_{option}=y\n' in config, 'kernel lacks ' + option)
    require('CONFIG_INITRAMFS_SOURCE=""\n' in config and 'CONFIG_CMDLINE_FORCE=y' not in config,
            'kernel must accept the platform command line and external disk root')
    archive = download(args.distro, args.downloads)
    directory.mkdir(parents=True)
    disk = directory / 'rootfs.ext4'
    fmt = SOURCES[args.distro]['format']
    if fmt == 'qcow2':
        raw = directory / 'cloud.raw'
        run(['qemu-img', 'convert', '-O', 'raw', archive, raw])
        extract_partition(raw, disk)
        raw.unlink()
    elif fmt == 'raw-tar':
        run(['/usr/bin/tar', '--sparse', '--extract', '--file', archive,
             '--directory', directory, 'disk.raw'])
        raw = directory / 'disk.raw'
        extract_partition(raw, disk)
        raw.unlink()
    elif fmt == 'alpine':
        packages = download_packages(args.distro, args.downloads)
        prefix = ([] if os.geteuid() == 0 else
                  (['unshare', '-r'] if shutil.which('unshare') else ['fakeroot']))
        run([*prefix, 'python3', Path(__file__).resolve(), 'alpine-disk',
             '--archive', archive, '--packages-archive', packages, '--work', directory])
    else:
        run(['fakeroot', 'python3', Path(__file__).resolve(), 'tar-disk',
             '--archive', archive, '--work', directory])
    if args.harts > 1:
        require('CONFIG_SMP=y\n' in config, 'kernel lacks SMP')
        count = re.search(r'^CONFIG_NR_CPUS=(\d+)$', config, re.M)
        require(count and int(count[1]) >= args.harts, 'kernel has too few CPU slots')
    if fmt == 'alpine':
        customize_alpine(disk, directory, args.harts)
    else:
        customize(disk, directory, args.harts)
    for name in ('Image', 'kernel.config'):
        shutil.copyfile(args.kernel_artifacts / name, directory / name)
    with (directory / 'opensbi.log').open('w') as log:
        run(['python3', Path(__file__).resolve(), 'firmware', '--work', directory],
            stdout=log, stderr=subprocess.STDOUT)
    dtb_source = 'nemu-distro-rva23.dts' if rva23 else 'nemu-distro-rv64.dts'
    build_dtb(directory, args.harts, source_name=dtb_source)
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
    if args.engine == 'nemu':
        require(sha(binary) == record['nemu_sha256'],
                'NEMU binary changed; prepare a new manifest')
    interactive = args.action == 'run'
    dtb = directory / 'nemu.dtb'
    if interactive and args.engine != 'sim':
        dtb = directory / 'interactive.dtb'
        shutil.copyfile(directory / 'nemu.dtb', dtb)
        bootargs = run(['fdtget', '-t', 's', dtb, '/chosen', 'bootargs'],
                       capture_output=True).stdout.decode().strip()
        run(['fdtput', '-t', 's', dtb, '/chosen', 'bootargs',
             bootargs + ' systemd.mask=raptor-distro-check.timer raptor.interactive=1'])
    rva23 = record.get('source', {}).get('isa_profile') == 'rva23'
    if args.engine == 'nemu':
        command = [str(binary), '-b', '-n', '-t', str(dtb),
                   '--disk=' + str(directory / 'rootfs.ext4'),
                   '--log=' + str(directory / ('interactive-monitor.log' if interactive
                                               else 'nemu-monitor.log')),
                   str(directory / 'fw_payload.bin')]
        if rva23:
            command.insert(1, '--isa-extensions=rva23')
        if harts > 1:
            command.insert(1, '--smp=' + str(harts))
        if backend == 'threaded':
            command.insert(1, '--smp-backend=threaded')
            command.insert(1, '--smp-clock-div=' + str(clock_div))
    elif args.engine == 'sim':
        require(1 <= harts <= 16, 'RTL sim distro boot requires 1..16 harts')
        (directory / 'data').mkdir(exist_ok=True)
        sim_preset = resolve_sim_preset(getattr(args, 'sim_preset', None), harts, rva23=rva23)
        info = rtl_preset_info(sim_preset)
        require(info['nharts'] == harts,
                f'RTL preset {sim_preset} has {info["nharts"]} harts, manifest requires {harts}')
        if rva23:
            require(info['rva23'],
                    f'{args.distro} RVA23 requires an RVA23 preset, got {sim_preset}')
        default_sim_mem = 128 if args.distro == 'alpine' else 256
        sim_mem = getattr(args, 'sim_memory_mib', None) or default_sim_mem
        sim_milestone = getattr(args, 'sim_milestone', None)
        sim_bin = ensure_sim_binary(sim_preset, getattr(args, 'sim_binary', None))
        mrom_bin = prepare_sim_mrom(directory, interactive=interactive, memory_mib=sim_mem,
                                    harts=harts, preset=sim_preset)
        command = [str(sim_bin), '-b', '-n', '--no-lightsss', '--trap-on-ebreak',
                   '--disk=' + str(directory / 'rootfs.ext4'),
                   '--virtio-net', '-r', str(mrom_bin),
                   '-l', str(directory / ('sim-interactive.log' if interactive
                                          else 'sim-monitor.log')),
                   str(directory / 'fw_payload.bin')]
        if sim_milestone and not interactive:
            command.insert(4, '--serial-exit-on=' + sim_milestone)
    else:
        qemu_cpu = 'rva23s64' if rva23 else 'rv64,h=false,sstc=false,svadu=false'
        command = ['qemu-system-riscv64', '-M', 'virt', '-cpu', qemu_cpu,
                   '-m', '1024M', '-smp', str(harts), '-nographic', '-no-reboot', '-snapshot',
                   '-bios', str(directory / 'fw_payload.bin'),
                   '-drive', f'file={directory / "rootfs.ext4"},format=raw,if=none,id=root',
                   '-device', 'virtio-blk-device,drive=root', '-netdev', 'user,id=net',
                   '-device', 'virtio-net-device,netdev=net', '-append',
                   'console=ttyS0 root=/dev/vda rw rootwait init=/sbin/init '
                   'random.trust_bootloader=on',
                   '-kernel', str(directory / 'Image')]
        if interactive:
            command[command.index('-append') + 1] += (
                ' systemd.mask=raptor-distro-check.timer raptor.interactive=1')
    environment = dict(os.environ, NEMU_HOME=str(ROOT / 'nemu'), NEMU_STATUS_DIR=str(directory),
                       TMPDIR=str(directory))
    if interactive:
        run(command, cwd=directory, env=environment)
        return
    manifest_digest = sha(directory / 'manifest.json')
    resultpath = directory / (args.engine + '-result.json')
    resultpath.unlink(missing_ok=True)
    process = subprocess.Popen(command, cwd=directory, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                               env=environment)
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
        sim_milestone = getattr(args, 'sim_milestone', None)
        if args.engine == 'sim' and sim_milestone:
            smp_ok = harts == 1 or f'Brought up 1 node, {harts} CPUs'.encode() in output
            passed = (process.returncode == 0
                      and sim_milestone.encode() in output
                      and smp_ok
                      and not re.search(FAULTS, output))
        else:
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


def default_kernel_artifacts(distro, harts=1):
    variant = 'alpine' if distro == 'alpine' else 'debian'
    candidates = [HOME / f'build/raptor/v6.18.51/rv64-{variant}-fpga',
                  HOME / 'build/raptor/v6.18.51/rv64-debian-fpga']
    candidates += [m.parent for m in sorted(
        ROOT.glob('fpga/*/build/*/kernels/*/manifest.json'),
        key=lambda p: p.stat().st_mtime, reverse=True)]
    for cand in candidates:
        cfg = cand / 'kernel.config'
        if (cand / 'manifest.json').is_file() and cfg.is_file():
            if harts <= 1 or 'CONFIG_SMP=y\n' in cfg.read_text():
                return cand
    return candidates[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('download', 'prepare', 'check', 'run',
                                           'tar-disk', 'alpine-disk', 'firmware'))
    parser.add_argument('--distro', choices=SOURCES, default=None,
                        help='distribution (default: debian for 1 hart, alpine for SMP)')
    parser.add_argument('--work', type=Path, default=HOME / 'build/distro-boot')
    parser.add_argument('--downloads', type=Path, default=HOME / 'build/distro-boot/downloads')
    parser.add_argument('--kernel-artifacts', type=Path, default=None)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--packages-archive', type=Path)
    parser.add_argument('--engine', choices=('nemu', 'sim', 'qemu'), default='nemu')
    parser.add_argument('--sim-preset', default='auto',
                        help='RTL preset for --engine sim (default: auto from --harts)')
    parser.add_argument('--sim-memory-mib', type=int, default=None,
                        help='guest RAM MiB for --engine sim (default: 128 alpine, 256 others)')
    parser.add_argument('--sim-milestone',
                        help='exit RTL sim cleanly once serial TX reaches this milestone')
    parser.add_argument('--sim-binary', type=Path,
                        help='optional prebuilt 2 GiB riscv64-npc-sim binary')
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--harts', type=int, choices=range(1, 17), default=1)
    parser.add_argument('--nemu-backend', choices=('rr', 'threaded'))
    parser.add_argument('--nemu-clock-div', type=int, choices=range(1, 1001), metavar='1..1000')
    args = parser.parse_args()
    if args.distro is None:
        if args.action in ('check', 'run'):
            for cand in ('alpine', 'debian', 'ubuntu', 'ubuntu-lts'):
                if ((args.work / cand) / 'manifest.json').is_file():
                    args.distro = cand
                    break
        if args.distro is None:
            args.distro = 'alpine' if args.harts > 1 else 'debian'
    args.work = args.work.resolve()
    args.downloads = args.downloads.resolve()
    raw_kernel = args.kernel_artifacts or default_kernel_artifacts(args.distro, args.harts)
    args.kernel_artifacts = raw_kernel.resolve()
    if args.action == 'download':
        download(args.distro, args.downloads)
    elif args.action == 'prepare':
        prepare(args)
    elif args.action in ('check', 'run'):
        check(args)
    elif args.action == 'tar-disk':
        make_tar_disk(args.archive, args.work)
    elif args.action == 'alpine-disk':
        make_alpine_disk(args.archive, args.packages_archive, args.work)
    else:
        opensbi(args.work / 'Image', 64, args.work / 'fw_payload.bin', 'riscv64-linux-gnu-')


if __name__ == '__main__':
    main()
