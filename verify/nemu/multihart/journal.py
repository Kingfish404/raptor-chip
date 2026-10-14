#!/usr/bin/env python3
"""Exercise real pthread transaction recording and independent memory replay."""
from lib.harness import Check, parser, sha256
from lib.journal import ACCESS, ACCESS_KIND, JournalError, check_journal, read_events, write_events

NEGATIVE = ('MMIO', 'WFI', 'TIME', 'IRQ', 'FINISHER')


def corrupt_load(source, destination):
    """Flip one bit of the first recorded load value."""
    header, events = read_events(source)
    event = next(event for event in events if event[0] == ACCESS_KIND and not ACCESS.unpack(event[3])[3])
    event[3][8] ^= 1
    write_events(destination, header, events)


def main():
    check = Check(parser(__doc__).parse_args(), 'journal')
    for xlen in check.args.xlen:
        check.target(xlen, reference=False, driver=False)
        binary, directory, dtb = check.binary, check.directory, check.dtb
        interleaved = False
        for harts in (1, 2, 4):
            for variant in ('normal', *NEGATIVE) if harts == 2 else ('normal',):
                normal = variant == 'normal'
                image = check.guest(f'harts{harts}-{variant}', ['nemu_multidiff.S'], harts,
                                    [] if normal else ['-DNEGATIVE_' + variant])
                for backend in ('rr', 'threaded'):
                    for repeat in range(check.args.repeat if backend == 'threaded' and normal else 1):
                        name = f'harts{harts}-{variant}-{backend}-{repeat}'
                        options = [f'--smp={harts}', '--smp-backend=' + backend]
                        journal, _ = check.record(name, options, image, expect=0 if normal else 1,
                                                  markers=b'status=OK' if normal else b'NEMU_JOURNAL_FAIL')
                        try:
                            replay = check_journal(journal)
                            details = dict(replay=replay)
                            interleaved |= backend == 'threaded' and replay['interleaved_accesses'] > 0
                        except (JournalError, OSError) as error:
                            replay, details = None, dict(replay_error=str(error))
                        check.save(name + '-inspect', (replay is not None) == normal, **details)
                        if normal and harts == 2 and backend == 'threaded' and repeat == 0:
                            fault = directory / 'corrupt-load.njr'
                            corrupt_load(journal, fault)
                            try:
                                check_journal(fault)
                                rejected = False
                            except JournalError as error:
                                rejected = 'load mismatch' in str(error)
                            check.save('reject-corrupt-load', rejected)
                            digest = sha256(journal)
                            check.run('reject-overwrite', [binary, '-b', '-n', *options,
                                                           '--diff-record=' + str(journal), '-t', dtb, image],
                                      'nonzero', b'refuses to overwrite')
                            check.save('overwrite-left-journal', sha256(journal) == digest)
        check.save('observed-interleaving', interleaved)
        for limit in (64, 200000):
            journal = directory / f'limit{limit}.njr'
            output = check.run(f'bounded-journal-{limit}', [binary, '-b', '--smp=2', '--smp-backend=threaded',
                                                           '--diff-record=' + str(journal),
                                                           f'--diff-record-max-bytes={limit}', '-t', dtb,
                                                           directory / 'harts2-normal.bin'], 1, b'byte limit reached')
            check.save(f'bounded-journal-{limit}-size', journal.stat().st_size <= limit
                       and (limit == 64 or b'NEMU_THREAD hart=' in output))
        for name, options, marker in (
                ('requires-batch', ['--diff-record=' + str(directory / 'unused.njr')], b'requires --batch'),
                ('reject-diff', ['-b', '--diff-mode=multihart', '--diff-record=unused'], b'no --diff'),
                ('invalid-limit', ['--diff-record-max-bytes=-1'], b'requires 64..')):
            check.run(name, [binary, *options], 'nonzero', marker)
    check.finish('JOURNAL')


if __name__ == '__main__':
    main()
