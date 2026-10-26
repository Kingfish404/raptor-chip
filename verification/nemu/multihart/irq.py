#!/usr/bin/env python3
"""Validate CPU interrupt selection, entry, return and WFI in multicore DiffTest."""
import copy
import struct

from lib.harness import Check, parser, wfi_waits
from lib.journal import (ACCESS_KIND, END, INTERRUPT, LOCK, STATE, UNLOCK, check_journal,
                         interrupt_causes, memory_consistent, read_events, synchronous_traps, write_events)

FAULTS = ('cause', 'epc', 'non-interrupt', 'drop', 'duplicate', 'wrong-hart', 'late', 'spurious',
          'v1', 'unknown-version', 'mepc', 'mcause', 'mstatus', 'sepc', 'scause', 'sstatus')
MARKERS = {**{fault: b'interrupt cause or entry PC mismatch' for fault in ('cause', 'epc', 'non-interrupt')},
           **{fault: b'architectural or reservation state mismatch'
              for fault in ('mepc', 'mcause', 'mstatus', 'sepc', 'scause', 'sstatus')}}


def corrupt(source, destination, fault):
    header, events = read_events(source)
    index = next(index for index, event in enumerate(events) if event[0] == INTERRUPT)
    entry = events[index]
    if fault in ('cause', 'epc', 'non-interrupt'):
        cause, pc = struct.unpack('<2Q', entry[3])
        if fault == 'cause':
            cause ^= 8
        elif fault == 'epc':
            pc ^= 4
        else:
            cause = 9
        entry[3] = struct.pack('<2Q', cause, pc)
    elif fault == 'drop':
        del events[index]
    elif fault == 'duplicate':
        events.insert(index, copy.deepcopy(entry))
    elif fault == 'wrong-hart':
        entry[1] ^= 1
    elif fault == 'late':
        events.pop(index)
        target = next(index for index, event in enumerate(events)
                      if event[0] == END and event[1:3] == entry[1:3])
        events.insert(target, entry)
    elif fault == 'spurious':
        target = next(index for index, event in enumerate(events) if event[0] == ACCESS_KIND)
        hart, instruction = events[target][1:3]
        pc, = struct.unpack_from('<Q', next(event[3] for event in events if event[0] == STATE and event[1] == hart))
        xlen, = struct.unpack_from('<Q', header, 16)
        assert events[target - 1][0] == LOCK
        events[target - 1:target - 1] = [[LOCK, hart, instruction, b''],
                                      [INTERRUPT, hart, instruction, struct.pack('<2Q', (1 << (xlen - 1)) | 9, pc)],
                                      [UNLOCK, hart, instruction, b'']]
    elif fault in ('v1', 'unknown-version'):
        struct.pack_into('<Q', header, 8, 1 if fault == 'v1' else 99)
    else:
        slot = 65 + {'mepc': 0x341, 'mcause': 0x342, 'mstatus': 0x300,
                     'sepc': 0x141, 'scause': 0x142, 'sstatus': 0x100}[fault]
        entries = {(event[1], event[2]) for event in events if event[0] == INTERRUPT}
        for event in events:
            if event[0] != END or tuple(event[1:3]) not in entries:
                continue
            for offset in range(32, len(event[3]), 16):
                if struct.unpack_from('<Q', event[3], offset)[0] == slot:
                    event[3][offset + 8] ^= 1
                    break
            else:
                continue
            break
        else:
            raise AssertionError('missing interrupt state delta: ' + fault)
    write_events(destination, header, events)
    consistent = memory_consistent(destination)
    if fault in ('cause', 'drop', 'spurious', 'mepc', 'mcause', 'mstatus', 'sepc', 'scause', 'sstatus'):
        assert consistent, fault
    return consistent


def main():
    check = Check(parser(__doc__).parse_args(), 'irq')
    for xlen in check.args.xlen:
        check.target(xlen)
        overlap = slept = False
        for harts in (1, 2, 4):
            image = check.guest(f'harts{harts}', ['nemu_diff_irq.S'], harts)
            for backend in ('rr', 'threaded'):
                for repeat in range(check.args.repeat if backend == 'threaded' else 1):
                    name = f'harts{harts}-{backend}-{repeat}'
                    options = ['--diff-interrupts', f'--smp={harts}', '--smp-backend=' + backend]
                    journal, output = check.record(name, options, image)
                    waits = wfi_waits(output)
                    slept |= waits > 0
                    memory = check_journal(journal)
                    assert memory['interrupts'] == [10] * harts and memory['version'] == 2
                    overlap |= memory['interleaved_accesses'] > 0
                    _, events = read_events(journal)
                    assert interrupt_causes(events, xlen, harts) == [[9, 1, 5, 1, 9, 5, 9, 1, 5, 1]] * harts
                    traps = synchronous_traps(events)
                    wfi = sum(struct.unpack_from('<Q', payload)[0] == 0x10500073
                              for kind, _, _, payload in events if kind == END)
                    assert traps == 6 * harts and 5 * harts <= wfi <= 6 * harts - 1, (traps, wfi)
                    check.replay(name + '-replay', journal, memory=memory, synchronous_traps=traps, wfi=wfi,
                                 wfi_waits=waits)
                    check.live(name + '-stream', ['-n', *options, '-t', check.dtb, image],
                               expect=lambda ref: ref['interrupts'] == 10 * harts)
                    if harts == 2 and backend == 'threaded' and repeat == 0:
                        source = journal
        check.save('observed-interleaving', overlap)
        check.save('observed-wfi-sleep', slept)
        check.run('requires-journal', [check.binary, '-b', '--diff-interrupts', image], 1,
                  b'--diff-interrupts requires --diff-record or --diff-stream-fd')
        check.run('v1-rejects-irq-workload', [check.binary, '-b', '-n', '--smp=4',
                                              '--diff-record=' + str(check.directory / 'strict.njr'),
                                              '-t', check.dtb, image], 1, b'NEMU_JOURNAL_FAIL')
        check.faults(source, corrupt, FAULTS, MARKERS)
    check.finish('IRQ')


if __name__ == '__main__':
    main()
