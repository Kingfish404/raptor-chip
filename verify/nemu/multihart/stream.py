#!/usr/bin/env python3
"""Validate bounded live multicore NEMU ISA checking and transport failures."""
import os
import struct
import subprocess

from lib.harness import Check, clean, parser, sha256
from lib.journal import END, HEADER, RECORD, STATE, records
from multihart.replay import mutate_journal

REASONS = {'gpr': 'architectural or reservation state mismatch',
           'consistent-store': 'store value mismatch before reference write',
           'truncated': 'truncated event payload', 'trailing': 'trailing data or read error'}


def check_progress(journal, output, interval):
    reported = [dict((key, int(value, 0)) for key, value in
                     (field.split('=', 1) for field in line.split()[1:]))
                for line in output.decode(errors='replace').splitlines()
                if line.startswith('NEMU_JOURNAL_PROGRESS ')]
    expected = []
    with journal.open('rb') as stream:
        harts = HEADER.unpack(stream.read(HEADER.size))[3]
        counts, pcs = [0] * harts, [0] * harts
        size = HEADER.size
        for kind, sequence, hart, instruction, payload in records(stream):
            size += RECORD.size + len(payload)
            if kind == STATE:
                pcs[hart] = struct.unpack_from('<Q', payload)[0]
            if kind != END:
                continue
            for offset in range(32, len(payload), 16):
                slot, value = struct.unpack_from('<2Q', payload, offset)
                if slot == 0:
                    pcs[hart] = value
            counts[hart] += 1
            retired = sum(counts)
            if interval and retired % interval == 0:
                fields = dict(retired=retired, events=sequence + 1, bytes=size)
                for index in range(harts):
                    fields[f'hart{index}_retired'] = counts[index]
                    fields[f'hart{index}_pc'] = pcs[index]
                expected.append(fields)
    return reported == expected


def main():
    arguments = parser(__doc__)
    arguments.add_argument('--long', action='store_true', help='also check a stream larger than 256 MiB')
    check = Check(arguments.parse_args(), 'stream')
    check.timeout = 300

    def direct(name, command, descriptors=(), required=b'pipe descriptor'):
        command = list(map(str, [*check.prefix, *command]))
        completed = subprocess.run(command, pass_fds=descriptors, env=check.environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        log = check.directory / (name + '.log')
        log.write_bytes(completed.stdout)
        check.save(name, completed.returncode == 1 and required in completed.stdout and clean(completed.stdout),
                   command=command, returncode=completed.returncode, log=str(log), log_sha256=sha256(completed.stdout))

    def live(name, image, harts, backend='threaded', extra=(), accepted=True, producer=None):
        return check.live(name, ['-n', f'--smp={harts}', '--smp-backend=' + backend, '-t', check.dtb, *extra, image],
                          accepted, producer, reference_rejects=producer is not None)

    for xlen in check.args.xlen:
        check.target(xlen)
        binary, directory, dtb, driver, reference = check.binary, check.directory, check.dtb, check.driver, check.reference
        overlap = False
        for harts in (1, 2, 4):
            image = check.guest(f'harts{harts}', ['nemu_multidiff.S'], harts)
            for backend in ('rr', 'threaded'):
                for repeat in range(check.args.repeat if backend == 'threaded' else 1):
                    result = live(f'harts{harts}-{backend}-{repeat}', image, harts, backend)
                    overlap |= result['summaries']['ref']['interleaved'] > 0
        check.save('observed-interleaving', overlap)
        for harts in (2, 4):
            image = check.guest(f'harts{harts}-faults', ['nemu_multidiff.S'], harts, ['-DREPLAY_FAULTS'])
            for backend in ('rr', 'threaded'):
                live(f'harts{harts}-faults-{backend}', image, harts, backend)
        image = check.guest('transport', ['nemu_multidiff.S'], 2)
        progress_dtb = directory / 'progress.dtb'
        progress_dtb.write_bytes(dtb.read_bytes())
        subprocess.run(['fdtput', '-d', str(progress_dtb), '/chosen', 'rng-seed'], check=True)
        baseline = None
        for interval in (0, 1, 17, 1 << 40):
            journal = directory / f'progress-{interval}.njr'
            output = check.run(f'progress-{interval}', [binary, '-b', '-n', '--smp=2', '--smp-backend=rr', '-t',
                                                       progress_dtb, '--diff-record=' + str(journal),
                                                       f'--diff-progress={interval}', image])
            digest = sha256(journal)
            baseline = baseline or digest
            check.save(f'progress-{interval}-reports', digest == baseline and check_progress(journal, output, interval),
                       journal_sha256=digest)
        for backend in ('rr', 'threaded'):
            live('progress-live-' + backend, image, 2, backend, extra=['--diff-progress=17'])
        for number, value in enumerate(('', '-1', '+1', '1x', '1.5', '1099511627777', '18446744073709551616')):
            direct(f'progress-invalid-{number}', [binary, '--diff-progress=' + value],
                   required=b'--diff-progress requires 0..')
        direct('progress-without-transport', [binary, '--diff-progress=1'],
               required=b'requires --diff-record or --diff-stream-fd')
        for limit in (64, 200000):
            live(f'quota-{limit}', image, 2, extra=[f'--diff-record-max-bytes={limit}'], accepted=False)
        base = [binary, '-b', '-n', '--smp=2', '--smp-backend=threaded', '-t', dtb]
        read_fd, write_fd = os.pipe()
        try:
            direct('dut-read-fd', [*base, f'--diff-stream-fd={read_fd}', image], (read_fd,))
            direct('ref-write-fd', [driver, reference, f'--fd={write_fd}'], (write_fd,))
            os.set_blocking(write_fd, False)
            direct('dut-nonblocking', [*base, f'--diff-stream-fd={write_fd}', image], (write_fd,))
            os.set_blocking(read_fd, False)
            direct('ref-nonblocking', [driver, reference, f'--fd={read_fd}'], (read_fd,))
            os.set_blocking(write_fd, True)
        finally:
            os.close(read_fd)
        try:
            direct('dut-disconnected', [*base, f'--diff-stream-fd={write_fd}', image], (write_fd,),
                   b'NEMU_JOURNAL_FAIL')
        finally:
            os.close(write_fd)
        regular = directory / 'regular-file'
        regular.write_bytes(b'preserve')
        with regular.open('ab') as stream:
            direct('dut-regular-file', [*base, f'--diff-stream-fd={stream.fileno()}', image], (stream.fileno(),))
        with regular.open('rb') as stream:
            direct('ref-regular-file', [driver, reference, f'--fd={stream.fileno()}'], (stream.fileno(),))
        check.save('regular-file-preserved', regular.read_bytes() == b'preserve')
        direct('dut-invalid-fd', [*base, '--diff-stream-fd=999999', image])
        direct('ref-invalid-fd', [driver, reference, '--fd=999999'])
        journal = directory / 'fault-source.njr'
        check.run('file-capture-compatibility', [*base, '--diff-record=' + str(journal), image])
        check.replay('file-replay-compatibility', journal)
        for fault, reason in REASONS.items():
            corrupted = directory / (fault + '.njr')
            mutate_journal(journal, corrupted, fault)
            live('stream-fault-' + fault, corrupted, 2, accepted=False, producer=check.producer())
            check.save('detected-' + fault, reason in (directory / ('stream-fault-' + fault) / 'ref.log').read_text())
        if check.args.long and xlen == 64:
            image = check.guest('long', ['nemu_multidiff.S'], 4, ['-DNEMU_MULTIDIFF_ITERATIONS=8192'])
            result = live('long', image, 4)
            check.save('long-bounded', result['summaries']['ref']['bytes'] > 256 << 20
                       and result['stdio_pipe_capacity_bytes'] == 135168)
    check.finish('STREAM')


if __name__ == '__main__':
    main()
