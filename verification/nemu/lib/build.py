"""Private NEMU builds plus guest and host compilation for the NEMU checks."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'linux'))
from distro_boot import build_dtb, build_nemu, nemu_build_flags  # noqa: E402

__all__ = ['ROOT', 'build_dtb', 'build_host', 'build_nemu', 'build_production_harness', 'build_reference', 'build_replay_driver',
           'compile_guest', 'dtb_path', 'guest_source', 'nemu_build_flags']

GUEST_CFLAGS = ['-O2', '-ffreestanding', '-fno-builtin', '-fno-stack-protector', '-mcmodel=medany',
                '-mno-relax', '-Wall', '-Wextra', '-Werror']


def build_reference(native, directory, xlen, sanitize=None):
    """Build the shared-library reference with the native build's configuration."""
    directory.mkdir(parents=True, exist_ok=True)
    nemu = ROOT / 'nemu'
    for name in ('src', 'configs'):
        if not (directory / name).exists():
            (directory / name).symlink_to(nemu / name, target_is_directory=True)
    config = (native / '.config').read_text()
    config = config.replace('CONFIG_TARGET_NATIVE_ELF=y', '# CONFIG_TARGET_NATIVE_ELF is not set')
    config = config.replace('# CONFIG_TARGET_SHARE is not set', 'CONFIG_TARGET_SHARE=y')
    config = config.replace('CONFIG_DEVICE=y', '# CONFIG_DEVICE is not set')
    config = config.replace('CONFIG_ROM_DTB=y', '# CONFIG_ROM_DTB is not set')
    private = directory / 'reference_defconfig'
    private.write_text(config)
    environment = dict(os.environ, NEMU_HOME=str(nemu))
    with (directory / 'build.log').open('w') as log:
        for operation in ('--defconfig=' + str(private), '--syncconfig'):
            subprocess.run([nemu / 'tools/kconfig/build/conf', '-s', operation, nemu / 'Kconfig'],
                           cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['make', '-f', nemu / 'Makefile', '-j4', 'app',
                        'BUILD_DIR=' + str(directory / 'build'), *nemu_build_flags(sanitize)],
                       cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    return directory / f'build/riscv{xlen}-nemu-interpreter-so'


def build_host(output, sources, sanitize=None, flags=()):
    """Compile a host test program against NEMU's public headers."""
    subprocess.run(['cc', '-Wall', '-Werror', '-pthread', *flags,
                    *(['-fsanitize=' + sanitize] if sanitize else []),
                    '-I' + str(ROOT / 'nemu/include'),
                    *[str(ROOT / 'app/tests/host' / source) for source in sources],
                    '-ldl', '-o', str(output)], check=True)
    return output


def build_replay_driver(output, sanitize=None):
    return build_host(output, ['nemu_journal_replay.c'], sanitize)


def compile_guest(elf, sources, xlen, harts, defines=(), c=False):
    """Link a bare-metal payload at 0x80000000 and return its raw image."""
    image = elf.with_suffix('.bin')
    subprocess.run(['riscv64-linux-gnu-gcc', *(GUEST_CFLAGS if c else []), '-nostdlib', '-static',
                    '-fno-pie', '-no-pie', f'-march=rv{xlen}gc', '-mabi=' + ('lp64d' if xlen == 64 else 'ilp32d'),
                    '-Wl,-Ttext=0x80000000', '-Wl,--build-id=none', f'-DHARTS={harts}', *defines,
                    *map(str, sources), '-o', str(elf)], check=True)
    subprocess.run(['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(image)], check=True)
    return image


def guest_source(name):
    return ROOT / 'app/tests/baremetal' / name


def dtb_path(xlen):
    return ROOT / f'nemu/src/memory/rom/spike-rv{xlen}gc-nemu.dtb'


def build_production_harness(output, sources, configured, sanitize='undefined'):
    """Link a host test against production NEMU sources configured like ``configured``."""
    platform_flags = ['-mcmodel=large'] if os.uname().machine == 'x86_64' else []
    command = ['cc', '-O1', '-g', '-Wall', '-Werror', '-fsanitize=' + sanitize, '-fno-sanitize-recover=all',
               '-D__GUEST_ISA__=riscv', '-pthread', '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
               *platform_flags, '-I' + str(configured / 'include'), '-I' + str(ROOT / 'nemu/include'),
               '-I' + str(ROOT / 'nemu/src/isa/riscv/include'), *[str(ROOT / source) for source in sources],
               '-o', str(output)]
    with output.with_suffix('.build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return output
