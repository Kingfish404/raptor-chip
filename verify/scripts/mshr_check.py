#!/usr/bin/env python3
"""Exercise real core miss replay and prove concurrent cache-to-bus miss ownership.

Requires RAPT_AXI_OBSERVE and RAPT_L1D_MSHRS=2, with difftest disabled.
Architectural results are checked by the bare-metal program, bus ownership
and internal miss overlap by this script. The external slave may serialize AR. This is not a differential ISA regression.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from svpbmt_axi_check import parse_trace


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('npc', 'mrom', 'output'):
        ap.add_argument('--' + name, required=True, type=Path)
    ap.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    elf, binary = out / 'test.elf', out / 'test.bin'
    subprocess.run(['riscv64-elf-gcc', f'-march=rv{args.xlen}imac_zicsr_zifencei',
                    '-mabi=' + ('lp64' if args.xlen == 64 else 'ilp32'),
                    '-nostdlib', '-nostartfiles', '-static', '-Wl,--no-relax',
                    '-T', str(root / 'verify/scripts/fuzz_link.ld'),
                    str(root / 'app/tests/baremetal/mmio_mshr_loads.S'), '-o', str(elf)], check=True)
    subprocess.run(['riscv64-elf-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    report = {'xlen': args.xlen, 'difftest': False,
              'inputs': {str(p.resolve()): sha(p) for p in (args.npc, args.mrom, binary)}, 'runs': []}
    observed_overlap = False
    for delay in (0, 7, 63):
        for seed in (1, 42):
            log = out / f'delay-{delay}-seed-{seed}.log'
            cmd = [str(args.npc.resolve()), '-b', '-n', '--no-lightsss', '-t', '60',
                   f'--mem-random-delay={delay}', f'--mem-random-seed={seed}',
                   '-r', str(args.mrom.resolve()), str(binary)]
            with log.open('w') as f:
                result = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=90)
            text = log.read_text()
            assert result.returncode == 0 and 'HIT GOOD TRAP' in text and '[ERROR]' not in text, str(log)
            reads, _ = parse_trace(text)
            misses = [r for r in reads if 8 <= r['id'] <= 11]
            assert misses and all(r['length'] == 64 // (args.xlen // 8) - 1 and 'done' in r for r in misses), 'missing/incomplete MSHR bursts'
            overlap = any(a['cycle'] < b['cycle'] < a['done'] and a['id'] != b['id']
                          for a in misses for b in misses)
            pending = set()
            max_pending = 0
            for line in text.splitlines():
                f = line.split()
                if len(f) >= 3 and f[0] == 'MSHR_OBS':
                    ident = int(f[2])
                    if f[1] == 'REQ':
                        assert ident not in pending, 'MSHR ID reused before completion'
                        pending.add(ident)
                        max_pending = max(max_pending, len(pending))
                    elif f[1] == 'DONE':
                        assert ident in pending, 'MSHR response without owner'
                        pending.remove(ident)
            assert not pending, 'core test terminated with undrained MSHRs'
            observed_overlap |= max_pending >= 2
            report['runs'].append({'delay': delay, 'seed': seed, 'command': cmd,
                                   'log': str(log), 'sha256': sha(log),
                                   'miss_bursts': len(misses), 'external_axi_overlap': overlap, 'max_mshr_pending': max_pending})
            print(f'PASS: RV{args.xlen} delay={delay} seed={seed} MSHR bursts={len(misses)} pending={max_pending} external_overlap={overlap}', flush=True)
    assert observed_overlap, 'no pair of concurrent cache-to-bus MSHR owners observed'
    (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
