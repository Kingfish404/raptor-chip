"""Run one HS/VS guest payload on native NEMU and the independent Spike simulator."""

from pathlib import Path
import subprocess

from lib.harness import Check, parser, sha256
from lib.build import ROOT


def main():
    arguments = parser(__doc__, repeat=1)
    arguments.set_defaults(xlen=[64])
    arguments.add_argument('--spike', type=Path,
                           default=ROOT / 'nemu/tools/spike-diff/repo/build/spike')
    args = arguments.parse_args()
    if args.xlen != [64]:
        arguments.error('hypervisor runtime check requires RV64')
    if not args.spike.is_file():
        arguments.error('build the bundled Spike before running this check')
    check = Check(args, 'hypervisor-runtime')
    check.details['spike_revision'] = subprocess.check_output(
        ['git', '-C', str(args.spike.parent.parent), 'rev-parse', 'HEAD'], text=True).strip()
    check.details['spike_sha256'] = sha256(args.spike)
    check.target(64, reference=False, driver=False)
    payload, = check.snapshot('nemu_rva23_hypervisor.S')
    image = check.guest('hypervisor', [payload], 1)
    spike_image = check.guest('hypervisor-spike', [payload], 1,
                              defines=('-DSPIKE_HTIF', '-Wl,-N'))
    check.run('spike', [args.spike, '-p1', '-m256',
                        '--isa=rv64gcvh_smstateen_sstc_zicntr_zihpm',
                        spike_image.with_suffix('.elf')], markers=(), timeout=60)
    check.run('nemu', [check.binary, '-b', '-n', '--isa-extensions=rva23',
                       '--smp=1', '-t', check.dtb, image], markers=b'Finisher: poweroff',
              timeout=60)
    check.run('disabled', [check.binary, '-b', '-n', '--smp=1', '-t', check.dtb,
                           image], expect='nonzero', markers=b'Finisher: fail', timeout=60)
    failed_image = check.guest('guest-failure', [payload], 1, defines=('-DFAIL_GUEST',))
    failed_spike = check.guest('guest-failure-spike', [payload], 1,
                               defines=('-DFAIL_GUEST', '-DSPIKE_HTIF', '-Wl,-N'))
    check.run('spike-guest-failure', [args.spike, '-p1', '-m256',
                                     '--isa=rv64gcvh_smstateen_sstc_zicntr_zihpm',
                                     failed_spike.with_suffix('.elf')], expect=5,
              markers=(), timeout=60)
    check.run('nemu-guest-failure', [check.binary, '-b', '-n', '--isa-extensions=rva23',
                                    '--smp=1', '-t', check.dtb, failed_image], expect='nonzero',
              markers=b'Finisher: fail (val=0x53333)', timeout=60)
    check.finish('HYPERVISOR_RUNTIME')


if __name__ == '__main__':
    main()
