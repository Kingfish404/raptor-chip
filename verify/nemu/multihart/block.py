#!/usr/bin/env python3
"""Validate independent disk/DMA/IRQ replay with 1/2/4 pthread harts."""
import struct

from lib.block import BLOCK_IMAGE, BLOCK_IRQ, BLOCK_PAGE, BLOCK_READ, BLOCK_WRITE
from lib.harness import Check, parser, sha256
from lib.journal import check_journal, read_events, write_events
from multihart.net import corrupt as common_corrupt

FAULTS = ('image-length', 'image-count', 'image-drop', 'image-duplicate',
          'page-offset', 'page-byte', 'page-drop', 'page-duplicate', 'page-reorder', 'page-hart',
          'diskread-offset', 'diskread-size', 'diskread-data', 'diskread-drop',
          'diskwrite-offset', 'diskwrite-size', 'diskwrite-data', 'diskwrite-drop', 'diskwrite-duplicate',
          'read-address', 'read-data', 'read-success', 'write-data', 'write-hart', 'write-drop',
          'irq-source', 'irq-context', 'irq-drop', 'irq-duplicate', 'version', 'rr', 'reservation')


def corrupt(source, destination, fault):
    if fault.startswith(('read-', 'write-')) or fault in ('rr', 'reservation'):
        return common_corrupt(source, destination, fault)
    header, events = read_events(source)
    if fault == 'version':
        struct.pack_into('<Q', header, 8, 8)
    else:
        family, action = fault.split('-', 1)
        kind = {'image': BLOCK_IMAGE, 'page': BLOCK_PAGE, 'diskread': BLOCK_READ,
                'diskwrite': BLOCK_WRITE, 'irq': BLOCK_IRQ}[family]
        index = next(index for index, event in enumerate(events) if event[0] == kind)
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
            offset = {'offset': 0, 'size': 8, 'data': 16, 'byte': 8, 'source': 0, 'context': 8,
                      'length': 0, 'count': 8}[action]
            event[3][offset] ^= 1
    write_events(destination, header, events)


def main():
    check = Check(parser(__doc__, repeat=2).parse_args(), 'block')
    check.timeout = 180
    payload = check.snapshot('nemu_diff_block.S', 'nemu_diff_block.c')
    for xlen in check.args.xlen:
        check.target(xlen)
        binary, directory = check.binary, check.directory
        disk = directory / 'disk.img'
        pattern = bytes((index * 7 + 3) & 255 for index in range(256))
        contents = bytearray(pattern * 4096 + pattern[:13])
        contents[0x80000:0x81000] = bytes(4096)
        disk.write_bytes(contents)
        check.hashes['disk_sha256'] = sha256(disk)
        options = ['--diff-block', '--diff-tlb=retain', '--smp-backend=threaded', '--diff-net-backend=script']
        for harts, mode in [(1, 'normal'), (2, 'normal'), (4, 'normal'), (1, 'big'), (2, 'empty')]:
            label = f'{mode}-harts{harts}'
            extra = ['-DBIG_REQUEST'] if mode == 'big' else ['-DEMPTY_DISK'] if mode == 'empty' else []
            image = check.guest(label, payload, harts, extra, c=True)
            base = [*options, f'--smp={harts}', *(['--disk=' + str(disk)] if mode != 'empty' else [])]
            for repeat in range(check.args.repeat if mode == 'normal' else 1):
                name = label + '-' + str(repeat)
                journal, _ = check.record(name, base, image)
                stats = check_journal(journal)
                check.save(name + '-inspect', stats['version'] == 9 and stats['tlb_retain']
                           and stats['uart_tx'] == harts
                           and stats['block_image_size'] == (0 if mode == 'empty' else len(contents))
                           and stats['block_pages'] == (0 if mode == 'empty' else 256)
                           and (mode == 'empty' or (stats['block_reads'] > 0 and stats['block_irqs'] > 0
                                                    and stats['interrupts'][0] > 0))
                           and (mode != 'normal' or stats['block_writes'] == 2 * harts)
                           and (harts == 1 or (stats['maximum_active'] > 1 and stats['interleaved_accesses'] > 0)),
                           stats=stats)
                check.replay(name + '-replay', journal)
                check.live(name + '-live', ['-n', *base, '-t', check.dtb, image])
                if harts == 2 and mode == 'normal':
                    source = journal
        check.save('disk-not-modified', sha256(disk) == check.hashes['disk_sha256'])
        bad_image = check.guest('bad-width', payload, 2, ['-DBAD_WIDTH'], c=True)
        check.run('reject-byte-mmio', [binary, '-b', '-n', *options, '-t', check.dtb, '--smp=2', '--disk=' + str(disk),
                                       '--diff-record=' + str(directory / 'bad-width.njr'), bad_image],
                  1, b'NEMU_MULTIDIFF_UNSUPPORTED')
        for name, arguments in (
                ('missing-transport', ['--diff-block']),
                ('missing-retain', ['--diff-block', '-b', '--smp-backend=threaded', '--diff-record=/unused']),
                ('wrong-backend', ['--diff-block', '--diff-tlb=retain', '--diff-record=/unused', '-b'])):
            check.run(name, [binary, *arguments], 1, b'--diff-block requires')
        check.faults(source, corrupt, FAULTS, inspect=set(FAULTS) - {'reservation'})
    check.finish('BLOCK')


if __name__ == '__main__':
    main()
