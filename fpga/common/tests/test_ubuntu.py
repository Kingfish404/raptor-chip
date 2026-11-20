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
import ubuntu
from unittest.mock import patch

FPGA = Path(__file__).resolve().parents[2]


class UbuntuTests(unittest.TestCase):
    def test_board_network_profiles_and_default_preset(self):
        for board, driver, address in (("rk-xcku5p-f", "native", "192.168.50.88"),
                                       ("mlk-cu08-ku15p", "liteeth", "192.168.50.90")):
            ubuntu.configure(FPGA / board)
            self.assertEqual(ubuntu.network_profile()["driver"], driver)
            self.assertEqual(ubuntu.PROFILE["ubuntu"]["boot_ip"], address)
            with patch.object(sys, "argv", ["ubuntu.py", "kernel"]), \
                    patch.object(ubuntu, "kernel") as kernel:
                ubuntu.main()
                self.assertEqual(kernel.call_args.args[0].preset, "default")

    def test_kernel_config_enables_rva23_and_kvm_without_conflict(self):
        source = ubuntu.json.loads((ubuntu.COMMON / "linux/kernel-source.json").read_text())
        self.assertRegex(source["version"], r"^\d+\.\d+\.\d+$")
        self.assertGreaterEqual(int(source["version"].split(".")[0]), 7)
        lines = (ubuntu.COMMON / "linux/ubuntu.config").read_text().splitlines()
        for option in ("CONFIG_RISCV_ISA_V=y", "CONFIG_RISCV_ISA_SUPM=y",
                       "CONFIG_RISCV_ISA_SVNAPOT=y", "CONFIG_RISCV_ISA_SVPBMT=y",
                       "CONFIG_VIRTUALIZATION=y", "CONFIG_KVM=y",
                       "CONFIG_VIRTIO_MMIO=y", "CONFIG_VIRTIO_BLK=y", "CONFIG_VIRTIO_NET=y",
                       "CONFIG_PCI=y", "CONFIG_PCI_HOST_GENERIC=y", "CONFIG_BLK_DEV_NVME=y",
                       "CONFIG_MMC=y", "CONFIG_MMC_SDHCI=y",
                       "CONFIG_MMC_SDHCI_OF_ARASAN=y", "CONFIG_MMC_SDHCI_PCI=y"):
            self.assertIn(option, lines)
        self.assertNotIn("# CONFIG_VIRTUALIZATION is not set", lines)
        self.assertNotIn("# CONFIG_KVM is not set", lines)
        self.assertNotIn("# CONFIG_PCI is not set", lines)
        self.assertNotIn("# CONFIG_MMC is not set", lines)

    def test_kernel_reuse_checks_driver_and_word_pio_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / "kernel.config"
            config.write_text("CONFIG_RAPTOR_NATIVE_ETH=y\nCONFIG_LITEX_LITEETH=y\n")
            record = {"schema": "raptor-native-ubuntu-kernel-v1", "inputs": {"driver": {}},
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
        with self.assertRaisesRegex(RuntimeError, "unsupported block root"):
            ubuntu.bootargs(SimpleNamespace(root_device="/dev/sda1 rw init=/bin/sh"))

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
