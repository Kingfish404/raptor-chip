#!/usr/bin/env python3
"""Standard EBBR/UEFI boot chain and zero-modification Ubuntu .img tooling.

Supports booting unmodified upstream Ubuntu RISC-V .img images (GPT + ESP +
GRUB BOOTRISCV64.EFI + upstream vmlinuz/initrd.img + ext4 rootfs) via OpenSBI
+ U-Boot (EFI_LOADER) and Cloud-Init NoCloud (cidata) seed disks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile

HOME = Path(__file__).resolve().parent
DEFAULT_DTS = HOME / 'dts' / 'raptor-rva23-uefi.dts'

SECTOR_SIZE = 512
GPT_SIGNATURE = b'EFI PART'
EXT4_SUPERBLOCK_OFFSET = 1024
EXT4_MAGIC_OFFSET = EXT4_SUPERBLOCK_OFFSET + 56
EXT4_MAGIC = b'\x53\xef'
QCOW2_MAGIC = b'QFI\xfb'

ESP_GUID = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
LINUX_FS_GUID = '0FC63DAF-8483-4772-8E79-3D69D8477DE4'
LINUX_ROOT_RISCV64_GUID = '72EC70A6-CF74-40E6-BD49-4BDA08E8F224'
BIOS_BOOT_GUID = '21686148-6449-6E6F-744E-656564454649'

KNOWN_TYPE_GUIDS = {
    ESP_GUID: 'EFI System Partition',
    LINUX_FS_GUID: 'Linux filesystem',
    LINUX_ROOT_RISCV64_GUID: 'Linux root (RISC-V 64)',
    BIOS_BOOT_GUID: 'BIOS boot',
}

DEFAULT_BOOTCMD = (
    'for devtype in virtio nvme mmc; do '
    'if ${devtype} scan; then '
    'for devnum in 0 1 2 3; do '
    'if load ${devtype} ${devnum}:1 ${kernel_addr_r} EFI/BOOT/BOOTRISCV64.EFI; then '
    'bootefi ${kernel_addr_r} ${fdtcontroladdr}; '
    'fi; '
    'done; '
    'fi; '
    'done'
)


def sha256_file(path):
    """Return the hex SHA-256 digest of a file."""
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def parse_gpt_guid(raw):
    """Decode a 16-byte mixed-endian UEFI/GPT GUID into canonical string form."""
    if len(raw) != 16:
        raise ValueError(f'expected 16-byte GUID, got {len(raw)} bytes')
    d1, d2, d3 = struct.unpack_from('<IHH', raw, 0)
    d4 = raw[8:10].hex().upper()
    d5 = raw[10:16].hex().upper()
    return f'{d1:08X}-{d2:04X}-{d3:04X}-{d4}-{d5}'


def encode_gpt_guid(guid):
    """Encode a canonical GUID string into 16-byte mixed-endian UEFI/GPT bytes."""
    parts = guid.strip().upper().split('-')
    if len(parts) != 5 or [len(p) for p in parts] != [8, 4, 4, 4, 12]:
        raise ValueError(f'invalid GUID string: {guid}')
    d1, d2, d3 = int(parts[0], 16), int(parts[1], 16), int(parts[2], 16)
    tail = bytes.fromhex(parts[3] + parts[4])
    return struct.pack('<IHH', d1, d2, d3) + tail


def _yaml_quote(value):
    return json.dumps(str(value))


def render_meta_data(instance_id='raptor-nocloud-01', hostname='raptor-ubuntu'):
    """Render Cloud-Init NoCloud meta-data YAML."""
    return (
        f'instance-id: {_yaml_quote(instance_id)}\n'
        f'local-hostname: {_yaml_quote(hostname)}\n'
    )


def render_network_config(match_names=('en*', 'eth*'), dhcp4=True):
    """Render Cloud-Init v2 network-config YAML with DHCP on Ethernet interfaces."""
    lines = ['version: 2', 'ethernets:']
    for idx, pattern in enumerate(match_names):
        lines.extend([
            f'  nic{idx}:',
            '    match:',
            f'      name: {_yaml_quote(pattern)}',
            f'    dhcp4: {"true" if dhcp4 else "false"}',
            '    optional: true',
        ])
    return '\n'.join(lines) + '\n'


def render_user_data(
    *,
    username='ubuntu',
    ssh_authorized_keys=None,
    password=None,
    serial_autologin=True,
    autologin_user='root',
    systemd_start_timeout=600,
    systemd_device_timeout=1800,
    ntp_servers=None,
):
    """Render Cloud-Init NoCloud user-data YAML without touching the OS image."""
    keys = [k.strip() for k in (ssh_authorized_keys or []) if k.strip()]
    ntp = [s.strip() for s in (ntp_servers or []) if s.strip()]

    lines = ['#cloud-config']
    lines.append('users:')
    lines.append('  - default')
    if username != 'ubuntu' or keys or password:
        lines.append(f'  - name: {_yaml_quote(username)}')
        lines.append('    sudo: "ALL=(ALL) NOPASSWD:ALL"')
        lines.append('    groups: [adm, sudo]')
        lines.append('    shell: /bin/bash')
        if password is not None:
            lines.append('    lock_passwd: false')
            lines.append(f'    plain_text_passwd: {_yaml_quote(password)}')
        if keys:
            lines.append('    ssh_authorized_keys:')
            for key in keys:
                lines.append(f'      - {_yaml_quote(key)}')

    if keys:
        lines.append('ssh_authorized_keys:')
        for key in keys:
            lines.append(f'  - {_yaml_quote(key)}')

    if password is not None:
        lines.append('ssh_pwauth: true')
        lines.append('chpasswd:')
        lines.append('  expire: false')
        lines.append('  users:')
        lines.append(f'    - name: {_yaml_quote(username)}')
        lines.append(f'      password: {_yaml_quote(password)}')
        lines.append('      type: text')

    write_files = []
    timeout_conf = (
        '[Manager]\n'
        f'DefaultTimeoutStartSec={int(systemd_start_timeout)}s\n'
        f'DefaultDeviceTimeoutSec={int(systemd_device_timeout)}s\n'
    )
    write_files.append((
        '/etc/systemd/system.conf.d/90-raptor-timeout.conf',
        '0644',
        timeout_conf,
    ))

    if serial_autologin:
        getty_conf = (
            '[Service]\n'
            'ExecStart=\n'
            f'ExecStart=-/sbin/agetty --autologin {autologin_user} '
            '--noclear --keep-baud 115200,57600,38400,9600 - $TERM\n'
        )
        write_files.append((
            '/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf',
            '0644',
            getty_conf,
        ))

    if ntp:
        timesync_conf = '[Time]\nNTP=' + ' '.join(ntp) + '\n'
        write_files.append((
            '/etc/systemd/timesyncd.conf.d/90-raptor-ntp.conf',
            '0644',
            timesync_conf,
        ))

    lines.append('write_files:')
    for path, perms, content in write_files:
        lines.append(f'  - path: {_yaml_quote(path)}')
        lines.append(f'    permissions: {_yaml_quote(perms)}')
        lines.append('    owner: "root:root"')
        lines.append('    content: |')
        for content_line in content.splitlines():
            lines.append('      ' + content_line)

    bootcmd = ['systemctl daemon-reload']
    if serial_autologin:
        bootcmd.append('systemctl restart serial-getty@ttyS0.service || true')
    if ntp:
        bootcmd.append('systemctl restart systemd-timesyncd.service || true')
    lines.append('bootcmd:')
    for cmd in bootcmd:
        lines.append(f'  - {_yaml_quote(cmd)}')

    return '\n'.join(lines) + '\n'


def _short_83_name(filename, index):
    """Build a valid FAT 8.3 short name (11 ASCII bytes) for a VFAT LFN entry."""
    clean = ''.join(
        ch for ch in filename.upper()
        if ch.isalnum() or ch in '_$'
    )
    stem = (clean[:6] or 'FILE') + f'~{index}'
    return stem[:8].ljust(8).encode('ascii') + b'   '


def _lfn_checksum(short_name):
    chk = 0
    for byte in short_name:
        chk = (((chk & 1) << 7) + (chk >> 1) + byte) & 0xFF
    return chk


def _vfat_lfn_entries(filename, short_name):
    """Build 32-byte VFAT Long File Name directory entries for filename."""
    checksum = _lfn_checksum(short_name)
    encoded = filename.encode('utf-16le') + b'\x00\x00'
    while len(encoded) % 26 != 0:
        encoded += b'\xff\xff'
    chunks = [encoded[i:i + 26] for i in range(0, len(encoded), 26)]
    entries = bytearray()
    for rev_idx, chunk in enumerate(reversed(chunks)):
        seq = len(chunks) - rev_idx
        if rev_idx == 0:
            seq |= 0x40
        entry = bytearray(32)
        entry[0] = seq
        entry[1:11] = chunk[0:10]
        entry[11] = 0x0F
        entry[12] = 0x00
        entry[13] = checksum
        entry[14:26] = chunk[10:22]
        entry[26:28] = b'\x00\x00'
        entry[28:32] = chunk[22:26]
        entries.extend(entry)
    return bytes(entries)


def _write_pure_fat16(output, files, volume_label='CIDATA'):
    """Write a minimal FAT16+VFAT LFN image without external mtools."""
    bytes_per_sector = 512
    sectors_per_cluster = 1
    reserved_sectors = 1
    num_fats = 2
    root_entry_count = 512
    root_dir_sectors = (root_entry_count * 32) // bytes_per_sector
    total_sectors = 8192  # 4 MiB (> 4085 clusters for valid FAT16)
    sectors_per_fat = 32
    label11 = volume_label.upper()[:11].ljust(11).encode('ascii')

    image = bytearray(total_sectors * bytes_per_sector)

    # Boot sector / BPB
    image[0:3] = b'\xeb\x3c\x90'
    image[3:11] = b'RAPTORFS'
    struct.pack_into('<HBHBHHBHHHII', image, 11,
                     bytes_per_sector, sectors_per_cluster, reserved_sectors,
                     num_fats, root_entry_count, total_sectors, 0xF8,
                     sectors_per_fat, 32, 64, 0, 0)
    image[36] = 0x80
    image[38] = 0x29
    struct.pack_into('<I', image, 39, 0x52415054)
    image[43:54] = label11
    image[54:62] = b'FAT16   '
    image[510:512] = b'\x55\xaa'

    fat_offset = reserved_sectors * bytes_per_sector
    root_offset = (reserved_sectors + num_fats * sectors_per_fat) * bytes_per_sector
    data_offset = root_offset + root_dir_sectors * bytes_per_sector

    fat = [0] * (sectors_per_fat * bytes_per_sector // 2)
    fat[0] = 0xFFF8
    fat[1] = 0xFFFF

    root_entries = bytearray()
    # Volume label entry
    vol_entry = bytearray(32)
    vol_entry[0:11] = label11
    vol_entry[11] = 0x08
    root_entries.extend(vol_entry)

    next_cluster = 2
    for file_idx, (name, payload) in enumerate(files.items(), 1):
        short_name = _short_83_name(name, file_idx)
        root_entries.extend(_vfat_lfn_entries(name, short_name))

        first_cluster = next_cluster if payload else 0
        if payload:
            cluster_bytes = sectors_per_cluster * bytes_per_sector
            num_clusters = (len(payload) + cluster_bytes - 1) // cluster_bytes
            for c_idx in range(num_clusters):
                cluster = next_cluster + c_idx
                fat[cluster] = (
                    0xFFFF if c_idx == num_clusters - 1 else cluster + 1
                )
                chunk = payload[c_idx * cluster_bytes:(c_idx + 1) * cluster_bytes]
                dest = data_offset + (cluster - 2) * cluster_bytes
                image[dest:dest + len(chunk)] = chunk
            next_cluster += num_clusters

        entry = bytearray(32)
        entry[0:11] = short_name
        entry[11] = 0x20
        struct.pack_into('<HI', entry, 26, first_cluster, len(payload))
        root_entries.extend(entry)

    fat_bytes = struct.pack(f'<{len(fat)}H', *fat)
    for fat_idx in range(num_fats):
        pos = fat_offset + fat_idx * sectors_per_fat * bytes_per_sector
        image[pos:pos + len(fat_bytes)] = fat_bytes

    image[root_offset:root_offset + len(root_entries)] = root_entries
    Path(output).write_bytes(image)


def create_cidata_image(
    output,
    *,
    fmt='auto',
    instance_id='raptor-nocloud-01',
    hostname='raptor-ubuntu',
    username='ubuntu',
    ssh_authorized_keys=None,
    password=None,
    serial_autologin=True,
    autologin_user='root',
    systemd_start_timeout=600,
    systemd_device_timeout=1800,
    ntp_servers=None,
    network_config=None,
    include_network_config=True,
):
    """Create a Cloud-Init NoCloud cidata seed disk (ISO9660 or VFAT)."""
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    user_data = render_user_data(
        username=username,
        ssh_authorized_keys=ssh_authorized_keys,
        password=password,
        serial_autologin=serial_autologin,
        autologin_user=autologin_user,
        systemd_start_timeout=systemd_start_timeout,
        systemd_device_timeout=systemd_device_timeout,
        ntp_servers=ntp_servers,
    )
    meta_data = render_meta_data(instance_id=instance_id, hostname=hostname)
    files = {
        'user-data': user_data.encode('utf-8'),
        'meta-data': meta_data.encode('utf-8'),
    }
    if network_config is not None:
        files['network-config'] = network_config.encode('utf-8')
    elif include_network_config:
        files['network-config'] = render_network_config().encode('utf-8')

    iso_tool = (
        shutil.which('genisoimage')
        or shutil.which('mkisofs')
        or shutil.which('xorrisofs')
    )
    mkfs_vfat = shutil.which('mkfs.vfat') or (
        '/usr/sbin/mkfs.vfat' if Path('/usr/sbin/mkfs.vfat').is_file() else None
    )
    mcopy = shutil.which('mcopy')

    chosen_fmt = fmt
    if chosen_fmt == 'auto':
        chosen_fmt = 'iso' if iso_tool else 'vfat'

    if chosen_fmt == 'iso':
        if not iso_tool:
            raise RuntimeError(
                'ISO format requested, but genisoimage/mkisofs/xorrisofs not found'
            )
        with tempfile.TemporaryDirectory(prefix='raptor-cidata-') as tmp:
            stage = Path(tmp)
            for name, data in files.items():
                (stage / name).write_bytes(data)
            subprocess.run(
                [iso_tool, '-quiet', '-output', str(output),
                 '-volid', 'cidata', '-joliet', '-rock', str(stage)],
                check=True,
            )
        backend = Path(iso_tool).name
    elif chosen_fmt == 'vfat':
        if mkfs_vfat and mcopy:
            with tempfile.TemporaryDirectory(prefix='raptor-cidata-') as tmp:
                stage = Path(tmp)
                for name, data in files.items():
                    (stage / name).write_bytes(data)
                with output.open('wb') as stream:
                    stream.truncate(2 * 1024 * 1024)
                subprocess.run(
                    [mkfs_vfat, '-n', 'cidata', str(output)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
                for name in files:
                    subprocess.run(
                        [mcopy, '-i', str(output), str(stage / name), '::' + name],
                        check=True,
                    )
            backend = 'mkfs.vfat+mcopy'
        else:
            _write_pure_fat16(output, files, volume_label='cidata')
            backend = 'pure-python-fat16'
    else:
        raise ValueError(f'unsupported cidata format: {fmt}')

    return {
        'path': str(output),
        'format': chosen_fmt,
        'backend': backend,
        'volume_label': 'cidata',
        'files': sorted(files.keys()),
        'size_bytes': output.stat().st_size,
        'sha256': sha256_file(output),
    }


def detect_image_format(path):
    """Detect whether a disk image is qcow2 or raw (read-only)."""
    with Path(path).open('rb') as stream:
        magic = stream.read(4)
    return 'qcow2' if magic == QCOW2_MAGIC else 'raw'


def probe_filesystem(first_2k):
    """Identify ext4 or FAT filesystem from the first 2 KiB of a partition."""
    if len(first_2k) >= EXT4_MAGIC_OFFSET + 2:
        if first_2k[EXT4_MAGIC_OFFSET:EXT4_MAGIC_OFFSET + 2] == EXT4_MAGIC:
            return 'ext4'
    if len(first_2k) >= 512 and first_2k[510:512] == b'\x55\xaa':
        if (b'FAT32' in first_2k[82:90]
                or b'FAT16' in first_2k[54:62]
                or b'FAT12' in first_2k[54:62]):
            return 'vfat'
    return 'unknown'


def _qcow2_read_sectors(path, skip_lba, count_sectors):
    """Read sectors from a qcow2 image read-only via QEMU raw slice driver."""
    qemu_img = shutil.which('qemu-img')
    if not qemu_img:
        raise RuntimeError('qemu-img is required to inspect qcow2 images')
    offset = skip_lba * SECTOR_SIZE
    size = count_sectors * SECTOR_SIZE
    escaped = str(path).replace(',', ',,')
    image_opts = (
        f'driver=raw,offset={offset},size={size},'
        'file.driver=qcow2,file.read-only=on,'
        f'file.file.driver=file,file.file.filename={escaped}'
    )
    with tempfile.TemporaryDirectory(prefix='raptor-qcow2-probe-') as tmp:
        out = Path(tmp) / 'slice.raw'
        subprocess.run(
            [qemu_img, 'convert', '--image-opts', image_opts, '-O', 'raw', str(out)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return out.read_bytes()


def inspect_image(path):
    """Inspect a raw or qcow2 Ubuntu .img GPT layout without modifying it."""
    path = Path(path).resolve()
    fmt = detect_image_format(path)
    if fmt == 'qcow2':
        qemu_img = shutil.which('qemu-img')
        if not qemu_img:
            raise RuntimeError('qemu-img is required to inspect qcow2 images')
        info = json.loads(subprocess.check_output(
            [qemu_img, 'info', '--output=json', str(path)], text=True
        ))
        disk_size = int(info['virtual-size'])
        header_block = _qcow2_read_sectors(path, 1, 1)
    else:
        disk_size = path.stat().st_size
        with path.open('rb') as stream:
            stream.seek(SECTOR_SIZE)
            header_block = stream.read(SECTOR_SIZE)

    if len(header_block) < 92 or header_block[:8] != GPT_SIGNATURE:
        raise ValueError(f'not a GPT disk image (missing EFI PART header): {path}')

    table_lba, part_count, entry_size = struct.unpack_from('<QII', header_block, 72)
    if not (0 < part_count <= 4096 and 128 <= entry_size <= 4096):
        raise ValueError(f'invalid GPT geometry: count={part_count}, entry_size={entry_size}')

    table_bytes_len = part_count * entry_size
    if fmt == 'qcow2':
        table_sectors = (table_bytes_len + SECTOR_SIZE - 1) // SECTOR_SIZE
        table_bytes = _qcow2_read_sectors(path, table_lba, table_sectors)
    else:
        with path.open('rb') as stream:
            stream.seek(table_lba * SECTOR_SIZE)
            table_bytes = stream.read(table_bytes_len)

    partitions = []
    for idx in range(part_count):
        entry = table_bytes[idx * entry_size:(idx + 1) * entry_size]
        if len(entry) < 128 or entry[:16] == bytes(16):
            continue
        type_guid = parse_gpt_guid(entry[0:16])
        unique_guid = parse_gpt_guid(entry[16:32])
        first_lba, last_lba, attrs = struct.unpack_from('<QQQ', entry, 32)
        if first_lba > last_lba or (last_lba + 1) * SECTOR_SIZE > disk_size:
            raise ValueError(
                f'partition {idx + 1} out of bounds: LBA {first_lba}..{last_lba}'
            )
        raw_name = entry[56:128].decode('utf-16le', errors='ignore').rstrip('\x00')
        size_bytes = (last_lba - first_lba + 1) * SECTOR_SIZE

        if fmt == 'qcow2':
            probe_bytes = _qcow2_read_sectors(path, first_lba, 4)
        else:
            with path.open('rb') as stream:
                stream.seek(first_lba * SECTOR_SIZE)
                probe_bytes = stream.read(2048)

        fs_type = probe_filesystem(probe_bytes)
        partitions.append({
            'index': idx + 1,
            'name': raw_name,
            'type_guid': type_guid,
            'type_name': KNOWN_TYPE_GUIDS.get(type_guid, 'Unknown'),
            'unique_guid': unique_guid,
            'first_lba': first_lba,
            'last_lba': last_lba,
            'size_bytes': size_bytes,
            'size_mib': round(size_bytes / (1024 * 1024), 2),
            'attributes': f'0x{attrs:016x}',
            'filesystem': fs_type,
        })

    esp_parts = [p for p in partitions if p['type_guid'] == ESP_GUID]
    ext4_parts = [p for p in partitions if p['filesystem'] == 'ext4']

    return {
        'image': str(path),
        'format': fmt,
        'disk_size_bytes': disk_size,
        'disk_size_mib': round(disk_size / (1024 * 1024), 2),
        'partitions': partitions,
        'has_esp': bool(esp_parts),
        'esp_partitions': [p['index'] for p in esp_parts],
        'has_ext4_root': bool(ext4_parts),
        'ext4_partitions': [p['index'] for p in ext4_parts],
        'uefi_bootable': bool(esp_parts and ext4_parts),
    }


def render_uboot_config(target='qemu-riscv64_smode_defconfig', bootcmd=None):
    """Render a U-Boot defconfig fragment for Raptor RVA23 EBBR/UEFI boot."""
    cmd = bootcmd or DEFAULT_BOOTCMD
    escaped_cmd = cmd.replace('\\', '\\\\').replace('"', '\\"')
    lines = [
        f'# U-Boot defconfig fragment for Raptor RVA23 EBBR/UEFI boot',
        f'# Base defconfig: {target}',
        '#',
        '# Usage:',
        f'#   make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- {target}',
        '#   scripts/kconfig/merge_config.sh -m .config raptor_rva23_efi.config',
        '#   make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig',
        '#',
        '# Cache maintenance note (CONFIG_SYS_RISCV_ZICBOM):',
        '#   Raptor SoC DMA masters (VirtIO, SDHCI, PCIe) are dma-noncoherent.',
        '#   Enable Zicbom cache maintenance in U-Boot when available in your',
        '#   U-Boot tree (CONFIG_SYS_RISCV_ZICBOM=y) so DMA buffers are flushed',
        '#   and invalidated across block/network transfers before ExitBootServices.',
        '',
        '# UEFI / EBBR loader and RNG protocol',
        'CONFIG_EFI_LOADER=y',
        'CONFIG_CMD_BOOTEFI=y',
        'CONFIG_EFI_RNG_PROTOCOL=y',
        'CONFIG_EFI_PARTITION=y',
        'CONFIG_DOS_PARTITION=y',
        'CONFIG_FS_FAT=y',
        'CONFIG_FS_EXT4=y',
        '',
        '# VirtIO MMIO devices (block, net, RNG)',
        'CONFIG_VIRTIO=y',
        'CONFIG_VIRTIO_MMIO=y',
        'CONFIG_VIRTIO_BLK=y',
        'CONFIG_VIRTIO_NET=y',
        'CONFIG_DM_RNG=y',
        'CONFIG_VIRTIO_RNG=y',
        '',
        '# PCIe ECAM + NVMe storage',
        'CONFIG_PCI=y',
        'CONFIG_PCI_HOST_GENERIC=y',
        'CONFIG_PCIE_ECAM_GENERIC=y',
        'CONFIG_NVME=y',
        'CONFIG_NVME_PCI=y',
        '',
        '# SDHCI storage',
        'CONFIG_MMC=y',
        'CONFIG_MMC_SDHCI=y',
        'CONFIG_MMC_SDHCI_SDMA=y',
        '',
        '# Zicbom non-coherent DMA cache maintenance (when supported by U-Boot)',
        'CONFIG_SYS_RISCV_ZICBOM=y',
        '',
        '# Boot EFI/BOOT/BOOTRISCV64.EFI with DTB pass-through',
        'CONFIG_USE_BOOTCOMMAND=y',
        f'CONFIG_BOOTCOMMAND="{escaped_cmd}"',
    ]
    return '\n'.join(lines) + '\n'


def write_uboot_config(output, target='qemu-riscv64_smode_defconfig', bootcmd=None):
    """Write the U-Boot defconfig fragment to output."""
    content = render_uboot_config(target=target, bootcmd=bootcmd)
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding='utf-8')
    return output


def compile_dtb(dts_path, dtb_path, include_dir=None):
    """Compile a DTS file to DTB using dtc."""
    dts_path = Path(dts_path).resolve()
    dtb_path = Path(dtb_path).resolve()
    dtb_path.parent.mkdir(parents=True, exist_ok=True)
    inc = Path(include_dir).resolve() if include_dir else dts_path.parent
    dtc = shutil.which('dtc') or '/usr/bin/dtc'
    subprocess.run(
        [dtc, '-I', 'dts', '-O', 'dtb', '-i', str(inc), '-o', str(dtb_path), str(dts_path)],
        check=True,
    )
    return dtb_path


def inject_rng_seed(dtb_path, seed=None):
    """Inject a 256-bit (32-byte) /chosen/rng-seed property into a DTB."""
    seed_bytes = os.urandom(32) if seed is None else bytes(seed)
    if len(seed_bytes) != 32:
        raise ValueError(f'rng-seed must be 32 bytes (256-bit), got {len(seed_bytes)}')
    fdtput = shutil.which('fdtput') or '/usr/bin/fdtput'
    hex_bytes = [f'{b:02x}' for b in seed_bytes]
    subprocess.run(
        [fdtput, '-t', 'bx', str(dtb_path), '/chosen', 'rng-seed', *hex_bytes],
        check=True,
    )
    return seed_bytes


def create_bundle(
    output_dir,
    *,
    firmware,
    firmware_mode='fw_dynamic',
    uboot=None,
    dts=DEFAULT_DTS,
    cidata=None,
    cidata_options=None,
    rng_seed=None,
):
    """Package OpenSBI, optional U-Boot, DTB with rng-seed, cidata, and manifest."""
    if firmware_mode not in ('fw_dynamic', 'fw_payload'):
        raise ValueError(f'invalid firmware_mode: {firmware_mode}')
    firmware = Path(firmware).resolve()
    if not firmware.is_file():
        raise FileNotFoundError(f'firmware binary not found: {firmware}')

    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    fw_name = 'fw_dynamic.bin' if firmware_mode == 'fw_dynamic' else 'fw_payload.bin'
    fw_dest = output_dir / fw_name
    shutil.copyfile(firmware, fw_dest)
    bundled_files = [fw_name]

    if uboot is not None:
        uboot_src = Path(uboot).resolve()
        if not uboot_src.is_file():
            raise FileNotFoundError(f'U-Boot binary not found: {uboot_src}')
        shutil.copyfile(uboot_src, output_dir / 'u-boot.bin')
        bundled_files.append('u-boot.bin')

    dtb_name = 'raptor-rva23-uefi.dtb'
    dtb_dest = output_dir / dtb_name
    compile_dtb(dts, dtb_dest)
    seed_bytes = inject_rng_seed(dtb_dest, seed=rng_seed)
    bundled_files.append(dtb_name)

    cidata_name = 'cidata.img'
    cidata_dest = output_dir / cidata_name
    if cidata is not None:
        cidata_src = Path(cidata).resolve()
        if not cidata_src.is_file():
            raise FileNotFoundError(f'cidata image not found: {cidata_src}')
        shutil.copyfile(cidata_src, cidata_dest)
        cidata_info = {'source': str(cidata_src)}
    else:
        opts = dict(cidata_options or {})
        cidata_info = create_cidata_image(cidata_dest, **opts)
    bundled_files.append(cidata_name)

    manifest = {
        'schema': 'raptor-uboot-efi-bundle-v1',
        'firmware_mode': firmware_mode,
        'dts_source': Path(dts).name,
        'rng_seed_injected': True,
        'rng_seed_bytes': len(seed_bytes),
        'cidata': cidata_info,
        'files': {name: sha256_file(output_dir / name) for name in bundled_files},
    }
    manifest_path = output_dir / 'manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest


def build_qemu_smoke_command(
    *,
    bios,
    disk,
    kernel=None,
    dtb=None,
    disk_format='raw',
    cidata=None,
    cpu='rva23s64',
    memory='2G',
    smp=1,
    snapshot=True,
    qemu_bin='qemu-system-riscv64',
):
    """Build a qemu-system-riscv64 -machine virt verification command."""
    cmd = [
        qemu_bin,
        '-machine', 'virt',
        '-cpu', cpu,
        '-m', str(memory),
        '-smp', str(smp),
        '-nographic',
        '-no-reboot',
        '-bios', str(bios),
    ]
    if kernel is not None:
        cmd.extend(['-kernel', str(kernel)])
    if dtb is not None:
        cmd.extend(['-dtb', str(dtb)])
    if snapshot:
        cmd.append('-snapshot')

    cmd.extend([
        '-drive', f'file={disk},format={disk_format},if=none,id=osdisk',
        '-device', 'virtio-blk-device,drive=osdisk',
    ])
    if cidata is not None:
        cmd.extend([
            '-drive', f'file={cidata},format=raw,if=none,id=cidata',
            '-device', 'virtio-blk-device,drive=cidata',
        ])
    cmd.extend([
        '-netdev', 'user,id=net0',
        '-device', 'virtio-net-device,netdev=net0',
        '-object', 'rng-random,filename=/dev/urandom,id=rng0',
        '-device', 'virtio-rng-device,rng=rng0',
    ])
    return cmd


def run_qemu_smoke(command, timeout=60):
    """Execute a QEMU smoke command with a timeout and return status/output."""
    try:
        proc = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        return {
            'returncode': proc.returncode,
            'timed_out': False,
            'output': proc.stdout.decode('utf-8', errors='replace'),
        }
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or b''
        if isinstance(out, bytes):
            out = out.decode('utf-8', errors='replace')
        return {
            'returncode': None,
            'timed_out': True,
            'output': out,
        }


def _cmd_cidata(args):
    keys = list(args.ssh_key_text or [])
    for key_path in args.ssh_key or []:
        keys.append(Path(key_path).read_text(encoding='utf-8').strip())
    net_cfg = None
    if args.network_config:
        net_cfg = Path(args.network_config).read_text(encoding='utf-8')
    info = create_cidata_image(
        args.output,
        fmt=args.format,
        instance_id=args.instance_id,
        hostname=args.hostname,
        username=args.user,
        ssh_authorized_keys=keys,
        password=args.password,
        serial_autologin=not args.no_serial_autologin,
        autologin_user=args.autologin_user,
        systemd_start_timeout=args.systemd_start_timeout,
        systemd_device_timeout=args.systemd_device_timeout,
        ntp_servers=args.ntp_server,
        network_config=net_cfg,
        include_network_config=not args.no_network_config,
    )
    print(json.dumps(info, indent=2))


def _cmd_inspect_img(args):
    report = inspect_image(args.image)
    print(json.dumps(report, indent=2))
    if args.require_uefi and not report['uefi_bootable']:
        sys.exit(1)


def _cmd_uboot_config(args):
    content = render_uboot_config(target=args.target, bootcmd=args.bootcmd)
    if str(args.output) == '-':
        sys.stdout.write(content)
    else:
        path = write_uboot_config(args.output, target=args.target, bootcmd=args.bootcmd)
        print(f'Wrote U-Boot config fragment: {path}')


def _cmd_bundle(args):
    cidata_opts = None
    if args.cidata is None:
        keys = []
        for key_path in args.ssh_key or []:
            keys.append(Path(key_path).read_text(encoding='utf-8').strip())
        cidata_opts = {
            'fmt': args.cidata_format,
            'hostname': args.hostname,
            'username': args.user,
            'ssh_authorized_keys': keys,
            'password': args.password,
        }
    manifest = create_bundle(
        args.output,
        firmware=args.firmware,
        firmware_mode=args.firmware_mode,
        uboot=args.uboot,
        dts=args.dts,
        cidata=args.cidata,
        cidata_options=cidata_opts,
    )
    print(json.dumps(manifest, indent=2))


def _cmd_qemu_smoke(args):
    disk_fmt = args.disk_format or detect_image_format(args.disk)
    cmd = build_qemu_smoke_command(
        bios=args.bios,
        kernel=args.kernel,
        dtb=args.dtb,
        disk=args.disk,
        disk_format=disk_fmt,
        cidata=args.cidata,
        cpu=args.cpu,
        memory=args.memory,
        smp=args.smp,
        snapshot=not args.no_snapshot,
    )
    if args.run:
        result = run_qemu_smoke(cmd, timeout=args.timeout)
        print(json.dumps({'command': cmd, **result}, indent=2))
        if result['timed_out'] or result['returncode'] != 0:
            sys.exit(1)
    elif args.json:
        print(json.dumps({'command': cmd}, indent=2))
    else:
        print(shlex.join(cmd))


def build_parser():
    """Build the CLI argument parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)

    p_ci = sub.add_parser('cidata', help='Generate a Cloud-Init NoCloud cidata seed disk')
    p_ci.add_argument('-o', '--output', type=Path, required=True, help='Output image path')
    p_ci.add_argument('--format', choices=('auto', 'iso', 'vfat'), default='auto')
    p_ci.add_argument('--instance-id', default='raptor-nocloud-01')
    p_ci.add_argument('--hostname', default='raptor-ubuntu')
    p_ci.add_argument('--user', default='ubuntu')
    p_ci.add_argument('--ssh-key', type=Path, action='append', help='SSH public key file')
    p_ci.add_argument('--ssh-key-text', action='append', help='Inline SSH public key')
    p_ci.add_argument('--password', help='Optional login password')
    p_ci.add_argument('--autologin-user', default='root')
    p_ci.add_argument('--no-serial-autologin', action='store_true')
    p_ci.add_argument('--systemd-start-timeout', type=int, default=600)
    p_ci.add_argument('--systemd-device-timeout', type=int, default=1800)
    p_ci.add_argument('--ntp-server', action='append', help='NTP server hostname/IP')
    p_ci.add_argument('--network-config', type=Path, help='Custom network-config YAML')
    p_ci.add_argument('--no-network-config', action='store_true')
    p_ci.set_defaults(func=_cmd_cidata)

    p_ins = sub.add_parser('inspect-img', help='Inspect GPT/ESP/ext4 layout of an Ubuntu .img')
    p_ins.add_argument('image', type=Path, help='Path to raw or qcow2 disk image')
    p_ins.add_argument('--require-uefi', action='store_true',
                       help='Exit non-zero if ESP or ext4 root is missing')
    p_ins.set_defaults(func=_cmd_inspect_img)

    p_ub = sub.add_parser('uboot-config', help='Generate U-Boot EFI defconfig fragment')
    p_ub.add_argument('-o', '--output', default='raptor_rva23_efi.config',
                      help='Output path (or - for stdout)')
    p_ub.add_argument('--target', default='qemu-riscv64_smode_defconfig')
    p_ub.add_argument('--bootcmd', help='Override CONFIG_BOOTCOMMAND')
    p_ub.set_defaults(func=_cmd_uboot_config)

    p_bun = sub.add_parser('bundle', help='Package OpenSBI, DTB (with rng-seed), and cidata')
    p_bun.add_argument('-o', '--output', type=Path, required=True, help='Bundle directory')
    p_bun.add_argument('--firmware', type=Path, required=True,
                       help='OpenSBI fw_dynamic.bin or fw_payload.bin')
    p_bun.add_argument('--firmware-mode', choices=('fw_dynamic', 'fw_payload'),
                       default='fw_dynamic')
    p_bun.add_argument('--uboot', type=Path, help='Optional U-Boot binary (for fw_dynamic)')
    p_bun.add_argument('--dts', type=Path, default=DEFAULT_DTS)
    p_bun.add_argument('--cidata', type=Path, help='Existing cidata image (generated if omitted)')
    p_bun.add_argument('--cidata-format', choices=('auto', 'iso', 'vfat'), default='auto')
    p_bun.add_argument('--hostname', default='raptor-ubuntu')
    p_bun.add_argument('--user', default='ubuntu')
    p_bun.add_argument('--ssh-key', type=Path, action='append')
    p_bun.add_argument('--password')
    p_bun.set_defaults(func=_cmd_bundle)

    p_qs = sub.add_parser('qemu-smoke', help='Construct or run QEMU virt UEFI smoke command')
    p_qs.add_argument('--bios', type=Path, required=True, help='OpenSBI firmware path')
    p_qs.add_argument('--kernel', type=Path, help='Optional U-Boot binary (with fw_dynamic)')
    p_qs.add_argument('--dtb', type=Path, help='Optional DTB path')
    p_qs.add_argument('--disk', type=Path, required=True, help='Ubuntu .img or synthetic GPT disk')
    p_qs.add_argument('--disk-format', choices=('raw', 'qcow2'))
    p_qs.add_argument('--cidata', type=Path, help='Optional cidata seed image')
    p_qs.add_argument('--cpu', default='rva23s64')
    p_qs.add_argument('--memory', default='2G')
    p_qs.add_argument('--smp', type=int, default=1)
    p_qs.add_argument('--no-snapshot', action='store_true')
    p_qs.add_argument('--run', action='store_true', help='Execute QEMU instead of printing')
    p_qs.add_argument('--timeout', type=int, default=60)
    p_qs.add_argument('--json', action='store_true')
    p_qs.set_defaults(func=_cmd_qemu_smoke)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == '__main__':
    main()
