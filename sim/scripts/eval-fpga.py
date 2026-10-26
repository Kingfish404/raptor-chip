#!/usr/bin/env python3
"""Isolated FPGA timing evaluation; see sim/README.md for calibration and images."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import threading
import tempfile
import contextlib
import signal
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from fpga_eval_summary import BENCHMARKS

MEM_LATENCY_LIMIT = 0xfffff  # monitor.cc rejects fixed/random delays >= this.


def memory_args(value):
    args = shlex.split(value)
    index = 0
    while index < len(args):
        option, equals, argument = args[index].partition('=')
        index += 1
        if option in ('--mem-read-latency', '--mem-write-latency'):
            raise ValueError('EVAL_MEM_ARGS cannot override fixed latency; use RL/WL instead')
        if option == '--mem-serialize-writes' and not equals:
            continue
        if option not in ('--mem-random-delay', '--mem-random-seed', '--mem-write-outstanding'):
            raise ValueError('EVAL_MEM_ARGS allows only --mem-serialize-writes, '
                             '--mem-random-delay, --mem-random-seed, and --mem-write-outstanding')
        if not equals:
            if index == len(args):
                raise ValueError(option + ' requires a value')
            argument = args[index]
            index += 1
        # Match the simulator's unsigned base-0 integer notation, while refusing
        # malformed values that strtoull would silently truncate or turn into 0.
        if not re.fullmatch(r'\+?(?:0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)', argument):
            raise ValueError(option + ' requires an unsigned integer')
        number = argument.lstrip('+')
        parsed = int(number, 16 if number.lower().startswith('0x') else 8 if number.startswith('0') else 10)
        if option == '--mem-write-outstanding' and not 1 <= parsed <= 64:
            raise ValueError(option + ' must be between 1 and 64')
        limit = MEM_LATENCY_LIMIT if option == '--mem-random-delay' else 1 << 64
        if parsed >= limit:
            raise ValueError(option + f' must be less than {limit}')
    return args


@contextlib.contextmanager
def stop_on_signals():
    stop = threading.Event()
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    for sig in previous:
        signal.signal(sig, lambda _sig, _frame: stop.set())
    try:
        yield stop
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def terminate_group(proc, grace=5):
    """Only signal the session/process group created for this child."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        proc.wait()
        return
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        proc.poll()  # Reap the direct child while descendants shut down.
        try:
            os.killpg(proc.pid, 0)
        except ProcessLookupError:
            proc.wait()
            return
        time.sleep(0.05)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def run_command(command, *, stop, cancel_file=None, pid_file=None, **kwargs):
    """Own the child session and clean it up on cancellation or an exception."""
    def cancelled():
        return stop.is_set() or (cancel_file is not None and cancel_file.exists())

    if cancelled():
        return -signal.SIGTERM
    proc = subprocess.Popen(command, stderr=subprocess.STDOUT, start_new_session=True, **kwargs)
    if pid_file is not None:
        pid_file.write_text(str(proc.pid))
    try:
        while not cancelled():
            try:
                return proc.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
        terminate_group(proc)
        return proc.returncode or -signal.SIGTERM
    except BaseException:
        terminate_group(proc)
        raise


def evaluate(stop):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('tree', type=Path)
    p.add_argument('tag')
    p.add_argument('preset')
    p.add_argument('vflags')
    p.add_argument('workloads', nargs='*', default=['mp', 'cm', 'eb'])
    a = p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', a.tag):
        p.error('tag must contain letters, numbers, underscore, dot or dash')
    for w in a.workloads:
        if w not in ('mp', 'mq', 'ms', 'pf', 'cm', 'eb', 'lx64'):
            p.error('workloads: mp mq ms pf cm eb lx64')
    if len(set(a.workloads)) != len(a.workloads) or sum(w in ('mp', 'mq', 'ms') for w in a.workloads) > 1:
        p.error('workloads must be unique; select only one of mp/mq/ms')
    tree = a.tree.resolve()
    cal = Path(os.environ.get('EVAL_CAL_DIR', tree/'sim'/'build'/'fpga-eval')).resolve()
    envfile = cal / 'latency.env'
    if not envfile.is_file():
        p.error('Missing calibration file: '+str(envfile)
                + '; provide latency.env with calibrated RL and WL values (no built-in calibration)')
    latency = dict(re.findall(r'^(RL|WL)=(\d+)\s*$', envfile.read_text(), re.M))
    if not all(name in latency for name in ('RL', 'WL')):
        p.error(str(envfile)+' must define integer RL and WL values')
    try:
        rl, wl = int(os.environ.get('RL', latency['RL'])), int(os.environ.get('WL', latency['WL']))
        if not (0 <= rl < MEM_LATENCY_LIMIT and 0 <= wl < MEM_LATENCY_LIMIT):
            raise ValueError(f'RL/WL must be integers in 0..{MEM_LATENCY_LIMIT - 1}')
    except ValueError:
        p.error(f'RL/WL must be integers in 0..{MEM_LATENCY_LIMIT - 1}')
    try:
        extra_memory_args = memory_args(os.environ.get('EVAL_MEM_ARGS', ''))
    except ValueError as error:
        p.error(str(error))
    xlen = int(os.environ.get('EVAL_XLEN', '64'))
    if xlen not in (32, 64):
        p.error('EVAL_XLEN must be 32 or 64')
    if xlen == 32 and any(w in ('pf', 'lx64') for w in a.workloads):
        p.error('pf and lx64 require RV64')
    if (xlen == 32 and '-DRAPT_RV64' in a.vflags) or (xlen == 64 and '-URAPT_RV64' in a.vflags):
        p.error('VFLAGS contradict EVAL_XLEN')
    dt_source = Path(os.environ.get('EVAL_DT_SOURCE', tree/'linux'/'dts'/f'spike-rv{xlen}gc.dts')).resolve()
    flags = ('-DRAPT_RV64 ' if xlen == 64 else '') + a.vflags
    identity = hashlib.sha256(str(tree).encode()).hexdigest()[:10]
    root = Path(os.environ.get('EVAL_BUILD_ROOT', cal/'build')).resolve()
    profile = f'eval-{identity}-{a.tag}-{a.preset}-rv{xlen}'
    logs = Path(os.environ.get('EVAL_LOG_ROOT', cal/'logs')).resolve() / a.tag / f'{a.preset}-rv{xlen}-r{rl}-w{wl}'
    logs.mkdir(parents=True, exist_ok=True)
    if (logs/'manifest.json').exists():
        raise SystemExit('Tag already has a manifest; choose a new tag: '+str(logs))
    env = os.environ.copy()
    env.update(RAPTOR_HOME=str(tree), NEMU_HOME=str(tree/'nemu'), NSIM_HOME=str(tree/'sim'),
               AM_HOME=str(tree/'abstract-machine'), CROSS_COMPILE='riscv64-elf-',
               RAPTOR_PMU_VERBOSE='1', NSIM_PROGRESS_CYCLES='10000000')
    wrapper = os.environ.get('EVAL_MAKE', 'make')
    common = ['make', '-C', str(tree/'sim'), '-j4', 'HDL_FORMAT_SOURCES=', 'ALL_SV_FORMAT_SOURCES=',
              'MAKE='+wrapper, 'RAPT_CONFIG='+a.preset, 'VERILATOR_EXTRA=-Wno-fatal',
              'VERILATOR_JOBS=4', 'BUILD_ROOT='+str(root), 'BUILD_PROFILE='+profile,
              'VFLAGS='+flags, 'DIFFTEST=0', 'SIM_MEM_READ_LATENCY=0', 'SIM_MEM_WRITE_LATENCY=0',
              'SIM_RANDOM_DELAY=0', 'SIM_RANDOM_SEED=1', 'SIM_MEM_SERIALIZE_WRITES=0', 'SIM_MEM_WRITE_OUTSTANDING=1']
    latargs = [f'--mem-read-latency={rl}', f'--mem-write-latency={wl}']
    latargs += extra_memory_args
    tasks = []
    for w in a.workloads:
        if w == 'mp':
            image = Path(os.environ.get(
                'EVAL_MEMPROBE_IMAGE',
                cal/'img'/f'memprobe-rv{xlen}'/f'memprobe-riscv{xlen}-npc.bin'))
            tasks.append(('mp', image, 'bare', []))
        elif w == 'mq':
            image = cal/'img'/f'memprobe-rv{xlen}'/f'memprobe-quick-matched-riscv{xlen}-npc.bin'
            tasks.append(('mp', image, 'bare', []))
        elif w == 'ms':
            tasks.append(('mp', cal/'img'/f'memprobe-rv{xlen}'/f'memprobe-store-riscv{xlen}-npc.bin', 'bare', []))
        elif w == 'pf':
            tasks.append(('pf', cal/'img'/f'pagefault-rv{xlen}'/f'pagefault-riscv{xlen}-npc.bin', 'bare', []))
        elif w == 'cm':
            image = Path(os.environ.get(
                'EVAL_COREMARK_IMAGE',
                cal/'img'/f'coremark-rv{xlen}'/f'coremark-riscv{xlen}-npc.bin'))
            tasks.append(('cm', image, 'bare', []))
        elif w == 'eb':
            images = sorted((cal/'img'/f'embench-rv{xlen}').glob('*.bin'))
            names = {image.stem for image in images}
            if names != set(BENCHMARKS):
                raise SystemExit('Expected the 19 Embench images; missing: '
                                 + ', '.join(sorted(set(BENCHMARKS) - names)) + '; unexpected: '
                                 + ', '.join(sorted(names - set(BENCHMARKS))))
            tasks += [('eb-'+image.stem, image, 'bare', []) for image in images]
        else:
            image = Path(os.environ.get('EVAL_LINUX_IMAGE', cal/'img'/'linux-rv64'/'fw_payload.bin'))
            args = ['--trap-on-ebreak', '--no-lightsss', '-m', os.environ.get('LX_MAX', '400000000'),
                    '--serial-exit-on='+os.environ.get('LX_EXIT', 'login:')]
            # Exact timestamps are available in trees with the instrumentation patch.
            if os.environ.get('EVAL_MILESTONES', '0') == '1':
                default_markers = ['Linux version', 'Run /bin/sh as init process',
                                   'Starting syslogd:', 'Starting klogd:', 'login:']
                markers = json.loads(os.environ.get('EVAL_MARKERS_JSON', json.dumps(default_markers)))
                if not isinstance(markers, list) or any(
                        not isinstance(marker, str) or not marker or '\n' in marker or '\r' in marker
                        for marker in markers):
                    p.error('EVAL_MARKERS_JSON must be a JSON list of nonempty single-line strings')
                args += ['--serial-milestone='+marker for marker in markers]
            tasks.append(('lx', image, 'linux', args))
    # Resolve overrides before workloads enter their isolated working directories.
    tasks = [(name, image.resolve(), kind, args) for name, image, kind, args in tasks]
    for _, image, _, _ in tasks:
        if not image.is_file():
            raise SystemExit('Missing image: '+str(image))
    run_jobs = int(os.environ.get('EVAL_RUN_JOBS', '1'))
    if run_jobs < 1:
        p.error('EVAL_RUN_JOBS must be positive')
    manifest_lock = threading.Lock()
    manifest = dict(tree=str(tree), tag=a.tag, preset=a.preset, vflags=flags, xlen=xlen,
                    read_latency=rl, write_latency=wl, build_profile=profile, workloads=a.workloads,
                    start=time.time(), commands=[], images={},
                    memory_args=extra_memory_args,
                    dtb_source=str(dt_source), dtb_source_sha256=hashlib.sha256(dt_source.read_bytes()).hexdigest())
    manifest['source_sha256'] = {}
    for folder in ('rtl', 'sim/csrc', 'sim/include', 'sim/rtl'):
        for source in sorted((tree/folder).rglob('*')):
            if source.is_file() and source.suffix in ('.sv', '.svh', '.cc', '.cpp', '.h'):
                digest = hashlib.sha256(source.read_bytes()).hexdigest()
                manifest['source_sha256'][str(source.relative_to(tree))] = digest
    manifest['git_head'] = subprocess.check_output(['git', '-C', str(tree), 'rev-parse', 'HEAD'], text=True).strip()
    diff = subprocess.check_output(['git', '-C', str(tree), 'diff', 'HEAD'])
    manifest['git_diff_sha256'] = hashlib.sha256(diff).hexdigest()

    def save():
        temporary = logs/'manifest.json.tmp'
        temporary.write_text(json.dumps(manifest, indent=2)+'\n')
        temporary.replace(logs/'manifest.json')

    def run(cmd, logfile, cwd=None, append=False):
        with manifest_lock:
            manifest['commands'].append(cmd)
            save()
        print(shlex.join(cmd), flush=True)
        with open(logfile, 'a' if append else 'w') as f:
            start = time.monotonic()
            rc = run_command(cmd, stop=stop,
                             cancel_file=logfile.with_suffix('.cancel'), env=env,
                             cwd=cwd, stdout=f, pid_file=logfile.with_suffix('.pid'))
            f.write(f'\nwall_seconds={time.monotonic()-start:.3f}\nrc={rc}\n')
        return rc

    root.mkdir(parents=True, exist_ok=True)
    if run(common+['o2_defconfig'], logs/'build.log') or run(common+['all'], logs/'build.log', append=True):
        raise SystemExit('Simulator build failed; see '+str(logs/'build.log'))
    commands = {}
    for kind in set('linux' if w == 'lx64' else 'bare' for w in a.workloads):
        dt = ['DT_SOURCE='+str(dt_source)] if kind == 'linux' else []
        cmd = common+dt+['--no-print-directory', 'print-npc-exec']
        manifest['commands'].append(cmd)
        with tempfile.TemporaryFile(mode='w+') as capture:
            rc = run_command(cmd, stop=stop,
                             cancel_file=(logs/'build.cancel'), env=env, stdout=capture)
            capture.seek(0)
            output = capture.read()
        with open(logs/'build.log', 'a') as f:
            f.write(output)
        if rc:
            raise SystemExit('Simulator command/ROM preparation failed; see '+str(logs/'build.log'))
        commands[kind] = shlex.split(output.strip().splitlines()[-1])
    manifest['binary_sha256'] = hashlib.sha256(Path(next(iter(commands.values()))[0]).read_bytes()).hexdigest()
    for name, image, _, _ in tasks:
        manifest['images'][name] = dict(
            path=str(image.resolve()), sha256=hashlib.sha256(image.read_bytes()).hexdigest())
    save()

    def workload(task):
        name, image, kind, args = task
        rundir = logs / ('run-'+name)
        rundir.mkdir(exist_ok=True)
        return run(commands[kind]+latargs+['-b', '-n']+args+[str(image)], logs/(name+'.log'), cwd=rundir)

    with concurrent.futures.ThreadPoolExecutor(max_workers=run_jobs) as pool:
        results = list(pool.map(workload, tasks))
    failed = any(rc != 0 for rc in results)
    manifest['end'] = time.time()
    save()
    raise SystemExit(1 if failed else 0)


def main():
    with stop_on_signals() as stop:
        evaluate(stop)


if __name__ == '__main__':
    main()
