#!/usr/bin/env python3
"""Strict single-step and breakpoint checks through the production chip's JTAG."""
import argparse
from contextlib import ExitStack
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

from run_smoke import ready, require, stop


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--npc', required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--xlen', type=int, choices=[32, 64], default=32)
    ap.add_argument('--gcc', default='riscv64-elf-gcc')
    ap.add_argument('--openocd', default='openocd')
    ap.add_argument('--gdb')
    ap.add_argument('--port', type=int, default=9824)
    ap.add_argument('--gdb-port', type=int, default=3333)
    ap.add_argument('--timeout', type=float, default=300)
    args = ap.parse_args()
    here = Path(__file__).resolve().parent
    args.output.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='step-', dir=args.output)).resolve()
    print(f'[step] logs: {out}', flush=True)
    elf, image = out / 'step.elf', out / 'step.bin'
    march = f'rv{args.xlen}imac_zicsr_zifencei'
    prefix = args.gcc.removesuffix('gcc')
    subprocess.run([args.gcc, f'-march={march}',
                    '-mabi=ilp32' if args.xlen == 32 else '-mabi=lp64',
                    '-nostdlib', '-nostartfiles', '-g', '-Wl,--no-relax',
                    '-Wl,-Ttext=0x80000000,-Tdata=0x80000300',
                    str(here / 'step.S'), '-o', str(elf)], check=True)
    subprocess.run([prefix + 'objcopy', '-O', 'binary', str(elf), str(image)], check=True)
    symbols = subprocess.check_output([prefix + 'nm', '-n', str(elf)], text=True)
    sym = {name: int(addr, 16) for addr, _, name in
           (line.split() for line in symbols.splitlines() if len(line.split()) == 3)}
    commands = [
        'proc value {name} {',
        '  set text [reg $name -force]',
        '  if {![regexp {0x([0-9a-fA-F]+)} $text dummy hex]} {error "no register: $text"}',
        '  return [expr 0x$hex]',
        '}',
        'proc equal {name expected} {',
        '  set actual [value $name]',
        '  if {$actual != $expected} {error "register $name: $actual expected $expected"}',
        '}',
        'reset halt', f'load_image {{{image}}} 0x80000000 bin', 'reset halt',
        'reg dcsr 0x40008003', 'reg s0 0x10001000', 'reg t5 0',
    ]
    expected = []

    def step(name, target=None, regs=(), retired=1, cause=4, reads=0, writes=0, result=None,
             committed=1, admitted=1, prv=3):
        pc = sym[name]
        target = sym[name + '_next'] if target is None else sym.get(target, target)
        commands.extend(f'reg {reg} {value:#x}' for reg, value in regs)
        commands.extend([f'reg pc {pc:#x}', 'step', f'equal pc {target:#x}',
                         f'if {{(([value dcsr] >> 6) & 7) != {cause}}} {{error "halt cause"}}'])
        if result is not None:
            commands.append(f'equal t2 {result:#x}')
        expected.append(dict(pc=target, retire=retired, commit=committed, admit=admitted,
                             cause=cause, prv=prv, reads=reads, writes=writes, name=name))

    step('mtvec', regs=[('t0', sym['handler'])])
    step('alu', regs=[('t2', 0)], result=1)
    step('compressed', regs=[('t2', 0)], result=1)
    step('branch', 'branch_target', [('t0', 1), ('t1', 1)])
    step('branch', 'branch_next', [('t0', 1), ('t1', 2)])
    step('jump', 'jump_target')
    step('indirect', 'jump_target', [('t0', sym['jump_target'])])
    step('load', regs=[('t0', sym['data'])], result=7)
    step('store', regs=[('t0', sym['data']), ('t1', 11)])
    step('load', regs=[('t0', sym['data'])], result=11)
    step('amo', regs=[('t0', sym['data']), ('t1', 3)], result=11)
    step('load', regs=[('t0', sym['data'])], result=14)
    step('lr', regs=[('t0', sym['data'])], result=14)
    # Debug entry may lose an LR reservation. Both SC outcomes are legal.
    step('sc', regs=[('t0', sym['data']), ('t1', 17)])
    commands.extend(['set sc_failed [value t2]',
                     'if {$sc_failed != 0 && $sc_failed != 1} {error "invalid SC result"}'])
    step('load', regs=[('t0', sym['data'])])
    commands.append('equal t2 [expr {$sc_failed ? 14 : 17}]')
    step('csr', regs=[('t0', 0x12345678)])
    step('csr_read', result=0x12345678)
    step('fence_i')
    step('wfi')
    # A misaligned normal RAM access is implemented as one split instruction.
    step('load', regs=[('t0', sym['data'] + 1)])
    step('store', regs=[('t0', sym['data'] + 1), ('t1', 0x10203040)])
    step('load', regs=[('t0', sym['data'] + 1)], result=0x10203040)
    # Read-sensitive MMIO: the following younger MMIO load must never issue.
    step('load', regs=[('t0', 0x10001000)], reads=1)
    step('store', regs=[('t0', 0x10001000), ('t1', 0x5a)], writes=1)
    for name, regs, cause, tval in [
        ('ecall', [], 11, 0), ('illegal', [], 2, 0xffffffff),
        ('load', [('t0', 0x60000000)], 5, 0x60000000),
        # A mapped cache-line read receives DECERR from the board model.
        ('load', [('t0', 0x80003f00)], 5, 0x80003f00),
        # Device transfers reject splitting with an access fault (PMA policy).
        ('load', [('t0', 0x10001001)], 5, 0x10001001),
        ('store', [('t0', 0x10001001)], 7, 0x10001001),
        # The IOQ's atomic PMA capability check rejects this store/AMO footprint.
        ('amo', [('t0', sym['data'] + 1)], 7, sym['data'] + 1),
    ]:
        step(name, 'handler', regs, retired=0)
        commands.append('equal t5 0')  # No handler instruction may execute.
        step('mcause', result=cause)
        step('mepc_read', result=sym[name])
        step('mtval', result=tval)
    # EBREAK disabled: a normal breakpoint exception, stepped to the handler.
    commands.extend(['riscv set_ebreakm off', 'reg dcsr 0x40000003'])
    step('ebreak', 'handler', retired=0)
    step('mcause', result=3)
    commands.extend(['riscv set_ebreakm on', 'reg dcsr 0x40008003'])
    step('ebreak', 'ebreak', retired=0, cause=1)
    step('c_ebreak', 'c_ebreak', retired=0, cause=1)

    # CSR enables stay architectural; stepie gates only delivery during the step.
    step('mie', regs=[('t0', 8)])
    step('mstatus', regs=[('t0', 8)])
    commands.append('mww 0x02000000 1')
    step('alu', regs=[('t2', 0)], result=1)
    commands.append('reg dcsr 0x40008803')
    step('alu', 'handler', retired=0, committed=0, admitted=0)
    commands.append('mww 0x02000000 0')
    step('mcause', result=(1 << (args.xlen - 1)) | 3)
    step('mepc_read', result=sym['alu'])
    step('mie', regs=[('t0', 0)])
    commands.append('reg dcsr 0x40008003')

    def reset_halt():
        commands.extend(['reset halt', 'reg s0 0x10001000'])
        expected.append(dict(pc=0x20000000, retire=0, commit=0, admit=0,
                             cause=3, prv=3, reads=0, writes=0, name='reset halt'))

    # Privilege is restored by normal MRET; dcsr.prv writes are read-only.
    for privilege, control in [(1, 0x4000a003), (0, 0x40009003)]:
        reset_halt()
        commands.append(f'reg dcsr {control:#x}')
        step('pmpaddr', regs=[('t0', 0xffffffff)])
        step('pmpcfg', regs=[('t0', 0x1f)])
        step('mtvec', regs=[('t0', sym['handler'])])
        step('mepc', regs=[('t0', sym['ebreak'])])
        step('mstatus', regs=[('t0', privilege << 11)])
        step('mret', 'ebreak', prv=privilege)
        step('ebreak', 'ebreak', retired=0, cause=1, prv=privilege)
        commands.append('reg dcsr 0x40008003')
        commands.append(f'if {{([value dcsr] & 3) != {privilege}}} '
                        '{error "prv is not read-only"}')
        mode = 's' if privilege else 'u'
        commands.append(f'riscv set_ebreak{mode} off')
        step('ebreak', 'handler', retired=0)
        step('mcause', result=3)
        commands.append(f'riscv set_ebreak{mode} on')
    reset_halt()
    commands.append('reg dcsr 0x40008003')

    # Prime this exact cache line before OpenOCD patches a 16-bit breakpoint.
    step('swbreak', regs=[('t2', 0)], result=1)
    commands.extend([f'bp {sym["swbreak"]:#x} 2', f'reg pc {sym["swbreak"]:#x}',
                     'resume', 'wait_halt 5000', f'equal pc {sym["swbreak"]:#x}',
                     'if {(([value dcsr] >> 6) & 7) != 1} {error "software breakpoint cause"}'])
    expected.append(dict(pc=sym['swbreak'], retire=0, commit=1, cause=1,
                         reads=0, writes=0, name='software breakpoint'))
    # Continue as a debugger does: restore the original instruction, step it,
    # reinsert the breakpoint, then run. Plain Tcl resume reexecutes EBREAK.
    commands.extend([f'rbp {sym["swbreak"]:#x}', 'step',
                     f'bp {sym["swbreak"]:#x} 2', 'resume', 'wait_halt 5000',
                     f'equal pc {sym["swbreak"]:#x}',
                     f'rbp {sym["swbreak"]:#x}'])
    expected.append(dict(pc=sym['swbreak_next'], retire=1, commit=1, cause=4,
                         reads=0, writes=0, name='breakpoint continuation step'))
    expected.append(dict(pc=sym['swbreak'], retire=2, commit=3, cause=1,
                         reads=0, writes=0, name='breakpoint continuation stop'))
    commands.extend(['echo "PASS: precise step, DPC redirect, traps, MMIO and software breakpoint"',
                     'shutdown'])
    script = out / 'step.tcl'
    script.write_text('\n'.join(commands) + '\n')
    with ExitStack() as stack:
        def launch(cmd, name):
            path = out / name
            log = stack.enter_context(path.open('w'))
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            stack.callback(stop, proc)
            return proc, path

        server, server_log = launch([args.npc, f'--jtag-port={args.port}', '+STEP_FAULTS'],
                                    'server.log')
        ready(server, server_log, 'waiting for OpenOCD', 30)
        ocd, ocd_log = launch([args.openocd, '-c', f'set RAPT_JTAG_PORT {args.port}',
                               '-c', 'set RAPT_GDB_PORT disabled',
                               '-f', str(here / 'openocd.cfg'), '-f', str(script)], 'openocd.log')
        code = ocd.wait(timeout=args.timeout)
        print(ocd_log.read_text(errors='replace'), end='')
        if code:
            raise RuntimeError(f'OpenOCD failed ({code}): {server_log}')
        require(ocd_log.read_text(), ['PASS: precise step'])
        # Wait for bitbang Q/EOF and stdio flush before inspecting witnesses.
        # Otherwise a successful client can race the last buffered halt records.
        if server.wait(timeout=10) != 0:
            raise RuntimeError(f'server failed: {server_log}')
        records = []
        for match in re.finditer(r'DEBUG_HALT (.*)', server_log.read_text()):
            fields = dict(re.findall(r'(\w+)=(\w+)', match[1]))
            records.append({k: int(v, 16 if k == 'pc' else 10) for k, v in fields.items()})
        if len(records) < len(expected) + 1:
            raise RuntimeError(f'missing halt witnesses: {len(records)} for {len(expected)} checks')
        records = records[-len(expected)-1:]
        for before, after, want in zip(records, records[1:], expected):
            for field in ('pc', 'cause', 'prv', 'retire', 'commit', 'admit', 'reads', 'writes'):
                if field not in want:
                    continue
                actual = (after[field] if field in ('pc', 'cause', 'prv')
                          else after[field] - before[field])
                if actual != want[field]:
                    raise RuntimeError(f'{want["name"]}: {field}={actual:#x}, '
                                       f'expected {want[field]:#x}; {before} -> {after}')
        print(f'[step] PASS: {len(expected)} independently counted halt boundaries RV{args.xlen}')
    if args.gdb:
        run_gdb(args, out, elf, image, here)


def run_gdb(args, out, elf, image, here):
    """Run the checked-in GDB session against a fresh production chip instance."""
    script = (here / 'step.gdb.in').read_text()
    for name, value in dict(XLEN=args.xlen, ELF=elf, IMAGE=image,
                            GDB_PORT=args.gdb_port).items():
        script = script.replace('@' + name + '@', str(value))
    path = out / 'step.gdb'
    path.write_text(script)
    with ExitStack() as stack:
        def launch(command, name):
            log = out / name
            output = stack.enter_context(log.open('w'))
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            stack.callback(stop, process)
            return process, log

        server, server_log = launch([args.npc, f'--jtag-port={args.port}'], 'gdb-server.log')
        ready(server, server_log, 'waiting for OpenOCD', 30)
        ocd, ocd_log = launch([args.openocd, '-c', f'set RAPT_JTAG_PORT {args.port}',
                               '-c', f'set RAPT_GDB_PORT {args.gdb_port}',
                               '-f', str(here / 'openocd.cfg')], 'gdb-openocd.log')
        ready(ocd, ocd_log, f'Listening on port {args.gdb_port}', 30)
        gdb, log = launch([args.gdb, '--batch', '-x', str(path)], 'gdb.log')
        code = gdb.wait(timeout=args.timeout)
        print(log.read_text(errors='replace'), end='')
        if code or server.poll() not in (None, 0) or ocd.poll() not in (None, 0):
            raise RuntimeError(f'GDB session failed: {out}')
        require(log.read_text(), ['PASS: GDB stepi'])


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'[step] FAIL: {error}', file=sys.stderr)
        sys.exit(1)
