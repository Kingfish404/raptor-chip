#!/usr/bin/env python3
"""Require witnessed wrong-path IO queue residency, cancellation, and no extra AR."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from svpbmt_axi_check import parse_trace


def check(text, symbols):
    reads, writes = parse_trace(text)
    queues, redirects, commits, flushes = [], [], [], []
    for line in text.splitlines():
        if not line.startswith('SPEC_OBS '):
            continue
        _, cycle, event, *fields = line.split()
        cycle = int(cycle)
        vals = [int(f,16) for f in fields]
        if event == 'Q': queues.append((cycle,*vals))
        elif event == 'REDIRECT': redirects.append((cycle,*vals))
        elif event == 'COMMIT': commits.append((cycle,*vals))
        elif event == 'FLUSH': flushes.append(cycle)
        else: raise AssertionError('unknown speculation observation')
    wrong = symbols['wrong_path_load']
    branch = symbols['prediction_branch']
    target = symbols['resolved_path']
    legitimate = symbols['legitimate_load']
    payload = symbols['io_payload']
    pending = [q for q in queues if q[1] == wrong and q[2] == 0x40000000]
    assert pending, 'no witnessed wrong-path IO load (coverage missing)'
    assert any(q[3] != q[5] for q in pending), 'IO load never waited behind an older ROB owner'
    # The predicted loop backedge may allocate several younger iterations
    # while DIV holds up the oldest branch. Track every dynamic owner.
    owners = {(q[3],q[4]) for q in pending}
    recovered = [r for r in redirects if r[1:] == (branch,target)]
    assert len(recovered) == 1, 'target branch did not mispredict exactly once'
    redirect = recovered[0][0]
    assert min(q[0] for q in pending) < redirect, 'queue observation came after resolution'
    later_flush = next((c for c in flushes if c >= redirect), None)
    assert later_flush is not None and max(q[0] for q in pending) <= later_flush, 'wrong-path owner survived recovery'
    assert sum(pc == wrong for _,pc,_ in commits) == 31, 'wrong-path load retired or training incomplete'
    branch_commits = [(c,npc) for c,pc,npc in commits if pc == branch]
    assert len(branch_commits) == 32 and branch_commits[-1][1] == target, 'branch training/outcome mismatch'
    final_load = [c for c,pc,_ in commits if pc == legitimate]
    assert len(final_load) == 1, 'legitimate IO load did not retire once'
    io_reads = [r for r in reads if payload <= r['addr'] < payload+4096]
    io_writes = [w for w in writes if payload <= w['addr'] < payload+4096]
    assert not io_writes and len(io_reads) == 1, 'wrong-path IO side effect or missing legitimate access'
    req = io_reads[0]
    assert req['addr'] == payload and req['cache'] == 0 and req['size'] == 3 and req['length'] == 0, 'IO request attributes'
    assert req.get('done', -1) >= req['cycle'], 'IO request incomplete'
    assert max(later_flush, branch_commits[-1][0]) < req['cycle'] <= req['done'] <= final_load[0], 'IO request escaped recovery/retirement order'
    return dict(wrong_path_queue_observations=len(pending), wrong_path_owners=len(owners), redirect_cycle=redirect,
                flush_cycle=later_flush, io_read_cycle=req['cycle'],
                training_load_commits=31, io_reads=1)


def run_check(checker, names, workload, description):
    ap = argparse.ArgumentParser(description=description)
    for name in ('summary','elf','output'):
        ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--nm',default='riscv64-elf-nm')
    ap.add_argument('--objcopy',default='riscv64-elf-objcopy')
    args=ap.parse_args()
    symbols={}
    for line in subprocess.check_output([args.nm,'-n',str(args.elf)],text=True).splitlines():
        f=line.split()
        if len(f)==3 and f[2] in names:symbols[f[2]]=int(f[0],16)
    assert symbols.keys() == names, 'missing test symbols'
    s=json.loads(args.summary.read_text())
    assert s['name']==workload
    for x in s['inputs'].values():
        assert hashlib.sha256(Path(x['path']).read_bytes()).hexdigest()==x['sha256'], 'input drift'
    with tempfile.TemporaryDirectory(prefix='svpbmt-spec-') as temp:
        p=Path(temp)/'test.bin'
        subprocess.run([args.objcopy,'-O','binary',str(args.elf),str(p)],check=True)
        assert hashlib.sha256(p.read_bytes()).hexdigest()==s['inputs']['image']['sha256'], 'ELF/image mismatch'
    result={'symbols':symbols,'inputs':s['inputs'],'runs':[]}
    for r in s['runs']:
        assert r['passed'] and r['returncode']==0
        log=Path(r['log']);text=log.read_text()
        assert 'HIT GOOD TRAP' in text and '[ERROR]' not in text
        evidence=checker(text,symbols)
        result['runs'].append(dict(delay=r['delay'],seed=r['seed'],log=str(log),
                                  sha256=hashlib.sha256(log.read_bytes()).hexdigest(),**evidence))
    assert result['runs'], 'empty coverage'
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(f"PASS: {len(result['runs'])} witnessed {workload} cancellations")


def main():
    run_check(check, {'wrong_path_load','prediction_branch','resolved_path',
                      'legitimate_load','io_payload'}, 'svpbmt-wrong-path', __doc__)


if __name__=='__main__':main()
