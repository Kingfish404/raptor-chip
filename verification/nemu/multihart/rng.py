#!/usr/bin/env python3
"""Check independent RNG/DMA replay, entropy EOF and multicore reservations."""
import struct

from lib.harness import Check, parser
from lib.journal import ACCESS, ACCESS_KIND, END, check_journal, read_events, write_events
from lib.rng import DMA_READ, DMA_WRITE, RNG_BASE, RNG_INPUT, RNG_IRQ

FAULTS = ('read-address', 'read-size', 'read-success', 'read-data', 'read-drop',
          'write-address', 'write-size', 'write-data', 'write-drop', 'write-duplicate', 'write-hart',
          'entropy-length', 'entropy-status', 'entropy-byte', 'entropy-reorder',
          'irq-source', 'irq-context', 'irq-drop', 'irq-duplicate', 'failed-success',
          'mmio-result', 'version', 'rr', 'reservation')
COUNTERS = ('dma_reads', 'dma_writes', 'dma_bytes', 'rng_inputs', 'rng_irqs')


def corrupt(source, destination, fault):
    header, events = read_events(source)
    selected = {
        'read': next(index for index, event in enumerate(events) if event[0] == DMA_READ),
        'write': next(index for index, event in enumerate(events) if event[0] == DMA_WRITE),
        'entropy': next(index for index, event in enumerate(events) if event[0] == RNG_INPUT),
        'irq': next(index for index, event in enumerate(events) if event[0] == RNG_IRQ),
        'failed': next(index for index, event in enumerate(events)
                       if event[0] == DMA_READ and struct.unpack_from('<Q', event[3], 16)[0] == 0),
    }
    if fault == 'version':
        struct.pack_into('<Q', header, 8, 6)
    elif fault == 'rr':
        struct.pack_into('<Q', header, 56, 0)
    elif fault == 'reservation':
        event = next(event for event in events if event[0] == END)
        values = list(struct.unpack('<' + 'Q' * (len(event[3]) // 8), event[3]))
        delta = dict(zip(values[4::2], values[5::2]))
        delta[4163] = delta.get(4163, 3) ^ (8 << 32)
        fields = values[:4] + [item for pair in sorted(delta.items()) for item in pair]
        event[3] = bytearray(struct.pack('<' + 'Q' * len(fields), *fields))
    elif fault == 'mmio-result':
        event = next(event for event in events if event[0] == ACCESS_KIND and ACCESS.unpack(event[3])[0] == RNG_BASE)
        event[3][8] ^= 1
    else:
        family, action = fault.split('-', 1)
        index = selected[family]
        event = events[index]
        if action == 'drop':
            del events[index]
        elif action == 'duplicate':
            events.insert(index, event)
        elif action == 'hart':
            event[1] ^= 1
        elif action == 'reorder':
            events[index], events[index + 1] = events[index + 1], events[index]
        else:
            offset = {'address': 0, 'size': 8, 'success': 16, 'data': 24,
                      'length': 0, 'status': 8, 'byte': 16, 'source': 0, 'context': 8}[action]
            event[3][offset] ^= 1
    write_events(destination, header, events)


def main():
    check = Check(parser(__doc__, repeat=2).parse_args(), 'rng')
    payload = check.snapshot('nemu_virtio_start.S', 'nemu_diff_rng.c')
    for xlen in check.args.xlen:
        check.target(xlen)
        binary, directory, dtb = check.binary, check.directory, check.dtb
        entropy = directory / 'entropy.bin'
        entropy.write_bytes(bytes(range(256)) * 32)
        short_entropy = directory / 'short-entropy.bin'
        short_entropy.write_bytes(entropy.read_bytes()[:270])
        options = ['--diff-rng', '--diff-tlb=retain', '--smp-backend=threaded']
        for harts, eof in [(1, False), (2, False), (4, False), (2, True), (4, True)]:
            label = f'harts{harts}' + ('-eof' if eof else '')
            image = check.guest(label, payload, harts, ['-DRNG_EOF'] if eof else [], c=True)
            base = [*options, f'--smp={harts}', '--diff-rng-input=' + str(short_entropy if eof else entropy)]
            for repeat in range(1 if eof else check.args.repeat):
                name = label + '-' + str(repeat)
                journal, _ = check.record(name, base, image)
                stats = check_journal(journal)
                check.save(name + '-inspect', stats['version'] == 7 and stats['tlb_retain']
                           and stats['uart_tx'] == harts and stats['interrupts'] == [1] + [0] * (harts - 1)
                           and (harts == 1 or (stats['maximum_active'] > 1 and stats['interleaved_accesses'] > 0))
                           and all(stats[field] > 0 for field in COUNTERS), stats=stats)
                check.replay(name + '-replay', journal)
                check.live(name + '-live', ['-n', *base, '-t', dtb, image],
                           expect=lambda ref: all(ref[field] > 0 for field in COUNTERS))
                if harts == 2 and not eof:
                    source = journal
        bad_image = check.guest('bad-width', payload, 2, ['-DBAD_WIDTH'], c=True)
        common = ['-n', *options, '-t', dtb]
        check.run('reject-byte-mmio', [binary, '-b', *common, '--smp=2', '--diff-rng-input=' + str(entropy),
                                       '--diff-record=' + str(directory / 'bad-width.njr'), bad_image],
                  1, b'NEMU_MULTIDIFF_UNSUPPORTED')
        for name, arguments, marker in (
                ('missing-transport', ['--diff-rng'], b'--diff-rng requires'),
                ('missing-retain', ['--diff-rng', '-b', '--smp-backend=threaded', '--diff-record=/unused'],
                 b'--diff-rng requires'),
                ('missing-rng', ['--diff-rng-input=' + str(entropy)], b'--diff-rng-input requires'),
                ('wrong-backend', ['--diff-rng', '--diff-tlb=retain', '--diff-record=/unused', '-b'],
                 b'--diff-rng requires'),
                ('bad-input', [*common, '-b', '--diff-record=' + str(directory / 'input.njr'),
                               '--diff-rng-input=' + str(directory)], b'virtio-rng: entropy input')):
            check.run(name, [binary, *arguments], 1, marker)
        check.faults(source, corrupt, FAULTS, inspect=set(FAULTS) - {'reservation'})
    check.finish('RNG')


if __name__ == '__main__':
    main()
