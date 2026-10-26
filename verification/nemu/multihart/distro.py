#!/usr/bin/env python3
"""Require both distribution userspace acceptance and complete threaded DiffTest."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import tempfile

from lib.build import ROOT, build_nemu, build_reference, build_replay_driver
from lib.stream import supervise
from distro_boot import verdict


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def read_output(directory):
    output = (directory / 'dut.log').read_bytes()
    stderr = directory / 'dut.stderr'
    if stderr.exists():
        output += b'\n' + stderr.read_bytes()
    return output


def accepted(distro, harts, result, output):
    if result.get('status') != 'OK' or result.get('returncodes') != {'dut': 0, 'ref': 0}:
        return False
    if not verdict(output, 0, distro, harts) or f'NEMU_THREADED harts={harts} '.encode() not in output:
        return False
    summaries = result.get('summaries') or {}
    native, reference = summaries.get('dut') or {}, summaries.get('ref') or {}
    fields = ('events', 'bytes', 'harts', 'interrupts', 'clocks', 'io_requests', 'plic_sources',
              'uart_rx', 'uart_irqs', 'uart_tx', 'dma_reads', 'dma_writes', 'dma_bytes',
              'rng_inputs', 'rng_irqs', 'net_rx', 'net_tx', 'net_irqs', 'net_rx_bytes',
              'net_tx_bytes', 'net_rx_drops', 'block_reads', 'block_writes', 'block_bytes',
              'block_irqs', 'block_image_size', 'block_pages')
    return (native.get('status') == reference.get('status') == 'OK'
            and all(isinstance(native.get(field), int) and native[field] >= 0 and native[field] == reference.get(field) for field in fields)
            and native['harts'] == harts and reference.get('checked', 0) > 0
            and reference.get('maximum_active', 0) >= min(harts, 2)
            and all(native[field] > 0 for field in ('events', 'bytes', 'uart_tx', 'block_reads', 'block_writes', 'block_irqs', 'block_image_size')))


def report_result(receipt, destination):
    destination.write_text(json.dumps(receipt, indent=2) + '\n')
    print('NEMU_DISTRO_DIFFTEST', 'PASS' if receipt['passed'] else 'FAIL', destination, flush=True)
    raise SystemExit(0 if receipt['passed'] else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared', type=Path, required=True, help='Prepared debian/ubuntu directory containing manifest.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'verification/build/nemu-distro')
    parser.add_argument('--timeout', type=float, default=3600)
    parser.add_argument('--pipe-bytes', type=int, default=65536, help='Bounded journal pipe capacity: 4096..1048576 bytes')
    parser.add_argument('--progress', type=int, default=1000000, help='Retirements per stderr progress report; 0 disables')
    parser.add_argument('--clock-div', type=int, help='Guest wall-clock divisor, 1..1000; defaults to the prepared manifest')
    parser.add_argument('--inspect', type=Path, help='Validate a completed live-stream result.json without restarting it')
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout must be finite and positive')
    if not 4096 <= args.pipe_bytes <= 1048576:
        parser.error('--pipe-bytes must be 4096..1048576')
    if not 0 <= args.progress <= 1099511627776:
        parser.error('--progress must be 0..1099511627776')
    if args.clock_div is not None and not 1 <= args.clock_div <= 1000:
        parser.error('--clock-div must be 1..1000')
    prepared = args.prepared.resolve()
    manifest = prepared / 'manifest.json'
    metadata = json.loads(manifest.read_text())
    distro, harts = metadata['distro'], metadata['harts']
    if distro not in ('debian', 'ubuntu') or harts not in (1, 2, 3, 4):
        parser.error('prepared image must describe Debian/Ubuntu and 1..4 harts')
    if not all(digest(prepared / name) == value for name, value in metadata['files'].items()):
        parser.error('prepared artifact hash mismatch')
    if args.inspect:
        result_path = args.inspect.resolve()
        result = json.loads(result_path.read_text())
        directory = result_path.parent
    else:
        work = args.output.resolve()
        work.mkdir(parents=True, exist_ok=True)
        directory = Path(tempfile.mkdtemp(prefix=f'{distro}-{harts}h-', dir=work)) / 'stream'
        build = work / 'build-rv64'
        binary = build_nemu(build / 'nemu', xlen=64)
        reference = build_reference(build / 'nemu', build / 'reference', 64, None)
        driver = build_replay_driver(build / 'nemu-journal-replay')
        options = ['-n', '--serial-stdout', '--diff-block', '--diff-tlb=retain', '--diff-progress=' + str(args.progress),
                   '--smp-backend=threaded', f'--smp={harts}',
                   '--smp-clock-div=' + str(args.clock_div if args.clock_div is not None else metadata.get('nemu_clock_div', 16)),
                   '--disk=' + str(prepared / 'rootfs.ext4'), '-t', str(prepared / 'nemu.dtb'), str(prepared / 'fw_payload.bin')]
        launch = dict(prepared=str(prepared), manifest_sha256=digest(manifest), artifacts_sha256=metadata['files'],
                      binaries_sha256={role: digest(path) for role, path in (
                          ('native', binary), ('reference', reference), ('driver', driver))})
        (directory.parent / 'launch.json').write_text(json.dumps(launch, indent=2) + '\n')
        print('NEMU_DISTRO_DIFFTEST_OUTPUT=' + str(directory), flush=True)
        result = supervise(binary, reference, driver, options, directory, timeout=args.timeout,
                           pipe_bytes=args.pipe_bytes, separate_stderr=True)
        result_path = directory / 'result.json'
    destination = directory / 'distro-difftest-result.json'
    logs = ['dut.log', 'ref.log']
    if result.get('stderr_separate'):
        logs.extend(('dut.stderr', 'ref.stderr'))
    missing = [name for name in logs if not (directory / name).is_file()]
    commands = result.get('commands') or {}
    if missing or not all(commands.get(role) for role in ('dut', 'ref')):
        receipt = dict(passed=False, distro=distro, harts=harts, prepared=str(prepared),
                       result=str(result_path), result_sha256=digest(result_path), manifest_sha256=digest(manifest),
                       artifacts_sha256=metadata['files'], error=result.get('error', 'incomplete endpoint evidence'),
                       missing_logs=missing, returncodes=result.get('returncodes', {}),
                       available_logs_sha256={name: digest(directory / name) for name in logs if name not in missing})
        report_result(receipt, destination)
    command = result['commands']['dut']
    required = {'--diff-block', '--diff-tlb=retain', '--smp-backend=threaded', f'--smp={harts}'}
    disks = [Path(value.split('=', 1)[1]).resolve() for value in command if value.startswith('--disk=')]
    dtbs = [Path(command[index + 1]).resolve() for index, value in enumerate(command[:-1]) if value == '-t']
    matching = required.issubset(command) and disks == [prepared / 'rootfs.ext4'] and dtbs == [prepared / 'nemu.dtb']
    matching &= Path(command[-1]).resolve() == prepared / 'fw_payload.bin'
    output = read_output(directory)
    unchanged = all(digest(prepared / name) == value for name, value in metadata['files'].items())
    passed = matching and unchanged and accepted(distro, harts, result, output)
    receipt = dict(passed=passed, distro=distro, harts=harts, prepared=str(prepared),
                   result=str(result_path), result_sha256=digest(result_path), manifest_sha256=digest(manifest),
                   artifacts_sha256=metadata['files'], log_sha256={role: digest(directory / (role + '.log')) for role in ('dut', 'ref')},
                   binaries_sha256={role: digest(path) for role, path in (
                       ('native', command[command.index('-b') - 1]),
                       ('driver', result['commands']['ref'][-3]), ('reference', result['commands']['ref'][-2]))})
    launch_path = directory.parent / 'launch.json'
    receipt['stderr_sha256'] = {role: digest(directory / (role + '.stderr')) for role in ('dut', 'ref')
                               if (directory / (role + '.stderr')).exists()}
    if launch_path.exists():
        launch = json.loads(launch_path.read_text())
        passed = passed and all(receipt[field] == launch[field] for field in
                                ('prepared', 'manifest_sha256', 'artifacts_sha256', 'binaries_sha256'))
        receipt['passed'] = passed
        receipt['launch_sha256'] = digest(launch_path)
    report_result(receipt, destination)


if __name__ == '__main__':
    main()
