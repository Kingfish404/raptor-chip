#!/usr/bin/env python3
"""Compare full-core commit timing for identical code with different seed data.

Requires an NPC binary built with RAPT_SPEC_OBSERVE and a differential reference.
This is a finite regression, not a proof of complete Zkt compliance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def commits(text, start, end):
    rows = [(int(c), int(pc, 16), int(npc, 16)) for c, pc, npc in
            re.findall(r'^SPEC_OBS (\d+) COMMIT ([0-9a-fA-F]+) ([0-9a-fA-F]+)$', text, re.M)]
    selected = [row for row in rows if start <= row[1] < end]
    if not selected or selected[0][1] != start:
        raise ValueError('missing measured commit sequence')
    # Compare absolute boot-relative cycles too: normalization must not hide
    # a data-dependent delay before the first measured instruction.
    return selected


def validate_trace(trace, expected, baseline=None):
    if [pc for cycle, pc, npc in trace] != expected:
        raise ValueError('missing, reordered or duplicated measured commit')
    if baseline is not None and trace != baseline:
        first = next((a, b) for a, b in zip(baseline, trace) if a != b)
        raise ValueError(f'data-dependent commit timing: {first}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--xlen', type=int, choices=[32, 64], required=True)
    ap.add_argument('--npc', type=Path, required=True)
    ap.add_argument('--reference', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--delays', type=int, nargs='+', default=[0, 7, 63])
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    subprocess.run(['python3', str(root/'verify/scripts/zkt_decode_vectors.py'), '--xlen', str(args.xlen), '--output', str(out/'vectors')], check=True)
    vectors = json.loads((out/'vectors/manifest.json').read_text())['rows']
    load = 'ld' if args.xlen == 64 else 'lw'
    asm = ['.section .text', '.globl _start', '.option norelax', '.option norvc', '_start:',
           'la t0, seed_data', f'{load} s4, 0(t0)']
    for reg in range(8, 16):
        asm += [f'xori x{reg}, s4, {reg}']
    asm += ['timing_start:']
    # Keep each input stream dependent on prior arithmetic and seed data.
    # No data-dependent addresses or branches occur inside this interval.
    for repeat in range(8):
        for row in vectors:
            asm += ['.option rvc' if row['compressed'] else '.option norvc', row['asm'], '.option norvc', 'xor x9, x8, s4', 'xor x14, x15, s4']
    asm += ['timing_end:', 'li a0, 0', 'ebreak', '.section .data', '.balign 8', 'seed_data:', '.dword 0']
    (out/'test.S').write_text('\n'.join(asm)+'\n')
    command = ['riscv64-elf-gcc',f'-march=rv{args.xlen}imac_zicsr_zifencei_zbb_zbc',f'-mabi={"lp64" if args.xlen==64 else "ilp32"}', '-nostdlib', '-nostartfiles','-static','-Wl,--no-relax','-T',str(root/'verify/scripts/fuzz_link.ld'), str(out/'test.S'),'-o',str(out/'test.elf')]
    subprocess.run(command,check=True)
    subprocess.run(['riscv64-elf-objcopy','-O','binary',str(out/'test.elf'),str(out/'test.bin')],check=True)
    symbols = {n:int(a,16) for a,k,n in (line.split() for line in subprocess.check_output(['riscv64-elf-nm','--defined-only',str(out/'test.elf')],text=True).splitlines())}
    start,end,offset = symbols['timing_start'],symbols['timing_end'],symbols['seed_data']-symbols['_start']
    base = (out/'test.bin').read_bytes()
    dis = subprocess.check_output(['riscv64-elf-objdump','-d','-M','no-aliases',str(out/'test.elf')],text=True)
    (out/'disassembly.txt').write_text(dis)
    expected = [int(a,16) for a in re.findall(r'^\s*([0-9a-f]+):\s+[0-9a-f]+\s+',dis,re.M) if start <= int(a,16) < end]
    assert len(expected) == len(vectors)*8*3
    patterns = [0, (1<<args.xlen)-1, 0xaaaaaaaaaaaaaaaa & ((1<<args.xlen)-1), 0x8123456789abcdef & ((1<<args.xlen)-1)]
    results = []
    for delay in args.delays:
        baseline = None
        for i, value in enumerate(patterns):
            image = out/f'data-{i}.bin'; data=bytearray(base); data[offset:offset+8]=value.to_bytes(8,'little'); image.write_bytes(data)
            assert image.read_bytes()[:offset]==base[:offset] and image.read_bytes()[offset+8:]==base[offset+8:]
            log = out/f'delay-{delay}-data-{i}.log'
            cmd = [str(args.npc.resolve()),'-b','-n','--no-lightsss','-t','180',f'--mem-random-delay={delay}','--mem-random-seed=42','-d',str(args.reference.resolve()),'-r',str(root/'sim/csrc/mem/mrom-data/build/mrom-data.bin'),str(image)]
            with log.open('w') as f:
                rc=subprocess.run(cmd,cwd=root/'sim',stdout=f,stderr=subprocess.STDOUT,timeout=210).returncode
            text=log.read_text()
            assert rc==0 and 'HIT GOOD TRAP' in text and not any(s in text for s in ['HIT BAD TRAP','[ERROR]','mismatch','Assertion failed','Wall-clock timeout']), str(log)
            trace=commits(text,start,end)
            validate_trace(trace, expected, baseline)
            if baseline is None:baseline=trace
            results.append({'delay':delay,'pattern':value,'command':cmd,'log':str(log),'image_sha256':digest(image),'commits':len(trace),'first_cycle':trace[0][0],'last_cycle':trace[-1][0]})
            print(f'PASS RV{args.xlen} delay={delay} data={i}: {len(trace)} identical commit positions/times',flush=True)
    result={'scope':'finite whole-core same-code/different-data timing regression with NEMU result comparison; not full Zkt proof','xlen':args.xlen,'compiler_command':command,'text_sha256':hashlib.sha256(base[:offset]).hexdigest(),'seed_offset':offset,'measurement':[start,end],'npc':{'path':str(args.npc.resolve()),'sha256':digest(args.npc)},'reference':{'path':str(args.reference.resolve()),'sha256':digest(args.reference)},'runs':results}
    (out/'summary.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':
    main()
