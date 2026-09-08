#!/usr/bin/env python3
"""Check real virtio DMA invalidation of LR/SC; use a private generated disk."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--npc', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mrom', type=Path)
    parser.add_argument('--runtime-cwd', type=Path)
    parser.add_argument('--progress', action='store_true',
                        help='also check constrained LR.W/SC.W after unrelated finite DMA burst')
    parser.add_argument('--compiler', default='riscv64-elf-gcc')
    parser.add_argument('--objcopy', default='riscv64-elf-objcopy')
    parser.add_argument('--delays', type=int, nargs='+', default=[0, 7, 63])
    parser.add_argument('--seeds', type=int, nargs='+', default=[1, 42])
    parser.add_argument('--expect-vulnerable', action='store_true',
                        help='require probe failure code1 plus passing DMA controls; reproduction only')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    npc = args.npc.resolve()
    disk = out / 'disk.bin'
    disk.write_bytes(bytes(range(256)) * 2)
    source = out / 'test.S'
    shutil.copyfile(root / 'app/tests/baremetal/lrsc_virtio_dma.S', source)
    linker = out / 'link.ld'
    shutil.copyfile(root / 'verify/scripts/fuzz_link.ld', linker)
    shutil.copyfile(Path(__file__).resolve(), out / 'runner.py')
    mrom = (args.mrom or root / 'sim/csrc/mem/mrom-data/build/mrom-data.bin').resolve()
    runtime_cwd = (args.runtime_cwd or root / 'sim').resolve()
    images = {}
    commands = []
    for name in (['probe', 'control', 'progress'] if args.progress else ['probe', 'control']):
        elf, binary = out / (name + '.elf'), out / (name + '.bin')
        cmd = [args.compiler, f'-march=rv{args.xlen}imac_zicsr_zifencei_zicbom',
               '-mabi=' + ('lp64' if args.xlen == 64 else 'ilp32'), '-nostdlib',
               '-nostartfiles', '-static', '-Wl,--no-relax', '-T',
               str(linker), str(source), '-o', str(elf)]
        if name == 'control':
            cmd.append('-DDMA_CONTROL_ONLY')
        if name == 'progress':
            cmd.append('-DDMA_PROGRESS_ONLY')
        commands.append(cmd)
        subprocess.run(cmd, check=True)
        subprocess.run([args.objcopy, '-O', 'binary', str(elf), str(binary)], check=True)
        images[name] = binary
    runs = []
    for delay in args.delays:
        for seed in args.seeds:
            for name, binary in images.items():
                cmd = [str(npc), '-b', '-n', '--no-lightsss', '-t', '60',
                       '--disk=' + str(disk), '--mem-random-delay=' + str(delay),
                       '--mem-random-seed=' + str(seed), '-r', str(mrom), str(binary)]
                log = out / f'{name}-delay{delay}-seed{seed}.log'
                with log.open('w') as stream:
                    try:
                        status = subprocess.run(cmd, cwd=runtime_cwd, stdout=stream,
                                                stderr=subprocess.STDOUT, timeout=90).returncode
                    except subprocess.TimeoutExpired:
                        status = 124
                text = re.sub(r'\x1b\[[0-9;]*m', '', log.read_text())
                good = status == 0 and 'HIT GOOD TRAP' in text
                vulnerable = status != 0 and 'HIT BAD TRAP' in text and bool(
                    re.search(r'a0 = 0x0*1\b', text))
                expected = vulnerable if args.expect_vulnerable and name == 'probe' else good
                print(f'{"EXPECTED" if expected else "FAIL"}: {name} XLEN={args.xlen} '
                      f'delay={delay} seed={seed} good={good} vulnerable={vulnerable}', flush=True)
                runs.append(dict(name=name, delay=delay, seed=seed, returncode=status,
                                 good=good, vulnerable=vulnerable, expected=expected,
                                 command=cmd, log=str(log)))
    files = [source, linker, out / 'runner.py', npc, mrom, disk, *images.values()]
    library = runtime_cwd / '../nemu/tools/capstone/repo/libcapstone.so.5'
    if library.is_file():
        files.append(library.resolve())
    summary = dict(scope='real NPC virtio DMA overlap after explicit cache maintenance; '
                         'not full coherence/progress verification', xlen=args.xlen,
                   progress=args.progress, runtime_cwd=str(runtime_cwd),
                   expect_vulnerable=args.expect_vulnerable, compile_commands=commands, runs=runs,
                   inputs={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return int(not all(r['expected'] for r in runs))


if __name__ == '__main__':
    raise SystemExit(main())
