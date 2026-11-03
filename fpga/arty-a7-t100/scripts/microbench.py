#!/usr/bin/env python3
"""Build the repository MicroBench test workload without writing to AM's tree."""

import argparse
import json
import os
from pathlib import Path
import subprocess

from sources import BOARD, ROOT, fingerprint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--prefix", default=os.environ.get("CROSS_COMPILE", "riscv64-elf-"))
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    am = ROOT / "abstract-machine"
    bench = am / "app/am-kernels/benchmarks/microbench"
    sources = sorted((bench / "src").rglob("*.c")) + sorted((bench / "src").rglob("*.cc"))
    sources += sorted((am / "klib/src").glob("*.c"))
    sources += [am / "am/src/riscv/npc" / p for p in
                ("start.S", "trm.c", "ioe.c", "input.c")]
    sources += [BOARD / "firmware/microbench_timer.c"]
    flags = ["-march=rv32imac_zicsr_zifencei", "-mabi=ilp32", "-mcmodel=medany",
             "-O2", "-g", "-fno-pic", "-ffreestanding", "-fno-builtin",
             "-fno-stack-protector", "-fno-asynchronous-unwind-tables",
             "-ffunction-sections", "-fdata-sections", "-Wno-main",
             '-DARCH_H="arch/riscv.h"', '-DMAINARGS="test"']
    flags += ["-I" + str(p) for p in (bench / "include", am / "am/include",
                                    am / "klib/include", am / "am/src/riscv/npc/include",
                                    am / "am/src")]
    objects = []
    # Compile sequentially, leaving the machine's four-job cap unambiguous.
    for index, source in enumerate(sources):
        obj = out / f"{index}-{source.stem}.o"
        objects.append(str(obj))
        cpp = source.suffix == ".cc"
        compiler = args.prefix + ("g++" if cpp else "gcc")
        extra = ["-fno-rtti", "-fno-exceptions"] if cpp else []
        subprocess.run([compiler, *flags, *extra, "-c", str(source), "-o", str(obj)], check=True)
    elf = out / "microbench-test.elf"
    command = [args.prefix + "gcc", *flags, "-nostdlib", "-Wl,--gc-sections",
               "-Wl,--defsym=_pmem_start=0x80000000", "-Wl,--defsym=_entry_offset=0",
               "-Wl,--no-relax", "-T", str(am / "scripts/linker.ld"), *objects,
               "-lgcc", "-o", str(elf)]
    subprocess.run(command, check=True)
    subprocess.run([args.prefix + "objcopy", "-O", "binary", str(elf),
                    str(elf.with_suffix(".bin"))], check=True)
    (out / "sources.json").write_text(json.dumps(fingerprint(sources), indent=2) + "\n")
    print(elf.with_suffix(".bin"))


if __name__ == "__main__":
    main()
