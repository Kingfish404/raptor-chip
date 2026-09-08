#!/usr/bin/env python3
"""Build/run constrained LR/SC loops; finite stress, not liveness proof."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import re
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def classify(status, text, negative, first, last, external_timeout=False):
    good = 'Finisher: poweroff (0x5555)' in text
    errors = any(s in text for s in ('Finisher: fail', 'Assertion failed',
                                     '[ERROR]', 'mismatch'))
    if not negative:
        return (status == 0 and good and not errors and not external_timeout
                and 'HIT BAD TRAP' not in text)
    # A nonzero exit or host kill alone never demonstrates that the loop ran.
    # NPC statistic() prints HIT BAD TRAP for every NPC_ABORT, including the
    # expected timeout. Require the specific timeout evidence below instead.
    timeout = re.search(r'Wall-clock timeout .*? at pc: (?:0x)?([0-9a-fA-F]+), '
                        r'(\d+) cycles, (\d+) insts', text)
    return (status != 0 and not external_timeout and not good and not errors
            and timeout is not None and first <= int(timeout[1], 16) < last
            and int(timeout[3]) > 16)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tool-prefix', default='riscv64-unknown-elf-')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--translation', choices=('bare', 'sv39'), default='bare')
    parser.add_argument('--loop-kind', choices=('maximal', 'minimal'), default='maximal')
    parser.add_argument('--npc', type=Path)
    parser.add_argument('--mrom', type=Path)
    parser.add_argument('--runtime-cwd', type=Path)
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--delays', type=int, nargs='+', default=[0, 63])
    parser.add_argument('--seeds', type=int, nargs='+', default=[42])
    parser.add_argument('--cases', nargs='+', help='Exact variant names for focused reproduction; '
                        'omit to run the full matrix, including the negative control')
    args = parser.parse_args()
    if args.translation == 'sv39' and args.xlen != 64:
        parser.error('Sv39 requires --xlen 64')
    if args.timeout <= 0 or any(d < 0 for d in args.delays):
        parser.error('timeout must be positive; delays must be nonnegative')
    if not args.build_only and not all((args.npc, args.mrom, args.runtime_cwd)):
        parser.error('execution requires --npc, --mrom and --runtime-cwd')
    tools = {}
    for tool in ('gcc', 'objcopy', 'nm', 'objdump'):
        located = shutil.which(args.tool_prefix + tool)
        if not located:
            parser.error('missing tool: ' + args.tool_prefix + tool)
        tools[tool] = str(Path(located).resolve())
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    scope = ('Bare M/S/U' if args.translation == 'bare' else 'Sv39 S/U, 4 KiB code/data leaves')
    report = dict(xlen=args.xlen, translation=args.translation, loop_kind=args.loop_kind,
                  scope=scope + ', three RAM regions; no external writer',
                  build_only=args.build_only, complete=False, builds=[], runs=[], inputs={})

    def save():
        temporary = out / 'summary.json.tmp'
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(out / 'summary.json')

    for name, path in [('test.S', root / 'app/tests/baremetal/lrsc_constrained_progress.S'),
                       ('link.ld', root / 'verify/scripts/fuzz_link.ld'),
                       ('runner.py', Path(__file__).resolve())]:
        shutil.copyfile(path, out / name)
        report['inputs'][name] = dict(origin=str(path), sha256=digest(out / name))
    report['tools'] = {k: dict(path=v, sha256=digest(Path(v))) for k, v in tools.items()}
    report['compiler_version'] = subprocess.check_output([tools['gcc'], '--version'], text=True)
    if not args.build_only:
        for name in ('npc', 'mrom'):
            path = getattr(args, name).resolve(strict=True)
            setattr(args, name, path)
            report['inputs'][name] = dict(origin=str(path), sha256=digest(path))
        args.runtime_cwd = args.runtime_cwd.resolve(strict=True)
        report['runtime_cwd'] = str(args.runtime_cwd)
        library = args.runtime_cwd / '../nemu/tools/capstone/repo/libcapstone.so.5'
        if not library.is_file():
            parser.error('runtime cwd lacks the NPC relative Capstone library')
        report['inputs']['capstone'] = dict(origin=str(library.resolve()), sha256=digest(library))
    save()
    privileges = (3, 1, 0) if args.translation == 'bare' else (1, 0)
    variants = [(d, p, o, a, False) for d, p, o, a in itertools.product(
        range(2 if args.xlen == 64 else 1), privileges, (0, 2, 32, 62), (0, 1))]
    variants.append((0, privileges[0], 2, 1, True))
    def variant_name(variant):
        d, p, o, a, negative = variant
        return f'd{d}-p{p}-o{o}-a{a}' + ('-negative' if negative else '')
    if args.cases:
        unknown = set(args.cases) - {variant_name(v) for v in variants}
        if unknown:
            parser.error('unknown cases: ' + ', '.join(sorted(unknown)))
        variants = [v for v in variants if variant_name(v) in args.cases]
    report['selected_cases'] = [variant_name(v) for v in variants]
    report['full_matrix_selected'] = not args.cases
    save()
    try:
        for double, privilege, offset, ordered, negative in variants:
            name = f'd{double}-p{privilege}-o{offset}-a{ordered}' + ('-negative' if negative else '')
            elf, binary = out / (name + '.elf'), out / (name + '.bin')
            command = [tools['gcc'], f'-march=rv{args.xlen}imac_zicsr_zifencei',
                       '-mabi=' + ('lp64' if args.xlen == 64 else 'ilp32'),
                       '-nostdlib', '-static', '-Wl,--no-relax', '-T', str(out / 'link.ld'),
                       f'-DTEST_D={double}', f'-DTEST_PRIV={privilege}',
                       f'-DCODE_OFFSET={offset}', f'-DORDERED={ordered}',
                       f'-DTEST_VM={int(args.translation == "sv39")}',
                       f'-DSHORT_LOOP={int(args.loop_kind == "minimal")}',
                       str(out / 'test.S'), '-o', str(elf)]
            if negative:
                command.append('-DINJECT_SC_FAIL')
            with (out / (name + '.build.log')).open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run([tools['objcopy'], '-O', 'binary', str(elf), str(binary)], check=True)
            symbols = subprocess.check_output([tools['nm'], '-n', str(elf)], text=True)
            (out / (name + '.nm')).write_text(symbols)
            addresses = {line.split()[2]: int(line.split()[0], 16) for line in symbols.splitlines()
                         if len(line.split()) == 3}
            first, last = addresses['maximal_loop'], addresses['maximal_loop_end']
            instruction_count = 3 if args.loop_kind == 'minimal' else 16
            if last - first != instruction_count * 4 or first % 4096 != (4032 + offset) % 4096:
                raise ValueError('invalid constrained loop size/placement: ' + name)
            disassembly = subprocess.check_output([tools['objdump'], '-d',
                f'--start-address={first}', f'--stop-address={last}', str(elf)], text=True)
            (out / (name + '.disassembly')).write_text(disassembly)
            words = re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', disassembly, re.M)
            if len(words) != instruction_count or any(len(word) != 8 for word in words):
                raise ValueError('loop instruction count/width is incorrect: ' + name)
            report['builds'].append(dict(name=name, command=command, first=first, last=last,
                                        negative=negative, elf_sha256=digest(elf),
                                        binary_sha256=digest(binary)))
            save()
            if args.build_only:
                continue
            for delay, seed in ([(0, args.seeds[0])] if negative else
                                itertools.product(args.delays, args.seeds)):
                log_path = out / f'{name}-delay{delay}-seed{seed}.log'
                command = [str(args.npc), '-b', '-n', '--no-lightsss', '-t', str(args.timeout),
                           f'--mem-random-delay={delay}', f'--mem-random-seed={seed}',
                           '-r', str(args.mrom), str(binary)]
                external_timeout = False
                with log_path.open('w') as log:
                    try:
                        status = subprocess.run(command, cwd=args.runtime_cwd, stdout=log,
                            stderr=subprocess.STDOUT, timeout=args.timeout + 120).returncode
                    except subprocess.TimeoutExpired:
                        status, external_timeout = 124, True
                text = re.sub(r'\x1b\[[0-9;]*m', '', log_path.read_text(errors='replace'))
                passed = classify(status, text, negative, first, last, external_timeout)
                report['runs'].append(dict(name=name, delay=delay, seed=seed, command=command,
                    returncode=status, external_timeout=external_timeout, passed=passed,
                    negative=negative, log=str(log_path), log_sha256=digest(log_path)))
                save()
                print(f'{name} delay={delay} seed={seed}: {passed}', flush=True)
                if not passed:
                    return 1
        report['complete'] = True
        report['execution_verified'] = not args.build_only
        save()
        return 0
    except Exception as error:
        report['error'] = repr(error)
        save()
        raise


if __name__ == '__main__':
    raise SystemExit(main())
