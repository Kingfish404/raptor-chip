#!/usr/bin/env python3
"""Isolated bring-up builds. No board programming operations are provided."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
HERE = REPO / "fpga/bringup"
sys.path.insert(0, str(REPO / "fpga/common/scripts"))
from rtl_pack import include_dirs, rtl_sources



def run(command, work, name):
    print(" ".join(map(str, command)), flush=True)
    with (work / f"{name}.log").open("w") as log:
        subprocess.run(list(map(str, command)), cwd=work, stdout=log,
                       stderr=subprocess.STDOUT, check=True)


def sources():
    return rtl_sources(REPO, pin_limited=True) + [
        REPO / "fpga/common/rtl/rapt_xspi_target.sv",
        *sorted((HERE / "rtl").glob("*.sv")),
    ]


def cpu_tests(repo):
    tests = repo / "abstract-machine/app/am-kernels/tests/cpu-tests"
    sources = sorted((tests / "tests").glob("*.c"))
    if not sources or not (tests / "include/trap.h").is_file():
        raise ValueError("Missing AM cpu-tests sources/headers; initialize the public "
                         "am-kernels dependency before building programs")
    return tests, sources


def programs(work, cross):
    am = REPO / "abstract-machine"
    tests, test_sources = cpu_tests(REPO)
    dest = work / "programs"
    dest.mkdir(exist_ok=True)
    flags = ["-march=rv32im_zicsr", "-mabi=ilp32", "-O2", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-fdata-sections", "-ffunction-sections",
             "-nostdlib", '-D__ISA__="riscv32"', '-DARCH_H="arch/riscv.h"']
    includes = [am / "am/include", am / "klib/include", tests / "include"]
    common = [REPO / "tools/bringup/start.S", REPO / "tools/bringup/runtime.c",
              am / "klib/src/string.c", am / "klib/src/stdio.c", am / "klib/src/stdlib.c"]
    manifest = []
    for source in test_sources:
        elf = dest / f"{source.stem}.elf"
        command = [cross + "gcc", *flags, *(f"-I{p}" for p in includes),
                   *common, source, "-T", REPO / "tools/bringup/program.ld",
                   "-Wl,--gc-sections", "-lgcc", "-o", elf]
        run(command, work, f"program-{source.stem}")
        subprocess.run([cross + "objcopy", "-O", "binary", str(elf),
                        str(elf.with_suffix(".bin"))], check=True)
        manifest.append(source.stem)
    diagnostics = work / "diagnostics"
    diagnostics.mkdir(exist_ok=True)
    for name in ("console_test", "fail_test"):
        elf = diagnostics / f"{name}.elf"
        run([cross + "gcc", *flags, *(f"-I{p}" for p in includes), *common,
             REPO / f"tools/bringup/{name}.c", "-T", REPO / "tools/bringup/program.ld",
             "-Wl,--gc-sections", "-lgcc", "-o", elf], work, name)
        subprocess.run([cross + "objcopy", "-O", "binary", str(elf),
                        str(elf.with_suffix(".bin"))], check=True)
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Built {len(manifest)} cpu-tests")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["sim", "programs", "emulation", "hardware",
                                          "clock-test", "ram-test"])
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4, choices=range(1, 5))
    parser.add_argument("--cross", default=os.environ.get("CROSS_COMPILE", "riscv64-elf-"))
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--clock-sim", choices=["iverilog", "xsim"], default="iverilog")
    args = parser.parse_args()
    work = args.work.resolve()
    if work.is_relative_to(REPO):
        parser.error("--work must be outside the source snapshot")
    work.mkdir(parents=True, exist_ok=True)
    if args.action == "programs":
        programs(work, args.cross)
        return
    block_tests = {"ram-test": ("ram", "PASS: bringup RAM")}
    if args.action in block_tests:
        block, marker = block_tests[args.action]
        top = f"tb_bringup_{block}"
        run(["verilator", "--binary", "--timing", "--assert", "-j", args.jobs,
             "--timescale", "1ns/1ps", "--top-module", top, "--Mdir", work / block,
             HERE / f"rtl/rapt_bringup_{block}.sv", HERE / f"tests/{top}.sv",
             "-o", args.action], work, f"{block}-build")
        run([work / block / args.action], work, f"{block}-run")
        if marker not in (work / f"{block}-run.log").read_text():
            raise RuntimeError(f"{block} test did not report PASS")
        return
    if args.action == "clock-test":
        vivado = Path(shutil.which(args.vivado)).resolve()
        binary = vivado.parent
        glbl = binary.parent / "data/verilog/src/glbl.v"
        if args.clock_sim == "iverilog":
            unisims = glbl.parent / "unisims"
            run(["iverilog", "-g2012", "-s", "tb_bringup_clock", "-s", "glbl",
                 "-y", unisims, "-o", work / "clock.vvp",
                 HERE / "cu08/rapt_bringup_clock.sv", HERE / "cu08/tb_bringup_clock.sv",
                 glbl], work, "clock-compile")
            run(["vvp", work / "clock.vvp"], work, "clock-run")
            if "6 dividers and external clock PASS" not in (work / "clock-run.log").read_text():
                raise RuntimeError("Clock primitive test did not report PASS")
            return
        run([binary / "xvlog", "-sv", HERE / "cu08/rapt_bringup_clock.sv",
             HERE / "cu08/tb_bringup_clock.sv", glbl], work, "clock-compile")
        run([binary / "xelab", "tb_bringup_clock", "glbl", "-L", "unisims_ver",
             "-s", "clock_test", "--mt", args.jobs], work, "clock-elaborate")
        run([binary / "xsim", "clock_test", "-tclbatch", HERE / "cu08/clock_test.tcl"],
            work, "clock-run")
        if "6 dividers and external clock PASS" not in (work / "clock-run.log").read_text():
            raise RuntimeError("Clock primitive test did not report PASS")
        return
    files = sources()
    includes = include_dirs(REPO, REPO / "rtl/configs/chip32-middle-16k")
    if args.action == "sim":
        files.append(HERE / "sim/rapt_bringup_sim.sv")
        command = ["verilator", "--cc", "--exe", "--build", "-j", args.jobs,
                   "--trace", "--trace-depth", "2", "--timescale", "1ns/1ps",
                   "--top-module", "rapt_bringup_sim", "--Mdir", work / "sim",
                   "-Wno-fatal", "-Wno-UNOPTFLAT", "-Wno-TIMESCALEMOD",
                   *(f"-I{p}" for p in includes), *files, HERE / "sim/host.cpp",
                   "-CFLAGS", "-O2", "-o", "bringup-sim"]
    else:
        available = next(int(s.split()[1]) for s in Path("/proc/meminfo").read_text().splitlines()
                         if s.startswith("MemAvailable:"))
        if available < 25 * 1024 * 1024:
            raise RuntimeError("Vivado needs MemAvailable above 25 GiB")
        files += sorted((HERE / "cu08").glob("rapt_*.sv"))
        inputs = work / "inputs"
        inputs.mkdir(exist_ok=True)
        for name in ("build.tcl", "pins.xdc"):
            shutil.copyfile(HERE / "cu08" / name, inputs / name)
        # Preprocess includes exactly as simulation; no generated source enters rtl/.
        packed = work / "sources.sv"
        with packed.open("w") as dest:
            subprocess.run(["verilator", "-E", "-P", "-DSYNTHESIS",
                            *(f"-I{p}" for p in includes), *map(str, files)],
                           stdout=dest, check=True)
        command = [args.vivado, "-mode", "batch", "-nojournal", "-log", work / "vivado.log",
                   "-source", inputs / "build.tcl", "-tclargs", packed,
                   inputs / "pins.xdc", int(args.action == "emulation"), args.jobs]
    files += sorted((REPO / "rtl").rglob("*.svh"))
    files += [REPO / "fpga/common/scripts/rtl_pack.py", HERE / "build.py",
              HERE / "sim/host.cpp", HERE / "cu08/build.tcl",
              HERE / "cu08/pins.xdc"]
    fingerprint = {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in files}
    (work / f"{args.action}-sources.json").write_text(json.dumps(fingerprint, indent=2) + "\n")
    run(command, work, "sim-build" if args.action == "sim" else "implementation")


if __name__ == "__main__":
    main()
