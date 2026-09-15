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
    def test_pack_override(self):
        for variant in ("linux32", "linux64"):
            with self.subTest(variant=variant), patch.dict(os.environ, {
                "RAPT_PACK_VFLAGS": "-DRAPT_PMEM_BYTES=268435456",
            }), patch("isolated_pack.pack", return_value=pathlib.Path("/private/rapt_pack.sv")) as run:
                Raptor.add_sources(Mock(), variant, pmem_size=0x40000000)
                flags = run.call_args.args[3]
                self.assertIn("-DRAPT_PMEM_BYTES=1073741824", flags)
                self.assertEqual(flags.count("-DRAPT_PMEM_BYTES="), 1)
                self.assertEqual("-DRAPT_RV64" in flags, variant == "linux64")

    def test_invalid_window(self):
        for size in (0, -1, 0x30000000, 0x80000000):
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
        fragment = source.split("# Match the shared KU15P target's PMA override", 1)[1]
        fragment = fragment.split("export RAPT_PACK_VFLAGS", 1)[0]
        fragment = fragment[fragment.index("KU15P_PMEM_SIZE :="):]
        ram = next(line for line in source.splitlines() if line.startswith("LINUX_FPGA_RAM_SIZE ?="))
        recipe = '\nall:\n\t@echo $(LINUX_FPGA_RAM_SIZE)\n\t@echo $(RAPT_PACK_VFLAGS)\n'
        for board in ("mlk_cu07_ku15p", "mlk_cu08_ku15p", "tang_mega_138k_pro"):
            for mig, dram in ((0, 0), (1, 0), (0, 1)):
                with self.subTest(board=board, mig=mig, dram=dram):
                    result = subprocess.run([
                        "make", "--no-print-directory", "-f", "-",
                        f"FPGA_BOARD={board}", f"WITH_MIG={mig}", f"WITH_LITEDRAM={dram}",
                        "MIG_SIZE=0x40000000", "LITEDRAM_SIZE=0x40000000",
                    ], input=fragment + ram + recipe, text=True, capture_output=True, check=True,
                       env={k: v for k, v in os.environ.items()
                            if k not in ("MAKEFLAGS", "MAKEOVERRIDES", "RAPT_PACK_VFLAGS", "LINUX_FPGA_RAM_SIZE")})
                    enabled = board.startswith("mlk_cu") and (mig or dram)
                    self.assertEqual(result.stdout.splitlines()[0].strip(),
                                     "0x40000000" if enabled else "0x10000000")
                    self.assertEqual("-DRAPT_PMEM_BYTES=1073741824" in result.stdout, bool(enabled))

    @unittest.skipUnless(shutil.which("dtc"), "dtc is required")
    def test_one_gib_device_tree(self):
        template = (LITEX / "firmware/linux-fpga/litex-soc.dts.in").read_text()
        for xlen, mmu in ((32, "sv32"), (64, "sv39")):
            with self.subTest(xlen=xlen):
                values = {
                    "MODEL": "KU15P DDR test", "TIMEBASE": "50000000",
                    "MEM_SIZE": "0x40000000", "BOOTARGS": "console=liteuart0,115200",
                    "UART_BASE": "0xf0001800", "UART_UNIT_ADDR": "f0001800",
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
                self.assertIn("reg = <0x80000000 0x40000000>;", memory)


if __name__ == "__main__":
    unittest.main()
