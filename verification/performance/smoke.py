#!/usr/bin/env python3
"""Exercise profiling/capture/RTL replay and PMP observation in either XLEN.

This is a functional integration check with short windows, not an application
performance result. All tools and models are explicit inputs.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from simpoints import write_json

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("nemu", "npc", "reference", "mrom", "dtb", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--cross", default="riscv64-unknown-elf-")
    parser.add_argument("--fixture", choices=("pmp", "store", "csr"), default="pmp")
    args = parser.parse_args()
    try:
        args.output = args.output.resolve()
        args.output.mkdir(parents=True, exist_ok=False)
        elf, image = (args.output / name for name in ("pmp.elf", "pmp.bin"))
        abi = "lp64d" if args.xlen == 64 else "ilp32d"
        subprocess.run([args.cross + "gcc", f"-march=rv{args.xlen}gc", f"-mabi={abi}",
                        "-nostdlib", "-static", "-Wl,-Ttext=0x80000000", "-Wl,--no-relax",
                        "-Wl,--build-id=none",
                        str(HERE / f"{args.fixture}_checkpoint.S"), "-o", str(elf)], check=True)
        subprocess.run([args.cross + "objcopy", "-O", "binary", str(elf), str(image)], check=True)
        if not 0 < image.stat().st_size < 65536:
            raise ValueError("unexpected PMP fixture layout")
        symbols = {}
        for line in subprocess.check_output([args.cross + "nm", str(elf)], text=True).splitlines():
            fields = line.split()
            if len(fields) == 3:
                symbols[fields[2]] = int(fields[0], 16)
        def run(tool, *arguments):
            subprocess.run([sys.executable, str(HERE / tool), *map(str, arguments)], check=True)
        profile = args.output / "profile"
        run("profile.py", "--nemu", args.nemu, "--firmware", image, "--dtb", args.dtb,
            "--output", profile, "--interval", 128, "--start-pc", hex(symbols["roi_start"]),
            "--stop-pc", hex(symbols["roi_end"]), "--timeout", 30, "--max-attempts", 200000)
        regions = args.output / "regions.json"
        end = 4096 if args.fixture == "pmp" else 128
        write_json(regions, [{"name": f"{args.fixture}-rv{args.xlen}", "start": 0, "end": end}])
        plan = args.output / "plan.json"
        run("simpoints.py", "select", "--bbv", profile / "profile.bbv.jsonl",
            "--profile-manifest", profile / "profile.json", "--regions", regions,
            "--warmup", 256 if args.fixture == "pmp" else 0,
            "--kmax", 3 if args.fixture == "pmp" else 1, "--output", plan)
        capture = args.output / "capture"
        run("capture.py", "--nemu", args.nemu, "--plan", plan, "--firmware", image,
            "--dtb", args.dtb, "--output", capture)
        manifest = json.loads((capture / "capture.json").read_text())
        for point in manifest["points"]:
            state = capture / point["directory"] / "state.txt"
            fields = dict(line.split("=", 1) for line in state.read_text().splitlines() if "=" in line)
            for index in range(8 if args.fixture == "pmp" else 0):
                if int(fields[f"pmpaddr{index}"], 0) != (index + 1) * 0x100000:
                    raise ValueError("PMP snapshot has wrong values or element stride")
        run("run_samples.py", "--plan", plan, "--capture", capture / "capture.json",
            "--baseline", args.npc, "--candidate", args.npc, "--reference", args.reference,
            "--mrom", args.mrom, "--read-latency", 0, "--write-latency", 0,
            "--cycle-limit", 200000, "--timeout", 60, "--jobs", 2,
            "--output", args.output / "ab")
        result = json.loads((args.output / "ab/results.json").read_text())
        if any(row["baseline_cycles"] != row["candidate_cycles"] for row in result["comparisons"]):
            raise ValueError("identical RTL models produced different cycle counts")
        print(f"PASS: RV{args.xlen} {args.fixture} checkpoint and matched-window replay")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
