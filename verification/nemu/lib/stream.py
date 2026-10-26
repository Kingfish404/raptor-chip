#!/usr/bin/env python3
"""Supervise live NEMU ISA checking through a bounded anonymous pipe."""
import argparse
from contextlib import ExitStack
import fcntl
import json
import math
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[3]


def read_tail(path, limit=65536):
    with path.open('rb') as stream:
        stream.seek(max(0, path.stat().st_size - limit))
        return stream.read(limit).decode(errors='replace')


def summary(path, prefix):
    lines = [line for line in read_tail(path).splitlines() if line.startswith(prefix)]
    if not lines:
        return None
    fields = {}
    for item in lines[-1].split()[1:]:
        key, value = item.split('=', 1)
        fields[key] = value if key == 'status' else int(value)
    return fields


def stop_group(process, signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def finish_processes(processes):
    for process in processes.values():
        stop_group(process, signal.SIGTERM)
    deadline = time.monotonic() + 1
    while any(process.poll() is None for process in processes.values()) and time.monotonic() < deadline:
        time.sleep(0.01)
    for process in processes.values():
        stop_group(process, signal.SIGKILL)
    for process in processes.values():
        process.wait()


def supervise(nemu, reference, replayer, arguments, output, timeout=120, pipe_bytes=None,
              prefix=(), environment=None, cancelled=None, separate_stderr=False):
    if not math.isfinite(timeout) or timeout <= 0 or (pipe_bytes is not None and not 4096 <= pipe_bytes <= 1048576):
        raise ValueError('timeout must be positive; pipe capacity must be 4096..1048576')
    forbidden = ('--diff-stream-fd', '--diff-record', '--diff-mode', '--diff')
    for argument in arguments:
        if argument in forbidden or any(argument.startswith(option + '=') for option in forbidden):
            raise ValueError('the supervisor owns the DiffTest transport options')
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ if environment is None else environment)
    environment.setdefault('NEMU_HOME', str(ROOT / 'nemu'))
    processes = {}
    commands = {}
    descriptors = []
    logs = {name: output / (name + '.log') for name in ('dut', 'ref')}
    started = time.monotonic()
    result = dict(status='FAIL', output=str(output), commands=commands, timeout_seconds=timeout,
                  transport='anonymous-pipe', transcript_saved=False, stderr_separate=separate_stderr,
                  pipe_bytes_requested=pipe_bytes,
                  environment={key: environment[key] for key in ('NEMU_HOME', 'UBSAN_OPTIONS', 'TSAN_OPTIONS')
                               if key in environment})
    try:
        read_fd, write_fd = os.pipe()
        descriptors.extend((read_fd, write_fd))
        if pipe_bytes is not None:
            if not hasattr(fcntl, 'F_SETPIPE_SZ'):
                raise ValueError('explicit pipe sizing is unsupported on this host')
            fcntl.fcntl(write_fd, fcntl.F_SETPIPE_SZ, pipe_bytes)
        capacity = fcntl.fcntl(write_fd, fcntl.F_GETPIPE_SZ) if hasattr(fcntl, 'F_GETPIPE_SZ') else None
        result['pipe_bytes'] = capacity
        commands['ref'] = list(map(str, [*prefix, replayer, reference, f'--fd={read_fd}']))
        commands['dut'] = list(map(str, [*prefix, nemu, '-b', f'--diff-stream-fd={write_fd}', *arguments]))
        with ExitStack() as stack:
            ref_log = stack.enter_context(logs['ref'].open('xb'))
            dut_log = stack.enter_context(logs['dut'].open('xb'))
            errors = {role: stack.enter_context((output / (role + '.stderr')).open('xb'))
                      if separate_stderr else subprocess.STDOUT for role in ('dut', 'ref')}
            processes['ref'] = subprocess.Popen(commands['ref'], pass_fds=(read_fd,), start_new_session=True,
                                                stdout=ref_log, stderr=errors['ref'], env=environment)
            processes['dut'] = subprocess.Popen(commands['dut'], pass_fds=(write_fd,), start_new_session=True,
                                                stdout=dut_log, stderr=errors['dut'], env=environment)
            for descriptor in descriptors:
                os.close(descriptor)
            descriptors.clear()
            while True:
                if cancelled is not None and cancelled():
                    result['error'] = 'cancelled'
                    break
                codes = {name: process.poll() for name, process in processes.items()}
                failures = [name for name, code in codes.items() if code not in (None, 0)]
                if failures:
                    result['error'] = 'endpoint failure: ' + ','.join(failures)
                    break
                if all(code is not None for code in codes.values()):
                    break
                if time.monotonic() - started >= timeout:
                    result['error'] = 'timeout'
                    break
                time.sleep(0.01)
    except KeyboardInterrupt:
        result['error'] = 'cancelled'
    except (OSError, ValueError) as error:
        result['error'] = str(error)
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
        finish_processes(processes)
    result['returncodes'] = {name: process.returncode for name, process in processes.items()}
    result['pids'] = {name: process.pid for name, process in processes.items()}
    result['elapsed_seconds'] = time.monotonic() - started
    try:
        dut = summary(logs['dut'], 'NEMU_JOURNAL events=')
        ref = summary(logs['ref'], 'NEMU_REPLAY checked=')
        result['summaries'] = {'dut': dut, 'ref': ref}
        valid = (result['returncodes'] == {'ref': 0, 'dut': 0} and dut and ref
                 and dut['status'] == ref['status'] == 'OK' and dut['events'] == ref['events'] > 0
                 and dut['bytes'] == ref['bytes'] > 64 and 1 <= dut['harts'] == ref['harts'] <= 4
                 and ref['checked'] > 0 and 1 <= ref['maximum_active'] <= ref['harts']
                 and ref['interleaved'] >= 0 and dut['buffer_bytes'] > 0 and ref['buffer_bytes'] > 0)
        valid = valid and dut.get('interrupts', 0) == ref.get('interrupts', 0) >= 0
        valid = valid and all(dut.get(field, 0) == ref.get(field, 0) >= 0
                              for field in ('clocks', 'io_requests', 'plic_sources', 'uart_rx', 'uart_irqs', 'uart_tx',
                                            'dma_reads', 'dma_writes', 'dma_bytes', 'rng_inputs', 'rng_irqs',
                                            'net_rx', 'net_tx', 'net_irqs', 'net_rx_bytes', 'net_tx_bytes', 'net_rx_drops',
                                            'block_reads', 'block_writes', 'block_bytes', 'block_irqs', 'block_image_size', 'block_pages'))
        if '--diff-rng' in arguments or '--diff-net' in arguments or '--diff-block' in arguments:
            valid = valid and all(field in dut and field in ref
                                  for field in ('dma_reads', 'dma_writes', 'dma_bytes', 'rng_inputs', 'rng_irqs'))
        if '--diff-net' in arguments or '--diff-block' in arguments:
            valid = valid and all(field in dut and field in ref
                                  for field in ('net_rx', 'net_tx', 'net_irqs', 'net_rx_bytes', 'net_tx_bytes', 'net_rx_drops'))
        if '--diff-block' in arguments:
            valid = valid and all(field in dut and field in ref
                                  for field in ('block_reads', 'block_writes', 'block_bytes', 'block_irqs', 'block_image_size', 'block_pages'))
        if valid and 'error' not in result:
            result['status'] = 'OK'
            if result['pipe_bytes'] is not None:
                result['stdio_pipe_capacity_bytes'] = dut['buffer_bytes'] + ref['buffer_bytes'] + result['pipe_bytes']
        else:
            result.setdefault('error', 'missing or inconsistent completion summaries')
    except (OSError, ValueError, KeyError, TypeError) as error:
        result.setdefault('error', 'invalid completion summaries: ' + str(error))
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nemu', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--replayer', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('--pipe-bytes', type=int)
    parser.add_argument('--disable-aslr', action='store_true')
    parser.add_argument('--separate-stderr', action='store_true', help='Keep stderr separate; pass NEMU --serial-stdout to isolate UART from progress')
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
    output = args.output
    if output is None:
        parent = ROOT / 'verification/build/nemu-supervise'
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='run-', dir=parent)) / 'session'
    prefix = ['setarch', platform.machine(), '-R'] if args.disable_aslr else []
    cancellation = [False]

    def cancel(signum, frame):
        cancellation[0] = True

    previous = {signum: signal.signal(signum, cancel) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        result = supervise(args.nemu.resolve(), args.reference.resolve(), args.replayer.resolve(), arguments,
                           output, args.timeout, args.pipe_bytes, prefix, cancelled=lambda: cancellation[0],
                           separate_stderr=args.separate_stderr)
    except (OSError, ValueError) as error:
        parser.exit(1, f'NEMU_STREAM_FAIL {error}\n')
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    print(f'NEMU_STREAM status={result["status"]} result={Path(result["output"]) / "result.json"}')
    if result['status'] != 'OK':
        parser.exit(1, result.get('error', 'stream failed') + '\n')

