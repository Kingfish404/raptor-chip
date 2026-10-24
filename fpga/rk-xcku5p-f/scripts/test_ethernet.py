#!/usr/bin/env python3
"""Focused native packet/MAC tests; optional AMD primitive skew sweep."""
import argparse
from pathlib import Path
import subprocess

BOARD = Path(__file__).resolve().parents[1]


def run(command, directory, name, success=None):
    print("+", " ".join(map(str, command)), flush=True)
    logfile = directory / (name + ".log")
    with logfile.open("w") as log:
        result = subprocess.run(list(map(str, command)), cwd=directory, stdout=log, stderr=subprocess.STDOUT)
    text = logfile.read_text()
    if result.returncode or (success and success not in text):
        raise SystemExit(text[-10000:] + "\nFAILED: " + str(logfile))
    if success:
        print(next(line for line in text.splitlines() if success in line))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=BOARD / "build/ethernet-tests")
    parser.add_argument("--vivado-bin", type=Path, help="also run AMD primitive simulation using this bin directory")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for top in ("tb_native_eth", "tb_native_eth_mac"):
        files = [BOARD / "rtl/rapt_native_eth.sv"]
        if top.endswith("_mac"):
            files += sorted((BOARD / "vendor/ethernet").glob("*.sv"))
        files += [BOARD / "tests" / (top + ".sv")]
        run(["verilator", "--binary", "--timing", "--assert", "--timescale", "1ns/1ps", "-Wno-fatal",
             "--top-module", top, "--Mdir", output / ("obj_" + top), *files], output, top + "-compile")
        run([output / ("obj_" + top) / ("V" + top)], output, top, "PASS native")
    if args.vivado_bin:
        bin_dir = args.vivado_bin.resolve()
        sim = output / "primitives"
        sim.mkdir(exist_ok=True)
        run([bin_dir / "xvlog", "--sv", BOARD / "rtl/rapt_rk_rgmii_rx.sv",
             BOARD / "tests/tb_rk_native_rx.sv"], sim, "compile")
        run([bin_dir / "xvlog", bin_dir.parent / "data/verilog/src/glbl.v"], sim, "glbl")
        run([bin_dir / "xelab", "tb_rk_native_rx", "glbl", "-L", "unisims_ver", "-s", "native_rx"], sim, "elaborate")
        for skew in ("-1.0", "0.0", "1.0"):
            run([bin_dir / "xsim", "native_rx", "-runall", "-testplusarg", "SKEW=" + skew],
                sim, "skew" + skew, "PASS native RGMII")


if __name__ == "__main__":
    main()
