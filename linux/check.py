#!/usr/bin/env python3
"""QEMU smoke/persistence test; all disks are newly created regular files in /tmp."""
import argparse
import json
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import sys

from build_linux import verify


def record_for(artifacts):
    if (artifacts / 'bundle.json').exists():
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fpga/litex/scripts'))
        from netboot_distro_publish import verify as verify_bundle
        record = dict(verify_bundle(artifacts))
        record.update(bits=record['xlen'], profile='netboot', ram_mib=1024)
    else:
        record = verify(artifacts)
    return record


def boot(artifacts, work, phase, disk=None, peers=()):
    record = record_for(artifacts)
    bits, profile = record['bits'], record['profile']
    owner = f'rv{bits}-{record["distro"]}'
    argv = [f'qemu-system-riscv{bits}', '-M', 'virt', '-cpu', f'rv{bits},h=false,sstc=false,svadu=false,zicbom=true',
            '-m', str(record['ram_mib']) + 'M', '-smp', '1', '-nographic',
            '-netdev', 'user,id=net0,restrict=on', '-device', 'virtio-net-device,netdev=net0']
    if profile == 'sim':
        argv += ['-bios', str(artifacts / 'fw_payload.bin')]
    elif profile == 'fpga':
        argv += ['-bios', str(artifacts / 'fw_dynamic.bin'), '-kernel', str(artifacts / 'Image'),
                 '-initrd', str(artifacts / 'rootfs.cpio.gz'), '-append',
                 'console=ttyS0 earlycon=sbi rdinit=/sbin/raptor-init']
    if disk:
        argv += ['-drive', f'file={disk},format=raw,if=none,id=data', '-device', 'virtio-blk-device,drive=data']
    if phase == 'duplicate':
        argv += ['-drive', f'file={work / "duplicate.ext4"},format=raw,if=none,id=duplicate',
                 '-device', 'virtio-blk-device,drive=duplicate']
    if profile == 'netboot':
        # Exercise the actual stage0/OpenSBI/kernel/rootfs bytes and addresses;
        # only the physical hardware description is substituted for QEMU virt.
        dtb = work / ('virt-' + phase + '.dtb')
        dump = list(argv)
        dump[dump.index('virt')] = 'virt,dumpdtb=' + str(dtb)
        subprocess.run(dump + ['-bios', 'none'], check=True, capture_output=True)
        rootfs = record.get('initramfs_file', 'rootfs.cpio.gz')
        for name, value in [('linux,initrd-start', 0x88000000),
                            ('linux,initrd-end', 0x88000000 + (artifacts / rootfs).stat().st_size)]:
            subprocess.run(['fdtput', '-t', 'x', str(dtb), '/chosen', name, '0', f'{value:x}'], check=True)
        subprocess.run(['fdtput', '-t', 's', str(dtb), '/chosen', 'bootargs',
                        'console=ttyS0 earlycon=sbi rdinit=/sbin/raptor-init'], check=True)
        argv += ['-bios', 'none']
        for name, address in json.loads((artifacts / 'boot.json').read_text()).items():
            if name == 'addr':
                continue
            leaf = Path(name).name
            file = dtb if leaf == 'soc.dtb' else artifacts / leaf
            argv += ['-device', f'loader,file={file},addr={address},force-raw=on' +
                     (',cpu-num=0' if leaf == 'stage0.bin' else '')]
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    poll = selectors.DefaultSelector()
    poll.register(process.stdout, selectors.EVENT_READ)
    data, sent, deadline = b'', False, time.monotonic() + 180
    logpath = work / (owner + '-' + profile + '-' + phase + '.log')
    try:
        with logpath.open('wb') as log:
            while time.monotonic() < deadline:
                for key, _ in poll.select(.2):
                    chunk = key.fileobj.read1(65536)
                    data += chunk
                    log.write(chunk); log.flush()
                if not sent and (b'Please press Enter to activate this console' in data or b'buildroot login:' in data):
                    process.stdin.write(b'root\n' if b'buildroot login:' in data else b'\n')
                    process.stdin.flush()
                    time.sleep(.2)
                    checks = 'test "$(uname -m)" = riscv' + str(bits) + '; '
                    if phase == 'first':
                        checks += f'test -s /run/raptor-persist/ready; echo {owner} > /root/raptor-check; echo {owner} > /home/raptor-check; echo shared > /data/shared/{owner}; echo ram > /etc/raptor-check; sync; '
                    elif phase == 'second':
                        checks += f'test "$(cat /root/raptor-check)" = {owner}; test "$(cat /home/raptor-check)" = {owner}; test ! -e /etc/raptor-check; '
                        checks += ''.join(f'test -s /data/shared/{peer}; ' for peer in peers)
                    else:
                        checks += 'test -f /run/raptor-persist/status; test ! -e /run/raptor-persist/ready; grep -q " /data tmpfs ro" /proc/mounts; ! touch /data/must-fail; '
                    checks += 'ip link show eth0; cat /etc/os-release; '
                    command = '( set -eu; ' + checks + '); rc=$?; printf "\\nRAPTOR_CHECK=%s\\n" "$rc"; sync; /bin/busybox poweroff -f\n'
                    process.stdin.write(command.encode()); process.stdin.flush(); sent = True
                if b'Kernel panic' in data or process.poll() is not None:
                    break
            if b'\r\nRAPTOR_CHECK=0\r\n' not in data or b'Kernel panic' in data:
                raise RuntimeError('QEMU check failed; see ' + str(logpath))
        print('PASS:', record['distro'], bits, profile, phase, logpath, flush=True)
    finally:
        poll.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path, nargs='+')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='raptor-chip-linux-check-', dir='/tmp'))
    print('VALIDATION=' + str(work), flush=True)
    disk = work / 'data.ext4'
    with disk.open('wb') as stream:
        stream.truncate(128 * 1024 * 1024)
    subprocess.run(['mke2fs', '-q', '-t', 'ext4', '-L', 'RAPTOR_DATA', str(disk)], check=True)
    artifacts = [p.resolve() for p in args.artifacts]
    peers = [f'rv{r["bits"]}-{r["distro"]}' for r in map(record_for, artifacts)]
    for phase in ('first', 'second'):
        for path in artifacts:
            boot(path, work, phase, disk, peers)
    duplicate = work / 'duplicate.ext4'
    with duplicate.open('wb') as stream:
        stream.truncate(128 * 1024 * 1024)
    subprocess.run(['mke2fs', '-q', '-t', 'ext4', '-L', 'RAPTOR_DATA', str(duplicate)], check=True)
    for path in artifacts:
        boot(path, work, 'no-card')
        boot(path, work, 'duplicate', disk)
    (work / 'result.json').write_text(json.dumps({'artifacts': list(map(str, artifacts)),
                                                'passed': ['first', 'second', 'no-card', 'duplicate'],
                                                'physical_sd_tested': False}, indent=2))


if __name__ == '__main__':
    main()
