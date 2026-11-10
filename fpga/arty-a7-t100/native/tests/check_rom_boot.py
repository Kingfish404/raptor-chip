#!/usr/bin/env python3
"""Bounded RTL checks for the Arty reset ROM, XIP mapping and automatic boot."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[4]
NATIVE = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "fpga/common/scripts"))
from rtl_pack import include_dirs, rtl_sources


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, directory, name, seconds, marker=None):
    command = list(map(str, command))
    (directory / f"{name}-command.json").write_text(json.dumps(command, indent=2) + "\n")
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    start = time.monotonic()
    with (directory / f"{name}.log").open("w") as log:
        result = subprocess.run(command, cwd=directory, env=environment,
                                stdout=log, stderr=subprocess.STDOUT, timeout=seconds, check=False)
    elapsed = time.monotonic() - start
    transcript = (directory / f"{name}.log").read_text(errors="replace")
    passed = result.returncode == 0 and (marker is None or transcript.count(marker) == 1)
    receipt = {"exit": result.returncode, "elapsed_seconds": elapsed, "pass": passed,
               "marker": marker, "log_sha256": digest(directory / f"{name}.log")}
    (directory / f"{name}-result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if not passed:
        raise RuntimeError(f"{name} failed; inspect {directory / (name + '.log')}")
    return receipt


def simulate(out, top, sources, flags, plusargs, marker):
    out.mkdir(parents=True, exist_ok=False)
    inputs = set(sources)
    inputs.update(ROOT.glob("rtl/**/*.svh"))
    inputs.update(ROOT.glob("sim/include/**/*.svh"))
    inputs.add(Path(__file__).resolve())
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in sorted(inputs)}
    (out / "inputs.json").write_text(json.dumps(hashes, indent=2) + "\n")
    command = ["verilator", "--binary", "--timing", "-j", "1", "-Wno-fatal",
               "-Wno-UNOPTFLAT", "--timescale", "1ns/1ps", "--top-module", top,
               "--Mdir", out / "obj", *flags, *sources]
    compile_result = execute(command, out, "compile", 180)
    run_result = execute([out / "obj" / ("V" + top), *plusargs], out, "run", 60, marker)
    return {"top": top, "inputs_sha256": digest(out / "inputs.json"),
            "compile": compile_result, "run": run_result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--case", choices=("bus", "cpu", "reset", "all"), default="all")
    parser.add_argument("--xlen", type=int, choices=(32, 64))
    parser.add_argument("--cross", default="riscv64-elf-")
    args = parser.parse_args()
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("place outputs outside the source tree")
    out.mkdir(parents=True, exist_ok=False)
    results = {}
    selected = {"bus", "cpu", "reset"} if args.case == "all" else {args.case}
    if "reset" in selected:
        reset = out / "reset"
        reset.mkdir()
        command = ["iverilog", "-g2012", "-s", "tb_native_rom_reset", "-o", reset / "test.vvp",
                   NATIVE / "rtl/rapt_arty_native_top.sv", NATIVE / "sim/clocks.sv",
                   TESTS / "tb_native_rom_reset.sv"]
        execute(command, reset, "compile", 30)
        results["reset"] = execute(["vvp", reset / "test.vvp"], reset, "run", 30,
                                   "NATIVE_ROM_RESET_PASS")
    for xlen in ([args.xlen] if args.xlen else [32, 64]):
        config = "chip32-small" if xlen == 32 else "small"
        flags = [f"-I{p}" for p in include_dirs(ROOT, ROOT / "rtl/configs" / config)]
        flags += ["-DRAPT_CORE_CLOCK_MHZ=10", "-DRAPT_MTIME_FREQ_MHZ=1"]
        if xlen == 64:
            flags += ["-DRAPT_RV64"]
        model = ROOT / "verification/models/rapt_xspi_profile1_model.sv"
        if "bus" in selected:
            modules = [ROOT / "rtl/rapt_pkg.sv"]
            modules += [ROOT / "synth/configs/pin-limited/rtl" / name for name in (
                "rapt_spi_byte.sv", "rapt_xspi_frame.sv", "rapt_spi_nor.sv", "rapt_axi_flash.sv",
                "rapt_chip_boot.sv")]
            modules += [model, TESTS / "tb_native_rom_axi.sv"]
            for enabled in (0, 1):
                name = f"bus-rv{xlen}-rom{enabled}"
                results[name] = simulate(out / name, "tb_native_rom_axi", modules,
                                         [*flags, f"-GEnableRom={enabled}"], [],
                                         "NATIVE_ROM_AXI_PASS")
        if "cpu" in selected:
            firmware = out / f"firmware-rv{xlen}"
            firmware.mkdir()
            abi = "ilp32" if xlen == 32 else "lp64"
            execute([args.cross + "gcc", f"-march=rv{xlen}i_zicsr_zifencei", f"-mabi={abi}",
                     "-nostdlib", "-nostartfiles", "-Wl,-Ttext=0x30000000,--build-id=none",
                     "-o", firmware / "boot.elf", TESTS / "rom_xip_boot.S"], firmware, "gcc", 30)
            execute([args.cross + "objcopy", "-O", "binary", firmware / "boot.elf",
                     firmware / "boot.bin"], firmware, "objcopy", 30)
            modules = rtl_sources(ROOT, io25=True)
            modules += [NATIVE / "rtl/rapt_arty_native_top.sv", NATIVE / "sim/clocks.sv",
                        model, TESTS / "tb_native_rom_cpu.sv"]
            name = f"cpu-rv{xlen}"
            results[name] = simulate(out / name, "tb_native_rom_cpu", modules, flags,
                                     [f"+FLASH_IMAGE={firmware / 'boot.bin'}"],
                                     "NATIVE_ROM_CPU_PASS")
    (out / "RESULT.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps({"pass": True, "cases": list(results), "hardware": False}))


if __name__ == "__main__":
    main()
