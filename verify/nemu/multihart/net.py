#!/usr/bin/env python3
"""Validate independent virtio-net replay with scripted RX and local slirp ARP."""
import os
import struct

from lib.harness import Check, parser
from lib.journal import ACCESS, ACCESS_KIND, END, check_journal, read_events, write_events
from lib.net import NET_BASE, NET_IRQ, NET_RX, NET_RX_RESULT, NET_TX
from lib.rng import DMA_READ, DMA_WRITE

FAULTS = ('read-address', 'read-size', 'read-success', 'read-data', 'read-drop',
          'write-address', 'write-size', 'write-data', 'write-drop', 'write-duplicate', 'write-hart',
          'rx-length', 'rx-context', 'rx-byte', 'rx-reorder', 'rx-drop', 'rx-duplicate',
          'tx-length', 'tx-context', 'tx-byte', 'tx-drop', 'tx-duplicate',
          'irq-source', 'irq-context', 'irq-drop', 'irq-duplicate',
          'result-return', 'result-disposition', 'result-executing', 'result-drop',
          'mmio-result', 'version', 'rr', 'reservation')
COUNTERS = ('dma_reads', 'dma_writes', 'net_rx', 'net_tx', 'net_irqs')
INVALID_INPUTS = {'phase': 'unknown 0 00\n', 'odd': 'poll 0 abc\n', 'hex': 'poll 0 gg\n',
                  'negative': 'poll -1 00\n', 'overflow': 'poll 18446744073709551616 00\n',
                  'zero-tx': 'tx 0 00\n', 'order': 'tx 2 00\ntx 1 00\n',
                  'extra': 'poll 0 00 extra\n', 'large': 'poll 0 ' + '00' * 65525 + '\n',
                  'count': 'poll 0 00\n' * 513, 'long-line': ' ' * 131136 + '\n'}


def input_script(harts, big=False):
    def packet(seed, size=60):
        return bytes((seed + index) & 255 for index in range(size)).hex()
    lines = ['poll 0 01', 'poll 0 -']
    lines += ['tx 1 ' + ('5a' * 65524 if big else packet(17 * hart)) for hart in range(harts)]
    if not big:
        lines += [f'poll {harts + 1} {packet(0x55)}']
        lines += [f'tx {harts + offset} {packet(0x77)}' for offset in range(2, 6)]
        lines += [f'tx {harts + 8} -']
    return '\n'.join(lines) + '\n'


def expected_counts(harts, mode):
    if mode == 'script':
        return dict(net_rx=harts + 8, net_tx=harts + 8, net_irqs=2 * harts + 17,
                    net_rx_bytes=60 * harts + 301, net_tx_bytes=60 * harts + 420, net_rx_drops=6)
    if mode == 'big':
        return dict(net_rx=3, net_tx=1, net_irqs=2, net_rx_bytes=65525, net_tx_bytes=65524, net_rx_drops=2)
    return dict(net_rx=harts, net_tx=harts, net_irqs=2 * harts, net_tx_bytes=42 * harts, net_rx_drops=0)


def corrupt(source, destination, fault):
    header, events = read_events(source)
    if fault == 'version':
        struct.pack_into('<Q', header, 8, 7)
    elif fault == 'rr':
        struct.pack_into('<Q', header, 56, 0)
    elif fault == 'reservation':
        event = next(event for event in events if event[0] == END)
        values = list(struct.unpack('<' + 'Q' * (len(event[3]) // 8), event[3]))
        delta = dict(zip(values[4::2], values[5::2]))
        delta[4163] = delta.get(4163, 3) ^ (8 << 32)
        values = values[:4] + [item for pair in sorted(delta.items()) for item in pair]
        event[3] = bytearray(struct.pack('<' + 'Q' * len(values), *values))
    elif fault == 'mmio-result':
        event = next(event for event in events if event[0] == ACCESS_KIND and ACCESS.unpack(event[3])[0] == NET_BASE)
        event[3][8] ^= 1
    else:
        family, action = fault.split('-', 1)
        kind = {'read': DMA_READ, 'write': DMA_WRITE, 'rx': NET_RX, 'tx': NET_TX,
                'irq': NET_IRQ, 'result': NET_RX_RESULT}[family]
        index = next(index for index, event in enumerate(events)
                     if event[0] == kind and (family != 'rx' or len(event[3]) > 17))
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
                      'length': 0, 'context': 8, 'byte': 16, 'source': 0,
                      'return': 0, 'disposition': 8, 'executing': 16}[action]
            event[3][offset] ^= 1
    write_events(destination, header, events)


def main():
    check = Check(parser(__doc__, repeat=2).parse_args(), 'net')
    check.timeout = 180
    payload = check.snapshot('nemu_diff_net.S', 'nemu_diff_net.c')
    for xlen in check.args.xlen:
        check.target(xlen)
        binary, directory, dtb = check.binary, check.directory, check.dtb
        options = ['--diff-net', '--diff-tlb=retain', '--smp-backend=threaded']
        for harts, mode in [(1, 'script'), (2, 'script'), (4, 'script'), (1, 'big'), (1, 'slirp'), (2, 'slirp'),
                            (4, 'slirp')]:
            label = f'{mode}-harts{harts}'
            extra = ['-DBIG_PACKET'] if mode == 'big' else ['-DSLIRP_ARP'] if mode == 'slirp' else []
            image = check.guest(label, payload, harts, extra, c=True)
            base = [*options, f'--smp={harts}', '--diff-net-backend=' + ('slirp' if mode == 'slirp' else 'script')]
            if mode != 'slirp':
                inputs = directory / (label + '.input')
                inputs.write_text(input_script(harts, mode == 'big'))
                base += ['--diff-net-input=' + str(inputs)]
            for repeat in range(check.args.repeat if mode == 'script' else 1):
                name = label + '-' + str(repeat)
                journal, _ = check.record(name, base, image)
                stats = check_journal(journal)
                check.save(name + '-inspect', stats['version'] == 8 and stats['tlb_retain']
                           and stats['uart_tx'] == harts and stats['interrupts'][0] > 0
                           and all(stats[field] == value for field, value in expected_counts(harts, mode).items())
                           and (harts == 1 or (stats['maximum_active'] > 1 and stats['interleaved_accesses'] > 0))
                           and all(stats[field] > 0 for field in COUNTERS), stats=stats)
                check.replay(name + '-replay', journal)
                check.live(name + '-live', ['-n', *base, '-t', dtb, image],
                           expect=lambda ref: all(ref[field] > 0 for field in (*COUNTERS, 'net_rx_bytes',
                                                                                 'net_tx_bytes')))
                if harts == 2 and mode == 'script':
                    source = journal
        common = ['-n', *options, '-t', dtb]
        bad_image = check.guest('bad-width', payload, 2, ['-DBAD_WIDTH'], c=True)
        check.run('reject-byte-mmio', [binary, '-b', *common, '--smp=2', '--diff-net-backend=script',
                                       '--diff-record=' + str(directory / 'bad-width.njr'), bad_image],
                  1, b'NEMU_MULTIDIFF_UNSUPPORTED')
        for name, arguments, marker in (
                ('missing-transport', ['--diff-net'], b'--diff-net requires'),
                ('missing-retain', ['--diff-net', '-b', '--smp-backend=threaded', '--diff-record=/unused'],
                 b'--diff-net requires'),
                ('missing-net', ['--diff-net-backend=script'], b'--diff-net-backend requires'),
                ('wrong-backend', ['--diff-net', '--diff-tlb=retain', '--diff-record=/unused', '-b'],
                 b'--diff-net requires'),
                ('unknown-backend', ['--diff-net-backend=invalid'], b'--diff-net-backend requires'),
                ('input-with-slirp', [*common, '--diff-net-input=/unused'], b'--diff-net-backend requires')):
            check.run(name, [binary, *arguments], 1, marker)
        for label, content in INVALID_INPUTS.items():
            (directory / (label + '.input')).write_text(content)
        os.mkfifo(directory / 'fifo.input')
        for label in [*INVALID_INPUTS, 'directory', 'fifo', 'missing']:
            path = directory if label == 'directory' else directory / (label + '.input')
            check.run('reject-input-' + label, [binary, '-b', *common, '--diff-net-backend=script',
                                                '--diff-net-input=' + str(path),
                                                '--diff-record=' + str(directory / ('bad-input-' + label + '.njr'))],
                      1, b'virtio-net: invalid script')
        unused = directory / 'unused.input'
        unused.write_text(input_script(1) + 'tx 999 -\n')
        check.run('reject-unconsumed-input', [binary, '-b', *common, '--smp=1', '--diff-net-backend=script',
                                              '--diff-net-input=' + str(unused),
                                              '--diff-record=' + str(directory / 'unused.njr'),
                                              directory / 'script-harts1.bin'], 1, b'NEMU_JOURNAL_FAIL')
        check.faults(source, corrupt, FAULTS, inspect=set(FAULTS) - {'reservation'})
    check.finish('NET')


if __name__ == '__main__':
    main()
