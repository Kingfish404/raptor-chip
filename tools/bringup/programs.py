"""Build small local-I/O diagnostics using the existing AM TRM/klib flow."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from .native import output_path
from .native_links import ROOT


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cross", default="riscv64-elf-")
    parser.add_argument("--clock-hz", type=int, required=True)
    args = parser.parse_args(argv)
    if not 1000000 <= args.clock_hz <= 100000000:
        parser.error("give the measured diagnostic clock in 1..100 MHz")
    out = output_path(args.output)
    out.mkdir(parents=True, exist_ok=False)
    source = ROOT / "app/tests/silicon"
    am = ROOT / "abstract-machine"
    flags = ["-march=rv32im_zicsr", "-mabi=ilp32", "-mcmodel=medany", "-mno-relax",
             "-msmall-data-limit=0", "-Os", "-g", "-Wall", "-Wextra", "-Werror",
             "-Wno-unused-parameter",
             "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-nostdlib",
             "-ffunction-sections", "-fdata-sections", '-DARCH_H="arch/riscv.h"',
             f"-DCORE_CLOCK_HZ={args.clock_hz}", f"-I{am / 'am/include'}",
             f"-I{am / 'klib/include'}"]
    common = [source / "start.S", source / "runtime.c", am / "klib/src/stdio.c",
              am / "klib/src/string.c", am / "klib/src/stdlib.c"]
    records = {}
    for program in sorted(source.glob("*.c")):
        if program.name == "runtime.c":
            continue
        for mode in ("ram", "xip"):
            dest = out / mode
            dest.mkdir(exist_ok=True)
            elf = dest / f"{program.stem}.elf"
            code, size, data = ((0x0f000000, 0x1000, 0x0f001000) if mode == "ram" else
                                (0x30000000, 0x10000, 0x0f000000))
            definitions = {"CODE_BASE": code, "CODE_SIZE": size,
                           "DATA_BASE": data, "DATA_SIZE": 0x1600 - (data & 0x1fff)}
            command = [args.cross + "gcc", *flags, f'-DPROGRAM_NAME="{program.stem}"',
                       *map(str, common), str(program), "-T", str(source / "program.ld"),
                       *(f"-Wl,--defsym={name}={value}" for name, value in definitions.items()),
                       "-Wl,--gc-sections,--no-relax,--build-id=none", "-lgcc", "-o", str(elf)]
            commands = [command, [args.cross + "objcopy", "-O", "binary", str(elf),
                                  str(elf.with_suffix(".bin"))]]
            (elf.with_suffix(".commands.json")).write_text(json.dumps(commands, indent=2) + "\n")
            with elf.with_suffix(".build.log").open("w") as log:
                for item in commands:
                    subprocess.run(item, stdout=log, stderr=subprocess.STDOUT, check=True)
            binary = elf.with_suffix(".bin").read_bytes()
            records[f"{mode}/{program.stem}"] = {
                "entry": code, "bytes": len(binary), "clock_hz": args.clock_hz,
                "sha256": hashlib.sha256(binary).hexdigest(),
            }
            if mode == "xip":
                for name, offset in (("silicon", 0), ("arty-native", 0x800000)):
                    text = f"@{offset:08x}\n" + "\n".join(f"{b:02x}" for b in binary) + "\n"
                    elf.with_suffix(f".{name}.hex").write_text(text)
    inputs = [*common, *source.glob("*.c"), source / "program.ld", Path(__file__)]
    sources = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in sorted(set(inputs))}
    manifest = {"programs": records, "sources": sources, "compiler": args.cross + "gcc"}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {len(records)} AM diagnostic images in {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
