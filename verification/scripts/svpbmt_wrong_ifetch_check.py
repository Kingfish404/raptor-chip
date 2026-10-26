#!/usr/bin/env python3
"""Require a mispredicted IO instruction fetch to wait for authorization and cancel."""
from svpbmt_axi_check import parse_trace
from svpbmt_wrong_path_check import run_check


def check(text, symbols):
    reads, writes = parse_trace(text)
    states, starts, commits, redirects, flushes = [], [], [], [], []
    for line in text.splitlines():
        f = line.split()
        if len(f) < 3:
            continue
        if f[0] not in ('IFETCH_OBS', 'SPEC_OBS'):
            continue
        cycle = int(f[1])
        vals = [int(x,16) for x in f[3:]]
        if f[0] == 'IFETCH_OBS':
            if f[2] == 'STATE': states.append((cycle,*vals))
            elif f[2] == 'START': starts.append((cycle,*vals))
            else: raise AssertionError('unknown IFETCH observation')
        elif f[2] == 'COMMIT': commits.append((cycle,*vals))
        elif f[2] == 'REDIRECT': redirects.append((cycle,*vals))
        elif f[2] == 'FLUSH': flushes.append(cycle)
    io_va = 0x40000000
    physical = symbols['io_code']
    jump = symbols['prediction_jump']
    target = symbols['resolved_path']
    io_commits = [c for c,pc,_ in commits if io_va <= pc < io_va+4096]
    assert len(io_commits) == 31, 'wrong IO instruction retired or training incomplete'
    jumps = [(c,npc) for c,pc,npc in commits if pc == jump]
    assert len(jumps) == 32 and [npc for _,npc in jumps] == [io_va]*31+[target], 'indirect jump training/outcomes'
    recoveries = [c for c,pc,npc in redirects if pc == jump and npc == target]
    assert len(recoveries) == 1, 'final indirect jump did not mispredict'
    redirect = recoveries[0]
    # STATE fields are owner PC, word-fetch FSM, PBMT, authorized, kill,
    # io_owned. DATA_REQ=3 in the production rapt_ifetch_word FSM.
    waits = [x for x in states if io_commits[-1] < x[0] < redirect
             and x[1:] == (io_va,3,2,0,0,0)]
    assert waits, 'no witnessed IO DATA_REQ waiting for authorization'
    flush = next((c for c in flushes if c >= redirect), None)
    assert flush is not None, 'missing final recovery flush'
    killed = [x for x in states if redirect <= x[0] <= flush+1
              and x[1:] == (io_va,3,2,0,1,0)]
    assert killed, 'wrong IO DATA_REQ was not observed cancelled by final recovery'
    assert not any(x[0] > flush+1 and x[1] == io_va and x[2] == 3 for x in states), 'wrong fetch remained pending after flush'
    io_starts = [(c,pc) for c,pc in starts if io_va <= pc < io_va+4096]
    assert len(io_starts) == 31 and all(pc == io_va and c < io_commits[-1] for c,pc in io_starts), 'wrong IO fetch received authorization'
    requests = [r for r in reads if physical <= r['addr'] < physical+4096]
    assert len(requests) == 31, 'extra or missing external IO fetch'
    assert not any(physical <= w['addr'] < physical+4096 for w in writes), 'write to IO code'
    for r, (start,_), commit in zip(requests, io_starts, io_commits):
        assert r['addr'] == physical and r['size'] == 2 and r['length'] == 0 and r['cache'] == 0, 'IO fetch address/width/cache'
        assert start <= r['cycle'] <= r.get('done',-1) <= commit, 'IO fetch start/response/retirement order'
    assert all(r['cycle'] < waits[0][0] for r in requests), 'cancelled IO fetch reached external AXI'
    return dict(training_fetches=31, wait_cycles=len(waits), first_wait=waits[0][0],
                redirect_cycle=redirect, cancel_cycle=killed[0][0], flush_cycle=flush)


def main():
    run_check(check, {'io_code','prediction_jump','resolved_path'},
              'svpbmt-wrong-ifetch', __doc__)


if __name__ == '__main__': main()
