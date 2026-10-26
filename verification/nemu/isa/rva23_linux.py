"""Boot RVA23 Linux and exercise user extensions, context switching and KVM."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from lib.build import ROOT, build_nemu
from lib.console import run_console as run_logged_console
from lib.harness import sha256

sys.path.insert(0, str(ROOT / 'linux'))
from build_linux import lock, overlay
from distro_boot import build_dtb
from raptor_linux import kernel


PASS_MARKERS = (b'RVA23_VECTOR_PASS', b'RVA23_CACHE_BLOCK_PASS', b'RVA23_POINTER_MASK_PASS', b'RVA23_KVM_PASS',
                b'RVA23_LINUX_PASS', b'Finisher: poweroff')
FAIL_MARKERS = (b'RVA23_LINUX_FAIL', b'Kernel panic', b'Oops:', b'BUG:')


def verdict(returncode, output, timed_out=False, harts=1):
    return (not timed_out and returncode == 0 and
            all(marker in output for marker in PASS_MARKERS) and
            (harts == 1 or f'RVA23_SMP_PASS harts={harts} workers={2 * harts}\n'.encode() in
             output.replace(b'\r\n', b'\n')) and
            not any(marker in output for marker in FAIL_MARKERS))


def run_console(command, log_path, timeout):
    return run_logged_console(command, log_path, timeout, failure_markers=FAIL_MARKERS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    kernels = parser.add_mutually_exclusive_group(required=True)
    kernels.add_argument('--kernel', type=Path,
                         help='RV64 kernel Image with V, SUPM, Zicboz, KVM and embedded /dev directory')
    kernels.add_argument('--kernel-package', type=Path,
                         help='pinned RV64 release package from which to build a NEMU RVA23 kernel')
    parser.add_argument('--kernel-cache', type=Path, default=ROOT / 'linux/build/netboot-kernels')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--harts', type=int, choices=(1, 2, 3, 4), default=1)
    parser.add_argument('--cross-compile', default='riscv64-linux-gnu-')
    args = parser.parse_args()
    if (args.kernel and not args.kernel.is_file()) or args.timeout <= 0:
        parser.error('requires an existing kernel and a positive timeout')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    session = Path(tempfile.mkdtemp(prefix='run-', dir=args.output))
    kernel_config = None
    if args.kernel_package:
        with lock(args.kernel_cache / 'build.lock'):
            built = kernel(args.kernel_package.resolve(), args.kernel_cache.resolve(),
                           args.cross_compile, profile='nemu-rva23')
        args.kernel = built / 'arch/riscv/boot/Image'
        kernel_config = built / '.config'
    binary = build_nemu(args.output / 'nemu')
    sources = []
    for suffix in ('.c', '_start.S'):
        source = ROOT / f'app/tests/linux/nemu_rva23{suffix}'
        snapshot = session / source.name
        shutil.copyfile(source, snapshot)
        sources.append(snapshot)
    probe = session / 'probe'
    subprocess.run([args.cross_compile + 'gcc', '-nostdlib', '-static', '-fno-pie', '-no-pie',
                    '-fno-builtin', '-fno-stack-protector', '-fno-tree-vectorize', '-mno-relax',
                    '-march=rv64gcv', '-mabi=lp64d', '-O2', '-Wall', '-Wextra', '-Werror',
                    f'-DRVA23_TEST_HARTS={args.harts}',
                    *map(str, sources), '-o', str(probe)], check=True)
    initrd = overlay(b'', {'rva23-check': probe.read_bytes()})
    kernel_digest = sha256(args.kernel)
    firmware = args.output / ('opensbi-' + kernel_digest)
    with (session / 'firmware.log').open('w') as log:
        subprocess.run(['make', '-C', str(ROOT / 'third_party/riscv-software-src/opensbi'),
                        'CROSS_COMPILE=' + args.cross_compile,
                        'PLATFORM_RISCV_ISA=rv64imafdc_zicntr_zicsr_zifencei',
                        'PLATFORM_RISCV_XLEN=64', 'PLATFORM=generic', f'O={firmware}',
                        f'FW_PAYLOAD_PATH={args.kernel.resolve()}', 'FW_PAYLOAD_FDT_ADDR=0x8fff0000',
                        '-j8'], check=True, stdout=log, stderr=subprocess.STDOUT)
    payload = firmware / 'platform/generic/firmware/fw_payload.bin'
    initrd_offset = 0x4000000
    if payload.stat().st_size >= initrd_offset:
        raise RuntimeError('kernel firmware overlaps the test initramfs at 0x84000000')
    image = session / 'image.bin'
    with image.open('wb') as output, payload.open('rb') as source:
        shutil.copyfileobj(source, output)
        output.seek(initrd_offset)
        output.write(initrd)
    build_dtb(session, args.harts, source_name='spike-rva23-nemu.dts')
    dtb = session / 'nemu.dtb'
    for name, address in (('linux,initrd-start', 0x84000000),
                          ('linux,initrd-end', 0x84000000 + len(initrd))):
        subprocess.run(['fdtput', '-t', 'x', str(dtb), '/chosen', name, '0', f'{address:x}'], check=True)
    subprocess.run(['fdtput', '-t', 's', str(dtb), '/chosen', 'bootargs',
                    'console=ttyS0 earlycon=sbi unaligned_scalar_speed=fast '
                    'random.trust_bootloader=on cryptomgr.notests=1 '
                    'initcall_blacklist=jent_mod_init,raid6_select_algo rdinit=/rva23-check'], check=True)
    command = [str(binary), '-b', '-n', '--isa-extensions=rva23', f'--smp={args.harts}', '--smp-backend=rr',
               '-t', str(dtb), str(image)]
    log_path = session / 'console.log'
    returncode, timed_out = run_console(command, log_path, args.timeout)
    output = log_path.read_bytes()
    passed = verdict(returncode, output, timed_out, args.harts)
    report = dict(passed=passed, timed_out=timed_out, returncode=returncode, command=command, harts=args.harts,
                  kernel_sha256=kernel_digest, native_sha256=sha256(binary),
                  native_config_sha256=sha256(args.output / 'nemu/.config'),
                  firmware_sha256=sha256(payload), dtb_sha256=sha256(dtb),
                  source_sha256={path.name: sha256(path) for path in sources},
                  probe_sha256=sha256(probe), log=str(log_path))
    if kernel_config:
        shutil.copyfile(kernel_config, session / 'kernel.config')
        report['kernel_config_sha256'] = sha256(kernel_config)
        report['kernel_package_manifest_sha256'] = sha256(args.kernel_package / 'manifest.json')
    (session / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'NEMU_RVA23_LINUX {"PASS" if passed else "FAIL"} results={session / "results.json"}')
    return not passed


if __name__ == '__main__':
    raise SystemExit(main())
