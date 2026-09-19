"""Check that the raw simulation ROM begins with its reset entry."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


FIRMWARE = Path(__file__).resolve().parents[1] / "firmware/sim"
CROSS = "riscv64-linux-gnu-"


@unittest.skipUnless(shutil.which(CROSS + "gcc") and shutil.which("dtc"),
                     "RISC-V Linux GCC and dtc are required")
class SimBootTest(unittest.TestCase):
    def test_build_id_cannot_displace_reset_entry(self):
        with tempfile.TemporaryDirectory(prefix="raptor-chip-rom-test-", dir="/tmp") as tmp:
            root = Path(tmp)
            subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o",
                            str(root / "litex-soc.dtb"), str(FIRMWARE / "litex-soc.dts")],
                           check=True, capture_output=True)
            elf = root / "boot.elf"
            subprocess.run([CROSS + "gcc", "-march=rv32imac", "-mabi=ilp32",
                            "-nostdlib", "-nostartfiles", "-fno-pic", "-no-pie",
                            "-Wl,--build-id=sha1", "-T", str(FIRMWARE / "link.ld"),
                            "-I" + str(root), "-o", str(elf), str(FIRMWARE / "boot.S")],
                           check=True, capture_output=True)
            symbols = subprocess.check_output([CROSS + "nm", str(elf)], text=True)
            self.assertRegex(symbols, r"(?m)^20000000 T _start$")
            sections = subprocess.check_output([CROSS + "readelf", "-SW", str(elf)], text=True)
            self.assertNotIn(".note", sections)


if __name__ == "__main__":
    unittest.main()
