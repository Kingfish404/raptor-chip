"""Unit and integration tests for EBBR/UEFI DTB and zero-mod Ubuntu tooling."""
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout

import uboot_efi
from uboot_efi import (
    DEFAULT_DTS,
    ESP_GUID,
    EXT4_MAGIC,
    EXT4_MAGIC_OFFSET,
    LINUX_FS_GUID,
    SECTOR_SIZE,
    build_qemu_smoke_command,
    compile_dtb,
    create_bundle,
    create_cidata_image,
    encode_gpt_guid,
    inject_rng_seed,
    inspect_image,
    parse_gpt_guid,
    render_uboot_config,
    render_user_data,
    sha256_file,
    write_uboot_config,
)


def make_synthetic_gpt_image(path, *, include_esp=True, include_ext4=True):
    """Create a small synthetic GPT raw disk with optional ESP and ext4 parts."""
    total_sectors = 2048  # 1 MiB
    data = bytearray(total_sectors * SECTOR_SIZE)

    # Protective MBR signature
    data[510:512] = b'\x55\xaa'

    # GPT Header at LBA 1
    parts = []
    if include_esp:
        parts.append((ESP_GUID, 'EFI System', 64, 511, 'vfat'))
    if include_ext4:
        parts.append((LINUX_FS_GUID, 'cloudimg-rootfs', 512, 1999, 'ext4'))

    header_off = SECTOR_SIZE
    data[header_off:header_off + 8] = b'EFI PART'
    struct.pack_into('<I', data, header_off + 8, 0x00010000)
    struct.pack_into('<I', data, header_off + 12, 92)
    struct.pack_into('<QII', data, header_off + 72, 2, 128, 128)

    table_off = 2 * SECTOR_SIZE
    for idx, (guid, name, first_lba, last_lba, fs_kind) in enumerate(parts):
        entry_off = table_off + idx * 128
        data[entry_off:entry_off + 16] = encode_gpt_guid(guid)
        data[entry_off + 16:entry_off + 32] = bytes([idx + 1]) * 16
        struct.pack_into('<QQQ', data, entry_off + 32, first_lba, last_lba, 0)
        encoded_name = name.encode('utf-16le')[:72]
        data[entry_off + 56:entry_off + 56 + len(encoded_name)] = encoded_name

        part_off = first_lba * SECTOR_SIZE
        if fs_kind == 'vfat':
            data[part_off + 54:part_off + 62] = b'FAT16   '
            data[part_off + 510:part_off + 512] = b'\x55\xaa'
        elif fs_kind == 'ext4':
            magic_pos = part_off + EXT4_MAGIC_OFFSET
            data[magic_pos:magic_pos + 2] = EXT4_MAGIC

    Path(path).write_bytes(data)
    return Path(path)


class UefiDeviceTreeTest(unittest.TestCase):
    def test_raptor_rva23_uefi_dts_compiles_and_has_expected_nodes(self):
        with tempfile.TemporaryDirectory() as tmp:
            dtb = Path(tmp) / 'raptor-rva23-uefi.dtb'
            proc = subprocess.run(
                ['dtc', '-I', 'dts', '-O', 'dtb', '-i', str(DEFAULT_DTS.parent),
                 '-o', str(dtb), str(DEFAULT_DTS)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(proc.stderr.strip(), '')
            self.assertTrue(dtb.is_file())

            def fdtget(node, prop, kind='s'):
                return subprocess.check_output(
                    ['fdtget', '-t', kind, str(dtb), node, prop], text=True
                ).strip()

            def fdtprops(node):
                return subprocess.check_output(
                    ['fdtget', '-p', str(dtb), node], text=True
                ).split()

            # Aliases and chosen
            self.assertEqual(fdtget('/aliases', 'serial0'), '/soc/ns16550@10000000')
            self.assertEqual(fdtget('/chosen', 'stdout-path'), 'serial0:115200n8')
            bootargs = fdtget('/chosen', 'bootargs')
            for token in (
                'earlycon=sbi',
                'console=ttyS0,115200n8',
                'systemd.default_timeout_start_sec=600',
                'systemd.default_device_timeout_sec=1800',
            ):
                self.assertIn(token, bootargs)
            self.assertNotIn('rng-seed', fdtprops('/chosen'))

            # RVA23U64 + RVA23S64 CPU extensions
            isa_exts = set(fdtget('/cpus/cpu@0', 'riscv,isa-extensions').split())
            for ext in (
                'i', 'm', 'a', 'f', 'd', 'c', 'v', 'h',
                'zicbom', 'zicbop', 'zicboz', 'svinval', 'svnapot',
                'svpbmt', 'sstc', 'sscofpmf', 'supm', 'ssnpm', 'smnpm', 'smstateen',
            ):
                self.assertIn(ext, isa_exts)

            # Standard UEFI/EBBR peripherals and dma-noncoherent
            self.assertIn('dma-noncoherent', fdtprops('/soc'))
            self.assertEqual(fdtget('/soc/rtc@101000', 'compatible'), 'google,goldfish-rtc')
            self.assertEqual(fdtget('/soc/rtc@101000', 'interrupts', 'x'), '6')

            self.assertEqual(fdtget('/soc/virtio_rng@10003000', 'compatible'), 'virtio,mmio')
            self.assertEqual(fdtget('/soc/virtio_rng@10003000', 'interrupts', 'x'), '5')
            self.assertIn('dma-noncoherent', fdtprops('/soc/virtio_rng@10003000'))

            self.assertEqual(fdtget('/soc/virtio_blk@10001000', 'compatible'), 'virtio,mmio')
            self.assertEqual(fdtget('/soc/virtio_blk@10001000', 'interrupts', 'x'), '1')
            self.assertIn('dma-noncoherent', fdtprops('/soc/virtio_blk@10001000'))

            self.assertEqual(fdtget('/soc/virtio_net@10002000', 'compatible'), 'virtio,mmio')
            self.assertEqual(fdtget('/soc/virtio_net@10002000', 'interrupts', 'x'), '2')
            self.assertIn('dma-noncoherent', fdtprops('/soc/virtio_net@10002000'))

            self.assertIn('arasan,sdhci-8.9a', fdtget('/soc/sdhci@42000000', 'compatible'))
            self.assertEqual(fdtget('/soc/sdhci@42000000', 'interrupts', 'x'), '4')
            self.assertIn('dma-noncoherent', fdtprops('/soc/sdhci@42000000'))

            self.assertEqual(fdtget('/soc/pci@41000000', 'compatible'), 'pci-host-ecam-generic')
            self.assertIn('dma-noncoherent', fdtprops('/soc/pci@41000000'))
            irq_map = fdtget('/soc/pci@41000000', 'interrupt-map', 'x').split()
            for irq_hex in ('b', 'c', 'd', 'e'):
                self.assertIn(irq_hex, irq_map)

            self.assertEqual(fdtget('/poweroff', 'compatible'), 'syscon-poweroff')
            self.assertEqual(fdtget('/reboot', 'compatible'), 'syscon-reboot')


class CidataTest(unittest.TestCase):
    def test_render_user_data_contains_expected_yaml_keys(self):
        yaml_text = render_user_data(
            username='ubuntu',
            ssh_authorized_keys=['ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@raptor'],
            password='raptor-test-password',
            serial_autologin=True,
            ntp_servers=['ntp.ubuntu.com', 'pool.ntp.org'],
        )
        self.assertTrue(yaml_text.startswith('#cloud-config\n'))
        for expected in (
            'ssh_authorized_keys:',
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@raptor',
            'chpasswd:',
            'write_files:',
            'DefaultTimeoutStartSec=600s',
            'DefaultDeviceTimeoutSec=1800s',
            'serial-getty@ttyS0.service.d/autologin.conf',
            'timesyncd.conf.d/90-raptor-ntp.conf',
            'NTP=ntp.ubuntu.com pool.ntp.org',
            'bootcmd:',
            'systemctl daemon-reload',
        ):
            self.assertIn(expected, yaml_text)

    def test_create_cidata_iso_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'cidata.iso'
            info = create_cidata_image(
                out,
                fmt='iso',
                hostname='raptor-uefi-test',
                ssh_authorized_keys=['ssh-ed25519 AAAAC3Test key@host'],
            )
            self.assertEqual(info['format'], 'iso')
            self.assertEqual(info['files'], ['meta-data', 'network-config', 'user-data'])
            self.assertEqual(info['sha256'], sha256_file(out))

            raw = out.read_bytes()
            # ISO9660 Primary Volume Descriptor at sector 16 (offset 32768)
            self.assertEqual(raw[32768:32774], b'\x01CD001')
            vol_id = raw[32768 + 40:32768 + 72].decode('ascii', errors='ignore').strip()
            self.assertEqual(vol_id.lower(), 'cidata')
            self.assertIn(b'#cloud-config', raw)
            self.assertIn(b'local-hostname: "raptor-uefi-test"', raw)
            self.assertIn(b'ssh-ed25519 AAAAC3Test key@host', raw)

    def test_create_cidata_vfat_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'cidata.vfat'
            info = create_cidata_image(
                out,
                fmt='vfat',
                hostname='raptor-fat-test',
                include_network_config=False,
            )
            self.assertEqual(info['format'], 'vfat')
            self.assertEqual(info['files'], ['meta-data', 'user-data'])
            raw = out.read_bytes()
            self.assertEqual(raw[510:512], b'\x55\xaa')
            label = raw[43:54].decode('ascii', errors='ignore').strip().lower()
            self.assertEqual(label, 'cidata')
            self.assertIn(b'#cloud-config', raw)
            self.assertIn(b'local-hostname: "raptor-fat-test"', raw)


class InspectImgTest(unittest.TestCase):
    def test_guid_roundtrip(self):
        raw = encode_gpt_guid(ESP_GUID)
        self.assertEqual(len(raw), 16)
        self.assertEqual(parse_gpt_guid(raw), ESP_GUID)
        self.assertEqual(parse_gpt_guid(encode_gpt_guid(LINUX_FS_GUID)), LINUX_FS_GUID)

    def test_inspect_raw_gpt_with_esp_and_ext4_is_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            img = make_synthetic_gpt_image(Path(tmp) / 'ubuntu.img')
            before_sha = sha256_file(img)
            report = inspect_image(img)
            after_sha = sha256_file(img)

            self.assertEqual(before_sha, after_sha)
            self.assertEqual(report['format'], 'raw')
            self.assertTrue(report['has_esp'])
            self.assertEqual(report['esp_partitions'], [1])
            self.assertTrue(report['has_ext4_root'])
            self.assertEqual(report['ext4_partitions'], [2])
            self.assertTrue(report['uefi_bootable'])
            self.assertEqual(len(report['partitions']), 2)
            self.assertEqual(report['partitions'][0]['type_guid'], ESP_GUID)
            self.assertEqual(report['partitions'][0]['filesystem'], 'vfat')
            self.assertEqual(report['partitions'][1]['filesystem'], 'ext4')

    def test_inspect_qcow2_gpt_image(self):
        if not shutil.which('qemu-img'):
            self.skipTest('qemu-img not installed')
        with tempfile.TemporaryDirectory() as tmp:
            raw_img = make_synthetic_gpt_image(Path(tmp) / 'ubuntu.raw')
            qcow2_img = Path(tmp) / 'ubuntu.qcow2'
            subprocess.run(
                ['qemu-img', 'convert', '-f', 'raw', '-O', 'qcow2',
                 str(raw_img), str(qcow2_img)],
                check=True,
            )
            before_sha = sha256_file(qcow2_img)
            report = inspect_image(qcow2_img)
            self.assertEqual(before_sha, sha256_file(qcow2_img))
            self.assertEqual(report['format'], 'qcow2')
            self.assertTrue(report['has_esp'])
            self.assertTrue(report['has_ext4_root'])
            self.assertTrue(report['uefi_bootable'])

    def test_inspect_missing_esp_and_non_gpt(self):
        with tempfile.TemporaryDirectory() as tmp:
            no_esp = make_synthetic_gpt_image(
                Path(tmp) / 'no-esp.img', include_esp=False, include_ext4=True
            )
            report = inspect_image(no_esp)
            self.assertFalse(report['has_esp'])
            self.assertTrue(report['has_ext4_root'])
            self.assertFalse(report['uefi_bootable'])

            bad = Path(tmp) / 'not-gpt.img'
            bad.write_bytes(b'\x00' * 4096)
            with self.assertRaisesRegex(ValueError, 'EFI PART'):
                inspect_image(bad)


class UbootConfigAndBundleTest(unittest.TestCase):
    def test_uboot_config_fragment_contains_required_options(self):
        cfg = render_uboot_config()
        for symbol in (
            'qemu-riscv64_smode_defconfig',
            'CONFIG_EFI_LOADER=y',
            'CONFIG_CMD_BOOTEFI=y',
            'CONFIG_VIRTIO_MMIO=y',
            'CONFIG_VIRTIO_BLK=y',
            'CONFIG_VIRTIO_NET=y',
            'CONFIG_NVME_PCI=y',
            'CONFIG_PCI_HOST_GENERIC=y',
            'CONFIG_MMC_SDHCI=y',
            'CONFIG_EFI_RNG_PROTOCOL=y',
            'CONFIG_SYS_RISCV_ZICBOM',
            'CONFIG_USE_BOOTCOMMAND=y',
            'CONFIG_BOOTCOMMAND=',
            'EFI/BOOT/BOOTRISCV64.EFI',
            'bootefi',
            'fdtcontroladdr',
        ):
            self.assertIn(symbol, cfg)

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'raptor_rva23_efi.config'
            write_uboot_config(out)
            self.assertEqual(out.read_text(encoding='utf-8'), cfg)

    def test_bundle_creates_manifest_and_injects_fresh_rng_seed(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            fw = work / 'fw_dynamic.bin'
            fw.write_bytes(b'OPENSBI-DYNAMIC-PLACEHOLDER')
            uboot = work / 'u-boot.bin'
            uboot.write_bytes(b'UBOOT-EFI-PLACEHOLDER')

            bundle_a = work / 'bundle-a'
            manifest_a = create_bundle(
                bundle_a,
                firmware=fw,
                firmware_mode='fw_dynamic',
                uboot=uboot,
                dts=DEFAULT_DTS,
            )
            self.assertEqual(manifest_a['schema'], 'raptor-uboot-efi-bundle-v1')
            self.assertTrue(manifest_a['rng_seed_injected'])
            self.assertEqual(manifest_a['rng_seed_bytes'], 32)
            for name, digest in manifest_a['files'].items():
                self.assertEqual(sha256_file(bundle_a / name), digest)
            self.assertEqual(
                set(manifest_a['files'].keys()),
                {'fw_dynamic.bin', 'u-boot.bin', 'raptor-rva23-uefi.dtb', 'cidata.img'},
            )

            seed_a = subprocess.check_output(
                ['fdtget', '-t', 'bx', str(bundle_a / 'raptor-rva23-uefi.dtb'),
                 '/chosen', 'rng-seed'],
                text=True,
            ).split()
            self.assertEqual(len(seed_a), 32)

            # A second bundle must get a distinct fresh 256-bit rng-seed
            bundle_b = work / 'bundle-b'
            create_bundle(bundle_b, firmware=fw, firmware_mode='fw_payload', dts=DEFAULT_DTS)
            seed_b = subprocess.check_output(
                ['fdtget', '-t', 'bx', str(bundle_b / 'raptor-rva23-uefi.dtb'),
                 '/chosen', 'rng-seed'],
                text=True,
            ).split()
            self.assertEqual(len(seed_b), 32)
            self.assertNotEqual(seed_a, seed_b)

    def test_inject_rng_seed_validates_length(self):
        with tempfile.TemporaryDirectory() as tmp:
            dtb = compile_dtb(DEFAULT_DTS, Path(tmp) / 'test.dtb')
            with self.assertRaisesRegex(ValueError, '32 bytes'):
                inject_rng_seed(dtb, seed=b'short')

    def test_qemu_smoke_command_and_cli_smoke(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            img = make_synthetic_gpt_image(work / 'ubuntu.img')
            bios = work / 'fw_dynamic.bin'
            bios.write_bytes(b'fw')
            uboot = work / 'u-boot.bin'
            uboot.write_bytes(b'ub')
            cidata = work / 'cidata.img'
            create_cidata_image(cidata, fmt='iso')

            cmd = build_qemu_smoke_command(
                bios=bios, kernel=uboot, disk=img, cidata=cidata
            )
            self.assertEqual(cmd[0], 'qemu-system-riscv64')
            self.assertIn('virt', cmd)
            self.assertIn('rva23s64', cmd)
            self.assertIn('-snapshot', cmd)
            self.assertTrue(any('id=osdisk' in arg for arg in cmd))
            self.assertTrue(any('id=cidata' in arg for arg in cmd))
            self.assertTrue(any('virtio-rng-device' in arg for arg in cmd))

            buf = io.StringIO()
            with redirect_stdout(buf):
                uboot_efi.main([
                    'qemu-smoke', '--bios', str(bios), '--kernel', str(uboot),
                    '--disk', str(img), '--cidata', str(cidata), '--json',
                ])
            parsed = json.loads(buf.getvalue())
            self.assertEqual(parsed['command'], cmd)


if __name__ == '__main__':
    unittest.main()
