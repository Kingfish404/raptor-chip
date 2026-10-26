#!/usr/bin/env python3
"""Validate retained per-hart translation caches without skipping ISA checks."""
import struct
import subprocess

from lib.harness import Check, parser
from lib.journal import ACCESS, ACCESS_KIND, BEGIN, END, HEADER, check_journal, records
from multihart.replay import mutate_journal

FAULTS = ('flush-policy', 'rr-policy', 'gpr', 'consistent-store', 'load', 'address', 'drop-access',
          'missing-unlock', 'wrong-hart')


def inspect(journal, lower, upper):
    result = check_journal(journal)
    walks = traps = fetches = faulting_fetches = 0
    current = {}
    with journal.open('rb') as stream:
        stream.read(HEADER.size)
        for kind, sequence, hart, instruction, payload in records(stream):
            if kind == BEGIN:
                current[hart] = [struct.unpack('<Q', payload)[0], False]
            elif kind == ACCESS_KIND:
                address, value, width, write = ACCESS.unpack(payload)
                walks += not write and lower <= address < upper
                pc = current[hart][0]
                aliases = (upper + hart * 4096, upper + 16384 + hart * 4096)
                translated_fetch = 0x40000000 <= pc < 0x40001000 and any(
                    address == page + pc - 0x40000000 for page in aliases)
                if not write and (address == pc or translated_fetch):
                    current[hart][1] = True
            elif kind == END:
                trapped = struct.unpack_from('<Q', payload, 8)[0]
                if current[hart][1]:
                    fetches += 1
                else:
                    delta = dict(struct.iter_unpack('<2Q', payload[32:]))
                    assert trapped and current[hart][0] == 0x40000020 and delta.get(65 + 0x342) == 12
                    faulting_fetches += 1
                traps += trapped
    assert fetches + faulting_fetches == sum(result['instructions'])
    assert faulting_fetches == result['harts'] and traps == result['harts'] * 9
    return dict(**result, page_table_reads=walks, fetched_instructions=fetches,
                faulting_fetches=faulting_fetches, synchronous_traps=traps)


def corrupt(source, destination, fault):
    if fault in ('flush-policy', 'rr-policy'):
        data = bytearray(source.read_bytes())
        struct.pack_into('<Q', data, 8 if fault == 'flush-policy' else 56, 5 if fault == 'flush-policy' else 0)
        destination.write_bytes(data)
        return None
    return mutate_journal(source, destination, fault)


def main():
    check = Check(parser(__doc__).parse_args(), 'tlb')
    payload, = check.snapshot('nemu_diff_tlb.S')
    for xlen in check.args.xlen:
        check.target(xlen)
        binary, directory, dtb = check.binary, check.directory, check.dtb
        for harts in (1, 2, 4):
            image = check.guest(f'harts{harts}', [payload], harts)
            symbols = {name: int(address, 16) for address, kind, name in
                       (line.split() for line in subprocess.check_output(
                           ['riscv64-linux-gnu-nm', image.with_suffix('.elf')], text=True).splitlines())}
            base = ['--diff-uart', f'--smp={harts}', '--smp-backend=threaded']
            for mode in ('flush', 'retain'):
                for repeat in range(check.args.repeat if mode == 'retain' else 1):
                    name = f'harts{harts}-{mode}-{repeat}'
                    options = [*base, '--diff-tlb=' + mode]
                    journal, _ = check.record(name, options, image)
                    stats = inspect(journal, symbols['roots'], symbols['tables_end'])
                    assert stats['version'] == (6 if mode == 'retain' else 5)
                    if mode == 'flush':
                        baseline = stats['page_table_reads']
                    else:
                        check.save(name + '-fewer-walks', 0 < stats['page_table_reads'] * 4 < baseline,
                                   flush_reads=baseline, retain_reads=stats['page_table_reads'])
                    check.replay(name + '-replay', journal, stats=stats)
                    check.live(name + '-stream', ['-n', *options, '-t', dtb, image])
                    if harts == 2 and mode == 'retain' and repeat == 0:
                        source = journal
        image = check.guest('unsupported', [payload], 1, ['-DNEMU_TLB_UNSUPPORTED'])
        for mode in ('flush', 'retain'):
            journal = directory / ('unsupported-' + mode + '.njr')
            check.run('unsupported-' + mode, [binary, '-b', '-n', '--smp=1', '--smp-backend=threaded', '--diff-uart',
                                             '--diff-tlb=' + mode, '--diff-record=' + str(journal), '-t', dtb, image],
                      1, b'address=0x10002000 size=4 write=0')
            check.replay('unsupported-' + mode + '-replay', journal, 1, b'NEMU_REPLAY_FAIL')
        for name, options in [('invalid', ['--diff-tlb=wrong']), ('transport', ['--diff-tlb=retain']),
                              ('uart', ['--diff-tlb=retain', '--smp-backend=threaded',
                                        '--diff-record=' + str(directory / 'unused')]),
                              ('backend', ['--diff-tlb=retain', '--diff-uart',
                                           '--diff-record=' + str(directory / 'unused')])]:
            check.run('reject-' + name, [binary, '-b', *options], 1, b'--diff-tlb')
        check.faults(source, corrupt, FAULTS)
    check.finish('TLB')


if __name__ == '__main__':
    main()
