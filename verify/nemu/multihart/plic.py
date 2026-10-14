#!/usr/bin/env python3
"""Validate independent multicore PLIC MMIO and external source replay."""
import copy
import struct

from lib.harness import Check, parser, wfi_waits
from lib.journal import (ACCESS, ACCESS_KIND, BEGIN, CLOCK, END, INTERRUPT, IO_REQUEST, PLIC_BASE,
                         PLIC_SOURCE, STATE, check_journal, interrupt_causes, memory_consistent,
                         read_events, synchronous_traps, write_events)

FAULTS = ('consistent-store', 'consistent-target', 'width', 'claim-value', 'request-data',
          'drop-request', 'duplicate-request', 'unexpected-clock', 'source-zero', 'source-range',
          'source-context', 'source-wrong', 'drop-source', 'late-source', 'state-meip', 'state-seip',
          'irq-cause', 'downgrade')
MARKERS = {'consistent-store': b'store value mismatch before reference write',
           'consistent-target': b'memory address/width/direction mismatch before access',
           'claim-value': b'independent reference load value mismatch'}
BAD_INPUTS = ('', '-1 1\n', '1 0\n', '1 33\n', '1 1 extra\n', '2 1\n1 2\n', '18446744073709551616 1\n', '0 1\n' * 4097)


def corrupt(source, destination, fault):
    header, events = read_events(source)
    request = next(index for index, event in enumerate(events)
                   if event[0] == IO_REQUEST and ACCESS.unpack(event[3]) == (PLIC_BASE, 0, 4, 1))
    pulse = next(index for index, event in enumerate(events) if event[0] == PLIC_SOURCE)
    assert events[request + 1][0] == ACCESS_KIND
    if fault in ('consistent-store', 'consistent-target', 'width'):
        address, value, width, write = ACCESS.unpack(events[request][3])
        if fault == 'consistent-store':
            value = 1
        elif fault == 'consistent-target':
            address += 16
        else:
            width = 2
        for index in (request, request + 1):
            events[index][3] = ACCESS.pack(address, value, width, write)
    elif fault in ('claim-value', 'request-data'):
        index = next(index for index, event in enumerate(events)
                     if event[0] == IO_REQUEST and ACCESS.unpack(event[3]) == (PLIC_BASE + 0x200004, 0, 4, 0))
        if fault == 'claim-value':
            index += 1
        address, value, width, write = ACCESS.unpack(events[index][3])
        events[index][3] = ACCESS.pack(address, value ^ 1, width, write)
    elif fault in ('drop-request', 'duplicate-request', 'unexpected-clock'):
        if fault == 'drop-request':
            del events[request]
        elif fault == 'duplicate-request':
            events.insert(request, copy.deepcopy(events[request]))
        else:
            events.insert(request + 1, [CLOCK, events[request][1], events[request][2], struct.pack('<3Q', 0, 1, 1)])
    elif fault in ('source-zero', 'source-range', 'source-context', 'source-wrong'):
        source_id, executing = struct.unpack('<2Q', events[pulse][3])
        if fault == 'source-context':
            executing ^= 1
        else:
            source_id = {'source-zero': 0, 'source-range': 33, 'source-wrong': 9}[fault]
        events[pulse][3] = struct.pack('<2Q', source_id, executing)
    elif fault == 'drop-source':
        index = next(index for index, event in enumerate(events)
                     if event[0] == PLIC_SOURCE and struct.unpack('<2Q', event[3])[0] == 31)
        del events[index]
    elif fault == 'late-source':
        event = events.pop(pulse)
        index = next(index for index, item in enumerate(events) if item[0] == BEGIN)
        event[1:3] = events[index][1:3]
        events.insert(index + 1, event)
    elif fault.startswith('state-'):
        slot = 65 + 0x344 if fault == 'state-meip' else 4164
        event = next(event for event in events if event[0] == END)
        initial = next(item[3] for item in events if item[0] == STATE and item[1] == event[1])
        fields = list(struct.unpack('<' + 'Q' * (len(event[3]) // 8), event[3]))
        delta = dict(zip(fields[4::2], fields[5::2]))
        delta[slot] = delta.get(slot, struct.unpack_from('<Q', initial, slot * 8)[0]) ^ (0x800 if fault == 'state-meip' else 1 << 32)
        fields = fields[:4] + [item for pair in sorted(delta.items()) for item in pair]
        event[3] = struct.pack('<' + 'Q' * len(fields), *fields)
    elif fault == 'irq-cause':
        next(event for event in events if event[0] == INTERRUPT)[3][0] ^= 2
    elif fault == 'downgrade':
        struct.pack_into('<Q', header, 8, 3)
    else:
        raise ValueError(fault)
    write_events(destination, header, events)
    consistent = memory_consistent(destination)
    if fault in ('consistent-store', 'consistent-target', 'irq-cause'):
        assert consistent, fault
    return consistent


def main():
    check = Check(parser(__doc__).parse_args(), 'plic')
    for xlen in check.args.xlen:
        check.target(xlen)
        directory = check.directory
        inputs = directory / 'inputs.txt'
        inputs.write_text('0 10\n0 10\n250000 31\n500000 32\n')
        overlap = slept = False
        for harts in (1, 2, 4):
            image = check.guest(f'harts{harts}', ['nemu_diff_plic.S'], harts)
            for backend in ('rr', 'threaded'):
                for repeat in range(check.args.repeat if backend == 'threaded' else 1):
                    name = f'harts{harts}-{backend}-{repeat}'
                    options = ['--diff-plic', '--diff-plic-input=' + str(inputs), f'--smp={harts}',
                               '--smp-backend=' + backend]
                    journal, output = check.record(name, options, image)
                    waits = wfi_waits(output)
                    slept |= waits > 0
                    memory = check_journal(journal)
                    assert memory['interrupts'] == [4] + [2] * (harts - 1) and memory['version'] == 4
                    assert memory['plic_sources'] == 4 and memory['clocks'] > 0 and memory['io_requests'] > 0
                    overlap |= memory['interleaved_accesses'] > 0
                    _, events = read_events(journal)
                    assert interrupt_causes(events, xlen, harts) == [[11, 11, 9, 9]] + [[11, 9]] * (harts - 1)
                    traps = synchronous_traps(events)
                    assert traps == harts
                    check.replay(name + '-replay', journal, memory=memory, synchronous_traps=traps, wfi_waits=waits)
                    check.live(name + '-stream', ['-n', *options, '-t', check.dtb, image],
                               expect=lambda ref: ref['interrupts'] == 2 * harts + 2 and ref['plic_sources'] == 4)
                    if harts == 2 and backend == 'threaded' and repeat == 0:
                        source = journal
        check.save('observed-interleaving', overlap)
        check.save('observed-wfi-sleep', slept)
        binary, dtb = check.binary, check.dtb
        check.run('requires-journal', [binary, '-b', '--diff-plic', image], 1, b'--diff-plic requires')
        check.run('requires-plic', [binary, '-b', '--diff-plic-input=' + str(inputs), image], 1,
                  b'--diff-plic-input requires --diff-plic')
        for fault in ('BAD_WIDTH', 'BAD_CONTEXT', 'BAD_HOLE'):
            bad_image = check.guest(fault, ['nemu_diff_plic.S'], 2, ['-D' + fault])
            check.run(fault, [binary, '-b', '-n', '--smp=2', '--smp-backend=threaded', '--diff-plic',
                              '--diff-record=' + str(directory / (fault + '.njr')), '-t', dtb, bad_image],
                      1, b'NEMU_JOURNAL_FAIL')
        for index, text in enumerate(BAD_INPUTS):
            bad_inputs = directory / f'bad-input{index}.txt'
            bad_inputs.write_text(text)
            check.run(f'bad-input{index}', [binary, '-b', '-n', '--diff-plic', '--diff-plic-input=' + str(bad_inputs),
                                            '--diff-record=' + str(directory / f'bad-input{index}.njr'), '-t', dtb,
                                            image], 1, b'PLIC input')
        late_inputs = directory / 'unconsumed.txt'
        late_inputs.write_text(inputs.read_text() + '18446744073709551615 1\n')
        check.run('unconsumed-input', [binary, '-b', '-n', '--smp=4', '--smp-backend=threaded', '--diff-plic',
                                       '--diff-plic-input=' + str(late_inputs),
                                       '--diff-record=' + str(directory / 'unconsumed.njr'), '-t', dtb, image],
                  1, b'unconsumed PLIC input schedule')
        check.run('v3-rejects-plic', [binary, '-b', '-n', '--smp=4', '--diff-clint',
                                      '--diff-record=' + str(directory / 'disabled.njr'), '-t', dtb, image],
                  1, b'NEMU_JOURNAL_FAIL')
        check.faults(source, corrupt, FAULTS, MARKERS)
    check.finish('PLIC')


if __name__ == '__main__':
    main()
