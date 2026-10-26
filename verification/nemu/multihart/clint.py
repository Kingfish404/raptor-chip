#!/usr/bin/env python3
"""Check multicore CLINT, raw clock replay, IPI/MTIP/Sstc and WFI wakeups."""
import copy
import struct

from lib.harness import Check, parser, wfi_waits
from lib.journal import (ACCESS, ACCESS_KIND, CLOCK, END, INTERRUPT, IO_REQUEST, STATE, check_journal,
                         interrupt_causes, memory_consistent, read_events, synchronous_traps, write_events)

STATE_MISMATCH = b'architectural or reservation state mismatch'
FAULTS = ('consistent-store', 'consistent-target', 'width', 'read-data', 'request-data',
          'clock-action', 'clock-context', 'clock-backwards', 'drop-clock', 'duplicate-clock',
          'drop-request', 'duplicate-request', 'state-time', 'state-timeh', 'state-compare',
          'state-pending', 'state-stip', 'irq-cause', 'downgrade')
MARKERS = {'consistent-store': b'store value mismatch before reference write',
           'consistent-target': b'memory address/width/direction mismatch before access',
           'read-data': b'independent reference load value mismatch',
           **{fault: STATE_MISMATCH for fault in FAULTS if fault.startswith('state-')}}


def corrupt(source, destination, fault):
    header, events = read_events(source)
    request = next(index for index, event in enumerate(events) if event[0] == IO_REQUEST)
    clock = request + 1
    completion = request + 2
    assert events[clock][0] == CLOCK and events[completion][0] == ACCESS_KIND
    if fault in ('consistent-store', 'consistent-target', 'width'):
        address, value, width, write = ACCESS.unpack(events[request][3])
        assert value == 2 and width == 4 and write == 1
        if fault == 'consistent-store':
            value = 4
        elif fault == 'consistent-target':
            address ^= 4
        else:
            width = 8
        for index in (request, completion):
            events[index][3] = ACCESS.pack(address, value, width, write)
    elif fault in ('read-data', 'request-data'):
        index = next(index for index, event in enumerate(events)
                     if event[0] == IO_REQUEST and ACCESS.unpack(event[3])[3] == 0)
        if fault == 'read-data':
            index += 2
            assert events[index][0] == ACCESS_KIND
        address, value, width, write = ACCESS.unpack(events[index][3])
        events[index][3] = ACCESS.pack(address, value ^ 1, width, write)
    elif fault in ('clock-action', 'clock-context', 'clock-backwards'):
        if fault == 'clock-backwards':
            previous = 0
            for index, event in enumerate(events):
                if event[0] != CLOCK:
                    continue
                if previous:
                    clock = index
                    break
                previous = struct.unpack_from('<Q', event[3])[0]
            else:
                raise AssertionError('no positive clock')
        ticks, action, executing = struct.unpack('<3Q', events[clock][3])
        if fault == 'clock-backwards':
            ticks = previous - 1
        elif fault == 'clock-action':
            action = 2
        else:
            executing ^= 1
        events[clock][3] = struct.pack('<3Q', ticks, action, executing)
    elif fault.startswith('drop-') or fault.startswith('duplicate-'):
        index = clock if fault.endswith('clock') else request
        if fault.startswith('drop-'):
            del events[index]
        else:
            events.insert(index, copy.deepcopy(events[index]))
    elif fault.startswith('state-'):
        slot = {'time': 65 + 0xc01, 'timeh': 65 + 0xc81, 'pending': 65 + 0x344,
                'compare': 4162, 'stip': 4164}[fault[6:]]
        event = next(event for event in events if event[0] == END)
        initial = next(item[3] for item in events if item[0] == STATE and item[1] == event[1])
        fields = list(struct.unpack('<' + 'Q' * (len(event[3]) // 8), event[3]))
        delta = dict(zip(fields[4::2], fields[5::2]))
        delta[slot] = delta.get(slot, struct.unpack_from('<Q', initial, slot * 8)[0]) ^ (8 if fault == 'state-pending' else 1)
        fields = fields[:4] + [item for pair in sorted(delta.items()) for item in pair]
        event[3] = struct.pack('<' + 'Q' * len(fields), *fields)
    elif fault == 'irq-cause':
        index = next(index for index, event in enumerate(events) if event[0] == INTERRUPT)
        events[index][3][0] ^= 4
    elif fault == 'downgrade':
        struct.pack_into('<Q', header, 8, 2)
    else:
        raise ValueError(fault)
    write_events(destination, header, events)
    consistent = memory_consistent(destination)
    if fault in ('consistent-store', 'consistent-target', 'irq-cause', 'state-stip'):
        assert consistent, fault
    return consistent


def main():
    check = Check(parser(__doc__).parse_args(), 'clint')
    for xlen in check.args.xlen:
        check.target(xlen)
        overlap = slept = False
        for harts in (1, 2, 4):
            for high in (False, True):
                image = check.guest(f'harts{harts}' + ('-high' if high else ''), ['nemu_diff_clint.S'], harts,
                                    ['-DHIGH_TIME'] if high else [])
                for backend in (('rr',) if high else ('rr', 'threaded')):
                    for repeat in range(check.args.repeat if backend == 'threaded' else 1):
                        name = f'harts{harts}-{backend}-{repeat}' + ('-high' if high else '')
                        options = ['--diff-clint', f'--smp={harts}', '--smp-backend=' + backend]
                        journal, output = check.record(name, options, image)
                        waits = wfi_waits(output)
                        slept |= waits > 0
                        memory = check_journal(journal)
                        assert memory['interrupts'] == [3] * harts and memory['version'] == 3
                        assert memory['clocks'] > 0 and memory['idle_clocks'] > 0 and memory['io_requests'] > 0
                        if high:
                            assert memory['last_clock'] > 1 << 32
                        overlap |= memory['interleaved_accesses'] > 0
                        _, events = read_events(journal)
                        assert interrupt_causes(events, xlen, harts) == [[3, 7, 5]] * harts
                        traps = synchronous_traps(events)
                        assert traps == 3 * harts, traps
                        check.replay(name + '-replay', journal, memory=memory, synchronous_traps=traps,
                                     wfi_waits=waits)
                        check.live(name + '-stream', ['-n', *options, '-t', check.dtb, image],
                                   expect=lambda ref: ref['interrupts'] == 3 * harts and ref['clocks'] > 0
                                   and ref['io_requests'] > 0)
                        if harts == 2 and backend == 'threaded' and repeat == 0:
                            source = journal
        check.save('observed-interleaving', overlap)
        check.save('observed-wfi-sleep', slept)
        check.run('requires-journal', [check.binary, '-b', '--diff-clint', image], 1,
                  b'--diff-clint requires --diff-record or --diff-stream-fd')
        for fault in ('BAD_MMIO', 'BAD_MTIME_WRITE', 'BAD_MSIP_WIDTH'):
            image = check.guest(fault, ['nemu_diff_clint.S'], 2, ['-D' + fault])
            check.run('unsupported-' + fault, [check.binary, '-b', '-n', '--smp=2', '--smp-backend=threaded',
                                              '--diff-clint', '--diff-record=' + str(check.directory / (fault + '.njr')),
                                              '-t', check.dtb, image], 1, b'NEMU_JOURNAL_FAIL')
        image = check.guest('disabled', ['nemu_diff_clint.S'], 2)
        check.run('disabled-clint', [check.binary, '-b', '-n', '--smp=2', '--diff-interrupts',
                                     '--diff-record=' + str(check.directory / 'disabled.njr'), '-t', check.dtb, image],
                  1, b'NEMU_JOURNAL_FAIL')
        check.faults(source, corrupt, FAULTS, MARKERS)
    check.finish('CLINT')


if __name__ == '__main__':
    main()
