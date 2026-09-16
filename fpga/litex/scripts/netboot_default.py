#!/usr/bin/env python3
"""Reproducible release -> LiteX kernel -> persistent RAM-root netboot bundle."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile

import netboot_distro as distro
from netboot_distro_publish import verify

LINUX = distro.LITEX.parents[1] / 'linux'
import sys
sys.path.insert(0, str(LINUX))
import build_linux
from pack_netboot import pack
RUNTIME = LINUX / 'raptor-persist.sh'


def identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()




def prepare(context, root, args):
    from netboot_flow import lock, execute, save
    distro.require(args.xlen == 64 or args.distro == 'buildroot', 'Alpine/Debian require RV64')
    distro.require(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', args.version), 'invalid release version')
    if args.distro == 'buildroot':
        name = f'linux-riscv-rv{args.xlen}-qemu-rv{args.xlen}-fast-buildroot-{args.version}'
        target = f'download-rv{args.xlen}gc'
    else:
        name = f'linux-riscv-qemu-rv64-{args.distro}-{args.version}'
        target = 'download-rv64-' + args.distro
    package = LINUX / 'build' / name
    with lock(LINUX / 'build' / ('.netboot-' + name + '.lock'), wait=True):
        execute(['make', '-C', LINUX, target,
                 'LINUX_BUILD_RELEASE=' + args.release, 'LINUX_BUILD_VERSION=' + args.version])
    cache = LINUX / 'build/netboot-kernels'
    artifact_key = identity([distro.sha(package / 'manifest.json'), distro.sha(LINUX / 'build_linux.py'),
                             distro.sha(LINUX / 'raptor_linux.py'), distro.sha(RUNTIME),
                             distro.run(context['cross'] + 'gcc', '--version').decode()])
    built = LINUX / 'build/raptor/fpga' / artifact_key
    with lock(built.parent / ('.' + artifact_key + '.lock'), wait=True):
        if not built.exists():
            build_linux.build(package, args.xlen, args.distro, 'fpga', built, cache, context['cross'])
        build_linux.verify(built)
    soc = Path(context.get('dtb', str(Path(context['firmware']) / 'litex-soc-seeded.dtb')))
    csr = Path(context['soc']) / 'csr.json'
    inputs = {'package': distro.sha(package / 'manifest.json'), 'kernel': distro.sha(built / 'manifest.json'),
              'dtb': distro.sha(soc), 'csr': distro.sha(csr), 'runtime': distro.sha(RUNTIME),
              'selector': args.data_selector, 'logs': args.persist_logs, 'compression': args.initramfs_compression,
              'packer': distro.sha(LINUX / 'pack_netboot.py'),
              'sd_dts': distro.sha(distro.LITEX / 'scripts/add_linux_sdcard_dts.py'),
              'orchestrator': distro.sha(Path(__file__)),
              'compiler': distro.run(context['cross'] + 'gcc', '--version').decode(),
              'stage0': distro.sha(distro.LITEX / 'firmware/linux-fpga/netboot_dynamic.S'),
              'cmo': distro.sha(distro.LITEX / 'firmware/linux-fpga/cmo_init.h')}
    key = identity(inputs)
    root.mkdir(parents=True, exist_ok=True)
    destination = root / key
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix='raptor-chip-netboot-distro-', dir='/tmp') as temporary:
            scratch = Path(temporary)
            pack(built, soc, csr, scratch / 'bundle', context['cross'], args.data_selector,
                 args.persist_logs, args.initramfs_compression)
            with tempfile.TemporaryDirectory(prefix='.bundle-', dir=root) as stage:
                staging = Path(stage) / 'result'
                shutil.copytree(scratch / 'bundle', staging)
                verify(staging)
                staging.rename(destination)
    verify(destination)
    save(root / 'current.json', {'path': str(destination), 'identity': key, 'inputs': inputs})
    return destination
