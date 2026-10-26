"""Check host throughput accounting separately from WFI guest-clock advances."""

import re
import time

from lib.harness import Check, parser


def main():
    args = parser(__doc__, repeat=1).parse_args()
    check = Check(args, 'stats')
    payload, = check.snapshot('nemu_execution_stats.S')
    for xlen in args.xlen:
        check.target(xlen, reference=False, driver=False)
        image = check.guest('idle', [payload], 1)
        for backend in ('rr', 'threaded'):
            started = time.monotonic_ns()
            output = check.run(backend, [check.binary, '-b', '-n', '--smp=1',
                                        '--smp-backend=' + backend, '-t', check.dtb, image],
                               markers=b'Finisher: poweroff', environment={'LC_ALL': 'C'})
            elapsed = (time.monotonic_ns() - started) // 1000
            stats = {}
            for name in ('host time spent', 'total guest instructions', 'guest clock steps', 'simulation frequency'):
                matches = re.findall(name.encode() + rb' = (\d+)', output)
                if matches:
                    stats[name] = int(matches[-1])
            passed = len(stats) == 4
            if passed:
                instructions = stats['total guest instructions']
                host = stats['host time spent']
                steps = stats['guest clock steps']
                passed &= 0 < host <= elapsed and 0 < instructions < 1000
                passed &= host > 0 and stats['simulation frequency'] == instructions * 1_000_000 // host
                passed &= steps > instructions * 100 if backend == 'rr' else steps == instructions
            check.save(backend + '-statistics', passed, statistics=stats, elapsed_us=elapsed)
    check.finish('STATS')


if __name__ == '__main__':
    main()
