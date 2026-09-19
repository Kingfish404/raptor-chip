"""Readable, immutable bundle names; timestamps describe bundle packaging, in UTC."""
from datetime import datetime, timezone
import hashlib
import json
import re


def digest(record):
    value = dict(record)
    for key in ('tftp_path', 'bundle_content_sha256'):
        value.pop(key, None)
    value['files'] = {k: v for k, v in record['files'].items() if k != 'boot.json'}
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def semantic_path(record):
    version = record['kernel_version']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.-]+)?', version):
        raise ValueError('invalid kernel version for bundle name')
    stamp = record['bundle_created_utc']
    datetime.strptime(stamp, '%Y%m%dT%H%M%SZ')
    if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z', stamp):
        raise ValueError('invalid bundle UTC timestamp')
    version_slug = version.replace('.', '_')
    return f'raptor-netboot/rv{record["xlen"]}/{record["distro"]}-linux{version_slug}-{stamp}-{digest(record)[:8]}'


def name_bundle(record, created=None, time_source='packaging-clock'):
    record['bundle_created_utc'] = (created or datetime.now(timezone.utc)).astimezone(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    record['bundle_time_source'] = time_source
    record['bundle_content_sha256'] = digest(record)
    record['tftp_path'] = semantic_path(record)
    return record['tftp_path']


def valid_namespace(record):
    relative = record['tftp_path']
    if 'bundle_created_utc' in record:
        try:
            return relative == semantic_path(record) and record['bundle_content_sha256'] == digest(record)
        except (KeyError, ValueError):
            return False
    return bool(re.fullmatch(rf'raptor-netboot/rv{record["xlen"]}/{record["distro"]}-[0-9a-f]{{20}}', relative))
