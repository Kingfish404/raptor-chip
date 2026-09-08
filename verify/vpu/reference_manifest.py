#!/usr/bin/env python3
"""Record and check the independent reference used by the optional VPU test."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PIN = "770ce31f7543f57472b35e66600085ea81184bb2"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build = args.build.resolve()
    revision = subprocess.check_output(["git", "-C", str(build), "rev-parse", "HEAD"], text=True).strip()
    if revision != PIN:
        raise RuntimeError(f"Reference adapter pinned to {PIN}, found {revision}; audit API/semantics before updating pin")
    subprocess.run(["git", "-C", str(build), "diff", "--exit-code", "HEAD", "--", "riscv", "softfloat", "fesvr", "disasm"],
                   check=True, stdout=subprocess.DEVNULL)
    hashes = {}
    for name in ("libriscv.a", "libdisasm.a", "libsoftfloat.a", "libfesvr.a", "libfdt.a", "config.h"):
        with (build / name).open("rb") as stream:
            hashes[name] = hashlib.file_digest(stream, "sha256").hexdigest()
    args.output.write_text(json.dumps(dict(revision=revision, sha256=hashes,
        policy="vstart_alu=true; per-test XLEN/VLEN/ELEN; architectural host writes only; no ISA difftest skips",
        boundary="Library hashes identify the existing reference build; not a claim of a fresh reproducible rebuild"), indent=2)+"\n")
    print(f"Reference pinned to {revision}; library fingerprints: {args.output}")


if __name__ == "__main__":
    main()
