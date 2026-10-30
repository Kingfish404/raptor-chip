#!/usr/bin/env python3
"""Run the pinned upstream Cascade generator against NPC architectural checkpoints."""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time

from run_riscv_tests import ROOT, execute, git, rtl_inputs, sha

URL = 'https://github.com/cascade-artifacts-designs/cascade-meta.git'
REVISION = 'c3de482f2c5451b4c571bc0384da45a84f892084'


def validate_source(repo):
    if git(repo, 'rev-parse', 'HEAD') != REVISION:
        raise ValueError('Cascade revision differs from the pinned artifact')
    if git(repo, 'status', '--porcelain', '--untracked-files=all', '--', 'fuzzer'):
        raise ValueError('Cascade fuzzer sources are modified or contain untracked files')
    return REVISION


def prepare(repo):
    repo.parent.mkdir(parents=True, exist_ok=True)
    if not repo.exists():
        subprocess.run(['git', 'clone', '--filter=blob:none', '--no-checkout', URL,
                        str(repo)], check=True)
        subprocess.run(['git', '-C', str(repo), 'sparse-checkout', 'set', 'fuzzer'], check=True)
        subprocess.run(['git', '-C', str(repo), 'checkout', '--detach', REVISION], check=True)
    print(validate_source(repo), flush=True)


def check_epilogue(words, num_gpr):
    """Checkpoint draining may execute this block; compared registers must survive it."""
    if not words:
        raise ValueError('Empty Cascade final block')
    for word in words:
        opcode, rd = word & 0x7f, (word >> 7) & 31
        if opcode in (0x37, 0x13, 0x6f, 0x73):
            if 0 < rd < num_gpr:
                raise ValueError('Cascade epilogue overwrites a compared GPR')
        elif opcode not in (0x0f, 0x23, 0x27):
            raise ValueError('Unexpected Cascade epilogue instruction')


def generate_local(args):
    """A labeled local random baseline; this is neither DifuzzRTL nor RISCV-DV."""
    from riscv_fuzz_gen import generate_program
    from common.spike import run_trace_regs_at_pc_locs
    if args.isa_profile != 'im':
        raise ValueError('The local baseline comparison requires the common IM ISA')
    started = time.monotonic()
    text = generate_program(random.Random(args.seed), args.instructions, args.xlen)
    lines = text.splitlines()
    boundary = next(i for i, line in enumerate(lines) if line.startswith('  li x15,')) + 1
    extra = ['  li x1, 0', '  li x10, 0'] + [f'  li x{i}, 0' for i in range(16, 32)]
    lines[boundary:boundary] = extra + ['.globl paper_body', 'paper_body:']
    text = '\n'.join(lines)
    prefix = text.split('  # --- Test complete ---', 1)[0]
    data = '.section .data' + text.split('.section .data', 1)[1]
    text = prefix + '.globl paper_done\npaper_done:\n  fence\n  j paper_done\n' + data + '\n'
    source, elf = args.output / 'baseline.S', args.output / 'baseline.elf'
    source.write_text(text)
    linker = args.output / 'baseline.ld'
    linker.write_text('OUTPUT_ARCH(riscv)\nENTRY(_start)\n'
        'PHDRS { code PT_LOAD; data PT_LOAD; }\nSECTIONS {\n'
        ' . = 0x80000000; .text : { *(.text*) } :code\n'
        ' . = ALIGN(4096); .data : { *(.data*) *(.rodata*) *(.bss*) } :data\n}\n')
    abi = 'lp64' if args.xlen == 64 else 'ilp32'
    subprocess.run([args.cross + 'gcc', f'-march=rv{args.xlen}im', f'-mabi={abi}',
                    '-nostdlib', '-nostartfiles', '-static', '-mcmodel=medany',
                    '-Wl,--build-id=none', '-Wl,-T,' + str(linker),
                    str(source), '-o', str(elf)], check=True)
    symbols = subprocess.check_output([args.cross + 'nm', str(elf)], text=True)
    addresses = {name: int(address, 16) for address, _, name in
                 (line.split() for line in symbols.splitlines() if len(line.split()) == 3)}
    end = addresses['paper_done']
    generation_time = time.monotonic() - started
    started = time.monotonic()
    expected = run_trace_regs_at_pc_locs('baseline', str(elf), f'rv{args.xlen}im',
        0x80000000, [(end - 0x80000000, False, i) for i in range(1, 32)], False, end, 0, False)
    return dict(elf=str(elf), expected=[expected, []], final_pc=hex(end),
                terminal_pc=hex(end + 4), num_gpr=32, num_fpr=0, blocks=None,
                timings=[generation_time, time.monotonic() - started, 0],
                body_ranges=[[addresses['paper_body'], end]])


def measure_program(args, record):
    """ISS program metrics at the full epilogue endpoint, with explicit dynamic body ranges."""
    from analyzeelfs.dependencies import get_dependencies_per_instruction
    started = time.monotonic()
    command_file, log = args.output / 'metrics-spike.cmd', args.output / 'metrics-spike.log'
    terminal = int(record['terminal_pc'], 16)
    command_file.write_text(f'untiln pc 0 {hex(terminal)}\npc 0\nq\n')
    result = execute([str(args.spike), '-d', '--debug-cmd=' + str(command_file),
                      f'--isa=rv{args.xlen}{args.isa_profile}', '--pc=0x80000000',
                      '-m0x0f000000:0x1000,0x80000000:0x10000000', record['elf']],
                     log, args.output, args.timeout)
    text = log.read_text(errors='replace')
    values = re.findall(r'^0x([0-9a-fA-F]+)\s*$', text, re.MULTILINE)
    if result['exit'] != 0 or not values or int(values[-1], 16) != terminal:
        raise ValueError('ISS metrics did not reach the declared epilogue endpoint')
    trace = []
    for line in text.splitlines():
        match = re.match(r'^core\s+0:\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)', line)
        if match and int(match[1], 16) >= 0x80000000:
            trace.append((int(match[1], 16), int(match[2], 16), line))
    body = [(pc, word, line) for pc, word, line in trace
            if any(start <= pc < end for start, end in record['body_ranges'])]
    if not trace or not body:
        raise ValueError('Empty measured program or fuzz body')
    metrics = dict(main_program_dynamic=len(trace), body_dynamic=len(body),
                   effective_fuzz_instructions=len(body) - int(args.generator == 'cascade'),
                   body_unique_pcs=len({pc for pc, _, _ in body}),
                   prevalence=len(body) / len(trace), spike_trace_sha256=sha(log),
                   scope='ISS execution including initialization and dump epilogue; excludes ISS ROM')
    if args.isa_profile == 'im':
        # Use the author's dependency analysis; PC ranges replace its fixed overhead length.
        ages, control = get_dependencies_per_instruction('\n'.join(line for _, _, line in body),
                                                         False, args.seed)
        metrics['dependency_ages'] = ages
        metrics['control_dependency_ages'] = [ages[index] for index in control]
        expected = sum((end - start) // 4 for start, end in record['body_ranges'])
        metrics['body_static_instructions'] = expected
        metrics['completion_unique_fraction'] = metrics['body_unique_pcs'] / expected
    metrics['analysis_seconds'] = time.monotonic() - started
    record['program_metrics'] = metrics


def generate(args):
    # Run in a child process: Cascade caches design properties and Spike speed globally.
    directory = args.output
    designs = directory / 'designs'
    config_dir = designs / 'raptor/meta'
    config_dir.mkdir(parents=True)
    (directory / 'data').mkdir()
    (designs / 'design_repos.json').write_text(json.dumps({'raptor': 'raptor'}))
    abi = ('lp64' if args.xlen == 64 else 'ilp32')
    if args.isa_profile == 'gc':
        abi += 'd'
    config = dict(toplevel='raptSoC', bootaddr='0x80000000',
                  marchflags=f'-march=rv{args.xlen}{args.isa_profile} -mabi={abi}',
                  stopsigaddr='0x0f000010', regdumpaddr='0x0f000000',
                  fpregdumpaddr='0x0f000008', misaligned_data_supported=True,
                  privlvs='m', mmu=[])
    (config_dir / 'cfg.json').write_text(json.dumps(config, indent=2) + '\n')
    tools = directory / 'tools'
    tools.mkdir()
    (tools / 'spike').symlink_to(args.spike)
    os.environ.update(CASCADE_ENV_SOURCED='1', CASCADE_DATADIR=str(directory / 'data'),
                      CASCADE_PATH_TO_FIGURES=str(directory / 'figures'),
                      CASCADE_DESIGN_PROCESSING_ROOT=str(designs))
    os.environ['PATH'] = str(tools) + os.pathsep + os.environ.get('PATH', '')
    sys.path.insert(0, str(args.repo / 'fuzzer'))
    import numpy as np
    import params.runparams as runparams
    runparams.NO_REMOVE_TMPFILES = True
    from common.spike import calibrate_spikespeed
    from cascade.fuzzfromdescriptor import gen_fuzzerstate_elf_expectedvals
    random.seed(args.seed)
    np.random.seed(args.seed)
    calibrate_spikespeed(100)
    if args.generator == 'local-random':
        record = generate_local(args)
        record.update(seed=args.seed, xlen=args.xlen, isa_profile=args.isa_profile,
                      max_instructions=args.instructions, generator=args.generator)
        if args.measure_program:
            measure_program(args, record)
        (directory / 'generated.json').write_text(json.dumps(record, indent=2) + '\n')
        return
    state, elf, expected, *timings = gen_fuzzerstate_elf_expectedvals(
        args.mem_bytes, 'raptor', args.seed, args.blocks, False, True, args.instructions,
        args.no_dependency_bias)
    words = [instruction.gen_bytecode_int(False) for instruction in state.final_bb]
    check_epilogue(words, state.num_pickable_regs)
    record = dict(elf=elf, expected=expected, final_pc=hex(
                  state.design_base_addr + state.final_bb_base_addr),
                  num_gpr=state.num_pickable_regs,
                  num_fpr=state.num_pickable_floating_regs if state.design_has_fpu else 0,
                  blocks=len(state.instr_objs_seq), epilogue_words=words, timings=timings,
                  seed=args.seed, xlen=args.xlen, isa_profile=args.isa_profile,
                  max_blocks=args.blocks,
                  max_instructions=args.instructions, mem_bytes=args.mem_bytes,
                  generator=args.generator, no_dependency_bias=args.no_dependency_bias,
                  terminal_pc=hex(state.design_base_addr + state.final_bb_base_addr
                                  + 4 * (len(state.final_bb) - 1)),
                  body_ranges=[[state.design_base_addr + address,
                                state.design_base_addr + address + 4 * len(block)]
                               for address, block in zip(state.bb_start_addr_seq[1:],
                                                         state.instr_objs_seq[1:])],
                  packages={name: importlib.metadata.version(name)
                            for name in ('numpy', 'filelock')})
    if args.measure_program:
        measure_program(args, record)
    if args.save_fuzzer_state:
        import pickle
        with (directory / 'fuzzer-state.pickle').open('wb') as stream:
            pickle.dump(state, stream)
        record['fuzzer_state_sha256'] = sha(directory / 'fuzzer-state.pickle')
    (directory / 'generated.json').write_text(json.dumps(record, indent=2) + '\n')


def compare_checkpoint(path, golden, xlen):
    values = {}
    trigger = None
    for line in path.read_text().splitlines():
        if line.startswith('save_trigger='):
            trigger = re.fullmatch(r'save_trigger=pc target=([0-9a-f]+) actual=([0-9a-f]+)', line)
        elif line and not line.startswith('#'):
            key, value = line.split('=', 1)
            if key in values:
                raise ValueError('Duplicate checkpoint field: ' + key)
            values[key] = value
    pc = int(golden['final_pc'], 16)
    if not trigger or any(int(value, 16) != pc for value in trigger.groups()):
        raise ValueError('Checkpoint did not retire the requested final-block PC')
    if int(values['xlen']) != xlen or int(values['instr']) <= 0:
        raise ValueError('Wrong checkpoint XLEN or empty execution')
    integers, floating = golden['expected']
    if not 2 <= golden['num_gpr'] <= 32 or not 0 <= golden['num_fpr'] <= 32:
        raise ValueError('Invalid Cascade register counts')
    if len(integers) < golden['num_gpr'] - 1 or len(floating) < golden['num_fpr']:
        raise ValueError('Incomplete Spike golden state')
    mismatches = []
    for index in range(1, golden['num_gpr']):
        key = f'gpr{index}'
        actual, expected = int(values[key], 16), integers[index - 1] & ((1 << xlen) - 1)
        if actual != expected:
            mismatches.append(dict(register=key, actual=hex(actual), expected=hex(expected)))
    for index in range(golden['num_fpr']):
        key = f'fpr{index}'
        actual, expected = int(values[key], 16), floating[index] & ((1 << 64) - 1)
        if actual != expected:
            mismatches.append(dict(register=key, actual=hex(actual), expected=hex(expected)))
    return mismatches


def run_case(args, seed):
    directory = args.output / f'seed-{seed}'
    directory.mkdir()
    command = [sys.executable, str(Path(__file__).resolve()), '_generate', '--repo', str(args.repo),
               '--output', str(directory), '--spike', str(args.spike), '--xlen', str(args.xlen),
               '--seed', str(seed), '--blocks', str(args.blocks), '--instructions',
               str(args.instructions), '--mem-bytes', str(args.mem_bytes),
               '--isa-profile', args.isa_profile, '--generator', args.generator,
               '--cross', args.cross]
    for flag in ('no_dependency_bias', 'measure_program', 'save_fuzzer_state'):
        if getattr(args, flag):
            command.append('--' + flag.replace('_', '-'))
    row = dict(seed=seed, passed=False, runs=[])
    row['generation'] = execute(command, directory / 'generation.log', ROOT, args.timeout)
    if row['generation']['exit'] != 0:
        row['failure'] = 'generation-or-Spike-resolution'
        return row
    golden = json.loads((directory / 'generated.json').read_text())
    return run_payload(args, directory, golden, row)


def run_payload(args, directory, golden, row=None):
    """Run an already resolved ELF; shared by fuzzing and the upstream reducer adapter."""
    if row is None:
        row = dict(passed=False, runs=[])
    elf = Path(golden['elf'])
    binary = directory / 'test.bin'
    subprocess.run([args.objcopy, '-O', 'binary', str(elf), str(binary)], check=True)
    row.update(elf_sha256=sha(elf), binary_sha256=sha(binary),
               golden_sha256=sha(directory / 'generated.json'),
               timings=golden['timings'], program_metrics=golden.get('program_metrics'),
               compared_gpr=golden['num_gpr'] - 1, compared_fpr=golden['num_fpr'])
    for delay in args.mem_delays:
        run_dir = directory / f'delay-{delay}'
        run_dir.mkdir()
        checkpoint = run_dir / 'checkpoint'
        command = [str(args.npc), '-b', '-n', '--no-lightsss', '--trap-on-ebreak',
                   '--ckpt-save=' + str(checkpoint), '--ckpt-pc=' + golden['final_pc'],
                   '--ckpt-save-exit', f'--mem-random-delay={delay}',
                   f'--mem-random-seed={args.memory_seed}', '-r', str(args.mrom)]
        if args.nemu:
            command += ['-d', str(args.nemu)]
        command.append(str(binary))
        if args.coverage:
            command = ['env', 'RAPT_COVERAGE_DIR=' + str(run_dir)] + command
        result = execute(command, run_dir / 'npc.log', run_dir, args.timeout)
        text = Path(result['log']).read_text(errors='replace')
        result['delay'] = delay
        result['passed'] = False
        if args.coverage:
            coverage_files = list(run_dir.glob('coverage-*.dat'))
            result['coverage'] = {str(path): sha(path) for path in coverage_files}
        if (result['exit'] == 0 and 'checkpoint: SAVED' in text and 'NPC QUIT' in text
                and not re.search(r'BAD TRAP|ABORT|mismatch', text, re.IGNORECASE)
                and (not args.nemu or '[difftest] reference ISA mask:' in text)):
            try:
                result['mismatches'] = compare_checkpoint(
                    checkpoint / 'state.txt', golden, args.xlen)
                result['checkpoint_sha256'] = sha(checkpoint / 'state.txt')
                result['passed'] = not result['mismatches']
                if args.coverage and not result['coverage']:
                    result['passed'] = False
                    result['failure'] = 'Instrumented NPC did not emit coverage'
            except (OSError, KeyError, ValueError) as error:
                result['failure'] = str(error)
        row['runs'].append(result)
    row['passed'] = all(run['passed'] for run in row['runs'])
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['setup', 'run', '_generate'])
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--xlen', type=int, choices=[32, 64], default=64)
    parser.add_argument('--isa-profile', choices=['gc', 'imac', 'im'], default='gc')
    parser.add_argument('--generator', choices=['cascade', 'local-random'], default='cascade')
    parser.add_argument('--cross', default='riscv64-unknown-elf-')
    parser.add_argument('--no-dependency-bias', action='store_true')
    parser.add_argument('--measure-program', action='store_true')
    parser.add_argument('--save-fuzzer-state', action='store_true')
    parser.add_argument('--coverage', action='store_true')
    for name in ('npc', 'mrom', 'nemu', 'spike'):
        parser.add_argument('--' + name, type=Path)
    parser.add_argument('--objcopy', default='riscv64-unknown-elf-objcopy')
    parser.add_argument('--seeds', nargs='+', type=int, default=list(range(16)))
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--mem-delays', nargs='+', type=int, default=[0, 31])
    parser.add_argument('--memory-seed', type=int, default=1)
    parser.add_argument('--blocks', type=int, default=20)
    parser.add_argument('--instructions', type=int, default=1000)
    parser.add_argument('--mem-bytes', type=int, default=65536)
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--preset', default='unspecified')
    args = parser.parse_args()
    args.repo = args.repo.resolve()
    if args.action == 'setup':
        prepare(args.repo)
        return 0
    if not args.output or not args.spike:
        parser.error('run/generate require --output and --spike')
    if (min(args.blocks, args.instructions, args.timeout) < 1 or args.mem_bytes < 65536
            or any(not 0 <= seed < 2**32 for seed in args.seeds + [args.seed, args.memory_seed])
            or any(delay < 0 for delay in args.mem_delays)):
        parser.error('Invalid campaign sizes, seeds or memory delays')
    args.output = args.output.resolve()
    args.spike = args.spike.resolve(strict=True)
    if args.action == '_generate':
        generate(args)
        return 0
    if not args.npc or not args.mrom:
        parser.error('run requires --npc and --mrom')
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('Output must be empty; use a new directory for each campaign')
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(schema='raptor-cascade-v1', complete=False, passed=False, cases=[],
                  xlen=args.xlen, isa_profile=args.isa_profile,
                  generator=args.generator, no_dependency_bias=args.no_dependency_bias,
                  preset=args.preset, coverage_guided=False,
                  privilege_scope='M mode, no address translation', whole_rtl_signoff=False)
    path = args.output / 'report.json'

    def save():
        path.write_text(json.dumps(report, indent=2) + '\n')

    save()
    try:
        validate_source(args.repo)
        for name in ('npc', 'mrom', 'nemu'):
            if getattr(args, name):
                setattr(args, name, getattr(args, name).resolve(strict=True))
        args.objcopy = shutil.which(args.objcopy)
        if not args.objcopy:
            raise ValueError('Missing objcopy')
        artifacts = {str(p): sha(p) for p in [args.npc, args.mrom, args.spike,
                     Path(args.objcopy), Path(__file__).resolve(),
                     Path(__file__).with_name('run_riscv_tests.py').resolve()] +
                     ([args.nemu] if args.nemu else [])}
        fingerprint = rtl_inputs()
        report.update(revision=REVISION, observed_rtl_sha256=fingerprint,
                      artifacts=artifacts, nemu=bool(args.nemu), python=sys.version,
                      memory_seed=args.memory_seed)
        for seed in dict.fromkeys(args.seeds):
            row = run_case(args, seed)
            report['cases'].append(row)
            print(f'seed {seed}: ' + ('PASS' if row['passed'] else 'FAIL'), flush=True)
            save()
        report['inputs_unchanged'] = fingerprint == rtl_inputs()
        report['upstream_unchanged'] = validate_source(args.repo) == REVISION
        report['artifacts_unchanged'] = all(
            sha(Path(p)) == digest for p, digest in artifacts.items())
        report['complete'] = True
        report['passed'] = (report['inputs_unchanged'] and report['upstream_unchanged']
                            and report['artifacts_unchanged']
                            and all(case['passed'] for case in report['cases']))
    finally:
        save()
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
