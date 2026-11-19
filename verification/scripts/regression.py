#!/usr/bin/env python3
"""Run format, CoreMark, STA and FPGA checks with bounded parallelism."""
import argparse
from collections import deque
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import asdict, dataclass
import fcntl
from graphlib import TopologicalSorter
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
CANCELLED = threading.Event()
PROCESSES = set()
PROCESS_LOCK = threading.RLock()


def cancel(signum, _frame):
    CANCELLED.set()
    with PROCESS_LOCK:
        for proc in PROCESSES:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


@dataclass
class Step:
    name: str
    command: list[str]
    check: str = "exit"
    requires: tuple[str, ...] = ()


def positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def plan(args, work):
    def make(directory, target, *settings, jobs=None, preset=None):
        return [args.make, '-C', str(ROOT / directory), f'-j{jobs or args.tool_jobs}', target,
                f'RAPT_CONFIG={preset or args.preset}', f'NPROC={args.tool_jobs}',
                f'VERILATOR_JOBS={args.tool_jobs}', 'VERILATOR_THREADS=1',
                *settings]

    formats = [Step('format', make('', 'format', 'FORMAT_SCOPE=all'))] if 'format' in args.suites else []
    steps = []
    if set(args.suites) & {'coremark', 'fpga', 'sta'}:
        steps.append(Step('rtl-decoders', make('sim', 'rtl-decoders')))
    if 'coremark' in args.suites:
        steps.append(Step('coremark-prepare', make('', 'coremark-prepare')))
    if 'sta' in args.suites:
        steps.append(Step('sta-prepare', make('sim', 'sta-deps', 'sram-ensure-libs',
            f'STA_PLATFORM={args.platform}', jobs=1, preset=args.sta_preset)))
    if 'fpga' in args.suites:
        settings = [f'BOARD={args.board}', 'FPGA_AUTO_DETECT=0',
                    f'BUILD_DIR={work}/fpga', f'VIVADO_JOBS={args.tool_jobs}']
        steps.append(Step('fpga-build', make('fpga/litex', 'fpga-build', *settings),
                          requires=('rtl-decoders',)))
        steps.append(Step('fpga-timing-ok', make('fpga/litex', 'fpga-timing-ok', *settings),
                          'fpga-timing', ('fpga-build',)))
    if 'sta' in args.suites:
        steps.extend(Step(f'sta-rv{x}', make('', 'sta',
            f'BUILD_ROOT={work}/sta-rv{x}/pack',
            f'STA_WORK_DIR={work}/sta-rv{x}', 'MEMORY=sram', f'XLEN={x}',
            f'VFLAGS={"-DRAPT_RV64" if x == 64 else ""}',
            f'STA_PLATFORM={args.platform}', f'CLK_FREQ_MHZ={args.clock_mhz}',
            'STA_REPORT_ONLY=1', jobs=1,
            preset=args.sta_preset), 'sta', ('rtl-decoders', 'sta-prepare'))
            for x in args.xlens)
    if 'coremark' in args.suites:
        for xlen in args.xlens:
            settings = [f'BUILD_ROOT={work}/sim', f'BUILD_PROFILE=regression-rv{xlen}',
                        f'VFLAGS={"-DRAPT_RV64" if xlen == 64 else ""}',
                        f'ITERATIONS={args.iterations}', 'ARGS=-b', 'DIFFTEST=1',
                        f'NPC_LOG_DIR={work}/logs/npc', f'NEMU_LOG_DIR={work}/logs/nemu']
            npc = f'coremark-rv{xlen}'
            native = f'coremark-nemu{xlen}'
            steps.append(Step(npc, make('', npc, *settings), 'coremark',
                              ('rtl-decoders', 'coremark-prepare')))
            steps.append(Step(native, make('', native, *settings, f'O={work}/nemu/rv{xlen}'),
                              'coremark', ('coremark-prepare',)))
    return formats, steps


def validate(check, output):
    output = re.sub(r'\x1b\[[0-9;]*m', '', output)
    if check == 'coremark':
        # Short functional runs intentionally do not meet EEMBC's 10-second
        # score rule. Still require all three official CRCs and a good trap.
        expected = {
            '8a02': ('d4b0', 'be52', '5e47'), '7b05': ('3340', '1199', '39bf'),
            '4eaf': ('6a79', '5608', 'e5a4'), 'e9f5': ('e714', '1fd7', '8e3a'),
            '18f2': ('e3c1', '0747', '8d84'),
        }
        seed = re.search(r'seedcrc\s*:\s*0x([0-9a-fA-F]{4})', output)
        crcs = [re.search(r'\[0\]crc' + name + r'\s*:\s*0x([0-9a-fA-F]{4})', output)
                for name in ('list', 'matrix', 'state')]
        actual = tuple(m[1].lower() if m else None for m in crcs)
        short_notice = 'ERROR! Must execute for at least 10 secs for a valid result!'
        errors = output.replace(short_notice, '')
        if (not seed or expected.get(seed[1].lower()) != actual
                or 'HIT GOOD TRAP' not in output or 'HIT BAD TRAP' in output
                or 'Cannot validate operation' in output or 'ERROR!' in errors
                or ('Errors detected' in output and short_notice not in output)):
            return 'missing CoreMark validation/good trap, or workload failure'
    elif check == 'sta':
        if 'fmax Summary' not in output or re.search(r'(?im)^\s*(?:Error:|ERROR:)|slack.*VIOLATED', output):
            return 'missing STA report, tool error, or timing violation'
    elif check == 'fpga-timing':
        if '[INFO] Vivado timing constraints are met:' not in output:
            return 'FPGA timing is missing, unsupported, or not met'
    return ''


def skip_step(step, reason):
    return dict(asdict(step), status='SKIP', exit_code=None, seconds=0, reason=reason, log=None)


def run_step(step, work, timeout):
    if CANCELLED.is_set():
        return skip_step(step, 'regression interrupted')
    started = time.monotonic()
    log = work / 'logs' / (step.name + '.log')
    env = os.environ.copy()
    # Own the subprocess budget; do not inherit a parent make jobserver or its
    # command-line overrides (notably BUILD_DIR, VFLAGS and recursive goals).
    for key in ('MAKEFLAGS', 'MFLAGS', 'MAKEOVERRIDES', 'MAKELEVEL'):
        env.pop(key, None)
    print(f'[RUN] {step.name}', flush=True)
    reason = ''
    code = None
    with log.open('w') as stream:
        stream.write(shlex.join(step.command) + '\n')
        stream.flush()
        try:
            with PROCESS_LOCK:
                proc = subprocess.Popen(step.command, stdout=stream, stderr=subprocess.STDOUT,
                                        env=env, start_new_session=True)
                PROCESSES.add(proc)
                if CANCELLED.is_set():
                    os.killpg(proc.pid, signal.SIGKILL)
            try:
                code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                reason = f'timeout after {timeout}s'
            finally:
                with PROCESS_LOCK:
                    PROCESSES.discard(proc)
        except OSError as exc:
            reason = str(exc)
    if not reason:
        reason = f'exit {code}' if code else validate(step.check, log.read_text(errors='replace'))
    result = dict(asdict(step), status='FAIL' if reason else 'PASS', exit_code=code,
                  seconds=round(time.monotonic() - started, 3), reason=reason, log=str(log))
    print(f'[{result["status"]}] {step.name} ({result["seconds"]:.1f}s) {reason}', flush=True)
    return result


def run_steps(steps, work, timeout, jobs, runner=None):
    runner = runner or run_step
    by_name = {step.name: step for step in steps}
    graph = TopologicalSorter({step.name: step.requires for step in steps})
    graph.prepare()
    ready = deque(graph.get_ready())
    active = {}
    results = {}
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        while ready or active:
            while ready and len(active) < jobs:
                name = ready.popleft()
                step = by_name[name]
                failed = next((dep for dep in step.requires if results[dep]['status'] != 'PASS'), None)
                if failed:
                    results[name] = skip_step(step, f'{failed} did not pass')
                    graph.done(name)
                    ready.extend(graph.get_ready())
                else:
                    active[pool.submit(runner, step, work, timeout)] = name
            if active:
                finished, _ = wait(active, return_when=FIRST_COMPLETED)
                for future in finished:
                    name = active.pop(future)
                    results[name] = future.result()
                    graph.done(name)
                ready.extend(graph.get_ready())

    if results.get('fpga-timing-ok', {}).get('status') == 'PASS':
        shutil.rmtree(work / 'fpga', ignore_errors=True)
    return [results[step.name] for step in steps]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--make', default='make')
    parser.add_argument('--preset', default='default')
    parser.add_argument('--sta-preset', default='small',
                        help='RTL configuration for STA; defaults to the CI STA preset')
    parser.add_argument('--board', default='mlk_cu08_ku15p')
    parser.add_argument('--platform', default='nangate45')
    parser.add_argument('--clock-mhz', type=positive, default=50)
    parser.add_argument('--jobs', type=positive,
                        help='maximum concurrent checks (default: CPUs divided by tool jobs)')
    parser.add_argument('--tool-jobs', type=positive, default=4)
    parser.add_argument('--timeout', type=positive, default=14400)
    parser.add_argument('--iterations', type=positive, default=2)
    parser.add_argument('--xlens', nargs='+', type=int, choices=(32, 64), default=[32, 64])
    parser.add_argument('--suites', nargs='+', choices=('format', 'coremark', 'sta', 'fpga'),
                        default=['format', 'coremark', 'sta', 'fpga'])
    parser.add_argument('--output', type=Path, help='new output directory in the system temp directory by default')
    args = parser.parse_args(argv)
    args.xlens = list(dict.fromkeys(args.xlens))
    if args.jobs is None:
        cpus = len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else os.cpu_count()
        args.jobs = max(1, (cpus or 1) // args.tool_jobs)
    if args.plan:
        work = args.output or Path('/tmp/raptor-chip-regression-PLAN')
        formats, steps = plan(args, work)
        print(json.dumps({'format_barrier': [asdict(s) for s in formats],
                          'steps': [asdict(s) for s in steps], 'max_jobs': args.jobs}, indent=2))
        return 0
    lock_name = hashlib.sha256(str(ROOT).encode()).hexdigest()[:16]
    with open(f'/tmp/raptor-chip-regression-{lock_name}.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error('another regression is running in this checkout')
        if args.output:
            work = args.output.resolve()
            work.mkdir(parents=True, exist_ok=False)
        else:
            work = Path(tempfile.mkdtemp(prefix='raptor-chip-regression-'))
        (work / 'logs').mkdir()
        print(f'[regression] output={work}', flush=True)
        formats, steps = plan(args, work)
        results = [run_step(step, work, args.timeout) for step in formats]
        # Record the actual post-format worktree, including staged changes.
        def git(*command):
            return subprocess.check_output(['git', '-C', str(ROOT), *command])
        diff = git('diff', 'HEAD', '--binary')
        (work / 'source.patch').write_bytes(diff)
        (work / 'source-status.txt').write_bytes(git('status', '--short'))
        untracked = {}
        for name in git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'):
            if name:
                path = ROOT / os.fsdecode(name)
                if path.is_file():
                    untracked[os.fsdecode(name)] = hashlib.sha256(path.read_bytes()).hexdigest()
        metadata = dict(head=git('rev-parse', 'HEAD').decode().strip(),
                        diff_sha256=hashlib.sha256(diff).hexdigest(),
                        untracked_sha256=untracked,
                        options={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()})
        if all(r['status'] == 'PASS' for r in results):
            results.extend(run_steps(steps, work, args.timeout, args.jobs))
        else:
            results.extend(skip_step(step, 'format barrier failed') for step in steps)
        passed = not CANCELLED.is_set() and all(r['status'] == 'PASS' for r in results)
        summary = dict(metadata, status='PASS' if passed else 'FAIL', results=results)
        (work / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        lines = [f'{r["status"]:4} {r["name"]:28} {r["seconds"]:9.1f}s {r["reason"]}' for r in results]
        (work / 'summary.txt').write_text('\n'.join(lines) + '\n')
        print('\n'.join(lines))
        print(f'[regression] {summary["status"]}: {work}/summary.json')
        return 0 if passed else 1


if __name__ == '__main__':
    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    raise SystemExit(main())
