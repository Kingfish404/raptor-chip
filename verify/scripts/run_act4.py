#!/usr/bin/env python3
"""Run ACT4 self-checking ELFs on Raptor NPC simulator.

Each ELF is converted to a raw binary via objcopy, then executed on the
simulator. The test prints RVCP-SUMMARY lines to the UART; we capture
stdout and check for PASSED/FAILED.

Usage:
    python3 run_act4.py --npc-bin <sim> --objcopy <objcopy> \\
            --mrom-img <mrom.bin> <elf_dir>
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

_SUMMARY_RE = re.compile(r"RVCP-SUMMARY: TEST (PASSED|FAILED|SIGRUN)")

USE_COLOR = sys.stdout.isatty()


def _c(code: str, t: str) -> str:
    return f"\033[{code}m{t}\033[0m" if USE_COLOR else t


def red(t: str) -> str:
    return _c("1;31", t)


def green(t: str) -> str:
    return _c("1;32", t)


def bold(t: str) -> str:
    return _c("1", t)


def dim(t: str) -> str:
    return _c("2", t)


def run_one(
    elf: Path,
    *,
    npc_bin: str,
    objcopy: str,
    mrom_img: str,
    nemu_so: str | None,
    log_dir: Path,
    timeout: int,
) -> bool:
    """Run a single ELF. Returns True on failure."""
    log_file = log_dir / elf.with_suffix(".log").name
    log_file.parent.mkdir(parents=True, exist_ok=True)

    # Convert ELF -> raw binary
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        bin_path = tmp.name
    try:
        subprocess.run(
            [objcopy, "-O", "binary", str(elf), bin_path],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as e:
        print(
            f"  {red('CERR')} {bold(elf.name)}: objcopy failed: {e.stderr.decode()[:200]}"
        )
        return True

    # Build simulator command
    cmd = [npc_bin, "-b", "-n"]
    if mrom_img:
        cmd += ["-r", mrom_img]
    if nemu_so:
        cmd += ["-d", nemu_so]
    cmd.append(bin_path)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            text=True,
        )
        output = result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        print(f"  {red('TIME')} {bold(elf.name)}: timeout after {timeout}s")
        return True
    finally:
        try:
            os.unlink(bin_path)
        except OSError:
            pass

    # Write log
    log_file.write_text(
        f"Command: {' '.join(cmd)}\nExit: {result.returncode}\n\n{output}"
    )

    # Check results
    summaries = _SUMMARY_RE.findall(output)
    failed = "FAILED" in summaries
    sigrun = "SIGRUN" in summaries
    no_summary = len(summaries) == 0

    if failed or sigrun:
        reason = "FAILED" if failed else "SIGRUN"
        print(f"  {red('FAIL')} {bold(elf.name)}: {reason}")
        print(f"         Log: {dim(str(log_file))}")
        return True
    elif no_summary:
        if result.returncode != 0:
            print(
                f"  {red('FAIL')} {bold(elf.name)}: exit {result.returncode}, no RVCP-SUMMARY"
            )
        else:
            print(f"  {red('FAIL')} {bold(elf.name)}: no RVCP-SUMMARY line")
        print(f"         Log: {dim(str(log_file))}")
        return True
    elif result.returncode != 0:
        print(f"  {red('FAIL')} {bold(elf.name)}: PASSED but exit {result.returncode}")
        print(f"         Log: {dim(str(log_file))}")
        return True

    return False  # success


def main() -> int:
    p = argparse.ArgumentParser(description="Run ACT4 ELFs on Raptor NPC")
    p.add_argument("elf_dir", type=Path, help="Directory containing .elf files")
    p.add_argument("--npc-bin", required=True, help="Path to NPC simulator binary")
    p.add_argument("--objcopy", default="riscv64-elf-objcopy", help="objcopy binary")
    p.add_argument("--mrom-img", default="", help="MROM image path")
    p.add_argument("--nemu-so", default="", help="NEMU difftest SO (optional)")
    p.add_argument("--log-dir", type=Path, default=None, help="Log output directory")
    p.add_argument("--timeout", type=int, default=60, help="Per-test timeout (seconds)")
    args = p.parse_args()

    elf_dir = args.elf_dir.resolve()
    log_dir = (args.log_dir or elf_dir.parent / "logs").resolve()
    log_dir.mkdir(parents=True, exist_ok=True)

    elfs = sorted(elf_dir.rglob("*.elf"))
    if not elfs:
        print(f"No ELF files found in {elf_dir}")
        return 1

    print(f"\n{bold('Running')} {len(elfs)} ACT4 tests")
    print(f"  ELFs:   {elf_dir}")
    print(f"  NPC:    {args.npc_bin}")
    print(f"  Logs:   {log_dir}")
    print()

    failed = 0
    for elf in elfs:
        ok = run_one(
            elf,
            npc_bin=args.npc_bin,
            objcopy=args.objcopy,
            mrom_img=args.mrom_img,
            nemu_so=args.nemu_so or None,
            log_dir=log_dir,
            timeout=args.timeout,
        )
        if ok:
            failed += 1

    passed = len(elfs) - failed
    print()
    if failed:
        print(
            red(f"RESULT: {failed} failed, {passed} passed out of {len(elfs)} tests.")
        )
    else:
        print(green(f"RESULT: All {len(elfs)} tests passed."))

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
