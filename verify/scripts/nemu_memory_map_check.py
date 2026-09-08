#!/usr/bin/env python3
"""Compile the real NEMU address predicates for Raptor and legacy layouts."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="raptor-memory-map-") as directory:
        work = Path(directory)
        (work / "common.h").write_text("""
#include <stdint.h>
#include <stdbool.h>
#if TEST_XLEN == 64
typedef uint64_t word_t;
typedef uint64_t paddr_t;
#else
typedef uint32_t word_t;
typedef uint32_t paddr_t;
#endif
#define CONFIG_MBASE 0x80000000u
#define CONFIG_MSIZE 0x10000000u
#define CONFIG_PC_RESET_OFFSET 0
""")
        (work / "check.c").write_text("""
#include <assert.h>
#include <memory/paddr.h>
int main(void) {
  assert(in_sdram(0xa0000000u));
  assert(in_sdram(0xa1ffffffu));
  assert(in_flash(0x30000000u));
  assert(in_flash(0x3fffffffu));
  assert(paddr_is_memory_span(0xa1fffff8u, 8));
  assert(paddr_is_memory_span(0x3ffffff8u, 8));
#ifdef CONFIG_RAPTOR_MEMORY_MAP
  assert(!in_sdram(0xa2000000u));
  assert(!in_sdram(0xbfffffffu));
  assert(!in_flash(0x40000000u));
  assert(!in_flash(0x6fffffffu));
  assert(!in_rom(0x1000u));
  assert(!paddr_is_memory_span(0xa1ffffffu, 2));
  assert(!paddr_is_memory_span(0x3fffffffu, 2));
#else
  assert(in_sdram(0xa2000000u));
  assert(in_sdram(0xbfffffffu));
  assert(in_flash(0x40000000u));
  assert(in_flash(0x6fffffffu));
  assert(in_rom(0x1000u));
#endif
  assert(!in_sdram(0xc0000000u));
  assert(!in_flash(0x70000000u));
  assert(in_mrom(0x20000000u));
  assert(in_sram(0x0f001fffu));
  assert(!in_sram(0x0f002000u));
  return 0;
}
""")
        for xlen in (32, 64):
            for raptor in (False, True):
                binary = work / "check"
                flags = ["-DCONFIG_RAPTOR_MEMORY_MAP=1"] if raptor else []
                subprocess.run([args.cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                                f"-DTEST_XLEN={xlen}", *flags, "-I", str(work),
                                "-I", str(root / "nemu/include"), str(work / "check.c"),
                                "-o", str(binary)], check=True)
                subprocess.run([str(binary)], check=True)
                print(f"PASS: NEMU RV{xlen} {'Raptor' if raptor else 'legacy'} memory map")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
