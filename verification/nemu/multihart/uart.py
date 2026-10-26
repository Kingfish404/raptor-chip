#!/usr/bin/env python3
"""Validate multicore UART state, raw RX, derived IRQs and single-owner TX."""
import copy
import struct

from lib.build import ROOT
from lib.harness import Check, parser, wfi_waits
from lib.journal import (ACCESS, ACCESS_KIND, CLOCK, IO_REQUEST, PLIC_SOURCE, UART_BASE, UART_IRQ, UART_RX, UART_TX,
                         check_journal, memory_consistent, read_events, synchronous_traps, write_events)

FAULTS = ('consistent-store', 'width', 'request-data', 'load-value', 'drop-request', 'duplicate-request',
          'unexpected-clock', 'rx-value', 'rx-range', 'rx-context', 'rx-drop', 'rx-duplicate',
          'irq-value', 'irq-context', 'irq-drop', 'irq-duplicate', 'irq-raw',
          'tx-value', 'tx-context', 'tx-drop', 'tx-duplicate', 'downgrade')
BAD_INPUTS = ('', '-1 1\n', '1 -1\n', '1 256\n', '1 1 extra\n', '2 1\n1 2\n', '18446744073709551616 1\n', '0 1\n' * 4097)
NOISE = b'unrecorded stdin must be ignored\n'


def corrupt(source, destination, fault):
    header, events = read_events(source)
    request = next(index for index, event in enumerate(events)
                   if event[0] == IO_REQUEST and ACCESS.unpack(event[3]) == (UART_BASE, 65, 1, 1))
    assert events[request + 1][0] == UART_TX and events[request + 2][0] == ACCESS_KIND
    if fault == 'consistent-store':
        for index in (request, request + 2):
            events[index][3] = ACCESS.pack(UART_BASE, 66, 1, 1)
        events[request + 1][3] = struct.pack('<2Q', 66, 1)
    elif fault == 'width':
        events[request][3] = ACCESS.pack(UART_BASE, 65, 4, 1)
    elif fault in ('request-data', 'load-value'):
        index = next(index for index, event in enumerate(events)
                     if event[0] == IO_REQUEST and ACCESS.unpack(event[3]) == (UART_BASE + 4, 0, 1, 0))
        index += fault == 'load-value'
        address, value, width, write = ACCESS.unpack(events[index][3])
        events[index][3] = ACCESS.pack(address, value ^ 1, width, write)
    elif fault in ('drop-request', 'duplicate-request', 'unexpected-clock'):
        if fault == 'drop-request':
            del events[request]
        elif fault == 'duplicate-request':
            events.insert(request, copy.deepcopy(events[request]))
        else:
            events.insert(request + 1, [CLOCK, events[request][1], events[request][2], struct.pack('<3Q', 0, 1, 1)])
    elif fault == 'downgrade':
        struct.pack_into('<Q', header, 8, 4)
    else:
        category, mutation = fault.split('-', 1)
        kind = {'rx': UART_RX, 'irq': UART_IRQ, 'tx': UART_TX}[category]
        index = next(index for index, event in enumerate(events) if event[0] == kind)
        if mutation == 'drop':
            del events[index]
        elif mutation == 'duplicate':
            events.insert(index, copy.deepcopy(events[index]))
        elif mutation == 'raw':
            events[index][0] = PLIC_SOURCE
        else:
            value, executing = struct.unpack('<2Q', events[index][3])
            if mutation == 'context':
                executing ^= 1
            elif mutation == 'range':
                value = 256
            else:
                value ^= 1
            events[index][3] = struct.pack('<2Q', value, executing)
    write_events(destination, header, events)
    consistent = memory_consistent(destination)
    if fault == 'consistent-store':
        assert consistent
    return consistent


def main():
    arguments = parser(__doc__)
    arguments.add_argument('--tlb-retain', action='store_true')
    check = Check(arguments.parse_args(), 'uart')
    retain = check.args.tlb_retain
    check.details = dict(retained_tlb_matrix=retain)
    tlb_options = ['--diff-tlb=retain'] if retain else []

    def run(*args, **kwargs):
        return check.run(*args, stdin=NOISE, **kwargs)

    for xlen in check.args.xlen:
        check.target(xlen)
        binary, directory, dtb = check.binary, check.directory, check.dtb
        check.environment['NEMU_UART_BINARY'] = str(binary)
        terminal = directory / 'nemu-uart-peer'
        terminal.write_text((ROOT / 'verification/nemu/lib/uart_input.py').read_text())
        terminal.chmod(0o700)
        inputs = directory / 'inputs.txt'
        inputs.write_text(''.join(f'0 {value & 255}\n' for value in range(260)))
        overlap = slept = False
        configurations = [(harts, backend, repeat, False) for harts in (1, 2, 4)
                          for backend in (('threaded',) if retain else ('rr', 'threaded'))
                          for repeat in range(check.args.repeat if backend == 'threaded' else 1)]
        for harts, backend, repeat, no_input in configurations + [(2, 'threaded', 0, True)]:
            name = f'harts{harts}-{backend}-{repeat}' + ('-no-input' if no_input else '')
            image = check.guest(name, ['nemu_diff_uart.S'], harts, ['-DNO_INPUT'] if no_input else [])
            options = ['--diff-uart', *tlb_options,
                       *([] if no_input else ['--diff-uart-stdin', '--diff-uart-input=' + str(inputs)]),
                       f'--smp={harts}', '--smp-backend=' + backend]
            journal, output = check.record(name, options, image, program=binary if no_input else terminal,
                                           stdin=NOISE)
            waits = wfi_waits(output)
            slept |= waits > 0
            memory = check_journal(journal)
            assert memory['interrupts'] == [0 if no_input else 2] + [0] * (harts - 1)
            assert memory['version'] == (6 if retain else 5)
            assert memory['uart_rx'] == (0 if no_input else 264)
            assert memory['uart_irqs'] == 1 if no_input else 4 <= memory['uart_irqs'] <= 6
            assert memory['uart_tx'] == harts + (1 if no_input else 26) and memory['plic_sources'] == 0
            overlap |= memory['interleaved_accesses'] > 0
            traps = synchronous_traps(read_events(journal)[1])
            assert traps == (0 if no_input else 1)
            check.replay(name + '-replay', journal, memory=memory, synchronous_traps=traps, wfi_waits=waits)

            def expect(ref, harts=harts, no_input=no_input):
                return (ref['interrupts'] == (0 if no_input else 2) and ref['uart_rx'] == (0 if no_input else 264)
                        and ref['uart_tx'] == harts + (1 if no_input else 26) and ref['plic_sources'] == 0
                        and (ref['uart_irqs'] == 1 if no_input else 4 <= ref['uart_irqs'] <= 6))
            check.live(name + '-stream', ['-n', *options, '-t', dtb, image],
                       producer=binary if no_input else terminal, expect=expect)
            if harts == 2 and backend == 'threaded' and repeat == 0 and not no_input:
                source = journal
        check.save('observed-interleaving', overlap)
        check.save('observed-wfi-sleep', slept)
        run('requires-journal', [binary, '-b', '--diff-uart', image], 1, b'--diff-uart requires')
        run('requires-uart', [binary, '-b', '--diff-uart-input=' + str(inputs), image], 1,
            b'--diff-uart-input requires --diff-uart')
        run('stdin-requires-uart', [binary, '-b', '--diff-uart-stdin', image], 1,
            b'--diff-uart-stdin requires --diff-uart')
        for fault in ('BAD_WIDTH', 'BAD_OFFSET', 'BAD_LITEX'):
            bad_image = check.guest(fault, ['nemu_diff_uart.S'], 2, ['-D' + fault])
            run(fault, [binary, '-b', '-n', '--smp=2', '--smp-backend=threaded', '--diff-uart',
                        '--diff-record=' + str(directory / (fault + '.njr')), '-t', dtb, bad_image],
                1, b'NEMU_JOURNAL_FAIL')
        for index, text in enumerate(BAD_INPUTS):
            bad_inputs = directory / f'bad-input{index}.txt'
            bad_inputs.write_text(text)
            run(f'bad-input{index}', [binary, '-b', '-n', '--diff-uart', '--diff-uart-input=' + str(bad_inputs),
                                      '--diff-record=' + str(directory / f'bad-input{index}.njr'), '-t', dtb, image],
                1, b'UART input')
        late_inputs = directory / 'unconsumed.txt'
        late_inputs.write_text('18446744073709551615 1\n')
        run('unconsumed-input', [binary, '-b', '-n', '--smp=2', '--smp-backend=threaded', '--diff-uart',
                                 '--diff-uart-input=' + str(late_inputs),
                                 '--diff-record=' + str(directory / 'unconsumed.njr'), '-t', dtb, image],
            1, b'unconsumed UART input schedule')
        run('v4-rejects-uart', [binary, '-b', '-n', '--smp=2', '--diff-plic',
                                '--diff-record=' + str(directory / 'disabled.njr'), '-t', dtb, image],
            1, b'NEMU_JOURNAL_FAIL')
        check.faults(source, corrupt, FAULTS, {'consistent-store': b'store value mismatch before reference write'})
    check.finish('UART')


if __name__ == '__main__':
    main()
