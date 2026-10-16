"""Check single-hart RVA23 vector memory, hypervisor CSRs and live Sstc timing."""

from lib.harness import Check, parser


def main():
    arguments = parser(__doc__, repeat=1)
    arguments.set_defaults(xlen=[64])
    args = arguments.parse_args()
    if args.xlen != [64]:
        arguments.error('RVA23 runtime check requires RV64')
    check = Check(args, 'rva23-runtime')
    check.target(64, reference=False, driver=False)
    payload, timing = check.snapshot('nemu_rva23_sstc.S', 'nemu_rva23_diel.S')
    image = check.guest('sstc', [payload], 1)
    check.run('sstc', [check.binary, '-b', '-n', '--isa-extensions=rva23',
                      '--smp=1', '-t', check.dtb, image], markers=b'Finisher: poweroff',
              timeout=60)
    check.run('disabled', [check.binary, '-b', '-n', '--smp=1', '-t', check.dtb,
                           image], expect='nonzero', markers=b'Finisher: fail', timeout=60)
    timing_image = check.guest('diel', [timing], 1, defines=('-march=rv64gcv_zbc',))
    check.run('diel', [check.binary, '-b', '-n', '--isa-extensions=rva23',
                      '--smp=1', '--smp-backend=rr', '-t', check.dtb, timing_image],
              markers=b'Finisher: poweroff', timeout=60)
    for ordering, options in (('profile-first', ['--isa-extensions=rva23', '--smp-backend=threaded']),
                              ('backend-first', ['--smp-backend=threaded', '--isa-extensions=rva23'])):
        check.run('wall-clock-' + ordering, [check.binary, '-b', '-n', '--smp=1', *options, image],
                  expect='nonzero', markers=b'RVA23 requires instruction-count timing', timeout=10)
    check.run('disable-profile-clock', [check.binary, '-b', '-n', '--smp=1',
                                        '--smp-backend=threaded', '--isa-extensions=rva23',
                                        '--isa-extensions=none', '-t', check.dtb, image],
              expect='nonzero', markers=b'Finisher: fail', timeout=60)
    check.finish('RVA23_RUNTIME')


if __name__ == '__main__':
    main()
