"""RV64 network profile checks; no shared RTL pack, synthesis or board access."""
import gzip
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / "scripts"))
sys.path.insert(0, str(LITEX))
import rv64_network as profile
import ku15p_soc as shared
import mlk_cu08_ku15p as cu08
from litex.soc.integration.builder import Builder


class RV64NetworkTest(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)

    def test_commands_keep_profile_in_recursive_make(self):
        for action, target in (("image", "fpga-img-rv64"), ("build", "fpga-build"), ("load", "fpga-load")):
            cmd = profile.make_command(action, Path("/tmp/release"))
            self.assertEqual(cmd[3], target)
            args = dict(arg.split("=", 1) for arg in cmd[4:])
            self.assertEqual(args["VARIANT"], "linux64")
            self.assertEqual(args["LINUX_IMG"], args["LINUX_FPGA_PAYLOAD"])
            self.assertEqual(args["LINUX_FPGA_INIT"], "full")
            self.assertEqual(args["WITH_ETHERNET"], "1")
            self.assertEqual(args["ETH_SPEED"], "1000")
            self.assertEqual(args["FMC_SLOT"], "c")
            self.assertEqual(args["ETH_PORT"], "a")
            self.assertEqual(args["EXTRA_FLAGS"], "")
            self.assertEqual(args["FPGA_FLAVOR_SUFFIX"], "manualboot")
            self.assertTrue(args["LINUX_ISA"].startswith("rv64imafdc_"))
            self.assertEqual(int(args["LINUX_FPGA_DTB_OFFSET"], 0), 64 * 1024**2)
            self.assertTrue(args["BUILD_DIR"].endswith("/build/rv64-network"))

    def test_newc_reader_does_not_extract(self):
        def entry(name, contents):
            fields = [0, 0o100644, 0, 0, 1, 0, len(contents), 0, 0, 0, 0, len(name) + 1, 0]
            header = b"070701" + b"".join(f"{x:08x}".encode() for x in fields)
            data = header + name.encode() + b"\0"
            data += b"\0" * (-len(data) % 4)
            data += contents
            return data + b"\0" * (-len(data) % 4)
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "rootfs.gz"
            archive.write_bytes(gzip.compress(entry("./etc/network/interfaces", b"auto eth0\n") + entry("TRAILER!!!", b"")))
            self.assertEqual(profile.cpio_files(archive), {"etc/network/interfaces": b"auto eth0\n"})
            self.assertEqual(list(Path(tmp).iterdir()), [archive])
            archive.write_bytes(gzip.compress(entry("init", b"bad")))
            with self.assertRaisesRegex(ValueError, "trailer"):
                profile.cpio_files(archive)

    def test_reject_tiny_shell(self):
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp)
            (package / "manifest.json").write_text(json.dumps({"bits": 64, "abi": "lp64", "variant": "tiny_shell"}))
            with self.assertRaisesRegex(ValueError, "Buildroot"):
                profile.check_package(package)

    def test_sd_autoboot_always_rejected(self):
        for controller in (False, True):
            with self.assertRaisesRegex(ValueError, "Automatic boot is disabled"):
                cu08.RaptorMLKCU08SoC(sys_clk_freq=50e6, sdcard_autoboot=True,
                                     with_sdcard=controller, integrated_main_ram_size=0x10000)

    def test_rv32_rv64_sd_boot_policy(self):
        # Production peripheral elaboration, CPU collection intentionally
        # disabled: this must never call sim/Makefile or alter shared stamps.
        for variant in ("linux32", "linux64"):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as tmp:
                with patch.object(shared.Raptor, "add_sources", lambda *args, **kwargs: None):
                    soc = cu08.RaptorMLKCU08SoC(sys_clk_freq=50e6,
                        cpu_variant=variant, with_sdcard=True, with_ethernet=True,
                        eth_speed=100, integrated_main_ram_size=0x10000)
                    Builder(soc, output_dir=tmp, compile_software=False).build(run=False)
                csr = json.loads((Path(tmp) / "csr.json").read_text())
                self.assertIn("sdcard_boot_disable", csr["constants"])
                self.assertIn("config_bios_no_boot", csr["constants"])
                self.assertIn("ethmac", csr["csr_bases"])
                self.assertEqual(csr["constants"]["cm005_eth_speed"], 100)


if __name__ == "__main__":
    unittest.main()
