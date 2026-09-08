#!/usr/bin/env python3
"""Directed breakpoint retirement selfchecks, independent of NEMU/ACT4.

The expected-failure controls must reach the finisher failure or halt early;
compile errors and timeouts never count as detection.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    p.add_argument('--npc', type=Path, required=True)
    p.add_argument('--mrom', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--gcc', default='riscv64-elf-gcc')
    p.add_argument('--objcopy', default='riscv64-elf-objcopy')
    a = p.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = root / 'app/tests/baremetal/compressed_breakpoint.S'
    linker = root / 'verify/scripts/fuzz_link.ld'
    manifest = {'scope': 'directed architectural selfchecks, no reference model',
                'xlen': a.xlen, 'inputs': {}, 'builds': [], 'runs': []}
    for path in (source, linker, Path(__file__), a.npc, a.mrom):
        manifest['inputs'][str(path.resolve())] = sha(path)

    def save():
        (out / 'results.json').write_text(json.dumps(manifest, indent=2) + '\n')

    for priv, delegate in ((3, 0), (1, 0), (0, 0), (1, 1), (0, 1)):
        for wrong in ((False, True) if priv == 3 else (False,)):
            name = f'p{priv}-d{delegate}' + ('-wrong-cause' if wrong else '')
            elf, binary = out / (name + '.elf'), out / (name + '.bin')
            cmd = [a.gcc, f'-march=rv{a.xlen}imac_zicsr_zifencei',
                   '-mabi=' + ('lp64' if a.xlen == 64 else 'ilp32'),
                   '-nostdlib', '-nostartfiles', '-static', '-Wl,--no-relax',
                   '-T', str(linker), f'-DBREAK_PRIV={priv}',
                   f'-DBREAK_DELEGATE={delegate}', f'-DBREAK_CAUSE={2 if wrong else 3}',
                   str(source), '-o', str(elf)]
            subprocess.run(cmd, check=True, capture_output=True)
            copy = [a.objcopy, '-O', 'binary', str(elf), str(binary)]
            subprocess.run(copy, check=True, capture_output=True)
            manifest['builds'].append({'command': cmd, 'objcopy': copy,
                                       'elf_sha256': sha(elf), 'bin_sha256': sha(binary)})
            timings = [(0, 1)] if wrong else [(d, s) for d in (0, 7, 63) for s in (1, 42)]
            for delay, seed in timings:
                cmd = [str(a.npc.resolve()), '-b', '-n', '--trap-on-ebreak',
                       f'--mem-random-delay={delay}', f'--mem-random-seed={seed}',
                       '-r', str(a.mrom.resolve()), str(binary)]
                run = subprocess.run(cmd, cwd=root / 'sim', text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
                log = out / f'{name}-delay{delay}-seed{seed}.log'
                log.write_text(run.stdout)
                good = run.returncode == 0 and 'Finisher: poweroff (0x5555)' in run.stdout
                detected = run.returncode != 0 and 'Finisher: fail (0x3333)' in run.stdout
                ok = detected if wrong else good
                manifest['runs'].append({'command': cmd, 'exit': run.returncode,
                    'expected_failure': wrong, 'passed': ok, 'log': str(log), 'log_sha256': sha(log)})
                save()
                print(f'{"PASS" if ok else "FAIL"} {name} delay={delay} seed={seed}', flush=True)
                if not ok:
                    return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
