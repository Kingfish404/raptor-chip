#!/usr/bin/env python3
"""Copy a verified legacy bundle to a readable name without rebuilding payloads."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import tempfile
from netboot_distro_publish import verify
from netboot_distro import sha, require
from netboot_names import name_bundle


def relabel(source, root):
    record = verify(source)
    old_path = record['tftp_path']
    if 'kernel_version' not in record:
        match = re.search(r'Linux/\S+ ([0-9]+\.[0-9]+\.[0-9]+) Kernel Configuration',
                          (source / 'kernel.config').read_text())
        require(match, 'cannot determine kernel version from kernel.config')
        record['kernel_version'] = match[1]
    record['renamed_from'] = {'tftp_path': old_path, 'manifest_sha256': sha(source / 'bundle.json')}
    # Historical bundles did not record creation time. Do not claim a rebuild.
    stamp = datetime.fromtimestamp((source / 'bundle.json').stat().st_mtime, timezone.utc)
    relative = name_bundle(record, stamp, 'legacy-manifest-mtime')
    destination = root / Path(relative).name
    require(not destination.exists(), 'destination already exists')
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.relabel-', dir=root) as tmp:
        stage = Path(tmp) / 'bundle'
        stage.mkdir()
        for name in [n for n in record['files'] if n != 'boot.json'] + ['kernel.config']:
            shutil.copyfile(source / name, stage / name)
        boot = json.loads((source / 'boot.json').read_text())
        boot = {key.replace(old_path+'/', relative+'/', 1) if key != 'addr' else key: value
                for key, value in boot.items()}
        (stage / 'boot.json').write_text(json.dumps(boot, indent=2)+'\n')
        record['files']['boot.json'] = sha(stage / 'boot.json')
        (stage / 'bundle.json').write_text(json.dumps(record, indent=2)+'\n')
        verify(stage)
        for p in stage.iterdir():
            p.chmod(0o444)
        stage.rename(destination)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output-root', type=Path, required=True)
    args = parser.parse_args()
    print(relabel(args.source, args.output_root))
