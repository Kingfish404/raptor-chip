#!/usr/bin/env python3
"""Run pinned, unmodified upstream riscv-tests through NPC's HTIF mailbox."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import fnmatch
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
URL = 'https://github.com/riscv-software-src/riscv-tests.git'
REVISION = '3df703cd52d5f0d8224e3c50bf03c6cb70efff98'
ENV_REVISION = '6de71edb142be36319e380ce782c3d1830c65d68'
GROUPS = ('ui', 'um', 'ua', 'uc', 'uf', 'ud', 'uzba', 'uzbb', 'uzbc', 'uzbs', 'uzicond')


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def validate_source(repo: Path) -> dict:
    revisions = {'tests': git(repo, 'rev-parse', 'HEAD'),
                 'env': git(repo / 'env', 'rev-parse', 'HEAD')}
    if revisions != {'tests': REVISION, 'env': ENV_REVISION}:
        raise ValueError(f'Unexpected upstream revisions: {revisions}')
    for directory in (repo, repo / 'env'):
        if git(directory, 'status', '--porcelain', '--untracked-files=no'):
            raise ValueError(f'Upstream tracked sources changed: {directory}')
    return revisions


def prepare(repo: Path) -> None:
    repo.parent.mkdir(parents=True, exist_ok=True)
    with (repo.parent / '.riscv-tests-source.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not repo.exists():
            subprocess.run(['git', 'clone', '--no-checkout', URL, str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), 'checkout', '--detach', REVISION], check=True)
        # Never reset or overwrite an existing checkout to hide version/local changes.
        if git(repo, 'rev-parse', 'HEAD') != REVISION:
            raise ValueError('Existing riscv-tests checkout differs from the pinned revision')
        if (repo / 'env/.git').exists():
            print(json.dumps(validate_source(repo)), flush=True)
            return
        if git(repo, 'status', '--porcelain', '--untracked-files=no'):
            raise ValueError('Upstream tracked sources changed before environment setup')
        subprocess.run(['git', '-C', str(repo), 'submodule', 'update', '--init', 'env'], check=True)
        print(json.dumps(validate_source(repo)), flush=True)


def select_tests(repo: Path, xlen: int, groups: list[str], patterns: list[str]) -> list[dict]:
    tests = []
    for suffix in groups:
        if suffix not in GROUPS:
            raise ValueError(f'Unsupported test group {suffix}; choose from {GROUPS}')
        group = f'rv{xlen}{suffix}'
        fragment = (repo / 'isa' / group / 'Makefrag').read_text().replace('\\\n', ' ')
        match = re.search(rf'^{group}_sc_tests\s*=\s*([^\n]+)', fragment, re.MULTILINE)
        if not match:
            raise ValueError(f'No upstream self-checking test list for {group}')
        names = match[1].split('#', 1)[0].split()
        if not names or any(not re.fullmatch(r'[a-z0-9_]+', name) for name in names):
            raise ValueError(f'Unexpected upstream test names for {group}: {names}')
        for name in names:
            label = f'{group}-p-{name}'
            source = repo / 'isa' / group / f'{name}.S'
            if not source.is_file():
                raise ValueError(f'Missing upstream source {source}')
            tests.append(dict(name=label, group=group, source=source))
    tests = list({test['name']: test for test in tests}.values())
    for pattern in patterns:
        if not any(fnmatch.fnmatchcase(test['name'], pattern) for test in tests):
            raise ValueError(f'Test selector matched nothing: {pattern}')
    selected = [test for test in tests if not patterns
                or any(fnmatch.fnmatchcase(test['name'], pattern) for pattern in patterns)]
    if not selected:
        raise ValueError('Empty upstream test selection')
    return selected


def execute(command: list[str], log: Path, cwd: Path, timeout: int) -> dict:
    started = time.time()
    with log.open('w') as stream:
        stream.write(f'Command: {shlex.join(command)}\n')
        stream.flush()
        try:
            result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=timeout, stdin=subprocess.DEVNULL)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
    return dict(command=command, exit=code, seconds=time.time() - started, log=str(log))


def npc_passed(code: int | str, text: str, xlen: int, difftest: bool = False) -> bool:
    return (code == 0 and f'HTIF: configured XLEN={xlen} ' in text
            and (not difftest or '[difftest] reference ISA mask:' in text)
            and re.search(r'HTIF: tohost=0x[0-9a-f]+ exit=0\b', text) is not None
            and 'HIT GOOD TRAP' in text
            and not re.search(r'BAD TRAP|ABORT|mismatch', text, re.IGNORECASE))


def run_one(test: dict, args: argparse.Namespace) -> dict:
    folder = args.output / test['name']
    folder.mkdir(parents=True, exist_ok=True)
    elf, binary = folder / 'test.elf', folder / 'test.bin'
    march = f'rv{args.xlen}g'
    if 'uz' in test['group']:
        march += '_' + test['group'].split('u', 1)[1]
    abi = 'lp64d' if args.xlen == 64 else 'ilp32'
    command = [args.cross + 'gcc', f'-march={march}', f'-mabi={abi}', '-static',
               '-mcmodel=medany', '-fvisibility=hidden', '-nostdlib', '-nostartfiles',
               '-Wl,--build-id=none', '-I' + str(args.repo / 'env/p'),
               '-I' + str(args.repo / 'isa/macros/scalar'),
               '-T' + str(args.repo / 'env/p/link.ld'), str(test['source']), '-o', str(elf)]
    record = dict(name=test['name'], source_sha256=sha(test['source']), passed=False, stages={})
    compiled = execute(command, folder / 'compile.log', folder, args.timeout)
    record['stages']['compile'] = compiled
    if compiled['exit'] != 0:
        return record
    symbols = subprocess.check_output([args.cross + 'nm', '--defined-only', str(elf)], text=True)
    matches = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+tohost$', symbols, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f'{test["name"]}: expected one tohost symbol')
    address = int(matches[0], 16)
    subprocess.run([args.cross + 'objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
    record.update(elf_sha256=sha(elf), binary_sha256=sha(binary), tohost=hex(address))
    reference_ok = True
    if args.spike:
        # Raptor implements ordinary misaligned RAM accesses. Match that EEI
        # contract in Spike; its default would trap the upstream ma_data test.
        isa = f'rv{args.xlen}gc_zba_zbb_zbc_zbs_zicond_zicclsm'
        reference = execute([str(args.spike), f'--isa={isa}', str(elf)],
                            folder / 'spike.log', folder, args.timeout)
        record['stages']['spike'] = reference
        reference_ok = reference['exit'] == 0
    runs = []
    for delay in args.mem_delays:
        for seed in args.mem_seeds:
            command = [str(args.npc), '-b', '-n', '--trap-on-ebreak', '--no-lightsss',
                       f'--tohost={address:#x}', f'--mem-random-delay={delay}',
                       f'--mem-random-seed={seed}']
            if args.mrom:
                command += ['-r', str(args.mrom)]
            if args.nemu:
                command += ['-d', str(args.nemu)]
            command.append(str(binary))
            log = folder / f'npc-delay{delay}-seed{seed}.log'
            result = execute(command, log, folder, args.timeout)
            text = log.read_text(errors='replace')
            result.update(delay=delay, seed=seed,
                          passed=npc_passed(result['exit'], text, args.xlen, bool(args.nemu)))
            runs.append(result)
    record['stages']['npc'] = runs
    record['passed'] = reference_ok and all(run['passed'] for run in runs)
    print(f'[{"PASS" if record["passed"] else "FAIL"}] {test["name"]}', flush=True)
    return record


def rtl_inputs() -> str:
    files = sorted(path for path in (ROOT / 'rtl').rglob('*')
                   if path.is_file() and path.suffix in ('.sv', '.svh', '.json'))
    hashes = {str(path.relative_to(ROOT)): sha(path) for path in files}
    return hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['setup', 'list', 'run'])
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=[32, 64], default=64)
    parser.add_argument('--groups', nargs='+', default=list(GROUPS))
    parser.add_argument('--tests', nargs='*', default=[])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--npc', type=Path)
    parser.add_argument('--mrom', type=Path)
    parser.add_argument('--nemu', type=Path)
    parser.add_argument('--spike', type=Path)
    parser.add_argument('--cross', default='riscv64-unknown-elf-')
    parser.add_argument('--timeout', type=int, default=60)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--preset', default='unspecified')
    parser.add_argument('--mem-delays', nargs='+', type=int, default=[0, 31])
    parser.add_argument('--mem-seeds', nargs='+', type=int, default=[1])
    args = parser.parse_args()
    args.repo = args.repo.resolve()
    if args.action == 'setup':
        prepare(args.repo)
        return 0
    if args.action == 'list':
        validate_source(args.repo)
        tests = select_tests(args.repo, args.xlen, args.groups, args.tests)
        print('\n'.join(test['name'] for test in tests))
        return 0
    if not args.output:
        parser.error('run requires --output')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = args.output / 'report.json'
        # Invalidate an earlier success before any fallible preflight step.
        # Acquire the lock first so a competing invocation cannot erase a live run.
        path.write_text(json.dumps(dict(complete=False, passed=False, phase='preflight',
                                        started=time.time()), indent=2) + '\n')
        revision = validate_source(args.repo)
        tests = select_tests(args.repo, args.xlen, args.groups, args.tests)
        if not args.npc:
            parser.error('run requires --npc')
        if args.jobs < 1 or args.timeout < 1 or any(n < 0 for n in args.mem_delays + args.mem_seeds):
            parser.error('jobs/timeout must be positive; memory delays/seeds must be nonnegative')
        for name in ('npc', 'mrom', 'nemu', 'spike'):
            value = getattr(args, name)
            if value:
                value = value.resolve(strict=True)
                setattr(args, name, value)
        for tool in ('gcc', 'nm', 'objcopy'):
            if not shutil.which(args.cross + tool):
                parser.error(f'Missing cross tool {args.cross + tool}')
        fingerprint = rtl_inputs()
        report = dict(schema='raptor-riscv-tests-v1', complete=False, passed=False,
                      revision=revision, xlen=args.xlen, preset=args.preset,
                      observed_rtl_sha256=fingerprint, selected=[test['name'] for test in tests],
                      artifacts={name: sha(getattr(args, name)) for name in
                                 ('npc', 'mrom', 'nemu', 'spike') if getattr(args, name)},
                      references=dict(nemu=bool(args.nemu), spike=bool(args.spike)),
                      runner_sha256=sha(Path(__file__)), started=time.time(), cases=[])
        path.write_text(json.dumps(report, indent=2) + '\n')
        try:
            with ThreadPoolExecutor(max_workers=args.jobs) as executor:
                report['cases'] = list(executor.map(lambda test: run_one(test, args), tests))
            report['inputs_unchanged'] = fingerprint == rtl_inputs()
            report['upstream_unchanged'] = validate_source(args.repo) == revision
            report['artifacts_unchanged'] = all(
                sha(getattr(args, name)) == digest for name, digest in report['artifacts'].items())
            report['complete'] = True
            report['passed'] = (report['inputs_unchanged'] and report['upstream_unchanged']
                                and report['artifacts_unchanged']
                                and all(case['passed'] for case in report['cases']))
        finally:
            report['finished'] = time.time()
            path.write_text(json.dumps(report, indent=2) + '\n')
        passed = sum(case['passed'] for case in report['cases'])
        print(f'{passed}/{len(tests)} upstream tests passed; report: {path}', flush=True)
        return 0 if report['passed'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
