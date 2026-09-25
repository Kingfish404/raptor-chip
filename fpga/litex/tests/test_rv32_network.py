"""RV32 profile isolation and architecture guards; no hardware access."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import rv32_network as rv32
import rv64_network as rv64


class RV32NetworkTest(unittest.TestCase):
    def test_commands_select_rv32_and_preserve_gigabit(self):
        for action, target in (("image", "fpga-img-rv32"), ("build", "fpga-build"), ("load", "fpga-load")):
            with self.subTest(action=action):
                command = rv32.make_command(action, Path("/tmp/rv32-release"))
                self.assertEqual(command[3], target)
                args = dict(arg.split("=", 1) for arg in command[4:])
                self.assertEqual(args["VARIANT"], "linux32")
                self.assertEqual(args["SYS_CLK"], "50000000")
                self.assertEqual(args["RAPT_CONFIG"], "default")
                self.assertEqual(args["ETH_SPEED"], "1000")
                self.assertEqual(args["FMC_SLOT"], "c")
                self.assertEqual(args["ETH_PORT"], "a")
                self.assertEqual(args["LINUX_FPGA_INIT"], "full")
                self.assertEqual(args["EXTRA_FLAGS"], "")  # BIOS awaits explicit boot selection.
                self.assertEqual(args["LINUX_IMG"], args["LINUX_FPGA_PAYLOAD"])
                self.assertTrue(args["LINUX_ISA"].startswith("rv32imafdc_"))
                self.assertTrue(args["BUILD_DIR"].endswith("/build/rv32-network"))
                self.assertEqual(int(args["LINUX_FPGA_DTB_ADDR"], 0), 0x83f00000)

    def test_rv64_defaults_remain_isolated(self):
        args = dict(arg.split("=", 1) for arg in rv64.make_command("build", Path("/tmp/rv64-release"))[4:])
        self.assertEqual(args["VARIANT"], "linux64")
        self.assertTrue(args["BUILD_DIR"].endswith("/build/rv64-network"))
        self.assertIn("rv64", rv64.DEFAULT_PACKAGE.name)
        self.assertIn("rv32", rv32.DEFAULT_PACKAGE.name)

    def test_reject_wrong_xlen_or_abi_before_reading_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            for bits, abi in ((64, "lp64d"), (32, "ilp32")):
                (package / "manifest.json").write_text(json.dumps({"bits": bits, "abi": abi, "variant": "buildroot"}))
                with self.assertRaisesRegex(ValueError, "RV32 ILP32D"):
                    rv32.check_package(package)


if __name__ == "__main__":
    unittest.main()
