#!/usr/bin/env python3
"""Package project-built Linux artifacts for the matching LiteX DTB and CSR map."""
import argparse
import json
from pathlib import Path
import shutil
import struct
import sys
import tempfile

from build_linux import verify
from raptor_linux import HOME, identity, require, run, sha

LITEX = HOME.parent / 'fpga/litex'
sys.path.insert(0, str(LITEX / 'scripts'))
from add_linux_sdcard_dts import sdcard_node
from netboot_distro import ADDRESSES, persistence_bootargs
from netboot_distro_publish import verify as verify_bundle


def pack(artifacts, soc, csr, output, cross='riscv64-linux-gnu-', selector='LABEL=RAPTOR_DATA',
         persist_logs=False, compression='none'):
    source = verify(artifacts)
    require(source['profile'] == 'fpga', 'netboot requires the external-rootfs FPGA kernel profile')
    require(source['bits'] in (32, 64), 'unsupported XLEN')
    require(compression in ('none', 'gzip'), 'invalid compression')
    require(not output.exists(), 'netboot output must be a new directory')
    bits = source['bits']
    require(run('fdtget', '-t', 's', soc, '/cpus/cpu@0', 'riscv,isa-base').strip() == f'rv{bits}i'.encode(), 'DTB XLEN mismatch')
    require(run('fdtget', '-t', 'x', soc, '/memory@80000000', 'reg').strip() == b'80000000 40000000', 'requires 1 GiB LiteX RAM')
    config = (artifacts / 'kernel.config').read_text()
    for option in ('MMC_LITEX', 'MMC_BLOCK', 'EXT4_FS', 'REGULATOR_FIXED_VOLTAGE', 'SERIAL_LITEUART_CONSOLE', 'LITEX_LITEETH', 'BLK_DEV_INITRD'):
        require(f'CONFIG_{option}=y\n' in config, 'kernel lacks ' + option)
    require('CONFIG_INITRAMFS_SOURCE=""\n' in config, 'FPGA kernel must use external rootfs')
    rootfs = 'rootfs.cpio' if compression == 'none' else 'rootfs.cpio.gz'
    addresses = dict(ADDRESSES, Image=0x80400000 if bits == 32 else 0x80200000)
    addresses[rootfs] = addresses.pop('rootfs.cpio.gz')
    image = (artifacts / 'Image').read_bytes()[:64]
    require(struct.unpack_from('<Q', image, 8)[0] == addresses['Image'] - 0x80000000,
            'kernel load alignment does not match XLEN')
    extensions = run('fdtget', '-t', 's', soc, '/cpus/cpu@0', 'riscv,isa-extensions').decode().split()
    require({'f', 'd'} <= set(extensions), 'hard-float userspace requires F/D in the DTB')
    limit = addresses['soc.dtb'] - addresses['Image']
    require(image[56:60] == b'RSC\x05' and struct.unpack_from('<Q', image, 16)[0] < limit,
            'kernel runtime overlaps DTB')
    require((artifacts / 'Image').stat().st_size < limit and
            (artifacts / 'fw_dynamic.bin').stat().st_size < addresses['Image'] - 0x80000000, 'download ranges overlap')
    size = (artifacts / rootfs).stat().st_size
    require(size + (artifacts / 'rootfs.cpio').stat().st_size < 700 * 1024 * 1024, 'insufficient RAM for rootfs')
    bootargs = ('console=liteuart0,115200 earlycon=sbi rdinit=/sbin/raptor-init '
                'pty.legacy_count=0 random.trust_bootloader=on') + persistence_bootargs(selector, persist_logs)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='raptor-chip-netboot-pack-', dir='/tmp') as tmp:
        work = Path(tmp)
        for name in ('Image', 'fw_dynamic.bin', 'kernel.config', rootfs):
            shutil.copyfile(artifacts / name, work / name)
        dts = run('dtc', '-q', '-I', 'dtb', '-O', 'dts', soc).decode()
        require('"litex,mmc"' not in dts, 'use the original base DTB without MMC')
        (work / 'soc.dts').write_text(dts + sdcard_node(json.loads(csr.read_text())))
        run('dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', work / 'soc.dtb', work / 'soc.dts')
        for name, value in [('linux,initrd-start', 0x88000000), ('linux,initrd-end', 0x88000000 + size)]:
            run('fdtput', '-t', 'x', work / 'soc.dtb', '/chosen', name, f'{value:x}')
        run('fdtput', '-t', 's', work / 'soc.dtb', '/chosen', 'bootargs', bootargs)
        run(cross + 'gcc', f'-march=rv{bits}imac_zicsr_zifencei', '-mabi=' + ('ilp32' if bits == 32 else 'lp64'),
            '-nostdlib', '-nostartfiles', '-static', '-fno-pic', '-no-pie',
            '-Wl,--build-id=none,-Ttext=0x87f00000', '-o', work / 'stage0.elf',
            LITEX / 'firmware/linux-fpga/netboot_dynamic.S')
        run(cross + 'objcopy', '-O', 'binary', work / 'stage0.elf', work / 'stage0.bin')
        require((work / 'stage0.bin').stat().st_size < 4096, 'stage0 is too large')
        record = {'schema': 'raptor-distro-netboot-v1', 'xlen': bits, 'distro': source['distro'],
                  'startup_cmo_policy': 'menvcfg-cbie3-cbcfe1', 'board_validated': False,
                  'kernel_version': source['kernel_version'], 'rootfs_persistent': False,
                  'source_manifest_sha256': sha(artifacts / 'manifest.json'),
                  'source_dtb_sha256': sha(soc), 'sd_csr_sha256': sha(csr),
                  'kernel_config_sha256': sha(artifacts / 'kernel.config'),
                  'data_selector': selector, 'initramfs_file': rootfs, 'bootargs': bootargs,
                  'persistent_directories': ['/data', '/home', '/root'] + (['/var/log'] if persist_logs else []),
                  'files': {name: sha(work / name) for name in addresses}}
        relative = f'raptor-netboot/rv{bits}/{source["distro"]}-' + identity(record)[:20]
        record['tftp_path'] = relative
        boot = {relative + '/' + name: hex(addr) for name, addr in addresses.items()}
        boot['addr'] = hex(addresses['stage0.bin'])
        (work / 'boot.json').write_text(json.dumps(boot, indent=2) + '\n')
        record['files']['boot.json'] = sha(work / 'boot.json')
        (work / 'bundle.json').write_text(json.dumps(record, indent=2) + '\n')
        with tempfile.TemporaryDirectory(prefix='.netboot-', dir=output.parent) as stage_dir:
            stage = Path(stage_dir) / 'result'
            stage.mkdir()
            for name in [*record['files'], 'bundle.json', 'kernel.config']:
                shutil.copyfile(work / name, stage / name)
                (stage / name).chmod(0o444)
            verify_bundle(stage)
            stage.rename(output)
    print('BUNDLE=' + str(output) + '\nnetboot ' + relative + '/boot.json', flush=True)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('artifacts', 'soc', 'csr', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--cross', default='riscv64-linux-gnu-')
    parser.add_argument('--data-selector', default='LABEL=RAPTOR_DATA')
    parser.add_argument('--persist-logs', action='store_true')
    parser.add_argument('--compression', choices=('none', 'gzip'), default='none')
    args = parser.parse_args()
    pack(args.artifacts.resolve(), args.soc.resolve(), args.csr.resolve(), args.output.resolve(),
         args.cross, args.data_selector, args.persist_logs, args.compression)
