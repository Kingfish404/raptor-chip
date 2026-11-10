#!/usr/bin/env python3
"""Run isolated JTAG integration checks; preserve logs and child failures."""
import argparse
from contextlib import ExitStack
from pathlib import Path
import os
import re
import signal
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'sim/gsim'))
from raptor_dse import parse_rapt_config


def stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def ready(process, log, marker, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'child exited with {process.returncode}: {log}')
        if marker in log.read_text(errors='replace'):
            return
        time.sleep(.05)
    raise RuntimeError(f'timed out waiting for {marker}: {log}')


def require(text, patterns):
    for pattern in patterns:
        if not re.search(pattern, text, re.IGNORECASE):
            raise RuntimeError(f'missing expected output: {pattern}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode', choices=['scan', 'halt', 'gdb', 'sba', 'reset'])
    ap.add_argument('--npc', required=True)
    ap.add_argument('--config', type=Path, required=True)
    ap.add_argument('--openocd', default='openocd')
    ap.add_argument('--openocd-config', type=Path, required=True)
    ap.add_argument('--gdb', default='riscv64-unknown-elf-gdb')
    ap.add_argument('--port', type=int, default=9824)
    ap.add_argument('--gdb-port', type=int, default=3333)
    ap.add_argument('--log-root', type=Path, required=True)
    ap.add_argument('--xlen', type=int, choices=[32, 64], default=32)
    ap.add_argument('--timeout', type=float, default=45)
    args = ap.parse_args()
    for port in (args.port, args.gdb_port):
        if not 1 <= port <= 65535:
            ap.error('ports must be between 1 and 65535')
    cfg = parse_rapt_config(args.config, False)
    misa = int(cfg['RAPT_MISA'])
    if args.mode in ('halt', 'gdb') and args.xlen != 32:
        ap.error('abstract-register smoke tests require RV32')
    args.log_root.mkdir(parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix=args.mode + '-', dir=args.log_root))
    print(f'[jtag] logs: {logs}', flush=True)
    with ExitStack() as stack:
        def launch(command, name):
            log = logs / name
            output = stack.enter_context(log.open('w'))
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            stack.callback(stop, process)
            return process, log

        server_cmd = [args.npc, '--jtag-server', f'--jtag-port={args.port}']
        server, server_log = launch(server_cmd, 'server.log')
        ready(server, server_log, 'waiting for OpenOCD', args.timeout)
        ocd = [args.openocd, '-c', f'set RAPT_JTAG_PORT {args.port}',
               '-c', f'set RAPT_BOOT_BRIDGE {int(args.mode in ("sba", "reset"))}',
               '-c', f'set RAPT_GDB_PORT {args.gdb_port if args.mode == "gdb" else "disabled"}',
               '-f', str(args.openocd_config)]
        if args.mode == 'gdb':
            debugger, debugger_log = launch(ocd, 'openocd.log')
            ready(debugger, debugger_log, f'Listening on port {args.gdb_port}', args.timeout)
            commands = ['set arch riscv:rv32', 'set confirm off',
                        f'target extended-remote 127.0.0.1:{args.gdb_port}',
                        'info reg misa pc t0', 'set $t0 = 0xDEADBEEF', 'info reg t0',
                        'set $t1 = 0x12345678', 'info reg t0 t1', 'kill']
            command = [args.gdb, '--batch']
            for c in commands:
                command += ['-ex', c]
            child, log = launch(command, 'gdb.log')
            patterns = [r'RV32', r't0\s+0xdeadbeef', r't1\s+0x12345678']
        elif args.mode in ('sba', 'reset'):
            image = logs / 'program.bin'
            image.write_bytes(struct.pack('<6I', 0x001002b7, 0x00005337, 0x55530313,
                                          0x0062a023, 0x00100073, 0x0000006f))
            ocd += ['-c', f'set RAPT_IMAGE {{{image}}}',
                    '-c', f'set RAPT_DUMP {{{logs / "dump.bin"}}}',
                    '-c', f'set RAPT_XLEN {args.xlen}',
                    '-f', str(Path(__file__).with_name(args.mode + '.tcl'))]
            child, log = launch(ocd, 'openocd.log')
            patterns = [r'tap/device found: 0x10001913', rf'XLEN={args.xlen}\b',
                        'PASS: SBA' if args.mode == 'sba' else 'PASS: reset halt and SBA boot']
        else:
            commands = ['scan_chain'] if args.mode == 'scan' else [
                'halt', 'reg t0 0xCAFEF00D', 'reg t0 -force',
                'reg t0 0x12345678', 'reg t0 -force', 'resume']
            for c in commands + ['exit']:
                ocd += ['-c', c]
            child, log = launch(ocd, 'openocd.log')
            patterns = [r'tap/device found: 0x10001913'] if args.mode == 'scan' else [
                r'Examined RISC-V core', rf'misa=0x{misa:x}\b',
                r't0 \(/32\): 0xcafef00d', r't0 \(/32\): 0x12345678']
        rc = child.wait(timeout=args.timeout)
        output = log.read_text(errors='replace')
        print(output, end='')
        if rc:
            raise RuntimeError(f'client exited with {rc}: {log}')
        require(output, patterns)
        if args.mode in ('sba', 'reset'):
            if (logs / 'dump.bin').read_bytes() != (logs / 'program.bin').read_bytes():
                raise RuntimeError('dump_image differs from program loaded through SBA')
        if args.mode == 'reset':
            require(server_log.read_text(errors='replace'), [r'HIT GOOD TRAP'])
        if args.mode == "gdb" and debugger.poll() not in (None, 0):
            raise RuntimeError(f"OpenOCD failed: {debugger_log}")
        if server.poll() not in (None, 0):
            raise RuntimeError(f'simulator failed: {server_log}')
    print('[jtag] PASS')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'[jtag] FAIL: {error}', file=sys.stderr)
        sys.exit(1)
