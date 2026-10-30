#!/usr/bin/env python3
"""Run independent, timed formal/fuzz lanes against an immutable source snapshot."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
PROFILES = [(20, 1000, 65536, 'gc'), (100, 5000, 262144, 'imac'),
            (300, 20000, 1048576, 'gc'), (1000, 50000, 4194304, 'imac')]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def snapshot(source, destination):
    names = subprocess.check_output(
        ['git', '-C', str(source), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']
    ).decode().split('\0')
    # The generated decoders are ignored by Git but are actual simulation/proof inputs.
    names += [str(path.relative_to(source)) for path in (source / 'rtl').rglob('*')
              if path.is_file() and path.suffix in ('.sv', '.svh', '.v', '.vh', '.json')]
    external = {'third_party', 'nemu', 'abstract-machine'}
    hashes = {}
    for name in sorted(set(names) - {''}):
        if Path(name).parts[0] in external or not (source / name).is_file():
            continue
        hashes[name] = sha(source / name)
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target, follow_symlinks=True)
        if sha(target) != hashes[name]:
            raise ValueError('Source changed while copying: ' + name)
    if any(sha(source / name) != digest for name, digest in hashes.items()):
        raise ValueError('Source changed during snapshot creation')
    for name in external:
        (destination / name).symlink_to(source / name, target_is_directory=True)
    return hashes


def pono_shape(index):
    # Walk each dimension without repeating a small fixed matrix for hours.
    entries = (1, 3, 7, 8, 16, 31, 32, 63, 64, 127, 128, 256)[index % 12]
    ports = (1, 3, 5, 6, 8)[(index // 12) % 5]
    full = (1 << ports) - 1
    masks = (full, full & 0x55, 1, 0, full & 0xaa)
    mask = masks[(index // 60) % len(masks)]
    width = (8, 32, 40, 64)[(index // 300) % 4]
    generation = (1, 2, 4, 8)[(index // 1200) % 4]
    return f'{entries}:{ports}:{mask}:{width}:{generation}'


def fuzz_parameters(index):
    blocks, instructions, memory, isa = PROFILES[index % len(PROFILES)]
    return dict(blocks=blocks, instructions=instructions, mem_bytes=memory, isa_profile=isa,
                seed=100000 + index, delay=(7, 31, 127)[(index // 4) % 3],
                memory_seed=(1, 42, 31337)[(index // 12) % 3])


class Campaign:
    def __init__(self, args, hashes):
        self.args = args
        self.source = args.output / 'source'
        self.hashes = hashes
        self.lock = threading.Lock()
        self.builders = threading.Semaphore(args.parallel_builds)
        self.report = dict(schema='raptor-extended-campaign-v1', complete=False, passed=False,
                           pid=os.getpid(), started=time.time(), target_seconds_per_lane=args.seconds,
                           build_time_counts=False, whole_rtl_signoff=False, lanes={},
                           source=str(self.source), source_manifest_sha256=sha(
                               args.output / 'source-manifest.json'))
        if args.resume:
            self.report = json.loads((args.output / 'status.json').read_text())
            self.report.setdefault('previous_pids', []).append(self.report['pid'])
            self.report.update(pid=os.getpid(), complete=False, passed=False, resumed=time.time())
        self.report['supervisor_sha256'] = sha(Path(__file__))
        archived = args.output / ('supervisor-' + self.report['supervisor_sha256'] + '.py')
        if not archived.exists():
            shutil.copy2(Path(__file__), archived)
        self.report['supervisor_source'] = str(archived)
        self.attempt = str(time.time_ns())

    def save(self):
        atomic_json(self.args.output / 'status.json', self.report)

    def patch(self, name, **values):
        with self.lock:
            self.report['lanes'][name].update(values)
            self.save()

    def execute(self, name, command, directory, timeout, *, verification=True):
        directory.mkdir(parents=True, exist_ok=True)
        record = dict(command=list(map(str, command)), started=time.time(), exit=None)
        atomic_json(directory / 'command.json', record)
        started = time.monotonic()
        log = directory / 'run.log'
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1',
                   RAPTOR_YOSYS_REAL=self.args.yosys, RAPTOR_HOME=str(self.source),
                   NEMU_HOME=str(self.source / 'nemu'))
        for variable in ('MAKEFLAGS', 'MFLAGS', 'MAKELEVEL'):
            env.pop(variable, None)
        with log.open('w') as stream:
            process = subprocess.Popen(record['command'], cwd=self.source, env=env,
                                       stdin=subprocess.DEVNULL, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            self.patch(name, current_pid=process.pid, current_command=str(directory / 'command.json'),
                       current_started=record['started'])
            while True:
                try:
                    remaining = timeout - (time.monotonic() - started)
                    record['exit'] = process.wait(timeout=min(15, max(0.1, remaining)))
                    break
                except subprocess.TimeoutExpired:
                    self.patch(name, heartbeat=time.time())
                    if time.monotonic() - started >= timeout:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                        record['exit'] = 'timeout'
                        break
        record.update(seconds=time.monotonic() - started, finished=time.time(), log_sha256=sha(log))
        atomic_json(directory / 'command.json', record)
        with self.lock:
            lane = self.report['lanes'][name]
            if verification:
                lane['active_seconds'] += record['seconds']
            lane['current_pid'] = None
            self.save()
        return record

    def build(self, name, preset, xlen, directory):
        sim = self.args.output / 'sim'
        with self.builders:
            self.patch(name, phase='building')
            common = ['make', '-C', str(self.source / 'sim'), 'all', f'RAPT_CONFIG={preset}',
                      f'XLEN={xlen}', 'DIFFTEST=1', f'BUILD_ROOT={sim}', f'BUILD_PROFILE={name}',
                      'VERILATOR_JOBS=4', 'VFLAGS=' + ('-DRAPT_RV64' if xlen == 64 else '')]
            build_log = directory / ('build-' + self.attempt)
            result = self.execute(name, common, build_log, 3600, verification=False)
            if result['exit'] != 0:
                raise RuntimeError('Simulator build failed: ' + str(build_log / 'run.log'))
            mrom_dir = directory / 'mrom'
            result = self.execute(name, ['make', '-C', str(self.source / 'sim/csrc/mem/mrom-data'),
                                  'all', f'BUILD_DIR={mrom_dir}', f'ISA64={int(xlen == 64)}',
                                  'CROSS_COMPILE=' + self.args.cross],
                                  directory / ('build-mrom-' + self.attempt),
                                  180, verification=False)
            if result['exit'] != 0:
                raise RuntimeError('MROM build failed')
        return sim / name / f'riscv{xlen}-npc-sim', mrom_dir / 'mrom-data.bin'

    def fuzz(self, name, index, directory, preset, xlen, npc, mrom):
        values = fuzz_parameters(index)
        command = [self.args.python, str(self.source / 'verification/scripts/cascade_fuzz.py'),
                   'run', '--repo', str(self.args.cascade_repo), '--output', str(directory / 'cases'),
                   '--xlen', str(xlen), '--preset', preset, '--npc', str(npc), '--mrom', str(mrom),
                   '--nemu', str(getattr(self.args, f'nemu{xlen}')), '--spike', str(self.args.spike),
                   '--objcopy', self.args.objcopy, '--seeds', str(values['seed']), '--blocks',
                   str(values['blocks']), '--instructions', str(values['instructions']),
                   '--mem-bytes', str(values['mem_bytes']), '--isa-profile', values['isa_profile'],
                   '--memory-seed', str(values['memory_seed']), '--mem-delays', '0',
                   str(values['delay']), '--timeout', '600']
        record = self.execute(name, command, directory, 2000)
        path = directory / 'cases/report.json'
        result = json.loads(path.read_text()) if path.is_file() else {}
        record['passed'] = record['exit'] == 0 and result.get('complete') and result.get('passed')
        record['parameters'] = values
        record['programs'] = len(result.get('cases', []))
        record['npc_runs'] = sum(len(case['runs']) for case in result.get('cases', []))
        # Keep input ELFs, seeds, golden state, architectural snapshots and all failed memory images.
        # Successful PMEM/flash checkpoint payloads are unnecessary for replaying the original ELF.
        removed = []
        for case in result.get('cases', []):
            for run in case['runs']:
                if run.get('passed'):
                    checkpoint = Path(run['log']).parent / 'checkpoint'
                    for payload in checkpoint.glob('mem_*.bin'):
                        removed.append(dict(path=str(payload), bytes=payload.stat().st_size))
                        payload.unlink()
        atomic_json(directory / 'retention.json', dict(removed_successful_memory_payloads=removed))
        return record

    def formal(self, name, index, directory):
        scripts = self.source / 'verification/scripts'
        if name == 'pono':
            # Interleave edge cases, production-sized ROBs, masks and generation widths early.
            permutation = (index * 137) % 4800
            command = [sys.executable, str(scripts / 'pono_recovery.py'), '--output',
                       str(directory / 'cases'), '--case', pono_shape(permutation),
                       '--bound', str((32, 64, 128)[index % 3]), '--timeout', '900',
                       '--pono', str(self.args.pono), '--btorsim', str(self.args.btorsim)]
            record = self.execute(name, command, directory, 3000)
            path = directory / 'cases/report.json'
            result = json.loads(path.read_text()) if path.is_file() else {}
            record['passed'] = record['exit'] == 0 and result.get('complete') and result.get('passed')
            record['dimensions'] = pono_shape(permutation)
            record['cases'] = len(result.get('cases', []))
            return record
        choices = [
            ('unit_contracts.py', ['stream-queue', '--jobs', '2', '--timeout', '600',
                                   '--solver', ('bitwuzla', 'yices', 'z3')[(index // 8) % 3]]),
            ('ioq_contract.py', ['prove', '--presets', ('small', 'middle-cache', 'default-w4-cache')[
                                       (index // 8) % 3], '--jobs', '2', '--metadata', 'rvfi',
                                       '--memory', ('dff', 'sram')[(index // 8) % 2],
                                       '--lutram', str((index // 8) % 2), '--synthesis', '1',
                                       '--timeout', '600']),
            ('rou_contract.py', ['retire', '--presets', ('formal', 'small', 'middle-cache')[
                                        (index // 8) % 3], '--metadata', 'functional', 'rvfi',
                                        '--validation-modes', str((index // 8) % 2),
                                        '--jobs', '2', '--timeout', '600']),
            ('unit_contracts.py', ['recovery', '--jobs', '2', '--timeout', '600']),
            ('unit_contracts.py', ['sram', '--jobs', '2', '--timeout', '600']),
            ('unit_contracts.py', ['nru', '--jobs', '2', '--timeout', '600']),
            ('rvfi_contract.py', ['--contract', 'effects', '--timeout', '600']),
            ('unit_contracts.py', ['l1d-data', '--presets', 'small-cache', 'middle-cache',
                                   'default-w4-cache', '--production-only', '--jobs', '2',
                                   '--timeout', '600'])]
        script, options = choices[index % len(choices)]
        # Give every selected block a chance before the more expensive matrix sweeps.
        subcommand = [options.pop(0)] if not options[0].startswith('-') else []
        record = self.execute(name, [sys.executable, str(scripts / script), *subcommand, '--output',
                              str(directory / 'cases'), *options], directory, 2400)
        path = directory / 'cases/results.json'
        result = json.loads(path.read_text()) if path.is_file() else {}
        record['passed'] = record['exit'] == 0 and result.get('complete') is True
        record['script'] = script
        return record

    def lane(self, name, preset=None, xlen=None):
        folder = self.args.output / name
        folder.mkdir(exist_ok=True)
        try:
            if self.report['lanes'][name]['active_seconds'] >= self.args.seconds:
                self.patch(name, phase='completed', duration_met=True)
                return
            npc = mrom = None
            if preset:
                npc, mrom = self.build(name, preset, xlen, folder)
            self.patch(name, phase='running', verification_started=time.time())
            index = 0
            while (folder / f'batch-{index:06d}').exists():
                index += 1
            immediate_errors = 0
            while self.report['lanes'][name]['active_seconds'] < self.args.seconds:
                if shutil.disk_usage(self.args.output).free < self.args.reserve_gib * 2**30:
                    raise RuntimeError('Disk reserve reached; reports and failures retained')
                directory = folder / f'batch-{index:06d}'
                if preset:
                    record = self.fuzz(name, index, directory, preset, xlen, npc, mrom)
                else:
                    record = self.formal(name, index, directory)
                atomic_json(directory / 'result.json', record)
                immediate_errors = (immediate_errors + 1 if not record['passed']
                                    and record['seconds'] < 3 else 0)
                with self.lock:
                    lane = self.report['lanes'][name]
                    lane['batches'] += 1
                    lane['passed_batches'] += int(bool(record['passed']))
                    lane['failed_batches'] += int(not record['passed'])
                    lane['programs'] += record.get('programs', 0)
                    lane['npc_runs'] += record.get('npc_runs', 0)
                    lane['last_result'] = str(directory / 'result.json')
                    self.save()
                print(name, index, 'PASS' if record['passed'] else 'INCOMPLETE', flush=True)
                if immediate_errors >= 3:
                    raise RuntimeError('Three immediate failures; refusing to count broken invocations')
                index += 1
            self.patch(name, phase='completed', finished=time.time(), duration_met=True)
        except Exception as error:
            self.patch(name, phase='failed', error=str(error), finished=time.time())
            print(name, 'FAILED:', error, flush=True)

    def run(self):
        lanes = [('pono', None, None), ('blocks', None, None)]
        lanes += [(f'{preset}-rv{xlen}', preset, xlen)
                  for preset in self.args.presets for xlen in self.args.xlens]
        for name, preset, xlen in lanes:
            self.report['lanes'].setdefault(name, dict(phase='waiting', preset=preset, xlen=xlen,
                active_seconds=0, batches=0, passed_batches=0, failed_batches=0,
                programs=0, npc_runs=0, duration_met=False))
            lane = self.report['lanes'][name]
            if 'error' in lane:
                lane.setdefault('previous_errors', []).append(lane.pop('error'))
            lane.update(phase='waiting', current_pid=None)
        self.save()
        with ThreadPoolExecutor(max_workers=len(lanes)) as pool:
            list(pool.map(lambda lane: self.lane(*lane), lanes))
        self.report['snapshot_unchanged'] = all(
            sha(self.source / name) == digest for name, digest in self.hashes.items())
        self.report['complete'] = True
        self.report['duration_met'] = all(lane['duration_met']
                                          for lane in self.report['lanes'].values())
        self.report['passed'] = (self.report['duration_met'] and self.report['snapshot_unchanged']
                                and all(lane['failed_batches'] == 0
                                        for lane in self.report['lanes'].values()))
        self.report['finished'] = time.time()
        self.save()
        lines = ['# Extended verification campaign', '',
                 f"Complete: {self.report['complete']}; passed: {self.report['passed']}", '',
                 '| Lane | Active hours | Passed batches | Failed/incomplete | Duration met |',
                 '| --- | --- | --- | --- | --- |']
        for name, lane in self.report['lanes'].items():
            lines.append(f"| {name} | {lane['active_seconds'] / 3600:.3f} | "
                         f"{lane['passed_batches']} | {lane['failed_batches']} | "
                         f"{lane['duration_met']} |")
        (self.args.output / 'summary.md').write_text('\n'.join(lines) + '\n')
        return 0 if self.report['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--seconds', type=int, default=10800)
    parser.add_argument('--presets', nargs='+', default=['small', 'middle-cache', 'default-w4-cache'])
    parser.add_argument('--xlens', nargs='+', type=int, choices=[32, 64], default=[32, 64])
    parser.add_argument('--parallel-builds', type=int, default=3)
    parser.add_argument('--reserve-gib', type=int, default=20)
    parser.add_argument('--resume', action='store_true', help='Resume the same unchanged snapshot')
    parser.add_argument('--cascade-repo', type=Path, required=True)
    parser.add_argument('--python', required=True, help='Python with Cascade dependencies')
    parser.add_argument('--spike', type=Path, required=True)
    parser.add_argument('--nemu32', type=Path, required=True)
    parser.add_argument('--nemu64', type=Path, required=True)
    parser.add_argument('--objcopy', default='riscv64-unknown-elf-objcopy')
    parser.add_argument('--cross', default='riscv64-unknown-elf-')
    parser.add_argument('--yosys', default=os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    parser.add_argument('--pono', type=Path, default=ROOT / 'third_party/oss-cad-suite/bin/pono')
    parser.add_argument('--btorsim', type=Path, default=ROOT / 'third_party/oss-cad-suite/bin/btorsim')
    args = parser.parse_args()
    if min(args.seconds, args.parallel_builds, args.reserve_gib) < 1:
        parser.error('Duration, build concurrency and disk reserve must be positive')
    if len(args.presets) != len(set(args.presets)) or len(args.xlens) != len(set(args.xlens)):
        parser.error('Duplicate configuration lanes')
    args.output = args.output.resolve()
    if args.output.exists() and not args.resume:
        parser.error('Campaign output must be a new directory')
    args.source = args.source.resolve(strict=True)
    for preset in args.presets:
        if not (args.source / 'rtl/configs' / preset / 'rapt_config.svh').is_file():
            parser.error('Unknown preset: ' + preset)
    for name in ('python', 'yosys', 'objcopy'):
        tool = shutil.which(getattr(args, name))
        if not tool:
            parser.error('Missing executable: ' + name)
        setattr(args, name, str(Path(tool).absolute()))
    for name in ('spike', 'nemu32', 'nemu64', 'pono', 'btorsim', 'cascade_repo'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    args.output.mkdir(parents=True, exist_ok=args.resume)
    supervisor_lock = (args.output / '.supervisor.lock').open('w')
    fcntl.flock(supervisor_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if args.resume:
        previous_pid = json.loads((args.output / 'status.json').read_text())['pid']
        try:
            os.kill(previous_pid, 0)
        except ProcessLookupError:
            pass
        else:
            state = Path(f'/proc/{previous_pid}/stat')
            if not state.exists() or state.read_text().rsplit(')', 1)[1].split()[0] != 'Z':
                parser.error('Previous supervisor is still active; stop it before resuming')
    inputs = args.output / 'inputs'
    inputs.mkdir(exist_ok=args.resume)
    for name in ('spike', 'nemu32', 'nemu64'):
        destination = inputs / getattr(args, name).name
        if not args.resume:
            shutil.copy2(getattr(args, name), destination)
        elif not destination.is_file():
            raise ValueError('Missing sealed reference binary: ' + str(destination))
        setattr(args, name, destination)
    if args.resume:
        hashes = json.loads((args.output / 'source-manifest.json').read_text())
        if any(sha(args.output / 'source' / name) != digest for name, digest in hashes.items()):
            raise ValueError('Cannot resume: source snapshot changed')
    else:
        hashes = snapshot(args.source, args.output / 'source')
    atomic_json(args.output / 'source-manifest.json', hashes)
    plan_path = args.output / ('resume-plan.json' if args.resume else 'plan.json')
    atomic_json(plan_path, {key: str(value) if isinstance(value, Path) else value
                           for key, value in vars(args).items()})
    (args.output / 'pid').write_text(str(os.getpid()) + '\n')
    return Campaign(args, hashes).run()


if __name__ == '__main__':
    raise SystemExit(main())
