"""Legacy LiteX cache-hook sweep and RV32/RV64 instruction checks.

These are firmware checks, not a substitute for DMA/cache RTL or board tests.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]


def cache_hook():
    source = (LITEX / "cores/cpu/raptor/system.h").read_text()
    return source.split("  __attribute__((unused)) static void flush_cpu_dcache(void)", 1)[1].split(
        "  void flush_l2_cache(void);", 1)[0]


PREFIX = """#define CONFIG_CPU_HAS_DCACHE
#define SRAM_BASE 0x0f000000UL
#define SRAM_SIZE 8192
"""


class CacheMaintenanceTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "host C compiler required")
    def test_all_mapped_blocks_and_fence_order(self):
        # Instrument only the two target-specific instructions; execute the
        # actual C loop and its address arithmetic on the host.
        body = cache_hook().replace(
            'asm volatile("fence iorw,iorw" ::: "memory");', 'record_fence();')
        body = body.replace(
            'asm volatile("cbo.flush 0(%0)" :: "r"(addr) : "memory");',
            'record_block(addr);')
        source = PREFIX + """
#include <assert.h>
static unsigned int count, fences;
static void record_fence(void) {
    assert((fences == 0 && count == 0) || (fences == 1 && count == 64));
    fences++;
}
static void record_block(unsigned long address) {
    assert(fences == 1);
    assert(address == SRAM_BASE + count * 64UL);
    assert(address >= SRAM_BASE && address + 64 <= SRAM_BASE + SRAM_SIZE);
    count++;
}
static void flush_cpu_dcache(void)
""" + body + """
int main(void) { flush_cpu_dcache(); assert(count == 64 && fences == 2); }
"""
        with tempfile.TemporaryDirectory(prefix="raptor-cache-hook-") as temp:
            path = Path(temp)
            (path / "test.c").write_text(source)
            subprocess.run(["cc", "-std=c99", "-Wall", "-Werror", str(path / "test.c"),
                            "-o", str(path / "test")], check=True, capture_output=True)
            subprocess.run([str(path / "test")], check=True)

    @unittest.skipUnless(shutil.which("riscv64-unknown-elf-gcc") and
                         shutil.which("riscv64-unknown-elf-objdump"),
                         "RISC-V toolchain required")
    def test_real_rv32_and_rv64_instructions(self):
        source = PREFIX + "void flush_cpu_dcache(void)" + cache_hook()
        with tempfile.TemporaryDirectory(prefix="raptor-cache-isa-") as temp:
            path = Path(temp)
            (path / "test.c").write_text(source)
            for xlen, abi in ((32, "ilp32"), (64, "lp64")):
                with self.subTest(xlen=xlen):
                    obj = path / f"test{xlen}.o"
                    subprocess.run(["riscv64-unknown-elf-gcc", "-Os", "-Wall", "-Werror",
                                    f"-march=rv{xlen}imac_zicbom", f"-mabi={abi}",
                                    "-c", str(path / "test.c"), "-o", str(obj)],
                                   check=True, capture_output=True)
                    dis = subprocess.run(["riscv64-unknown-elf-objdump", "-d", str(obj)],
                                         check=True, capture_output=True, text=True).stdout
                    self.assertIn("cbo.flush", dis)
                    self.assertNotRegex(dis, r"cbo\.flush\s+\(zero\)")
                    self.assertIn("f000", dis)
                    self.assertIn("f001", dis)
                    self.assertEqual(dis.count("\tfence"), 2)

    def test_sweep_covers_set_selection_contract(self):
        # Raptor's current CBO compares only address bits 11:6, invalidates
        # all ways, and clears higher physical colors together.
        blocks = range(0, 4096, 64)
        for line_bytes in (4, 8, 16, 32, 64, 128):
            for sets in (1, 2, 4, 16, 64, 128, 256):
                with self.subTest(line_bytes=line_bytes, sets=sets):
                    mask = ((sets - 1) * line_bytes) & 0xfc0
                    cleared = {s for address in blocks for s in range(sets)
                               if (s * line_bytes & mask) == (address & mask)}
                    self.assertEqual(cleared, set(range(sets)))


if __name__ == "__main__":
    unittest.main()
