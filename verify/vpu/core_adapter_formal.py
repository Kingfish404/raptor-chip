#!/usr/bin/env python3
"""Prove the core adapter public-interface contract; record reachable event witnesses.

This is control safety, not an external-memory drain or liveness proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / 'hdl/backend/vpu/rapt_vpu_core_adapter.sv'
HARNESS = ROOT / 'verify/vpu/formal_core_adapter.sv'
EVENTS = ['retirement','capture_cancel','grant_cancel_race','late_kill_blocked',
          'response_stall','early_response','wrong_response','unsafe_head',
          'wrong_generation_head','same_tag_reuse','reset_while_busy']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir', type=Path, default=ROOT/'verify/build/vpu/formal-core-adapter')
    ap.add_argument('--timeout', type=int, default=120)
    args = ap.parse_args()
    out = args.build_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out/'summary.json').unlink(missing_ok=True)
    files = [DUT,HARNESS,Path(__file__),ROOT/'hdl/include/rapt_sva.svh',ROOT/'verify/vpu/Makefile']
    source_hashes = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    records = []

    def run(name, source, params, commands):
        script = ('read_slang --top formal_core_adapter -Ihdl/include '
                  + ' '.join(f'-G{k}={v}' for k, v in params.items())
                  + f' {source} {HARNESS}; '
                  'select -assert-none t:$check t:$assert t:$assume t:$cover; '
                  'prep -top formal_core_adapter; flatten; memory_map; opt; '
                  + commands)
        (out/f'{name}.ys').write_text(script+'\n')
        with (out/f'{name}.log').open('w') as log:
            result = subprocess.run(['yosys','-Q','-T','-m','slang','-s',str(out/f'{name}.ys')],
                                    cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=args.timeout)
        return result.returncode, (out/f'{name}.log').read_text()

    for rob, generation, command, result, metadata in [(1,1,8,8,8),(3,1,17,29,37),(6,4,164,174,64),(6,4,228,270,64)]:
        params = dict(RobBits=rob,GenerationBits=generation,CommandBits=command,ResultBits=result,MetadataBits=metadata)
        name = f'adapter-{rob}-{generation}-{command}-{result}-{metadata}'
        rc, log = run(name, DUT, params,
            'sat -verify -tempinduct -seq 2 -maxsteps 12 -set-at 1 reset 1 -prove correct 1')
        if rc or 'Induction step proven: SUCCESS!' not in log:
            raise RuntimeError(f'{name} failed: {log[-4000:]}')
        print(f'PASS induction {name}',flush=True)
        commands = []
        for i,event in enumerate(EVENTS):
            commands.append(f'sat -seq 12 -set-at 1 reset 1 -set-at 12 witnessed[{i}] 1 '
                            f'-show-inputs -show-outputs -dump_vcd {out/name}-{event}.vcd')
        rc, log = run(name+'-covers',DUT,params,'; '.join(commands))
        if rc or log.count('SAT solving finished - model found:') != len(EVENTS):
            raise RuntimeError(f'{name} unreachable cover: {log[-4000:]}')
        records.append(dict(parameters=params,inductive_safety=True,witnesses=EVENTS,cover_depth=12))
        print(f'PASS witnesses {name}: {len(EVENTS)}',flush=True)

    mutations = {
        'ignore_head_generation': ('{head_generation,head_slot} == tag_q', 'head_slot == tag_q[RobBits-1:0]'),
        'ignore_head_safe': ('&& head_valid && head_safe &&', '&& head_valid &&'),
        'accept_early_response': ('live_q && authorized_q && vpu_rsp_tag == tag_q', 'live_q && vpu_rsp_tag == tag_q'),
        'release_wrong_response': ('(rsp_valid && rsp_ready)', '(vpu_rsp_valid && vpu_rsp_ready)'),
        'overwrite_metadata': ('if (grant_fire) authorized_q <= 1;', 'metadata_q <= cmd_metadata; if (grant_fire) authorized_q <= 1;'),
        'kill_after_authorization': ('live_q && !authorized_q && kill_match', 'live_q && kill_match'),
    }
    for name,(old,new) in mutations.items():
        original = DUT.read_text()
        assert original.count(old)==1, name
        mutant = out/f'mutant-{name}.sv'
        mutant.write_text(original.replace(old,new))
        rc,log = run('mutant-'+name,mutant,dict(RobBits=1,GenerationBits=1,CommandBits=8,ResultBits=8,MetadataBits=8),
                     f'sat -seq 12 -set-at 1 reset 1 -prove correct 1 -dump_vcd {out}/mutant-{name}.vcd')
        if rc or 'SAT proof finished - model found: FAIL!' not in log:
            raise RuntimeError(f'mutant {name} not detected: {log[-4000:]}')
        print(f'PASS mutation detected {name}',flush=True)
    if any(hashlib.sha256(p.read_bytes()).hexdigest() != source_hashes[str(p.relative_to(ROOT))] for p in files):
        raise RuntimeError('Formal inputs changed during the run; discard mixed-source results')
    (out/'summary.json').write_text(json.dumps(dict(
        scope='unbounded inductive core adapter control safety after reset; no fairness, liveness, external drain or full-tag stale-response provenance proof',
        initial_constraint='reset=1 at first sampled edge; all later inputs including reset unconstrained',
        yosys=subprocess.check_output(['yosys','-V'],text=True).strip(),proofs=records,
        mutations_detected=list(mutations),
        sources=source_hashes),indent=2)+'\n')


if __name__ == '__main__':
    main()
