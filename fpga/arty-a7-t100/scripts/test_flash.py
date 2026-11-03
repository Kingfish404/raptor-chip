#!/usr/bin/env python3
"""Simulate the board register bank and real serial engine against a strict MT35X model."""

import argparse
from pathlib import Path
import subprocess

from sources import BOARD, tool_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "obj/tb_flash"
    sources = [BOARD / p for p in (
        "rtl/rapt_arty_mt35x.sv", "rtl/rapt_arty_flash.sv",
        "tests/rapt_arty_mt35x_model.sv", "tests/rapt_arty_flash_bram.sv",
        "tests/tb_rapt_arty_flash.sv")]
    command = ["verilator", "--binary", "--timing", "--trace", "-j", "4", "-Wno-fatal",
               "--top-module", "tb_rapt_arty_flash", "--Mdir", str(out / "obj"),
               "-o", "tb_flash", *map(str, sources)]
    with (out / "compile.log").open("w") as log:
        subprocess.run(command, cwd=out, env=tool_environment(), stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    for name, extra in (("nor", []), ("unknown", ["+UNKNOWN_FLASH"])):
        log_path = out / f"{name}.log"
        with log_path.open("w") as log:
            result = subprocess.run([str(binary), *extra], cwd=out, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=120, check=False)
        output = log_path.read_text()
        print(output, end="")
        if result.returncode or "PASS" not in output or "%Fatal" in output or "%Error" in output:
            return 1
    model_dir = out / "bram"
    model_dir.mkdir(exist_ok=True)
    model_command = ["verilator", "--binary", "--timing", "-j", "4", "-Wno-fatal",
                     "-DARTY_FLASH_BRAM", "--top-module", "tb_rapt_arty_flash",
                     "--Mdir", str(model_dir / "obj"), "-o", "tb_bram", *map(str, sources)]
    with (model_dir / "compile.log").open("w") as log:
        subprocess.run(model_command, cwd=out, env=tool_environment(), stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    with (model_dir / "run.log").open("w") as log:
        result = subprocess.run([str(model_dir / "obj/tb_bram")], cwd=out,
                                stdout=log, stderr=subprocess.STDOUT, timeout=60, check=False)
    output = (model_dir / "run.log").read_text()
    print(output, end="")
    if result.returncode or "BRAM_REGISTER_INTERFACE PASS" not in output or "%Fatal" in output:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
