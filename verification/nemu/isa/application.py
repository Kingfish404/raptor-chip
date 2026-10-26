"""Build, stage, relocate and exercise the standalone application and reference SDK."""

import json
from pathlib import Path
import shutil
import subprocess

from lib.build import ROOT
from lib.harness import Check, parser, sha256


def main():
    arguments = parser(__doc__, repeat=1, sanitizers=())
    args = arguments.parse_args()
    if args.sanitize or args.disable_aslr:
        arguments.error('application packaging checks use the shipped build presets')
    check = Check(args, 'application')
    for variable in ('NEMU_HOME', 'RAPTOR_HOME', 'AM_HOME'):
        check.environment.pop(variable, None)
    original_config = ROOT / 'nemu/.config'
    before = sha256(original_config) if original_config.exists() else None
    staging = check.session / 'staging'
    prefix = check.session / 'relocated prefix'
    for xlen in args.xlen:
        check.xlen = xlen
        check.directory = check.session / f'rv{xlen}'
        check.directory.mkdir()
        for kind, config in (('native', f'riscv{xlen}_vm_defconfig'), ('ref', f'riscv{xlen}_ref_defconfig')):
            output = check.work / f'{kind}{xlen}'
            command = ['make', '-C', str(ROOT / 'nemu'), 'O=' + str(output)]
            with (check.directory / (kind + '-build.log')).open('w') as log:
                for options in ([config], ['-j4', 'install', 'PREFIX=/opt/nemu', 'DESTDIR=' + str(staging)]):
                    subprocess.run([*command, *options], stdout=log, stderr=subprocess.STDOUT,
                                   check=True, env=check.environment)
    shutil.move(staging / 'opt/nemu', prefix)
    launcher = prefix / 'bin/nemu'
    for xlen in args.xlen:
        check.xlen = xlen
        check.directory = check.session / f'rv{xlen}'
        binary_name = f'riscv{xlen}-nemu-interpreter'
        check.hashes = {'native_sha256': sha256(prefix / 'libexec/nemu' / binary_name),
                        'reference_sha256': sha256(prefix / 'lib/nemu' / (binary_name + '-so'))}
        output = check.run('relocated-info', [launcher, 'info', '--xlen', xlen], markers=())
        machine = json.loads(output)
        check.save('capabilities', machine['xlen'] == xlen and machine['vm_boot'] and
                   machine['max_harts'] == 4 and 'block' in machine['devices'] and
                   machine['memory']['size'] == (0x40000000 if xlen == 64 else 0x10000000), machine=machine)
        abi = check.directory / 'abi'
        include = prefix / 'include/nemu' / (binary_name + '-so')
        subprocess.run(['cc', '-Wall', '-Werror', '-I' + str(include),
                        str(ROOT / 'app/tests/host/nemu_multidiff_abi.c'), '-ldl', '-o', str(abi)], check=True)
        check.run('installed-reference-abi', [abi, prefix / 'lib/nemu' / (binary_name + '-so')],
                  markers=b'NEMU_MULTIDIFF_ABI_PASS')
        headers = check.directory / 'headers.c'
        headers.write_text('\n'.join('#include <' + path.name + '>' for path in sorted(include.glob('*.h'))) +
                           '\nint main(void) { return DIFFTEST_REG_SIZE != ' + str((xlen // 8) * 33) + '; }\n')
        subprocess.run(['cc', '-Wall', '-Werror', '-I' + str(include), str(headers), '-o', str(abi)], check=True)
        check.run('installed-headers', [abi], markers=())
        for harts in (1, 2, 4):
            image = check.guest(f'smp{harts}', ['nemu_smp.S'], harts)
            for backend in ('rr', 'threaded'):
                name = f'smp{harts}-{backend}'
                check.run(name, [launcher, 'run', '--xlen', xlen, '--harts', harts,
                                '--backend', backend, '--firmware', image,
                                '--state-dir', check.directory / name],
                          markers=(b'NEMU_SMP_BAREMETAL_PASS', b'Finisher: poweroff'), stdin=b'')
            if xlen == 64:
                name = f'smp{harts}-rva23'
                check.run(name, [launcher, 'run', '--harts', harts, '--isa-profile', 'rva23',
                                '--firmware', image, '--state-dir', check.directory / name],
                          markers=(b'NEMU_SMP_BAREMETAL_PASS', b'Finisher: poweroff'), stdin=b'')
        check.run('bad-profile-backend', [launcher, 'run', '--xlen', xlen, '--harts', 2,
                                        '--backend', 'threaded', '--isa-profile', 'rva23', '--firmware', image],
                  expect=2, markers=b'nemu:')
        check.save('installed-configs', all((prefix / 'share/nemu/configs' / (name + '.config')).is_file()
                   for name in (binary_name, binary_name + '-so')))
    after = sha256(original_config) if original_config.exists() else None
    check.save('source-config-unchanged', before == after, config_sha256=after, prefix=str(prefix))
    check.finish('APPLICATION')


if __name__ == '__main__':
    main()
