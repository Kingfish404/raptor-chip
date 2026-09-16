#!/usr/bin/env python3
"""Build Raptor RV32/RV64 Linux from pinned releases for sim/NEMU or LiteX."""
import argparse
import contextlib
import fcntl
import gzip
import json
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tempfile

from raptor_linux import HOME, export_rootfs, identity, kernel, require, run, sha


@contextlib.contextmanager
def lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def verify(path):
    record = json.loads((path / 'manifest.json').read_text())
    for name, digest in record['files'].items():
        require(Path(name).name == name and sha(path / name) == digest, 'artifact changed: ' + name)
    return record


def overlay(raw, entries):
    """Concatenate a newc overlay, retaining release ownership and special files."""
    raw = bytearray(raw)
    raw.extend(b'\0' * (-len(raw) % 4))
    for name, content in [*entries.items(), ('TRAILER!!!', b'')]:
        encoded = name.encode() + b'\0'
        fields = (0, stat.S_IFREG | 0o755, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(encoded), 0)
        header = b'070701' + ''.join(f'{v:08x}' for v in fields).encode() + encoded
        raw.extend(header + b'\0' * (-len(header) % 4))
        raw.extend(content + b'\0' * (-len(content) % 4))
    return bytes(raw)


def rootfs(package, cache):
    manifest = json.loads((package / 'manifest.json').read_text())
    is_disk = 'rootfs.ext4' in manifest['files']
    source = 'rootfs.ext4' if is_disk else 'initramfs.cpio.gz'
    require(sha(package / source) == manifest['files'][source], 'release rootfs hash mismatch')
    inputs = [manifest['files'][source], sha(HOME / 'raptor-persist.sh'),
              sha(HOME / 'raptor_linux.py'), sha(Path(__file__))]
    output = cache / identity(inputs)
    if output.exists():
        verify(output)
        return output
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='raptor-chip-rootfs-', dir='/tmp') as tmp:
        work = Path(tmp)
        if is_disk:
            (work / 'root').mkdir()
            export_rootfs(package / source, work / 'root', work, HOME / 'raptor-persist.sh')
            raw = (work / 'rootfs.cpio').read_bytes()
        else:
            init = b'''#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /proc /sys /dev /run
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs -o mode=0755 tmpfs /run
/sbin/raptor-persist || echo "SD persistence unavailable; continuing in RAM" >&2
exec /sbin/init
'''
            raw = overlay(gzip.decompress((package / source).read_bytes()), {
                'sbin/raptor-persist': (HOME / 'raptor-persist.sh').read_bytes(), 'sbin/raptor-init': init,
                'etc/init.d/S50sshd': b'''#!/bin/sh
case "$1" in
 start)
  (
   mkdir -p /run/sshd
   [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
   /usr/sbin/sshd
  ) </dev/null >/run/raptor-ssh.log 2>&1 &
  ;;
 stop) killall sshd 2>/dev/null || true ;;
 restart) "$0" stop; "$0" start ;;
esac
'''} )
            (work / 'rootfs.cpio').write_bytes(raw)
            (work / 'rootfs.cpio.gz').write_bytes(gzip.compress(raw, compresslevel=1, mtime=0))
        with tempfile.TemporaryDirectory(prefix='.rootfs-', dir=cache) as tmp_out:
            stage = Path(tmp_out) / 'result'
            stage.mkdir()
            names = ('rootfs.cpio', 'rootfs.cpio.gz')
            for name in names:
                shutil.copyfile(work / name, stage / name)
            (stage / 'manifest.json').write_text(json.dumps({'files': {n: sha(stage / n) for n in names},
                                                          'source': inputs, 'bytes': len(raw)}))
            stage.rename(output)
    return output


def opensbi_fingerprint():
    source = HOME.parent / 'third_party/riscv-software-src/opensbi'
    require((source / 'Makefile').is_file(), 'OpenSBI submodule missing; run repository setup')
    return identity({str(p.relative_to(source)): sha(p) for p in sorted(source.rglob('*'))
                     if p.is_file() and (p.suffix in ('.c', '.h', '.S', '.mk', '.ldS') or
                                         p.name in ('Makefile', 'Kconfig', 'defconfig')) and 'build' not in p.parts})


def opensbi(image, bits, output, cross):
    source = HOME.parent / 'third_party/riscv-software-src/opensbi'
    before = opensbi_fingerprint()
    with tempfile.TemporaryDirectory(prefix='raptor-chip-linux-opensbi-', dir='/tmp') as tmp:
        # Raptor's RTL simulation harness treats EBREAK as a test terminator,
        # including the speculative semihosting probe used by generic OpenSBI.
        config = (source / 'platform/generic/configs/defconfig').read_text()
        require('CONFIG_SERIAL_SEMIHOSTING=y' in config, 'OpenSBI generic config changed; review semihosting policy')
        config = config.replace('CONFIG_SERIAL_SEMIHOSTING=y', '# CONFIG_SERIAL_SEMIHOSTING is not set')
        kconfig = Path(tmp) / 'platform/generic/kconfig/.config'
        kconfig.parent.mkdir(parents=True)
        kconfig.write_text(config)
        subprocess.run(['make', '-C', str(source), 'O=' + tmp, 'PLATFORM=generic',
                        f'PLATFORM_RISCV_XLEN={bits}', f'PLATFORM_RISCV_ISA=rv{bits}imafdc_zicntr_zicsr_zifencei',
                        'CROSS_COMPILE=' + cross, 'FW_PAYLOAD_PATH=' + str(image),
                        'FW_PAYLOAD_FDT_ADDR=0x8fff0000', '-j8'], check=True)
        require(opensbi_fingerprint() == before, 'OpenSBI sources changed during build')
        require('CONFIG_SERIAL_SEMIHOSTING=y' not in kconfig.read_text(), 'semihosting was re-enabled')
        shutil.copyfile(Path(tmp) / 'platform/generic/firmware/fw_payload.bin', output)
    require(output.stat().st_size < 0x0fff0000, 'payload overlaps simulator FDT at 0x8fff0000')
    return before


def build(package, bits, distro, profile, output, cache, cross):
    manifest = json.loads((package / 'manifest.json').read_text())
    require(manifest['bits'] == bits, 'release XLEN mismatch')
    require(bits == 64 or distro == 'buildroot', 'Alpine/Debian release userspace requires RV64GC')
    if distro != 'buildroot':
        require(manifest['variant'] == distro, 'release distro mismatch')
    require(not output.exists(), 'output must be a new directory (existing artifacts are immutable)')
    for name in ('fw_dynamic.bin', 'kernel.config'):
        require(sha(package / name) == manifest['files'][name], 'source changed: ' + name)
    with lock(cache / 'build.lock'):
        ram = rootfs(package, cache / 'rootfs')
        if profile == 'sim':
            require((ram / 'rootfs.cpio').stat().st_size < 140 * 1024 * 1024, 'rootfs too large for 256 MiB sim RAM')
        built = kernel(package, cache, cross, profile=profile,
                       rootfs=ram / 'rootfs.cpio' if profile == 'sim' else None)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.linux-', dir=output.parent) as tmp:
        stage = Path(tmp) / 'result'
        stage.mkdir()
        shutil.copyfile(built / 'arch/riscv/boot/Image', stage / 'Image')
        shutil.copyfile(built / '.config', stage / 'kernel.config')
        shutil.copyfile(package / 'fw_dynamic.bin', stage / 'fw_dynamic.bin')
        for name in ('rootfs.cpio', 'rootfs.cpio.gz'):
            shutil.copyfile(ram / name, stage / name)
        header = (stage / 'Image').read_bytes()[:64]
        require(header[56:60] == b'RSC\x05', 'bad kernel Image')
        limit = 0x0fff0000 if profile == 'sim' else 0x03f00000
        offset = 0x400000 if bits == 32 else 0x200000
        require(struct.unpack_from('<Q', header, 8)[0] == offset, 'kernel XLEN/load alignment mismatch')
        require(struct.unpack_from('<Q', header, 16)[0] + offset < limit, 'kernel runtime overlaps FDT')
        record = {'schema': 'raptor-linux-v1', 'bits': bits, 'distro': distro, 'profile': profile,
                  'kernel_version': manifest['kernel_version'], 'source_manifest_sha256': sha(package / 'manifest.json'),
                  'builder_sha256': sha(Path(__file__)), 'runtime_sha256': sha(HOME / 'raptor-persist.sh'),
                  'kernel_builder_sha256': sha(HOME / 'raptor_linux.py'), 'rootfs_persistent': False,
                  'compiler': run(cross + 'gcc', '--version').decode(),
                  'ram_mib': 256 if profile == 'sim' else 1024, 'init': '/sbin/raptor-init',
                  'board_validated': False}
        if profile == 'sim':
            record['opensbi_source_sha256'] = opensbi(stage / 'Image', bits, stage / 'fw_payload.bin', cross)
        record['files'] = {p.name: sha(p) for p in stage.iterdir()}
        (stage / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
        verify(stage)
        stage.rename(output)
    print('LINUX_ARTIFACTS=' + str(output), flush=True)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', required=True, type=Path)
    parser.add_argument('--xlen', required=True, type=int, choices=(32, 64))
    parser.add_argument('--distro', required=True, choices=('buildroot', 'alpine', 'debian'))
    parser.add_argument('--profile', required=True, choices=('sim', 'fpga'))
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cache', type=Path, default=HOME / 'build/netboot-kernels')
    parser.add_argument('--cross', default='riscv64-linux-gnu-')
    args = parser.parse_args()
    with lock(args.output.resolve().parent / ('.' + args.output.name + '.lock')):
        if args.output.exists():
            record = verify(args.output)
            require((record['bits'], record['distro'], record['profile']) == (args.xlen, args.distro, args.profile),
                    'existing output belongs to another profile')
            require(record['source_manifest_sha256'] == sha(args.package / 'manifest.json') and
                    record['builder_sha256'] == sha(Path(__file__)) and
                    record['kernel_builder_sha256'] == sha(HOME / 'raptor_linux.py') and
                    record['runtime_sha256'] == sha(HOME / 'raptor-persist.sh'),
                    'build inputs changed; choose a new LINUX_OUTPUT directory')
            require(record.get('compiler') == run(args.cross + 'gcc', '--version').decode(),
                    'compiler changed; choose a new LINUX_OUTPUT directory')
            if args.profile == 'sim':
                require(record['opensbi_source_sha256'] == opensbi_fingerprint(),
                        'OpenSBI changed; choose a new LINUX_OUTPUT directory')
            print('LINUX_ARTIFACTS=' + str(args.output.resolve()))
        else:
            build(args.package.resolve(), args.xlen, args.distro, args.profile, args.output.resolve(),
                  args.cache.resolve(), args.cross)


if __name__ == '__main__':
    main()
