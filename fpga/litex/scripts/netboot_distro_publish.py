#!/usr/bin/env python3
"""Publish verified RV32/RV64 bundles into new immutable TFTP namespaces."""
import argparse
import json
from pathlib import Path
import re
import shutil
import tempfile

from netboot_distro import ADDRESSES, require, sha


def verify(bundle):
    record = json.loads((bundle / 'bundle.json').read_text())
    require(record['schema'] == 'raptor-distro-netboot-v1' and record['xlen'] in (32, 64),
            'not an RV32/RV64 distro bundle')
    require(record.get('distro') in ('alpine', 'debian', 'buildroot') and
            (record['xlen'] == 64 or record['distro'] == 'buildroot'), 'distro/XLEN mismatch')
    relative = record['tftp_path']
    require(re.fullmatch(rf'raptor-netboot/rv{record["xlen"]}/{record["distro"]}-[0-9a-f]{{20}}', relative),
            'invalid TFTP namespace')
    require(record.get('startup_cmo_policy') == 'menvcfg-cbie3-cbcfe1',
            'bundle lacks S-mode CMO initialization; rebuild with current packer')
    rootfs_name = record.get('initramfs_file', 'rootfs.cpio.gz')
    require(rootfs_name in ('rootfs.cpio', 'rootfs.cpio.gz'), 'invalid initramfs file')
    addresses = dict(ADDRESSES, Image=0x80400000 if record['xlen'] == 32 else 0x80200000)
    addresses[rootfs_name] = addresses.pop('rootfs.cpio.gz')
    require(set(record['files']) == set(addresses) | {'boot.json'}, 'invalid file set')
    for name, expected in record['files'].items():
        require(not (bundle / name).is_symlink() and sha(bundle / name) == expected,
                f'bundle hash mismatch: {name}')
    require(sha(bundle / 'kernel.config') == record['kernel_config_sha256'], 'kernel config mismatch')
    boot = {str(Path(relative) / name): hex(address) for name, address in addresses.items()}
    boot['addr'] = hex(ADDRESSES['stage0.bin'])
    require(json.loads((bundle / 'boot.json').read_text()) == boot, 'boot layout mismatch')
    return record


def publish(bundle, root=Path('/srv/tftp')):
    require(root == Path('/srv/tftp'), 'only /srv/tftp is supported')
    record = verify(bundle)
    relative = record['tftp_path']
    destination = root / relative
    for path in (root, *destination.parents, destination):
        require(not path.is_symlink(), f'refusing symlink: {path}')
    names = [*record['files'], 'bundle.json', 'kernel.config']
    if destination.exists():
        for name in names:
            require(not (destination / name).is_symlink() and
                    sha(destination / name) == sha(bundle / name), f'existing file differs: {name}')
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix='.distro-publish-', dir=destination.parent))
        try:
            for name in names:
                shutil.copyfile(bundle / name, staging / name)
                require(sha(staging / name) == sha(bundle / name), f'copy mismatch: {name}')
                (staging / name).chmod(0o444)
            staging.chmod(0o755)
            require(not destination.exists(), 'destination appeared during publication')
            staging.rename(destination)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    print(f'PUBLISHED={destination}\nnetboot {relative}/boot.json')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path, nargs='+')
    args = parser.parse_args()
    for bundle in args.bundle:
        publish(bundle.resolve())
