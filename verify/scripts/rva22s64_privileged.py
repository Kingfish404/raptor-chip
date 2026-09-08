#!/usr/bin/env python3
"""Run the supervisor translation/privilege regression with delayed AXI beats."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--npc", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--mrom", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--name", default="privileged", help="Regression name for reports")
    parser.add_argument("--delays", type=int, nargs="+", default=[0, 7, 63])
    parser.add_argument("--seeds", type=int, nargs="+", default=[1, 42])
    parser.add_argument("--timeout", type=int, default=60,
                        help="DUT wall-clock limit in seconds (default: 60)")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    root = Path(__file__).resolve().parents[2]
    artifacts = {name: getattr(args, name).resolve() for name in ("npc", "reference", "mrom", "image")}
    for path in artifacts.values():
        if not path.is_file():
            parser.error(f"missing input: {path}")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary = {
        "name": args.name,
        "inputs": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                   for name, path in artifacts.items()},
        "runs": [],
    }
    failed = False
    for delay in args.delays:
        for seed in args.seeds:
            log = output / f"delay-{delay}-seed-{seed}.log"
            command = [str(artifacts["npc"]), "-b", "-n", "--no-lightsss", "-t", str(args.timeout),
                       f"--mem-random-delay={delay}", f"--mem-random-seed={seed}",
                       "-d", str(artifacts["reference"]), "-r", str(artifacts["mrom"]),
                       str(artifacts["image"])]
            with log.open("w") as stream:
                try:
                    status = subprocess.run(command, cwd=root / "sim", stdout=stream,
                                            stderr=subprocess.STDOUT, timeout=args.timeout + 30).returncode
                except subprocess.TimeoutExpired:
                    status = 124
            text = log.read_text()
            passed = status == 0 and "HIT GOOD TRAP" in text and not any(
                marker in text for marker in ("HIT BAD TRAP", "[ERROR]", "Assertion failed", "mismatch"))
            summary["runs"].append({"delay": delay, "seed": seed, "returncode": status,
                                    "passed": passed, "log": str(log), "command": command})
            failed |= not passed
            print(f"{'PASS' if passed else 'FAIL'}: RVA22S64 {args.name} core delay={delay} seed={seed}", flush=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
