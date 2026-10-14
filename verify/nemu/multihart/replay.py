#!/usr/bin/env python3
"""Validate suboperation-scheduled ISA replay against real threaded NEMU journals."""
import copy
import re
import struct

from lib.harness import Check, parser
from lib.journal import (ACCESS, ACCESS_KIND, BEGIN, END, HEADER, LOCK, MEMORY, STATE, UNLOCK, check_journal,
                         memory_consistent, read_events, synchronous_traps, write_events)

STATE_MISMATCH = b'architectural or reservation state mismatch'
FAULTS = ('gpr', 'fpr', 'csr', 'privilege', 'reservation', 'missing-delta', 'instruction', 'trap', 'load', 'address',
          'width', 'direction', 'store', 'consistent-store', 'drop-access', 'duplicate-access', 'wrong-hart',
          'missing-unlock', 'duplicate-state', 'rr-overlap', 'bad-version', 'bad-geometry', 'bad-delta',
          'truncated', 'trailing', 'sequence', 'oversized')
MARKERS = {'store': b'store value mismatch before reference write',
           'consistent-store': b'store value mismatch before reference write',
           'load': b'independent reference load value mismatch',
           'rr-overlap': b'overlapping cooperative instructions',
           **{fault: STATE_MISMATCH for fault in ('gpr', 'fpr', 'csr', 'privilege', 'reservation', 'missing-delta')}}


def mutate_journal(source, destination, fault):
    header, events = read_events(source)
    access_index = next(index for index, event in enumerate(events) if event[0] == ACCESS_KIND)
    end_index = next(index for index, event in enumerate(events) if event[0] == END)
    consistent = False
    state_slots = {'gpr': 6, 'fpr': 33, 'csr': 65 + 0x340, 'privilege': 4163, 'reservation': 4161}
    if fault in state_slots or fault == 'missing-delta':
        event = events[end_index]
        fields = list(struct.unpack('<' + 'Q' * (len(event[3]) // 8), event[3]))
        delta = dict(zip(fields[4::2], fields[5::2]))
        if fault == 'missing-delta':
            slot = next(slot for slot in delta if 65 <= slot < 4161)
            del delta[slot]
        else:
            slot = state_slots[fault]
            initial = next(item[3] for item in events if item[0] == STATE and item[1] == event[1])
            value = delta.get(slot, struct.unpack_from('<Q', initial, slot * 8)[0])
            delta[slot] = value ^ 1
        fields = fields[:4] + [item for pair in sorted(delta.items()) for item in pair]
        event[3] = bytearray(struct.pack('<' + 'Q' * len(fields), *fields))
        consistent = True
    elif fault in ('instruction', 'trap'):
        offset = 0 if fault == 'instruction' else 8
        events[end_index][3][offset] ^= 1
        consistent = True
    elif fault == 'bad-delta':
        struct.pack_into('<Q', events[end_index][3], 32, 999999)
    elif fault in ('load', 'address', 'width', 'direction', 'store', 'consistent-store'):
        index = access_index
        if fault in ('store', 'consistent-store'):
            index = next(index for index, event in enumerate(events)
                         if event[0] == ACCESS_KIND and ACCESS.unpack(event[3])[3])
        address, value, width, write = ACCESS.unpack(events[index][3])
        if fault == 'address':
            address ^= 8
        elif fault == 'width':
            width = 2 if width != 2 else 4
            value &= (1 << (width * 8)) - 1
        elif fault == 'direction':
            write ^= 1
        else:
            value ^= 1
        events[index][3] = bytearray(ACCESS.pack(address, value, width, write))
        if fault == 'consistent-store':
            memory = {}
            for event in events:
                if event[0] == MEMORY:
                    address, = struct.unpack_from('<Q', event[3])
                    memory.update((address + offset, byte) for offset, byte in enumerate(event[3][8:]))
                elif event[0] == ACCESS_KIND:
                    address, value, width, write = ACCESS.unpack(event[3])
                    if write:
                        memory.update((address + offset, byte)
                                      for offset, byte in enumerate(value.to_bytes(width, 'little')))
                    else:
                        value = sum(memory.get(address + offset, 0) << (offset * 8) for offset in range(width))
                        event[3] = bytearray(ACCESS.pack(address, value, width, write))
            consistent = True
    elif fault == 'drop-access':
        del events[access_index]
        consistent = True
    elif fault == 'duplicate-access':
        events.insert(access_index, copy.deepcopy(events[access_index]))
    elif fault == 'wrong-hart':
        events[access_index][1] ^= 1
    elif fault == 'missing-unlock':
        del events[next(index for index, event in enumerate(events) if event[0] == UNLOCK)]
    elif fault == 'duplicate-state':
        index = next(index for index, event in enumerate(events) if event[0] == STATE)
        events.insert(index, copy.deepcopy(events[index]))
    elif fault == 'rr-overlap':
        struct.pack_into('<Q', header, 56, 0)
        events = [event for event in events if event[0] not in (LOCK, UNLOCK)]
        first = next(index for index, event in enumerate(events) if event[0] == BEGIN)
        second = next(index for index, event in enumerate(events)
                      if event[0] == BEGIN and event[1] != events[first][1])
        events.insert(first + 1, events.pop(second))
    elif fault == 'bad-version':
        struct.pack_into('<Q', header, 8, 99)
    elif fault == 'bad-geometry':
        struct.pack_into('<Q', header, 40, 4096)
    elif fault not in ('truncated', 'trailing', 'sequence', 'oversized'):
        raise ValueError(fault)
    write_events(destination, header, events)
    if fault in ('truncated', 'trailing', 'sequence', 'oversized'):
        data = bytearray(destination.read_bytes())
        if fault == 'truncated':
            del data[-1:]
        elif fault == 'trailing':
            data.append(1)
        elif fault == 'sequence':
            struct.pack_into('<Q', data, HEADER.size + 8, 1)
        else:
            struct.pack_into('<Q', data, HEADER.size + 32, 1 << 63)
        destination.write_bytes(data)
    accepted = memory_consistent(destination)
    if consistent and not accepted:
        raise AssertionError(f'{fault}: expected a memory-consistent corruption')
    return accepted


def main():
    check = Check(parser(__doc__).parse_args(), 'replay')
    for xlen in check.args.xlen:
        check.target(xlen)
        overlap = False
        for harts in (1, 2, 4):
            image = check.guest(f'harts{harts}', ['nemu_multidiff.S'], harts)
            for backend in ('rr', 'threaded'):
                for repeat in range(check.args.repeat if backend == 'threaded' else 1):
                    name = f'harts{harts}-{backend}-{repeat}'
                    journal, _ = check.record(name, [f'--smp={harts}', '--smp-backend=' + backend], image)
                    memory = check_journal(journal)
                    overlap |= memory['interleaved_accesses'] > 0
                    output = check.replay(name + '-replay', journal, memory=memory)
                    checked = re.search(rb'NEMU_REPLAY checked=(\d+)', output)
                    if not checked or int(checked[1]) != sum(memory['instructions']):
                        raise SystemExit('reference did not check every recorded instruction')
                    if harts == 2 and backend == 'threaded' and repeat == 0:
                        check.faults(journal, mutate_journal, FAULTS, MARKERS, live=False)
        for harts in (2, 4):
            image = check.guest(f'harts{harts}-faults', ['nemu_multidiff.S'], harts, ['-DREPLAY_FAULTS'])
            for backend in ('rr', 'threaded'):
                name = f'harts{harts}-faults-{backend}'
                journal, _ = check.record(name, [f'--smp={harts}', '--smp-backend=' + backend], image)
                memory = check_journal(journal)
                traps = synchronous_traps(read_events(journal)[1])
                if traps != harts * 4:
                    raise SystemExit('missing ecall/store/AMO/load exceptions')
                check.replay(name + '-replay', journal, memory=memory, traps=traps)
        if not overlap:
            raise SystemExit(f'RV{xlen}: no actual cross-hart memory interleaving observed')
    check.finish('REPLAY')


if __name__ == '__main__':
    main()
