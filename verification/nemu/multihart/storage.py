"""Check standalone disk modes and their fail-closed DiffTest boundary."""

import fcntl
import os

from lib.harness import Check, parser, sha256


def main():
    check = Check(parser(__doc__, repeat=1).parse_args(), 'storage')
    payload = check.snapshot('nemu_virtio_start.S', 'nemu_storage.c')
    for xlen in check.args.xlen:
        check.target(xlen, reference=False, driver=False)
        disk = check.directory / 'disk.raw'
        baseline = bytes([0x2b]) * 4096
        changed = baseline[:512] + bytes([0x73]) * 512 + baseline[1024:]
        for mode_index, mode in enumerate(('volatile', 'readonly', 'persistent')):
            for backend in ('rr', 'threaded'):
                name = mode + '-' + backend
                disk.write_bytes(baseline)
                image = check.guest(name, payload, 1, [f'-DSTORAGE_MODE={mode_index}'], c=True)
                command = [check.binary, '-b', '-n', '--smp=1', '--smp-backend=' + backend,
                           '--disk=' + str(disk), '--disk-mode=' + mode, '-t', check.dtb]
                check.run(name, [*command, image], markers=b'Finisher: poweroff')
                check.save(name + '-host-bytes', disk.read_bytes() == (changed if mode == 'persistent' else baseline),
                           disk_sha256=sha256(disk))
                if mode == 'persistent':
                    image = check.guest(name + '-reopen', payload, 1,
                                        ['-DSTORAGE_MODE=2', '-DEXPECT_STORED=1', '-DNEGOTIATE_FLUSH=0'], c=True)
                    check.run(name + '-reopen', [*command, image], markers=b'Finisher: poweroff')
                    check.save(name + '-reopen-bytes', disk.read_bytes() == changed)
        disk.write_bytes(baseline)
        for name, options, message in (
                ('invalid-mode', ['--disk-mode=invalid'], b'--disk-mode requires'),
                ('missing-disk', ['--disk-mode=persistent'], b'--disk-mode requires --disk'),
                ('empty-path', ['--disk='], b'--disk requires a nonempty image path'),
                ('persistent-diff', ['--disk-mode=persistent', '--disk=' + str(disk), '--diff=/unused'],
                 b'DiffTest and journal replay require --disk-mode=volatile'),
                ('readonly-journal', ['--disk-mode=readonly', '--disk=' + str(disk), '--diff-record=/unused'],
                 b'DiffTest and journal replay require --disk-mode=volatile')):
            check.run(name, [check.binary, *options], expect=1, markers=message)
            check.save(name + '-untouched', disk.read_bytes() == baseline)
        for name, path in (('missing', check.directory / 'missing'), ('empty', check.directory / 'empty'),
                           ('directory', check.directory), ('fifo', check.directory / 'fifo')):
            if name == 'empty':
                path.touch()
            elif name == 'fifo':
                os.mkfifo(path)
            check.run('reject-' + name, [check.binary, '-b', '-n', '--disk=' + str(path),
                                         '--disk-mode=persistent', '-t', check.dtb, image],
                      expect=1, markers=b'[virtio-blk] cannot attach')
        with disk.open('rb') as locked:
            fcntl.flock(locked, fcntl.LOCK_SH)
            check.run('writer-lock-conflict', [check.binary, '-b', '-n', '--disk=' + str(disk),
                                               '--disk-mode=persistent', '-t', check.dtb, image],
                      expect=1, markers=b'[virtio-blk] cannot attach')
        check.save('invalid-inputs-untouched', disk.read_bytes() == baseline)
    check.finish('STORAGE')


if __name__ == '__main__':
    main()
