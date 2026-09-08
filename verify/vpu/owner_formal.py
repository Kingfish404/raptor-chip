#!/usr/bin/env python3
"""Prove the owner public-interface contract; record reachable event witnesses.

This is control safety, not an external-memory drain or liveness proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / 'hdl/backend/vpu/rapt_vpu_owner.sv'
HARNESS = ROOT / 'verify/vpu/formal_owner.sv'
EVENTS = ['retirement', 'capture_cancel', 'grant_cancel_race', 'late_kill_blocked',
          'response_stall', 'zero_cycle_result', 'wrong_tag_result', 'duplicate_result',
          'same_tag_reuse', 'issue_stall', 'reset_while_busy']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir', type=Path, default=ROOT/'verify/build/vpu/formal-owner')
    ap.add_argument('--timeout', type=int, default=120)
    args = ap.parse_args()
    out = args.build_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out/'summary.json').unlink(missing_ok=True)
    files = [DUT,HARNESS,Path(__file__),ROOT/'hdl/include/rapt_sva.svh',ROOT/'verify/vpu/Makefile']
    source_hashes = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    records = []

    def run(name, source, params, commands):
        script = ('read_slang --top formal_owner -Ihdl/include '
                  + ' '.join(f'-G{k}={v}' for k, v in params.items())
                  + f' {source} {HARNESS}; '
                  'select -assert-none t:$check t:$assert t:$assume t:$cover; '
                  'prep -top formal_owner; flatten; memory_map; opt; '
                  + commands)
        (out/f'{name}.ys').write_text(script+'\n')
        with (out/f'{name}.log').open('w') as log:
            result = subprocess.run(['yosys','-Q','-T','-m','slang','-s',str(out/f'{name}.ys')],
                                    cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=args.timeout)
        return result.returncode, (out/f'{name}.log').read_text()

    for tag, command, result in [(1,8,8),(3,17,29),(10,164,174),(10,228,270)]:
        params = dict(TagBits=tag,CommandBits=command,ResultBits=result)
        name = f'owner-{tag}-{command}-{result}'
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
        'early_issue': ('assign engine_valid = !reset && state == ISSUE;',
                        'assign engine_valid = !reset && (state == ISSUE || state == PENDING);'),
        'wrong_tag': ('result_tag == tag_q\n', "1'b1\n"),
        'grant_kill': ('authorize_tag == tag_q && !kill_match;', 'authorize_tag == tag_q;'),
        'unstable_response': ('DONE: if (rsp_ready) state <= EMPTY;',
                              'DONE: begin if (result_valid) result_q <= result_payload; if (rsp_ready) state <= EMPTY; end'),
    }
    for name,(old,new) in mutations.items():
        original = DUT.read_text()
        assert original.count(old)==1, name
        mutant = out/f'mutant-{name}.sv'
        mutant.write_text(original.replace(old,new))
        rc,log = run('mutant-'+name,mutant,dict(TagBits=1,CommandBits=8,ResultBits=8),
                     f'sat -seq 12 -set-at 1 reset 1 -prove correct 1 -dump_vcd {out}/mutant-{name}.vcd')
        if rc or 'SAT proof finished - model found: FAIL!' not in log:
            raise RuntimeError(f'mutant {name} not detected: {log[-4000:]}')
        print(f'PASS mutation detected {name}',flush=True)
    if any(hashlib.sha256(p.read_bytes()).hexdigest() != source_hashes[str(p.relative_to(ROOT))] for p in files):
        raise RuntimeError('Formal inputs changed during the run; discard mixed-source results')
    (out/'summary.json').write_text(json.dumps(dict(
        scope='unbounded inductive owner control safety after reset; no fairness, liveness, external drain or full-tag stale-response provenance proof',
        initial_constraint='reset=1 at first sampled edge; all later inputs including reset unconstrained',
        yosys=subprocess.check_output(['yosys','-V'],text=True).strip(),proofs=records,
        mutations_detected=list(mutations),
        sources=source_hashes),indent=2)+'\n')


if __name__ == '__main__':
    main()
