"""Host-side checks for privileged rootfs overlays and boot artifact integrity."""
import array
import fcntl
import os
from pathlib import Path
import pty
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import fast_upload
import distro as ubuntu
from unittest.mock import patch

FPGA = Path(__file__).resolve().parents[2]


class DistroTests(unittest.TestCase):
    def test_board_network_profiles_and_default_preset(self):
        for board, driver, address in (("rk-xcku5p-f", "raptor", "192.168.50.88"),
                                       ("mlk-cu08-ku15p", "liteeth", "192.168.50.90")):
            ubuntu.configure(FPGA / board)
            self.assertEqual(ubuntu.network_profile()["driver"], driver)
            self.assertEqual(ubuntu.PROFILE["ubuntu"]["boot_ip"], address)
            with patch.object(sys, "argv", ["distro.py", "kernel"]), \
                    patch.object(ubuntu, "kernel") as kernel:
                ubuntu.main()
                self.assertEqual(kernel.call_args.args[0].preset, "default")

    def test_kernel_config_enables_rva23_and_kvm_without_conflict(self):
        source = ubuntu.json.loads((ubuntu.COMMON / "linux/kernel-source.json").read_text())
        self.assertRegex(source["version"], r"^\d+\.\d+\.\d+$")
        self.assertGreaterEqual(int(source["version"].split(".")[0]), 7)
        lines = (ubuntu.COMMON / "linux/distro.config").read_text().splitlines()
        for option in ("CONFIG_RISCV_ISA_V=y", "CONFIG_RISCV_ISA_SUPM=y",
                       "CONFIG_RISCV_ISA_SVNAPOT=y", "CONFIG_RISCV_ISA_SVPBMT=y",
                       "CONFIG_VIRTUALIZATION=y", "CONFIG_KVM=y",
                       "CONFIG_VIRTIO_MMIO=y", "CONFIG_VIRTIO_BLK=y", "CONFIG_VIRTIO_NET=y",
                       "CONFIG_PCI=y", "CONFIG_PCI_HOST_GENERIC=y", "CONFIG_BLK_DEV_NVME=y",
                       "CONFIG_MMC=y", "CONFIG_MMC_SDHCI=y",
                       "CONFIG_MMC_SDHCI_OF_ARASAN=y", "CONFIG_MMC_SDHCI_PCI=y",
                       "CONFIG_OVERLAY_FS=y", "CONFIG_SQUASHFS=y", "CONFIG_SQUASHFS_LZ4=y",
                       "CONFIG_MTD=y", "CONFIG_MTD_BLOCK=y", "CONFIG_MTD_PHRAM=y"):
            self.assertIn(option, lines)
        self.assertNotIn("# CONFIG_VIRTUALIZATION is not set", lines)
        self.assertNotIn("# CONFIG_KVM is not set", lines)
        self.assertNotIn("# CONFIG_PCI is not set", lines)
        self.assertNotIn("# CONFIG_MMC is not set", lines)
        self.assertNotIn("# CONFIG_MTD is not set", lines)

    def test_kernel_reuse_checks_driver_and_word_pio_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / "kernel.config"
            config.write_text("CONFIG_RAPTOR_ETH=y\nCONFIG_LITEX_LITEETH=y\n")
            record = {"schema": "raptor-ubuntu-kernel-v1", "inputs": {"driver": {}},
                      "files": {"kernel.config": ubuntu.sha(config)}}
            ubuntu.save(root / "manifest.json", record)
            args = SimpleNamespace(kernel_dir=root)
            ubuntu.configure(FPGA / "rk-xcku5p-f")
            self.assertEqual(ubuntu.kernel(args), root)
            ubuntu.configure(FPGA / "mlk-cu08-ku15p")
            with self.assertRaisesRegex(RuntimeError, "32-bit packet PIO"):
                ubuntu.kernel(args)
            name = "liteeth-native-pio.patch"
            record["inputs"]["driver"][name] = ubuntu.sha(ubuntu.COMMON / "linux" / name)
            ubuntu.save(root / "manifest.json", record)
            self.assertEqual(ubuntu.kernel(args), root)

    def test_overlay_rejects_parent_symlink_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            outside = Path(temporary) / "outside"
            root.mkdir()
            outside.mkdir()
            (root / "etc").symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "escapes rootfs"):
                ubuntu.overlay_file(root, "etc/new/config", "must not escape")
            self.assertEqual(list(outside.iterdir()), [])

    def test_overlay_replaces_final_symlink_without_modifying_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            outside = Path(temporary) / "host-resolv.conf"
            outside.write_text("host DNS")
            (root / "resolv.conf").symlink_to(outside)
            ubuntu.overlay_file(root, "resolv.conf", "guest DNS", 0o600)
            self.assertEqual(outside.read_text(), "host DNS")
            self.assertEqual((root / "resolv.conf").read_text(), "guest DNS")
            self.assertEqual((root / "resolv.conf").stat().st_mode & 0o777, 0o600)

    def test_artifact_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / "Image"
            image.write_bytes(b"verified kernel")
            ubuntu.save(root / "manifest.json", {"files": {"Image": ubuntu.sha(image)}})
            ubuntu.verify(root)
            image.write_bytes(b"changed kernel")
            with self.assertRaisesRegex(RuntimeError, "artifact changed"):
                ubuntu.verify(root)

    def test_nfs_command_line_rejects_path_option_injection(self):
        for name in ("/tmp/root rw init=/bin/sh", "/tmp/root,vers=4", "/tmp/root:other"):
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "invalid NFS"):
                ubuntu.bootargs(SimpleNamespace(rootfs=Path(name), server="192.168.50.1"))
        for dev in ("/dev/vda", "/dev/nvme0n1", "/dev/mmcblk0"):
            cmd = ubuntu.bootargs(SimpleNamespace(root_device=dev))
            self.assertIn(f"root={dev}", cmd)
        cmd = ubuntu.bootargs(SimpleNamespace(root_device="ramroot", rootfs=Path("/srv/raptor"),
                                              server="192.168.50.1"))
        self.assertIn("rdinit=/sbin/init", cmd)
        self.assertIn("ip=dhcp", cmd)
        self.assertNotIn("root=/dev/nfs", cmd)
        sqsh_cmd = ubuntu.bootargs(SimpleNamespace(root_device="squashfs",
                                                   rootfs=Path("/srv/raptor"),
                                                   server="192.168.50.1"))
        self.assertIn("rdinit=/init", sqsh_cmd)
        self.assertNotIn("systemd.unit=", sqsh_cmd)
        min_cmd = ubuntu.bootargs(SimpleNamespace(root_device="squashfs",
                                                  systemd_target="minimal",
                                                  rootfs=Path("/srv/raptor"),
                                                  server="192.168.50.1"))
        self.assertIn("rdinit=/init", min_cmd)
        self.assertIn("systemd.unit=raptor-minimal.target", min_cmd)
        with self.assertRaisesRegex(RuntimeError, "unsupported systemd target"):
            ubuntu.bootargs(SimpleNamespace(root_device="squashfs", systemd_target="custom",
                                            rootfs=Path("/srv/raptor"), server="192.168.50.1"))
        with self.assertRaisesRegex(RuntimeError, "unsupported block root"):
            ubuntu.bootargs(SimpleNamespace(root_device="/dev/sda1 rw init=/bin/sh"))

    def test_ramroot_fstab_and_initrd_packaging(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "rootfs"
            (root / "etc").mkdir(parents=True)
            (root / "usr/share/doc/pkg").mkdir(parents=True)
            (root / "usr/share/doc/pkg/README").write_text("pruned")
            (root / "sbin").mkdir(parents=True)
            (root / "sbin/init").write_text("#!/bin/sh\n")
            ubuntu.save(root / ".raptor-rootfs.json", {"schema": "v1"})
            out = Path(temp) / "initrd.img"
            ubuntu.build_ramroot(root, out, "192.168.50.1", root)
            self.assertTrue(out.is_file())
            self.assertGreater(out.stat().st_size, 0)
            # Original rootfs must remain untouched
            self.assertTrue((root / "usr/share/doc/pkg/README").is_file())
            fstab = ubuntu.ramroot_fstab("192.168.50.1", root)
            self.assertIn("/mnt/host nfs", fstab)
            self.assertIn("x-systemd.automount", fstab)

    def test_squashfs_packaging_preserves_full_rootfs(self):
        if ubuntu.shutil.which("mksquashfs") is None:
            self.skipTest("mksquashfs not installed")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "rootfs"
            (root / "etc/ssh/sshd_config.d").mkdir(parents=True)
            (root / "etc/fstab").write_text("# old\n")
            (root / "usr/sbin").mkdir(parents=True)
            (root / "usr/share/doc/pkg").mkdir(parents=True)
            (root / "usr/share/doc/pkg/README").write_text("kept")
            (root / "mnt").mkdir(parents=True)
            ubuntu.save(root / ".raptor-rootfs.json", {"schema": "v1"})
            out = Path(temp) / "ubuntu.sqsh"
            ubuntu.build_squashfs(root, out, "192.168.50.1", root, use_sudo=False)
            self.assertTrue(out.is_file())
            self.assertEqual(out.read_bytes()[:4], b"hsqs")
            self.assertTrue((root / "usr/share/doc/pkg/README").is_file())
            if ubuntu.shutil.which("riscv64-linux-gnu-gcc") is not None:
                cpio_gz = Path(temp) / "initramfs.cpio.gz"
                cpio_sz = ubuntu.build_switchroot_initramfs(cpio_gz, "riscv64-linux-gnu-")
                self.assertGreater(cpio_sz, 0)
                self.assertLess(cpio_sz, ubuntu.PHRAM_OFFSET)
                combined = Path(temp) / "combined.img"
                packed_cpio, packed_sqsh = ubuntu.pack_combined_squashfs_initrd(
                    cpio_gz, out, combined)
                found_cpio, found_sqsh = ubuntu.inspect_combined_squashfs_initrd(combined)
                self.assertEqual((packed_cpio, packed_sqsh), (found_cpio, found_sqsh))

    def test_runtime_dtb_stamps_epoch_proxy_and_mirror(self):
        if ubuntu.shutil.which("dtc") is None or ubuntu.shutil.which("fdtget") is None:
            self.skipTest("dtc/fdtget not installed")
        with tempfile.TemporaryDirectory() as temp:
            dts = Path(temp) / "test.dts"
            dtb = Path(temp) / "runtime.dtb"
            dts.write_text("/dts-v1/;\n/ {\n\tchosen {\n\t};\n};\n")
            ubuntu.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)])
            ubuntu.stamp_runtime_dtb(
                dtb,
                host_epoch=0x0000000067456789,
                http_proxy="http://192.168.50.1:7890",
                apt_mirror="http://mirrors.example.org/ubuntu-ports",
            )
            epoch_cells = ubuntu.subprocess.check_output(
                ["fdtget", "-t", "x", str(dtb), "/chosen", "raptor,host-epoch"], text=True
            ).split()
            self.assertEqual(epoch_cells, ["0", "67456789"])
            proxy = ubuntu.subprocess.check_output(
                ["fdtget", "-t", "s", str(dtb), "/chosen", "raptor,http-proxy"], text=True
            ).strip()
            self.assertEqual(proxy, "http://192.168.50.1:7890")
            mirror = ubuntu.subprocess.check_output(
                ["fdtget", "-t", "s", str(dtb), "/chosen", "raptor,apt-mirror"], text=True
            ).strip()
            self.assertEqual(mirror, "http://mirrors.example.org/ubuntu-ports/")
            with self.assertRaisesRegex(RuntimeError, "invalid HTTP proxy"):
                ubuntu.stamp_runtime_dtb(dtb, http_proxy="http://bad\"quote")

    def test_boot_env_enables_user_perf_counters_and_apps_path(self):
        self.assertIn("perf_user_access", ubuntu.RAPTOR_BOOT_ENV_SH)
        self.assertIn("debian.list", ubuntu.RAPTOR_BOOT_ENV_SH)
        self.assertIn("/etc/apk/repositories", ubuntu.RAPTOR_BOOT_ENV_SH)
        self.assertIn("kernel.perf_user_access = 2", ubuntu.PERF_SYSCTL_CONF)
        self.assertIn("/opt/raptor/bin", ubuntu.RAPTOR_APPS_PROFILE_SH)

    def test_debian_and_alpine_ramroot_squashfs_and_make_targets(self):
        alpine_cmd = ubuntu.bootargs(SimpleNamespace(
            distro="alpine", root_device="squashfs", systemd_target="minimal",
            rootfs=Path("/srv/alpine"), server="192.168.50.1"))
        self.assertIn("rdinit=/init", alpine_cmd)
        self.assertNotIn("systemd.unit=", alpine_cmd)
        debian_cmd = ubuntu.bootargs(SimpleNamespace(
            distro="debian", root_device="squashfs", systemd_target="minimal",
            rootfs=Path("/srv/debian"), server="192.168.50.1"))
        self.assertIn("systemd.unit=raptor-minimal.target", debian_cmd)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "alpine-rootfs"
            (root / "sbin").mkdir(parents=True)
            (root / "sbin/openrc").write_text("#!/bin/sh\n")
            (root / "sbin/init").write_text("#!/bin/sh\n")
            (root / "etc/ssh/sshd_config.d").mkdir(parents=True)
            ubuntu.save(root / ".raptor-rootfs.json", {"schema": "v1", "distro": "alpine"})
            self.assertTrue(ubuntu.is_openrc_rootfs(root))
            fstab = ubuntu.ramroot_fstab("192.168.50.1", root, openrc=True)
            self.assertIn("noauto,nolock", fstab)
            self.assertNotIn("x-systemd.automount", fstab)
            initrd = Path(temp) / "alpine-initrd.img"
            ubuntu.build_ramroot(root, initrd, "192.168.50.1", root)
            self.assertGreater(initrd.stat().st_size, 0)
            if ubuntu.shutil.which("mksquashfs") is not None:
                sqsh = Path(temp) / "alpine.sqsh"
                ubuntu.build_squashfs(root, sqsh, "192.168.50.1", root, use_sudo=False)
                self.assertEqual(sqsh.read_bytes()[:4], b"hsqs")
        for board, smp_preset in (("mlk-cu08-ku15p", "default-smp2"),
                                  ("rk-xcku5p-f", "small-smp2")):
            for target, expected in (("debian-rootfs", "--distro 'debian'"),
                                     ("alpine-rootfs", "--distro 'alpine'"),
                                     ("debian-info", "native_build.py"),
                                     ("alpine-info", "native_build.py"),
                                     ("alpine-smp-info", f"--preset {smp_preset}"),
                                     ("alpine-smp-bundle", f"--preset '{smp_preset}'")):
                dry = ubuntu.subprocess.check_output(
                    ["make", "-n", "-C", str(FPGA / board), target], text=True)
                self.assertIn(expected, dry)
            smp_bundle_dry = ubuntu.subprocess.check_output(
                ["make", "-n", "-C", str(FPGA / board), "alpine-smp-bundle"], text=True)
            self.assertIn("--distro 'alpine'", smp_bundle_dry)
            self.assertIn("--root-device 'squashfs'", smp_bundle_dry)
            smp_boot_dry = ubuntu.subprocess.check_output(
                ["make", "-n", "-C", str(FPGA / board), "alpine-smp-boot",
                 "UART_PORT=/dev/ttyUSB0", "UBUNTU_MAC=02:52:41:50:15:02"],
                text=True)
            self.assertIn("--mac '02:52:41:50:15:02'", smp_boot_dry)

    def test_runtime_dtb_mac_override(self):
        clean_mac, octets = ubuntu.parse_unicast_mac("02:52:41:50:15:02")
        self.assertEqual(clean_mac, "02:52:41:50:15:02")
        self.assertEqual(octets, bytes.fromhex("025241501502"))
        with self.assertRaises(RuntimeError):
            ubuntu.parse_unicast_mac("03:52:41:50:15:02")
        with tempfile.TemporaryDirectory() as tmp:
            dts = Path(tmp) / "board.dts"
            dtb = Path(tmp) / "board.dtb"
            dts.write_text(
                "/dts-v1/;\n/ {\n"
                "  chosen {};\n"
                "  soc {\n"
                "    ethernet@18002000 {\n"
                "      local-mac-address = [02 52 41 50 15 01];\n"
                "    };\n"
                "  };\n};\n"
            )
            ubuntu.subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
                                  check=True)
            ubuntu.stamp_runtime_dtb(dtb, host_epoch=1700000000,
                                     mac_override="02:52:41:50:15:02",
                                     eth_node="/soc/ethernet@18002000")
            stamped = ubuntu.subprocess.check_output(
                ["fdtget", "-t", "bx", str(dtb), "/soc/ethernet@18002000", "local-mac-address"],
                text=True).strip()
            self.assertEqual(stamped, "2 52 41 50 15 2")

    def test_localhost_proxy_relay_forwards_bytes(self):
        import socket

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as upstream:
            upstream.bind(("127.0.0.1", 0))
            upstream.listen(1)
            up_port = upstream.getsockname()[1]

            def serve_once():
                conn, _ = upstream.accept()
                with conn:
                    req = conn.recv(64)
                    conn.sendall(b"OK:" + req)

            worker = ubuntu.threading.Thread(target=serve_once, daemon=True)
            worker.start()
            with ubuntu.board_proxy_context(f"http://127.0.0.1:{up_port}", "127.0.0.1") as url:
                relay_port = int(url.rsplit(":", 1)[1])
                with socket.create_connection(("127.0.0.1", relay_port), timeout=3.0) as client:
                    client.sendall(b"PING")
                    self.assertEqual(client.recv(64), b"OK:PING")
            worker.join(timeout=2.0)

    def test_nfs_nolock_and_sshd_proxy_setenv(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            root.mkdir()
            args = ubuntu.argparse.Namespace(
                root_device="nfs", server="192.168.50.1", rootfs=root,
                systemd_target="default", distro="alpine",
            )
            bargs = ubuntu.bootargs(args)
            self.assertIn(",vers=3,tcp,nolock,rsize=32768,wsize=32768 ", bargs)
        self.assertIn("98-raptor-proxy.conf", ubuntu.RAPTOR_BOOT_ENV_SH)
        self.assertIn("SetEnv http_proxy=", ubuntu.RAPTOR_BOOT_ENV_SH)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux termios2")
    def test_exact_upload_baud_and_console_restore(self):
        master, slave = pty.openpty()
        try:
            serial = fast_upload.Serial(os.ttyname(slave))
            try:
                for baud in (312500, 625000, 115200):
                    fast_upload.baudrate(serial, baud)
                    config = array.array("I", [0] * 11)
                    fcntl.ioctl(slave, 0x802c542a, config, True)
                    self.assertEqual(config[9:11].tolist(), [baud, baud])
            finally:
                serial.close()
        finally:
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    unittest.main()
