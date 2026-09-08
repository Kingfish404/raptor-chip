#!/usr/bin/env python3
"""Record why each upstream test in a chosen tree is selected or excluded.

Run with the ACT4 virtualenv Python. This uses the installed checkout's actual
metadata parser and selector, and does not modify tests or remove NORUN markers.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--repo', type=Path, required=True)
    ap.add_argument('--config', type=Path, required=True)
    ap.add_argument('--extensions-file', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--test-tree', choices=['priv', 'rv32i', 'rv64i'], default='priv',
                    help='upstream tests subtree; default preserves privileged audits')
    ap.add_argument('--extensions', default='all', help='actual ACT4 EXTENSIONS value')
    ap.add_argument('--exclude', default='', help='actual EXCLUDE_EXTENSIONS value, including Make defaults')
    args = ap.parse_args()
    repo = args.repo.resolve()
    sys.path.insert(0, str(repo / 'framework/src'))
    from ruamel.yaml import YAML
    from act.parse_test_constraints import generate_test_dict
    from act.select_tests import PRIV_EXTENSIONS, check_test_params, select_tests
    from act.parse_udb_config import get_implemented_extensions
    yaml = YAML(typ='safe')
    config = yaml.load(args.config.read_text())
    udb_path = args.config.parent / config['udb_config']
    udb = yaml.load(udb_path.read_text())
    params = udb['params']
    implemented = get_implemented_extensions(args.extensions_file)
    tests = generate_test_dict(repo / 'tests' / args.test_tree, 'all')
    include = config.get('include_priv_tests', True)
    requested = set(args.extensions.split(',')) if args.extensions != 'all' else None
    excluded = set(filter(None, args.exclude.split(',')))
    candidates = {n: t for n, t in tests.items()
                  if (requested is None or t.coverage_group in requested)
                  and t.coverage_group not in excluded}
    selected = select_tests(candidates, implemented, params, include_priv_tests=include)
    records = []
    for name, test in sorted(tests.items()):
        reasons = []
        if requested is not None and test.coverage_group not in requested:
            reasons.append({'kind': 'not_requested'})
        if test.coverage_group in excluded:
            reasons.append({'kind': 'directory_excluded'})
        if not include and not test.required_extensions.isdisjoint(PRIV_EXTENSIONS):
            reasons.append({'kind': 'priv_disabled'})
        missing = sorted(test.required_extensions - implemented)
        if missing:
            reasons.append({'kind': 'missing_extensions', 'values': missing})
        for key, value in test.params.items():
            if not check_test_params({key: value}, params):
                reasons.append({'kind': 'parameter', 'name': key,
                                'required': value, 'configured': params.get(key)})
        assert (name in selected) == (not reasons), name
        records.append({'test': name, 'selected': name in selected,
                        'required_extensions': sorted(test.required_extensions),
                        'reasons': reasons,
                        'sha256': hashlib.sha256(test.test_path.read_bytes()).hexdigest()})
    inputs = [args.config, udb_path, args.extensions_file,
              repo / 'framework/src/act/select_tests.py',
              repo / 'framework/src/act/parse_test_constraints.py']
    report = {'scope': f'upstream tests/{args.test_tree} selection only; not execution or certification',
              'extensions': args.extensions, 'exclude': args.exclude,
              'repo_head': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
              'inputs': [{'path': str(p.resolve()), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in inputs],
              'counts': {'total': len(records), 'selected': len(selected),
                         'excluded': len(records) - len(selected)},
              'reason_counts': dict(Counter(r['kind'] for t in records for r in t['reasons'])),
              'tests': records}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['counts']))


if __name__ == '__main__':
    main()
