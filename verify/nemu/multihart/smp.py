#!/usr/bin/env python3
"""Build isolated RV32/RV64 NEMU and exercise 1..4-hart programs on both SMP backends."""
from lib.build import build_production_harness
from lib.harness import Check, parser

DEVICE_SOURCES = ['nemu/src/cpu/smp.c', 'nemu/src/cpu/thread.c', 'nemu/src/device/timer.c',
                  'nemu/src/device/intr.c', 'nemu/src/isa/riscv/system/pmp.c']
HARNESSES = {'rr': ['app/tests/host/nemu_smp_devices.c'],
             'threaded': ['nemu/src/device/io/map.c', 'nemu/src/device/io/mmio.c', 'nemu/src/memory/paddr.c',
                          'nemu/src/utils/timer.c', 'app/tests/host/nemu_threaded_bus.c']}


def main():
    arguments = parser(__doc__)
    arguments.add_argument('--backend', choices=tuple(HARNESSES), nargs='+', default=list(HARNESSES))
    check = Check(arguments.parse_args(), 'smp')
    for xlen in check.args.xlen:
        check.target(xlen, reference=False, driver=False)
        binary, directory = check.binary, check.directory
        for backend in check.args.backend:
            harness = build_production_harness(check.build / f'devices-{backend}', DEVICE_SOURCES + HARNESSES[backend],
                                               check.build / 'nemu', check.args.sanitize or 'undefined')
            for harts in (2, 3, 4):
                check.run(f'devices-{backend}-harts{harts}', [harness, harts], markers=(), timeout=60)
        for harts in (1, 2, 3, 4):
            image = check.guest(f'harts{harts}', ['nemu_smp.S'], harts)
            for backend in check.args.backend:
                for repeat in range(check.args.repeat if backend == 'threaded' else 1):
                    markers = [b'NEMU_SMP_BAREMETAL_PASS']
                    if backend == 'threaded':
                        markers.append(f'NEMU_THREADED harts={harts} '.encode())
                    check.run(f'harts{harts}-{backend}-{repeat}',
                              [binary, '-b', '-n', f'--smp={harts}', '--smp-backend=' + backend, '-t', check.dtb,
                               '--log=' + str(directory / f'harts{harts}-monitor.log'), image],
                              markers=markers, environment=dict(NEMU_STATUS_DIR=str(directory)))
        for invalid in ('0', '5', '-1', '2junk', ''):
            check.run(f'reject-smp-{invalid or "empty"}', [binary, '--smp=' + invalid], 'nonzero', b'--smp requires')
        for name, option, message in (('backend', '--smp-backend=invalid', b'--smp-backend requires'),
                                      ('threaded-interactive', '--smp-backend=threaded', b'requires --batch'),
                                      ('clock-div-low', '--smp-clock-div=0', b'--smp-clock-div requires'),
                                      ('clock-div-high', '--smp-clock-div=1001', b'--smp-clock-div requires')):
            check.run('reject-' + name, [binary, option], 'nonzero', message)
    check.finish('SMP')


if __name__ == '__main__':
    main()
