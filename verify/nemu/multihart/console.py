#!/usr/bin/env python3
"""Check actual UART routing while per-instruction DiffTest progress is enabled."""
import hashlib

from lib.harness import Check, parser, sha256
from lib.stream import supervise


def assess_output(result, output, expected, stdout):
    names = ('dut.log', 'dut.stderr', 'ref.log', 'ref.stderr')
    logs = {name: (output / name).read_bytes() for name in names if (output / name).is_file()}
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in logs.items()}
    if result.get('status') != 'OK' or len(logs) != len(names):
        return False, hashes
    destination = logs['dut.log' if stdout else 'dut.stderr']
    other = logs['dut.stderr' if stdout else 'dut.log']
    passed = expected in destination and b'NEMU_UART_OUTPUT hart=' not in other
    passed &= (b'NEMU_JOURNAL_PROGRESS' in logs['dut.stderr']) == stdout
    passed &= b'NEMU_JOURNAL_PROGRESS' not in logs['dut.log']
    passed &= all(b'runtime error:' not in data and b'WARNING: ThreadSanitizer' not in data for data in logs.values())
    summaries = result.get('summaries') or {}
    passed &= all((summaries.get(role) or {}).get('uart_tx') == len(expected) for role in ('dut', 'ref'))
    return bool(passed), hashes


def main():
    arguments = parser(__doc__, repeat=1)
    arguments.add_argument('--pipe-bytes', type=int, default=65536)
    args = arguments.parse_args()
    if not 4096 <= args.pipe_bytes <= 1048576:
        arguments.error('--pipe-bytes must be 4096..1048576')
    check = Check(args, 'console')
    payload, = check.snapshot('nemu_uart_output.S')
    for xlen in check.args.xlen:
        check.target(xlen)
        for harts in (1, 2, 4):
            image = check.guest(f'harts{harts}', [payload], harts, ['-mno-relax'])
            expected = ''.join(f'NEMU_UART_OUTPUT hart={hart}\n' for hart in range(harts)).encode()
            for stdout in (False, True):
                name = f'harts{harts}-' + ('stdout-progress' if stdout else 'legacy')
                output = check.directory / name
                arguments = ['-n', '--diff-uart', '--diff-tlb=retain', '--smp-backend=threaded', f'--smp={harts}',
                             *(['--serial-stdout', '--diff-progress=1'] if stdout else []),
                             '-t', str(check.dtb), str(image)]
                result = supervise(check.binary, check.reference, check.driver, arguments, output, timeout=180,
                                   pipe_bytes=check.args.pipe_bytes, prefix=check.prefix,
                                   environment=check.environment, separate_stderr=True)
                passed, log_hashes = assess_output(result, output, expected, stdout)
                check.save(name, passed, result=result, image_sha256=sha256(image), logs_sha256=log_hashes)
    check.finish('CONSOLE')


if __name__ == '__main__':
    main()
