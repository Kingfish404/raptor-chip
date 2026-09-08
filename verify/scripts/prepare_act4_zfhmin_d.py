#!/usr/bin/env python3
"""Expose the two D/half conversions required by Zfhmin without claiming Zfh.

Upstream currently groups these tests under ZfhD and requires full Zfh.
Only metadata is adapted in an isolated test tree; test bodies are preserved.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = args.repo.resolve() / 'tests'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source / 'env', output / 'env', dirs_exist_ok=True)
    records = []
    for op in ('fcvt.d.h', 'fcvt.h.d'):
        original = source / 'rv64i' / 'ZfhD' / f'ZfhD-{op}-00.S'
        text = original.read_text()
        before, body = text.split('##### END_TEST_CONFIG #####', 1)
        required = "# REQUIRED_EXTENSIONS: ['I', 'Zfh', 'D', 'F']"
        march = '# MARCH: rv64ifd_zfh\n'
        if before.count(required) != 1 or before.count(march) != 1:
            raise ValueError(f'upstream metadata changed: {original}')
        adapted = before.replace(required, "# REQUIRED_EXTENSIONS: ['I', 'Zfhmin', 'D', 'F']")
        adapted = adapted.replace(march, '# MARCH: rv64ifd_zfhmin\n')
        adapted += '##### END_TEST_CONFIG #####' + body
        target = output / 'rv64i' / 'ZfhminD' / original.name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(adapted)
        assert adapted.split('##### END_TEST_CONFIG #####', 1)[1] == body
        records.append({'source': str(original), 'output': str(target),
                        'source_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
                        'output_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                        'unchanged_body_sha256': hashlib.sha256(body.encode()).hexdigest()})
    (output / 'adaptation.json').write_text(json.dumps({
        'scope': 'metadata-only adaptation; no instruction, expected result or signature changes',
        'specification': 'https://docs.riscv.org/reference/isa/unpriv/zfh.html',
        'tests': records}, indent=2) + '\n')
    print('Prepared 2 Zfhmin+D conversion tests; instruction bodies unchanged')


if __name__ == '__main__':
    main()
