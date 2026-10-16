#!/usr/bin/env python3
"""Relocatable launcher for installed NEMU system emulators."""

import argparse
import contextlib
import json
import os
import re
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


BASE_EXTENSIONS = 'i m a f d c zicsr zifencei zicntr'.split()
RVA23_EXTENSIONS = (
    'i m a f d c b v h zicbom zicbop zicboz zicntr zicond zicsr zifencei '
    'zihintntl zihintpause zihpm zimop zkt zawrs zfa zfhmin zca zcb zcd zcmop '
    'zba zbb zbc zbs zvbb zvfhmin zvkt smstateen smnpm sscofpmf ssnpm ssstateen '
    'sstc svade svinval svnapot svpbmt'
).split()


def describe(binary):
    result = subprocess.run([str(binary), '--describe'], capture_output=True, text=True,
                            check=True, timeout=15)
    machine = json.loads(result.stdout)
    if machine.get('schema') != 1 or machine.get('isa') != 'riscv':
        raise ValueError('unsupported emulator capability schema or ISA')
    return machine


def regular_file(path, name):
    resolved = path.expanduser().resolve(strict=True)
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode) or not metadata.st_size:
        raise ValueError(name + ' must be a nonempty regular file')
    return resolved, metadata.st_size


def validate(machine, args):
    if not machine['vm_boot']:
        raise ValueError('this binary cannot boot VM payloads; build a riscv32/64_vm_defconfig')
    if machine['xlen'] != args.xlen:
        raise ValueError('--xlen does not match the emulator')
    if not 1 <= args.harts <= machine['max_harts']:
        raise ValueError('hart count exceeds compiled capabilities')
    if args.backend == 'threaded' and not machine['threaded']:
        raise ValueError('threaded execution is not compiled in')
    if args.isa_profile not in machine['profiles']:
        raise ValueError('ISA profile is not supported by this binary')
    if args.isa_profile == 'rva23' and (args.backend != 'rr' or not machine['cycle_timer']):
        raise ValueError('rva23 requires round-robin instruction-count timing')
    devices = machine['devices']
    if args.hostfwd:
        limit = devices.get('net', {}).get('hostfwd_max', 0)
        if len(args.hostfwd) > limit:
            raise ValueError(f'this binary supports at most {limit} host forwarding rules')
        seen = set()
        for rule in args.hostfwd:
            protocol, host, guest = rule.split(':')
            key = protocol, int(host)
            if key in seen:
                raise ValueError('duplicate host forwarding protocol/port: ' + rule)
            seen.add(key)
    for required in ('uart', 'clint', 'plic', 'finisher'):
        if required not in devices:
            raise ValueError('VM boot requires device: ' + required)
    if args.disk and 'block' not in devices:
        raise ValueError('this binary has no block device')
    if not args.disk and args.disk_mode != 'volatile':
        raise ValueError('--disk-mode requires --disk')
    args.firmware, size = regular_file(args.firmware, 'firmware')
    if size > machine['memory']['size']:
        raise ValueError('firmware exceeds compiled guest RAM')
    with args.firmware.open('rb') as stream:
        if stream.read(4) == b'\x7fELF':
            raise ValueError('firmware must be a raw fw_payload.bin, not an ELF file')
    if args.disk:
        args.disk, size = regular_file(args.disk, 'disk')
        if os.path.samefile(args.disk, args.firmware):
            raise ValueError('disk and firmware must be different files')
        if size % 512:
            raise ValueError('raw disk size must be a multiple of 512 bytes')
        with args.disk.open('rb') as stream:
            if stream.read(4) == b'QFI\xfb':
                raise ValueError('QCOW2 is unsupported; use a raw disk image')
    if args.append is not None and any(ord(character) < 32 or ord(character) > 126 for character in args.append):
        raise ValueError('--append must contain printable ASCII characters only')


def cells(value):
    return f'0x{value >> 32:x} 0x{value & 0xffffffff:x}'


def reg(device):
    return f'reg = <{cells(device["base"])} {cells(device["size"])}>;'


def device_tree(machine, args):
    devices = machine['devices']
    xlen = machine['xlen']
    extensions = RVA23_EXTENSIONS if args.isa_profile == 'rva23' else BASE_EXTENSIONS
    single = ''.join(extension for extension in extensions if len(extension) == 1)
    multi = '_'.join(extension for extension in extensions if len(extension) > 1)
    isa = f'rv{xlen}{single}_{multi}'
    append = args.append
    if append is None:
        append = 'console=ttyS0,115200 earlycon=sbi random.trust_bootloader=on'
        if args.disk:
            append += ' root=/dev/vda rootwait ' + ('ro' if args.disk_mode == 'readonly' else 'rw')
    uart_path = f'/soc/serial@{devices["uart"]["base"]:x}'
    lines = [
        '/dts-v1/;', '/ {', '#address-cells = <2>; #size-cells = <2>;',
        'compatible = "ucbbar,spike-bare-dev"; model = "NEMU virtual machine";',
        f'chosen {{ stdout-path = "{uart_path}"; bootargs = {json.dumps(append)};',
        'rng-seed = [' + '00 ' * 32 + ']; };',
        f'memory@{machine["memory"]["base"]:x} {{ device_type = "memory"; {reg(machine["memory"])} }};',
        'poweroff { compatible = "syscon-poweroff"; regmap = <&finisher>; offset = <0>; value = <0x5555>; };',
        'cpus { #address-cells = <1>; #size-cells = <0>;',
        f'timebase-frequency = <{devices["timebase_hz"]}>;',
    ]
    for hart in range(args.harts):
        lines.extend([
            f'cpu@{hart:x} {{ device_type = "cpu"; reg = <{hart}>; status = "okay"; compatible = "riscv";',
            f'riscv,isa = "{isa}"; riscv,isa-base = "rv{xlen}i";',
            'riscv,isa-extensions = ' + ', '.join(json.dumps(extension) for extension in extensions) + ';',
            f'mmu-type = "riscv,sv{39 if xlen == 64 else 32}"; riscv,pmpregions = <8>;',
            'riscv,pmpgranularity = <4>; clock-frequency = <1000000000>;',
        ])
        if args.isa_profile == 'rva23':
            lines.append('riscv,cbom-block-size = <64>; riscv,cbop-block-size = <64>; riscv,cboz-block-size = <64>;')
        lines.append(f'intc{hart}: interrupt-controller {{ #address-cells = <0>; #interrupt-cells = <1>; '
                     'interrupt-controller; compatible = "riscv,cpu-intc"; }; };')
    lines.extend(['};', 'soc { #address-cells = <2>; #size-cells = <2>; compatible = "simple-bus"; ranges;'])
    for name, interrupts, compatible in (('clint', (3, 7), 'riscv,clint0'), ('plic', (11, 9), 'riscv,plic0')):
        device = devices[name]
        lines.append(f'{name}: {name}@{device["base"]:x} {{ compatible = "{compatible}"; {reg(device)}')
        contexts = ' '.join(f'&intc{hart} {irq}' for hart in range(args.harts) for irq in interrupts)
        lines.append(f'interrupts-extended = <{contexts}>;')
        if name == 'plic':
            lines.append(f'#address-cells = <0>; #interrupt-cells = <1>; interrupt-controller; '
                         f'riscv,ndev = <{device["sources"]}>; riscv,max-priority = <15>;')
        lines.append('};')
    uart = devices['uart']
    lines.extend([
        f'serial@{uart["base"]:x} {{ compatible = "ns16550a"; {reg(uart)}',
        f'clock-frequency = <10000000>; interrupt-parent = <&plic>; interrupts = <{uart["irq"]}>;',
        'reg-shift = <0>; reg-io-width = <1>; };',
        f'finisher: test@{devices["finisher"]["base"]:x} {{ '
        f'compatible = "sifive,test1", "sifive,test0", "syscon"; {reg(devices["finisher"])} }};',
    ])
    for name in ('block', 'net', 'rng'):
        if name not in devices or (name == 'block' and not args.disk):
            continue
        device = devices[name]
        lines.append(f'virtio@{device["base"]:x} {{ compatible = "virtio,mmio"; {reg(device)} '
                     f'interrupt-parent = <&plic>; interrupts = <{device["irq"]}>; }};')
    return '\n'.join(lines + ['};', '};', ''])


def execute(command, directory):
    child = None

    def forward(signum, frame):
        if child is not None and child.poll() is None:
            child.send_signal(signum)

    previous = {signum: signal.signal(signum, forward)
                for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        child = subprocess.Popen(command, cwd=directory)
        returncode = child.wait()
        return returncode if returncode >= 0 else 128 - returncode
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def run(machine, args, binary, directory):
    dtc = shutil.which('dtc')
    if not dtc:
        raise ValueError('device-tree-compiler (dtc) is required for VM boot')
    source = directory / 'machine.dts'
    tree = directory / 'machine.dtb'
    source.write_text(device_tree(machine, args))
    subprocess.run([dtc, '-I', 'dts', '-O', 'dtb', '-o', str(tree), str(source)], check=True)
    if tree.stat().st_size > machine['rom']['dtb_max_size']:
        raise ValueError('generated device tree exceeds the emulator ROM capacity')
    command = [str(binary), '--batch', '--serial-stdout', '--smp=' + str(args.harts),
               '--smp-backend=' + args.backend, '--isa-extensions=' + args.isa_profile,
               '--log=' + str(directory / 'nemu.log'), '--tree=' + str(tree)]
    if args.disk:
        command.extend(['--disk=' + str(args.disk), '--disk-mode=' + args.disk_mode])
    command.extend('--hostfwd=' + rule for rule in args.hostfwd)
    command.append(str(args.firmware))
    plan = {'schema': 1, 'machine': machine, 'command': command, 'dry_run': args.dry_run,
            'disk_mode': args.disk_mode, 'directory': str(directory)}
    (directory / 'run.json').write_text(json.dumps(plan, indent=2) + '\n')
    if args.dry_run:
        print(json.dumps(plan, indent=2))
        return 0
    print('NEMU run directory: ' + str(directory), file=sys.stderr)
    if args.disk_mode == 'persistent':
        print('Persistent mode: guest writes modify ' + str(args.disk), file=sys.stderr)
    returncode = execute(command, directory)
    (directory / 'result.json').write_text(json.dumps({'returncode': returncode}) + '\n')
    return returncode


def host_forward(value):
    if not re.fullmatch(r'tcp:[0-9]{1,5}:[0-9]{1,5}', value):
        raise argparse.ArgumentTypeError('expected tcp:HOST_PORT:GUEST_PORT (loopback only; UDP unsupported)')
    protocol, host, guest = value.split(':')
    if not 1 <= int(host) <= 65535 or not 1 <= int(guest) <= 65535:
        raise argparse.ArgumentTypeError('forwarding ports must be in 1..65535')
    return f'{protocol}:{int(host)}:{int(guest)}'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    info = commands.add_parser('info', help='show actual compiled emulator capabilities')
    launch = commands.add_parser('run', help='boot a raw OpenSBI+kernel fw_payload.bin')
    for command in (info, launch):
        command.add_argument('--xlen', type=int, choices=(32, 64), default=64)
        command.add_argument('--emulator', type=Path, help='override the installed emulator path')
    launch.add_argument('--firmware', type=Path, required=True)
    launch.add_argument('--disk', type=Path, help='existing raw image (never created or truncated)')
    launch.add_argument('--disk-mode', choices=('volatile', 'readonly', 'persistent'), default='volatile')
    launch.add_argument('--hostfwd', type=host_forward, action='append', default=[],
                        help='repeatable tcp:HOST_PORT:GUEST_PORT; binds 127.0.0.1 only')
    launch.add_argument('--harts', type=int, default=1)
    launch.add_argument('--backend', choices=('rr', 'threaded'), default='rr')
    launch.add_argument('--isa-profile', choices=('none', 'rva23'), default='none')
    launch.add_argument('--append', help='replace the complete kernel command line')
    launch.add_argument('--state-dir', type=Path, help='new directory retaining DT, logs and launch metadata')
    launch.add_argument('--dry-run', action='store_true', help='validate and generate DT without starting the guest')
    args = parser.parse_args(argv)
    try:
        prefix = Path(__file__).resolve().parent.parent
        binary = (args.emulator or prefix / f'libexec/nemu/riscv{args.xlen}-nemu-interpreter').expanduser().resolve(strict=True)
        machine = describe(binary)
        if args.command == 'info':
            print(json.dumps(machine, indent=2))
            return 0
        validate(machine, args)
        with contextlib.ExitStack() as cleanup:
            if args.state_dir:
                directory = args.state_dir.expanduser().resolve()
                directory.mkdir(mode=0o700, parents=True, exist_ok=False)
            else:
                directory = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix='nemu-')))
            return run(machine, args, binary, directory)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('nemu: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
