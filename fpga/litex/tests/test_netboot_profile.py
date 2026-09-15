"""Fixed-profile command expansion only; never invoke Vivado or the real submake."""
import pathlib
import shlex
import subprocess
import unittest


LITEX = pathlib.Path(__file__).resolve().parents[1]


class NetbootProfileTest(unittest.TestCase):
    def test_help_declarations(self):
        text = (LITEX / "Makefile").read_text()
        for xlen in (32, 64):
            for operation in ("build", "load", "info", "check", "bundle", "serve", "run", "test", "console"):
                self.assertIn(f"fpga-netboot-rv{xlen}-{operation}: ## ", text)

    def expand(self, target, *overrides):
        result = subprocess.run(
            ["make", "--no-print-directory", "-n", "MAKE=echo", target, *overrides],
            cwd=LITEX, text=True, capture_output=True, check=True,
        )
        calls = []
        for line in result.stdout.replace("\\\n", " ").splitlines():
            words = shlex.split(line)
            if len(words) > 2 and words[1].endswith("/scripts/netboot_flow.py"):
                split = words.index("--")
                calls.append((words[2], dict(w.split("=", 1) for w in words[split + 1:])))
        return calls

    def test_build_load_info_same_profile(self):
        for xlen in (32, 64):
            with self.subTest(xlen=xlen):
                prefix = f"fpga-netboot-rv{xlen}-"
                build = self.expand(prefix + "build")
                load = self.expand(prefix + "load")
                info = self.expand(prefix + "info")
                self.assertEqual([c[0] for c in load], ["load"])
                settings = build[0][1]
                self.assertEqual(build[0][0], "build")
                for _, args in load + info:
                    self.assertEqual(args, settings)
                for operation in ("check", "bundle", "serve", "run", "test", "console"):
                    self.assertEqual(self.expand(prefix + operation)[0][1], settings)
                self.assertEqual(settings["VARIANT"], f"linux{xlen}")
                self.assertEqual(settings["WITH_ETHERNET"], "1")
                self.assertEqual(settings["VIVADO_ROUTE_DIRECTIVE"], "Explore")
                self.assertEqual(settings["SYS_CLK"], "50000000")
                self.assertEqual(settings["RAPT_CONFIG"], "default")
                self.assertEqual(settings["RAPT_PACK_VFLAGS"], "")
                self.assertIn(f"/rv{xlen}/soc", settings["FPGA_DIR"])

    def test_paths_and_fixed_settings(self):
        calls = self.expand("fpga-netboot-rv32-build",
                            "NETBOOT_BUILD_ROOT=/tmp/netboot path",
                            "NETBOOT_PAYLOAD_RV32=/tmp/payload path/fw.bin",
                            "WITH_ETHERNET=0", "VIVADO=/opt/tool path/vivado")
        settings = calls[0][1]
        self.assertEqual(settings["WITH_ETHERNET"], "1")
        self.assertEqual(settings["FPGA_DIR"], "/tmp/netboot path/rv32/soc")
        self.assertEqual(settings["LINUX_IMG"], "/tmp/payload path/fw.bin")
        self.assertEqual(settings["VIVADO"], "/opt/tool path/vivado")


if __name__ == "__main__":
    unittest.main()
