#!/usr/bin/env python3
"""Correlate NPC LRSC_EVT observations; finite execution evidence only."""
import argparse
from collections import defaultdict
import json
from pathlib import Path


def check_trace(text, expected_success, reservation_address=None):
    if not __debug__:
        raise RuntimeError('trace checks require Python assertions; do not use -O')
    cycles = defaultdict(list)
    previous_cycle = -1
    for line in text.splitlines():
        if line.startswith('LRSC_EVT '):
            fields = line.split()
            cycle = int(fields[1])
            if cycle < previous_cycle:
                raise ValueError('trace cycles regress; resets/concatenated runs are unsupported')
            previous_cycle = cycle
            cycles[cycle].append(fields[2:])
    if not cycles:
        raise ValueError('no LRSC_EVT observations')
    pending, sq = {}, {}
    counts = dict(accepted_sc=0, retired_success=0, retired_failure=0,
                  canceled_sc=0, drained_sc=0, retired_lr=0,
                  external_events=0, pending_lr_cycles=0,
                  unrelated_pending_lr_cycles=0)

    def bits(mask):
        return [i for i in range(mask.bit_length()) if mask & (1 << i)]

    for cycle in sorted(cycles):
        rows = cycles[cycle]
        flush = any(r[0] == 'F' and int(r[1]) for r in rows)
        queue_rows = [r for r in rows if r[0] == 'Q']
        assert len(queue_rows) <= 1, ('duplicate SQ sample', cycle)
        for r in rows:
            if r[0] == 'E':
                valid, blocked = int(r[1]), int(r[2])
                counts['external_events'] += valid
                if blocked and int(r[5]) and int(r[6]):
                    counts['pending_lr_cycles'] += 1
                    if reservation_address is not None and valid:
                        first, last = int(r[3], 16), int(r[4], 16)
                        if last < reservation_address or first > reservation_address + 3:
                            counts['unrelated_pending_lr_cycles'] += 1
            elif r[0] == 'A' and int(r[4]) == 1 and int(r[5]) and int(r[6]):
                key = (int(r[1], 16), int(r[2]), int(r[3]))
                assert key not in pending, ('duplicate accepted SC identity', cycle, key)
                assert not int(r[9]) and int(r[10]), ('accepted SC blocked/not clearing', cycle)
                pending[key] = dict(result=int(r[7], 16), retired=False, cycle=cycle)
                counts['accepted_sc'] += 1
        for r in queue_rows:
            alloc = int(r[1], 16)
            assert alloc.bit_count() <= 1
            key = (int(r[5], 16), int(r[6]), int(r[7]))
            for slot in bits(alloc):
                assert slot not in sq, ('reuse of occupied SQ slot', cycle, slot)
                sc = pending.get(key)
                if sc is not None:
                    assert sc['cycle'] == cycle and sc['result'] == 0
                sq[slot] = dict(committed=False, sc=sc, key=key)
        for r in rows:
            if r[0] != 'R':
                continue
            instruction = int(r[2], 16)
            assert flush, ('atomic retirement missing flush observation', cycle)
            if instruction & 0x7f != 0x2f:
                raise ValueError('atomic retirement has unexpected opcode')
            operation = instruction >> 27
            if operation == 2:
                counts['retired_lr'] += 1
            if operation != 3:
                continue
            assert not int(r[5]), ('trapping SC outside this checker scope', cycle)
            key = (int(r[1], 16), int(r[3]), int(r[4]))
            sc = pending.pop(key)
            success = sc['result'] == 0
            assert bool(int(r[6])) == success, ('SC result/store retirement mismatch', cycle)
            sc['retired'] = True
            counts['retired_success' if success else 'retired_failure'] += 1
        for r in queue_rows:
            for slot in bits(int(r[2], 16)):
                lease = sq[slot]
                assert not lease['committed'], ('SQ committed twice', cycle, slot)
                if lease['sc'] is not None:
                    assert lease['sc']['retired'], ('SC SQ commit without retirement', cycle)
                lease['committed'] = True
            for slot in bits(int(r[3], 16)):
                lease = sq.pop(slot)
                assert lease['committed'], ('SQ drained speculative entry', cycle, slot)
                counts['drained_sc'] += lease['sc'] is not None
            for slot in bits(int(r[4], 16)):
                lease = sq.pop(slot)
                assert not lease['committed'], ('flush discarded committed store', cycle)
        if flush:
            counts['canceled_sc'] += len(pending)
            pending.clear()
    assert counts['retired_success'] == expected_success, counts
    assert counts['drained_sc'] == expected_success, counts
    assert not pending, ('trace ended with unresolved accepted SC', pending)
    assert not any(lease['sc'] is not None for lease in sq.values()), 'undrained SC at trace end'
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--expected-success', required=True, type=int)
    parser.add_argument('--reservation-address', type=lambda s: int(s, 0))
    args = parser.parse_args()
    print(json.dumps(check_trace(args.log.read_text(), args.expected_success,
                                 args.reservation_address), indent=2))


if __name__ == '__main__':
    main()
