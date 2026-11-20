"""Check that the raw simulation ROM begins with its reset entry."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


LITEX = Path(__file__).resolve().parents[1]
FIRMWARE = LITEX / "firmware/sim"
CROSS = "riscv64-linux-gnu-"


@unittest.skipUnless(shutil.which(CROSS + "gcc") and shutil.which("dtc") and shutil.which("fdtget"),
                     "RISC-V Linux GCC and device-tree tools are required")
class SimBootTest(unittest.TestCase):
    def test_build_id_cannot_displace_reset_entry(self):
        with tempfile.TemporaryDirectory(prefix="raptor-chip-rom-test-", dir="/tmp") as tmp:
            root = Path(tmp)
            for xlen, abi, mmu in ((32, "ilp32", "sv32"), (64, "lp64", "sv39")):
                with self.subTest(xlen=xlen):
                    output = root / f"linux{xlen}"
                    dtb = output / "litex-soc.dtb"
                    subprocess.run(["make", "-C", str(LITEX), f"VARIANT=linux{xlen}",
                                    f"FW_SIM_DIR={output}", str(dtb)], check=True,
                                   capture_output=True)
                    isa = subprocess.check_output(["fdtget", str(dtb), "/cpus/cpu@0", "riscv,isa"],
                                                  text=True).strip()
                    self.assertTrue(isa.startswith(f"rv{xlen}imac_"), isa)
                    mmu_type = subprocess.check_output(
                        ["fdtget", str(dtb), "/cpus/cpu@0", "mmu-type"], text=True).strip()
                    self.assertEqual(mmu_type, f"riscv,{mmu}")
                    elf = output / "boot.elf"
                    subprocess.run([CROSS + "gcc", f"-march=rv{xlen}imac", f"-mabi={abi}",
                                    "-nostdlib", "-nostartfiles", "-fno-pic", "-no-pie",
                                    "-Wl,--build-id=sha1", "-T", str(FIRMWARE / "link.ld"),
                                    "-I" + str(output), "-o", str(elf), str(FIRMWARE / "boot.S")],
                                   check=True, capture_output=True)
                    symbols = subprocess.check_output([CROSS + "nm", str(elf)], text=True)
                    self.assertRegex(symbols, r"(?m)^0*20000000 T _start$")
                    sections = subprocess.check_output([CROSS + "readelf", "-SW", str(elf)],
                                                       text=True)
                    self.assertNotIn(".note", sections)


if __name__ == "__main__":
    unittest.main()
