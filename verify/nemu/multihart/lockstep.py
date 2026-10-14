#!/usr/bin/env python3
"""Validate the strict cooperative multi-hart DiffTest runtime and ABI."""
from lib.build import build_host
from lib.harness import Check, parser

NEGATIVE = ('MMIO', 'WFI', 'TIME', 'IRQ', 'FINISHER')
FAULTS = ('gpr', 'fpr', 'csr', 'hart', 'route', 'trap', 'drop', 'address', 'load', 'store')


def main():
    check = Check(parser(__doc__, sanitizers=('undefined',)).parse_args(), 'lockstep')
    for xlen in check.args.xlen:
        check.target(xlen, driver=False)
        binary, directory, reference = check.binary, check.directory, check.reference
        check.environment['NEMU_TEST_REFERENCE'] = str(reference)
        abi = build_host(check.build / 'abi', ['nemu_multidiff_abi.c'], check.args.sanitize)
        proxy = build_host(check.build / 'fault.so', ['nemu_multidiff_fault.c'], check.args.sanitize,
                           ['-shared', '-fPIC'])
        check.run('abi', [abi, reference], markers=b'NEMU_MULTIDIFF_ABI_PASS')
        for harts in (1, 2, 4):
            for variant in ('normal', *NEGATIVE) if harts == 2 else ('normal',):
                normal = variant == 'normal'
                image = check.guest(f'harts{harts}-{variant}', ['nemu_multidiff.S'], harts,
                                    [] if normal else ['-DNEGATIVE_' + variant])
                command = [binary, '-b', '-n', f'--smp={harts}', '--diff-mode=multihart', '--diff=' + str(reference),
                           '-t', check.dtb, '--log=' + str(directory / 'monitor.log'), image]
                check.run(f'harts{harts}-{variant}', command, 0 if normal else 'nonzero',
                          f'seen=0x{(1 << harts) - 1:x} status=OK'.encode() if normal else b'NEMU_MULTIDIFF_FAIL')
                if variant == 'FINISHER':
                    standalone = [item for item in command if not str(item).startswith('--diff')]
                    check.run('standalone-batch-failure', standalone, 'nonzero', b'Finisher: fail')
                if harts == 2 and normal:
                    corrupted = ['--diff=' + str(proxy) if str(item).startswith('--diff=') else item
                                 for item in command]
                    for fault in FAULTS:
                        check.run('fault-' + fault, corrupted, 'nonzero', b'NEMU_MULTIDIFF_FAIL',
                                  environment=dict(NEMU_TEST_FAULT=fault))
                    check.run('bad-abi', corrupted, 'nonzero', b'ABI version/size mismatch',
                              environment=dict(NEMU_TEST_BAD_ABI='1'))
                    check.run('bad-capability', corrupted, 'nonzero', b'memory capability/map mismatch',
                              environment=dict(NEMU_TEST_BAD_CAP='1'))
                    check.run('reject-threaded', [*command[:-1], '--smp-backend=threaded', image], 'nonzero',
                              b'requires --diff, --batch and --smp-backend=rr')
        check.run('missing-ref', [binary, '-b', '--diff-mode=multihart'], 'nonzero', b'requires --diff')
        check.run('invalid-mode', [binary, '--diff-mode=invalid'], 'nonzero', b'--diff-mode requires')
    check.finish('LOCKSTEP')


if __name__ == '__main__':
    main()
