#!/usr/bin/env python3
"""Build an immutable RV64 Alpine/Debian RAM-root bundle; no board/host setup."""
from netboot_names import name_bundle

import argparse
import gzip
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import struct
import stat
import subprocess
from add_linux_sdcard_dts import ensure_sdcard_dtb
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "linux"))
from raptor_linux import background_services, export_rootfs

LITEX = Path(__file__).resolve().parents[1]
ADDRESSES = {'fw_dynamic.bin': 0x80000000, 'Image': 0x80200000,
             'soc.dtb': 0x83f00000, 'rootfs.cpio.gz': 0x88000000,
             'stage0.bin': 0x87f00000}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], stderr=subprocess.STDOUT)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def persistence_bootargs(selector, logs=False):
    require(re.fullmatch(r'(LABEL|UUID)=[a-zA-Z0-9_-]+', selector), 'invalid data selector')
    return ('' if selector == 'LABEL=RAPTOR_DATA' else ' raptor.data=' + selector) + (
            ' raptor.persist_logs=1' if logs else '')




def build(package, kernel, soc, output, work, sd_csr=None, persistence_runtime=None,
          data_selector='LABEL=RAPTOR_DATA', persist_logs=False, initramfs_compression='gzip', cross='riscv64-linux-gnu-'):
    require(initramfs_compression in ('gzip', 'none'), 'invalid initramfs compression')
    rootfs_name = 'rootfs.cpio.gz' if initramfs_compression == 'gzip' else 'rootfs.cpio'
    addresses = dict(ADDRESSES)
    addresses[rootfs_name] = addresses.pop('rootfs.cpio.gz')
    require(bool(sd_csr) == bool(persistence_runtime), 'SD CSR and persistence runtime must be supplied together')
    extra_bootargs = persistence_bootargs(data_selector, persist_logs)
    require(sd_csr or not extra_bootargs, 'persistence options require SD CSR/runtime')
    require(not output.exists(), 'output must be a new directory')
    manifest = json.loads((package / 'manifest.json').read_text())
    require(manifest['bits'] == 64 and manifest['variant'] in ('alpine', 'debian'),
            'requires an RV64 Alpine/Debian disk package')
    for name in ('rootfs.ext4', 'fw_dynamic.bin', 'kernel.config'):
        require(sha(package / name) == manifest['files'][name], f'source hash mismatch: {name}')
    config = (kernel / '.config').read_text()
    for option in ('64BIT', 'BLK_DEV_INITRD', 'RD_GZIP', 'DEVTMPFS',
                   'SERIAL_LITEUART', 'SERIAL_LITEUART_CONSOLE', 'LITEX_LITEETH'):
        require(f'CONFIG_{option}=y\n' in config, f'kernel lacks {option}')
    require('CONFIG_INITRAMFS_SOURCE=""\n' in config, 'kernel must have no embedded rootfs')
    if sd_csr:
        for option in ('MMC', 'MMC_BLOCK', 'MMC_LITEX', 'EXT4_FS', 'REGULATOR_FIXED_VOLTAGE'):
            require(f'CONFIG_{option}=y\n' in config, f'persistent SD kernel lacks {option}')
    require(run('fdtget', '-t', 's', soc, '/cpus/cpu@0', 'riscv,isa-base').strip() == b'rv64i',
            'DTB must be RV64')
    require(run('fdtget', '-t', 'x', soc, '/memory@80000000', 'reg').strip() == b'80000000 40000000',
            'this test layout requires the 1 GiB FPGA RAM map')
    work.mkdir(parents=True, exist_ok=False)
    root = work / 'root'
    root.mkdir()
    export_rootfs(package / 'rootfs.ext4', root, work, persistence_runtime)
    busybox = root / 'bin/busybox'
    # Resolve guest absolute symlinks without following them into the host.
    require(not (root / 'bin').is_symlink() or (root / 'bin').readlink() == Path('usr/bin'),
            'unexpected guest /bin symlink')
    data = busybox.read_bytes()[:24]
    require(data[:5] == b'\x7fELF\x02' and struct.unpack_from('<H', data, 18)[0] == 243,
            'userspace BusyBox must be RV64 ELF')
    require(sha(package / 'rootfs.ext4') == manifest['files']['rootfs.ext4'], 'source disk changed')
    files = work / 'files'
    files.mkdir()
    shutil.copyfile(kernel / 'arch/riscv/boot/Image', files / 'Image')
    shutil.copyfile(package / 'fw_dynamic.bin', files / 'fw_dynamic.bin')
    shutil.copyfile(work / rootfs_name, files / rootfs_name)
    shutil.copyfile(soc, files / 'soc.dtb')
    size = (files / rootfs_name).stat().st_size
    require(0x88000000 + size < 0xc0000000, 'initramfs exceeds FPGA RAM')
    require((work / 'rootfs.cpio').stat().st_size + size < 700 * 1024 * 1024,
            'RAM root leaves insufficient headroom in 1 GiB')
    require((files / 'Image').stat().st_size < 0x83f00000 - 0x80200000, 'kernel overlaps DTB')
    image = (files / 'Image').read_bytes()[:64]
    require(image[56:60] == b'RSC\x05', 'invalid RISC-V Image header')
    require(struct.unpack_from('<Q', image, 16)[0] < 0x83f00000 - 0x80200000,
            'kernel runtime memory overlaps DTB')
    require((files / 'fw_dynamic.bin').stat().st_size < 0x200000, 'OpenSBI overlaps kernel')
    dtb = files / 'soc.dtb'
    if sd_csr:
        ensure_sdcard_dtb(soc, json.loads(sd_csr.read_text()), dtb)
    run('fdtput', '-t', 'x', dtb, '/chosen', 'linux,initrd-start', '88000000')
    run('fdtput', '-t', 'x', dtb, '/chosen', 'linux,initrd-end', f'{0x88000000 + size:x}')
    bootargs = ('console=liteuart0,115200 earlycon=sbi rdinit=/sbin/raptor-init pty.legacy_count=0 '
                'random.trust_bootloader=on') + extra_bootargs
    run('fdtput', '-t', 's', dtb, '/chosen', 'bootargs', bootargs)
    run(cross + 'gcc', '-march=rv64imac_zicsr_zifencei', '-mabi=lp64',
        '-nostdlib', '-nostartfiles', '-static', '-fno-pic', '-no-pie',
        '-Wl,--build-id=none,-Ttext=0x87f00000', '-o', work / 'stage0.elf',
        LITEX / 'firmware/linux-fpga/netboot_dynamic.S')
    run(cross + 'objcopy', '-O', 'binary', work / 'stage0.elf', files / 'stage0.bin')
    require((files / 'stage0.bin').stat().st_size < 4096, 'trampoline too large')
    record = {'schema': 'raptor-distro-netboot-v1', 'xlen': 64, 'distro': manifest['variant'],
              'startup_cmo_policy': 'menvcfg-cbie3-cbcfe1',
              'board_validated': False, 'rootfs_persistent': False, 'source': str(package),
              'source_manifest_sha256': sha(package / 'manifest.json'),
              'source_disk_sha256': manifest['files']['rootfs.ext4'],
              'kernel_config_sha256': sha(kernel / '.config'),
              'source_dtb_sha256': sha(soc), 'bootargs': bootargs,
              'rootfs_uncompressed_bytes': (work / 'rootfs.cpio').stat().st_size,
              'initramfs_file': rootfs_name,
              'files': {name: sha(files / name) for name in addresses}}
    if sd_csr:
        record.update(persistent_directories=['/data', '/home', '/root'] + (['/var/log'] if persist_logs else []),
                      data_selector=data_selector, sd_csr_sha256=sha(sd_csr),
                      persistence_runtime_sha256=sha(persistence_runtime))
    record['kernel_version'] = manifest['kernel_version']
    relative = Path(name_bundle(record))
    record['tftp_path'] = str(relative)
    boot = {str(relative / name): hex(address) for name, address in addresses.items()}
    boot['addr'] = hex(ADDRESSES['stage0.bin'])
    (files / 'boot.json').write_text(json.dumps(boot, indent=2) + '\n')
    record['files']['boot.json'] = sha(files / 'boot.json')
    (files / 'bundle.json').write_text(json.dumps(record, indent=2) + '\n')
    shutil.copytree(files, output)
    shutil.copyfile(kernel / '.config', output / 'kernel.config')
    for path in output.iterdir():
        path.chmod(0o444)
    print(f'BUNDLE={output}\nTFTP_PATH={relative}\nnetboot {relative}/boot.json', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('package', 'kernel', 'soc', 'output', 'work'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--sd-csr', type=Path)
    parser.add_argument('--persistence-runtime', type=Path)
    parser.add_argument('--data-selector', default='LABEL=RAPTOR_DATA')
    parser.add_argument('--persist-logs', action='store_true')
    parser.add_argument('--initramfs-compression', choices=('gzip', 'none'), default='gzip')
    args = parser.parse_args()
    build(*(getattr(args, name).resolve() for name in ('package', 'kernel', 'soc', 'output', 'work')),
          sd_csr=args.sd_csr, persistence_runtime=args.persistence_runtime,
          data_selector=args.data_selector, persist_logs=args.persist_logs,
          initramfs_compression=args.initramfs_compression)
