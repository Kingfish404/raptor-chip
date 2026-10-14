#!/usr/bin/env python3
"""Check syscon read/modify/write poweroff without skipping reference loads."""
from lib.harness import Check, parser
from lib.journal import ACCESS, ACCESS_KIND, check_journal, read_events, write_events

FINISHER_READ = (0x100000, 0, 4, 0)
FIELD_OFFSETS = {'data': 8, 'address': 0, 'width': 16, 'direction': 20}


def corrupt(source, destination, fault):
    """Flip one field of the first finisher read."""
    header, events = read_events(source)
    event = next(event for event in events if event[0] == ACCESS_KIND and ACCESS.unpack(event[3]) == FINISHER_READ)
    event[3][FIELD_OFFSETS[fault]] ^= 1
    write_events(destination, header, events)


def main():
    check = Check(parser(__doc__).parse_args(), 'finisher')
    payload, = check.snapshot('nemu_diff_finisher.S')
    for xlen in check.args.xlen:
        check.target(xlen)
        full = ['--diff-block', '--diff-tlb=retain', '--diff-net-backend=script', '--smp-backend=threaded']
        for harts, finisher in ((1, 0), (2, 0), (4, 0), (2, 1), (4, 3)):
            image = check.guest(f'harts{harts}-finisher{finisher}', [payload], harts,
                                ['-mno-relax', f'-DFINISH_HART={finisher}'])
            for profile, options in (('rr', ['--smp-backend=rr']), ('threaded', ['--smp-backend=threaded']),
                                     ('block', full)):
                name = f'{profile}-harts{harts}-finisher{finisher}'
                arguments = [*options, f'--smp={harts}']
                journal, _ = check.record(name, arguments, image)
                stats = check_journal(journal)
                reads = sum(kind == ACCESS_KIND and ACCESS.unpack(data) == FINISHER_READ
                            for kind, _, _, data in read_events(journal)[1])
                check.save(name + '-inspect', reads == harts + 1
                           and stats['version'] == (9 if profile == 'block' else 1), stats=stats, finisher_reads=reads)
                check.replay(name + '-replay', journal)
                check.live(name + '-live', ['-n', *arguments, '-t', check.dtb, image])
                if profile == 'block' and harts == 2 and finisher == 0:
                    source = journal
        for variant in ('BAD_WIDTH', 'BAD_ADDRESS', 'BAD_WRITE'):
            image = check.guest(variant, [payload], 2, ['-mno-relax', '-D' + variant])
            check.run('reject-' + variant, [check.binary, '-b', '-n', '-t', check.dtb, *full, '--smp=2',
                                            '--diff-record=' + str(check.directory / (variant + '.njr')), image],
                      1, b'NEMU_MULTIDIFF_UNSUPPORTED')
        check.faults(source, corrupt, FIELD_OFFSETS, inspect=True, live=False)
    check.finish('FINISHER')


if __name__ == '__main__':
    main()
