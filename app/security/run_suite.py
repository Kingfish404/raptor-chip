#!/usr/bin/env python3
"""Run the Raptor side-channel detection suite and print a hardening matrix.

Each test ELF emits one or more machine-readable lines:
    SCRESULT <name> <verdict> key=value ...
This runner executes every ELF, parses those lines, and aggregates them into
a per-variant matrix (verdict, positive-control status, effect size, z).

Exit codes:
    0  all variants NOT_VULNERABLE / PASS / SKIP (default; detection is info)
    1  any ERROR or INCONCLUSIVE (the measurement itself is not trustworthy)
    2  SC_STRICT=1 (or --strict) and any VULNERABLE confirmed

No hostnames or private paths are embedded: use --exec-prefix to wrap each
command for a remote board or a simulator, e.g.
    --exec-prefix "ssh <board>"   or   --exec-prefix "<sim-wrapper>"
"""
import argparse
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

SC_LINE = re.compile(r"^SCRESULT\s+(\S+)\s+(\S+)(.*)$")
KV = re.compile(r"(\w+)=([^\s]+)")

# Order matters: the canary must run first; it gates the rest.
ORDER = [
    "cache-timing",
    # transient-execution attacks
    "spectre-v1",
    "spectre-v2",
    "spectre-v3-meltdown",
    "spectre-v4",
    "spectre-v5",
    "spectre-bhi",
    "spectre-bse",
    "spec-store-bypass",
    "spectre-v2-xctx",
    "bpu-collision",
    "l2-residue",
    "tlb-residue",
    "fence-timing",
    # cache side channels
    "prime-probe",
    "flush-reload",
    "ghostcache",
]


def parse(stdout):
    rows = []
    for line in stdout.splitlines():
        m = SC_LINE.match(line.strip())
        if not m:
            continue
        name, verdict, rest = m.groups()
        kv = dict(KV.findall(rest))
        rows.append((name, verdict, kv))
    return rows


def run_one(elf, prefix, timeout):
    cmd = (shlex.split(prefix) if prefix else []) + [str(elf)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return [(elf.stem, "ERROR", {"reason": "timeout"})], ""
    out = p.stdout + p.stderr
    rows = parse(p.stdout)
    if not rows:
        rows = [(elf.stem, "ERROR", {"reason": "no-scresult", "rc": str(p.returncode)})]
    return rows, out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", type=Path, required=True,
                    help="directory holding the security test ELFs")
    ap.add_argument("--exec-prefix", default="",
                    help="generic wrapper command prepended to each ELF")
    ap.add_argument("--only", default="", help="comma-separated test subset")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero on confirmed VULNERABLE")
    ap.add_argument("--out", type=Path, default=None,
                    help="optional matrix output path (must be outside repo)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    strict = args.strict or os.environ.get("SC_STRICT") == "1"
    only = {s.strip() for s in args.only.split(",") if s.strip()}

    elfs = {}
    for e in sorted(args.build_dir.glob("*.elf")):
        elfs[e.stem] = e
    names = [n for n in ORDER if n in elfs]
    names += [n for n in sorted(elfs) if n not in ORDER]
    if only:
        names = [n for n in names if n in only]

    all_rows = []
    logs = []
    for n in names:
        rows, out = run_one(elfs[n], args.exec_prefix, args.timeout)
        all_rows.extend(rows)
        logs.append((n, out))
        if args.verbose:
            sys.stderr.write(out + "\n")

    # Hardening matrix
    print("=" * 78)
    print("Raptor side-channel hardening matrix")
    print("=" * 78)
    hdr = f"{'variant':32} {'verdict':16} {'pos':4} {'effect':7} {'z':6}"
    print(hdr)
    print("-" * 78)
    bad = False
    vuln = False
    for name, verdict, kv in all_rows:
        pos = kv.get("pos", "-")
        eff = kv.get("effect", kv.get("penalty", "-"))
        z = kv.get("z", "-")
        print(f"{name:32} {verdict:16} {pos:4} {str(eff):7} {str(z):6}")
        if verdict in ("ERROR", "INCONCLUSIVE"):
            bad = True
        if verdict == "VULNERABLE":
            vuln = True
    print("-" * 78)
    n_v = sum(1 for _, v, _ in all_rows if v == "VULNERABLE")
    n_n = sum(1 for _, v, _ in all_rows if v == "NOT_VULNERABLE")
    n_i = sum(1 for _, v, _ in all_rows if v == "INCONCLUSIVE")
    n_e = sum(1 for _, v, _ in all_rows if v == "ERROR")
    n_s = sum(1 for _, v, _ in all_rows if v == "SKIP")
    print(f"VULNERABLE={n_v} NOT_VULNERABLE={n_n} INCONCLUSIVE={n_i} "
          f"ERROR={n_e} SKIP={n_s}")
    print("NOTE: trust a NOT_VULNERABLE only where its positive control "
          "(pos=1) passed; INCONCLUSIVE means the channel was not validated.")

    if args.out:
        args.out.write_text(
            "\n".join(f"{n}\t{v}\t{kv}" for n, v, kv in all_rows) + "\n")

    if bad:
        return 1
    if strict and vuln:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())