#!/usr/bin/env python3
"""Run a sequential benchmark stage on an SSH-accessible native Ubuntu board.

The binaries and results must be visible through the board's host-mounted NFS
root. Never run stages concurrently: the CSR counters cover the entire hart.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

from analyze import read_metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True,
                        help="host path corresponding to GUEST_DIR/results")
    parser.add_argument("--guest-dir", required=True)
    parser.add_argument("--ssh-config", type=Path, required=True)
    parser.add_argument("--host", default="ku5p")
    parser.add_argument("--coremark-iterations", type=int, default=8192,
                        help="increase this if CoreMark reports less than ten seconds")
    parser.add_argument("--stage", choices=("baseline", "profile", "baseline-long"), required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((args.binaries / "manifest.json").read_text())
    jobs = []
    for name in manifest["binaries"]:
        if name == "coremark":
            repeats = args.coremark_iterations
        elif args.stage == "baseline":
            repeats = 1
        else:
            metric = read_metrics(args.results / f"{name}-baseline.log")
            repeats = min(10000, max(1, int(12_000_000_000 / metric["wall_ns"]) + 1))
        jobs.append((name, repeats))
    period = 19_000_000 if args.stage == "profile" else 0
    script = '''set -u
f=/proc/sys/kernel/perf_user_access
old=$(cat "$f") || exit 2
trap 'printf "%s\\n" "$old" > "$f"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
echo "COUNTER_MODE_ORIGINAL=$old"
echo 2 > "$f" || exit 2
export RAPTOR_READ_CSR=1
'''
    script += f"cd {shlex.quote(args.guest_dir)} || exit 2\nmkdir -p results || exit 2\n"
    script += f"export RAPTOR_SAMPLE_NS={period}\nfailed=0\n"
    for name, repeats in jobs:
        stem = f"results/{name}-{args.stage}"
        script += f"echo {shlex.quote(f'START {args.stage} {name} repeats={repeats}')}\n"
        script += f"export RAPTOR_PROFILE_PREFIX={shlex.quote(stem)}\n"
        script += ("timeout 300 /usr/bin/time -f "
                   "'PROCESS wall_s=%e user_s=%U system_s=%S major=%F minor=%R' "
                   f"-o {shlex.quote(stem + '.time')} ./{shlex.quote(name)} {repeats} "
                   f"> {shlex.quote(stem + '.log')} 2>&1\n")
        script += f"rc=$?\nprintf '%s\\n' \"$rc\" > {shlex.quote(stem + '.exit')}\n"
        script += f'echo "END {args.stage} {name} exit=$rc"\n'
        script += '[ "$rc" -eq 0 ] || failed=1\n'
    script += "echo STAGE_FINISHED\nexit $failed\n"
    (args.evidence / f"{args.stage}.sh").write_text(script)
    (args.evidence / f"{args.stage}-jobs.json").write_text(json.dumps(jobs, indent=2) + "\n")
    result = subprocess.run(["ssh", "-F", str(args.ssh_config), "-T", args.host, "sh", "-s"],
                            input=script, text=True)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
