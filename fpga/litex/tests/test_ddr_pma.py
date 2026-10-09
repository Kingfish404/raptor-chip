"""KU15P DDR defaults and pack contract, without touching shared build outputs."""
import os
import pathlib
import shutil
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

LITEX = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / "cores"))
sys.path.insert(0, str(LITEX / "scripts"))
from cpu.raptor.core import Raptor


class DDRPMATest(unittest.TestCase):
    def test_mig_accepts_narrow_litex_transfers(self):
        source = (LITEX / "scripts/ku15p_ddr4_mig.tcl").read_text()
        self.assertIn("CONFIG.C0.DDR4_AxiDataWidth {512}", source)
        self.assertIn("CONFIG.C0.DDR4_AxiNarrowBurst {true}", source)

    def test_cu08_2133_mig_is_board_specific(self):
        config = (LITEX / "mk/config.mk").read_text()
        board = (LITEX / "mlk_cu08_ku15p.py").read_text()
        soc = (LITEX / "ku15p_soc.py").read_text()
        common = (LITEX / "scripts/ku15p_ddr4_mig.tcl").read_text()
        cu08 = (LITEX / "scripts/ku15p_cu08_ddr4_mig.tcl").read_text()
        self.assertIn("BOARD_mlk_cu08_ku15p_MIG_TCL             := "
                      "scripts/ku15p_cu08_ddr4_mig.tcl", config)
        self.assertIn("BOARD_mlk_cu07_ku15p_MIG_TCL             := "
                      "scripts/ku15p_ddr4_mig.tcl", config)
        self.assertIn('mig_tcl="ku15p_cu08_ddr4_mig.tcl"', board)
        self.assertIn('platform.add_ip(os.path.join(_here, "scripts", mig_tcl))', soc)
        self.assertIn('platform.add_ip(os.path.join(_here, "scripts", "ku15p_ddr4_mig.tcl"))', soc)
        self.assertLess(soc.index('platform.add_ip(os.path.join(_here, "scripts", mig_tcl))'),
                        soc.index('platform.add_ip(os.path.join(_here, "scripts", "ku15p_ddr4_mig.tcl"))'))
        for key, default, new in (("time_period", 833, 938),
                                  ("input_clock_period", 9996, 10005),
                                  ("cas_latency", 17, 15),
                                  ("cas_write_latency", 12, 11)):
            self.assertIn(f"set raptor_ddr4_{key} {default}", common)
            self.assertIn(f"set raptor_ddr4_{key} {new}", cu08)

    def test_pack_override(self):
        for variant in ("linux32", "linux64"):
            for capacity in (0x40000000, 0x80000000):
                with self.subTest(variant=variant, capacity=capacity), patch.dict(os.environ, {
                    "RAPT_PACK_VFLAGS": "-DRAPT_PMEM_BYTES=268435456",
                }), patch("isolated_pack.pack", return_value=pathlib.Path("/private/rapt_pack.sv")) as run:
                    Raptor.add_sources(Mock(), variant, pmem_size=capacity)
                    flags = run.call_args.args[3]
                    self.assertIn(f"-DRAPT_PMEM_BYTES={capacity}", flags)
                    self.assertEqual(flags.count("-DRAPT_PMEM_BYTES="), 1)
                    self.assertEqual("-DRAPT_RV64" in flags, variant == "linux64")

    def test_invalid_window(self):
        for size in (0, -1, 0x30000000, 0x100000000):
            with self.subTest(size=size), patch("isolated_pack.pack") as run:
                with self.assertRaises(ValueError):
                    Raptor.add_sources(Mock(), pmem_size=size)
                run.assert_not_called()

    def test_finalize_forwards_size(self):
        cpu = Raptor(Mock())
        cpu.set_reset_address(0x20000000)
        cpu.pmem_size = 0x40000000
        with patch.object(cpu, "add_sources") as add:
            cpu.do_finalize()
        self.assertEqual(add.call_args.kwargs["pmem_size"], 0x40000000)

    def test_make_defaults(self):
        # Evaluate only the real capacity fragment; the full Makefile has
        # parse-time build-stamp writes and board-detection side effects.
        source = (LITEX / "Makefile").read_text()
        fragment = source.split("_WITH_EXTERNAL_MAIN_RAM :=", 1)[1]
        fragment = "_WITH_EXTERNAL_MAIN_RAM :=" + fragment.split("export RAPT_PACK_VFLAGS", 1)[0]
        ram = next(line for line in source.splitlines() if line.startswith("LINUX_FPGA_RAM_SIZE ?="))
        recipe = '\nall:\n\t@echo $(LINUX_FPGA_RAM_SIZE)\n\t@echo $(RAPT_PACK_VFLAGS)\n'
        for xlen, mig, dram, size, expected_linux in (
            (32, 1, 0, '0x80000000', '0x40000000'),
            (64, 1, 0, '0x80000000', '0x80000000'),
            (32, 1, 0, '0x40000000', '0x40000000'),
            (32, 0, 1, '0x40000000', '0x40000000'),
            (32, 0, 0, '0x80000', '0x80000'),
        ):
            with self.subTest(xlen=xlen, mig=mig, dram=dram, size=size):
                result = subprocess.run([
                    "make", "--no-print-directory", "-f", "-",
                    f"LINUX_XLEN={xlen}", f"WITH_MIG={mig}", f"WITH_LITEDRAM={dram}",
                    f"MIG_SIZE={size}", f"LITEDRAM_SIZE={size}",
                    f"INTEGRATED_MAIN_RAM_SIZE={size if not (mig or dram) else '0'}",
                ], input=fragment + ram + recipe, text=True, capture_output=True, check=True,
                   env={k: v for k, v in os.environ.items()
                        if k not in ("MAKEFLAGS", "MAKEOVERRIDES", "RAPT_PACK_VFLAGS", "LINUX_FPGA_RAM_SIZE")})
                self.assertEqual(result.stdout.splitlines()[0].strip(), expected_linux)
                self.assertIn(f"-DRAPT_PMEM_BYTES={int(size, 0)}", result.stdout)

    @unittest.skipUnless(shutil.which("dtc"), "dtc is required")
    def test_linux_device_tree_ram_caps(self):
        template = (LITEX / "firmware/linux-fpga/litex-soc.dts.in").read_text()
        for xlen, mmu, memory_size in ((32, "sv32", "0x40000000"),
                                       (64, "sv39", "0x80000000")):
            with self.subTest(xlen=xlen):
                values = {
                    "MODEL": "KU15P DDR test", "TIMEBASE": "50000000",
                    "MEM_SIZE": memory_size, "BOOTARGS": "console=liteuart0,115200",
                    "UART_BASE": "0x11001800", "UART_UNIT_ADDR": "11001800",
                    "CBOM_BLOCK_SIZE": "64", "RISCV_ISA": f"rv{xlen}ima",
                    "RISCV_ISA_BASE": f"rv{xlen}i", "RISCV_ISA_EXTENSIONS": '"i", "m", "a"',
                    "RISCV_MMU": mmu,
                }
                source = template
                for key, value in values.items():
                    source = source.replace(f"@{key}@", value)
                dtb = subprocess.run(["dtc", "-I", "dts", "-O", "dtb"],
                                     input=source.encode(), capture_output=True, check=True).stdout
                decoded = subprocess.run(["dtc", "-I", "dtb", "-O", "dts"],
                                         input=dtb, capture_output=True, check=True).stdout.decode()
                memory = decoded.split("memory@80000000 {", 1)[1].split("};", 1)[0]
                self.assertIn(f"reg = <0x80000000 {memory_size}>;", memory)


if __name__ == "__main__":
    unittest.main()
