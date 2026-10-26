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
                self.assertEqual(kernel.call_args.args[0].preset, "middle-cache")

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
