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
import concurrent.futures
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
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
    elf_root: Path,
    npc_bin: str,
    objcopy: str,
    mrom_img: str,
    nemu_so: str | None,
    log_dir: Path,
    timeout: int,
    mem_random_delay: int,
    mem_random_seed: int,
    trap_on_ebreak: bool = False,
) -> bool:
    """Run a single ELF. Returns True on failure."""
    # Preserve the extension/test directory structure.  ACT4 has identically
    # named ELFs in different suites, so flattening logs silently overwrites
    # earlier results (and is especially racy with parallel execution).
    log_file = log_dir / elf.relative_to(elf_root).with_suffix(".log")
    log_file.parent.mkdir(parents=True, exist_ok=True)
    log_file.write_text(f"ELF: {elf}\nStatus: converting\n")

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
        Path(bin_path).unlink(missing_ok=True)
        diagnostic = e.stderr.decode(errors="replace")
        log_file.write_text(f"ELF: {elf}\nStatus: objcopy failed\n{diagnostic}")
        print(
            f"  {red('CERR')} {bold(elf.name)}: objcopy failed: {diagnostic[:200]}"
        )
        return True
    except OSError as e:
        Path(bin_path).unlink(missing_ok=True)
        log_file.write_text(f"ELF: {elf}\nStatus: objcopy unavailable\n{e}\n")
        print(f"  {red('CERR')} {bold(elf.name)}: cannot run objcopy: {e}")
        return True

    # Build simulator command
    cmd = [npc_bin, "-b", "-n"]
    if trap_on_ebreak:
        cmd.append("--trap-on-ebreak")
    cmd += [
        f"--mem-random-delay={mem_random_delay}",
        f"--mem-random-seed={mem_random_seed}",
    ]
    if mrom_img:
        cmd += ["-r", mrom_img]
    if nemu_so:
        cmd += ["-d", nemu_so]
    cmd.append(bin_path)

    started = time.monotonic()
    command_header = f"ELF: {elf}\nCommand: {shlex.join(cmd)}\n"
    log_file.write_text(command_header + "Status: running\n")
    try:
        result = subprocess.run(
            cmd,
            cwd=Path(__file__).resolve().parents[2] / "sim",
            capture_output=True,
            timeout=timeout,
            text=True,
        )
        output = result.stdout + result.stderr
    except subprocess.TimeoutExpired as e:
        # TimeoutExpired carries bytes even when subprocess uses text=True.
        def decoded(part: str | bytes | None) -> str:
            return part.decode(errors="replace") if isinstance(part, bytes) else (part or "")
        output = decoded(e.stdout) + decoded(e.stderr)
        log_file.write_text(
            command_header + f"Exit: TIMEOUT\nElapsed: {time.monotonic() - started:.3f}s\n"
            + f"Wall timeout: {timeout}s\n\n{output}"
        )
        print(f"  {red('TIME')} {bold(elf.name)}: timeout after {timeout}s")
        print(f"         Log: {dim(str(log_file))}")
        return True
    except OSError as e:
        log_file.write_text(command_header + f"Status: NPC launch failed\n{e}\n")
        print(f"  {red('FAIL')} {bold(elf.name)}: cannot run NPC: {e}")
        return True
    finally:
        try:
            os.unlink(bin_path)
        except OSError:
            pass

    # Write log
    log_file.write_text(
        command_header + f"Exit: {result.returncode}\n"
        + f"Elapsed: {time.monotonic() - started:.3f}s\n\n{output}"
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
    p.add_argument("--timeout", type=int, default=60, help="Per-test wall-clock timeout (seconds)")
    p.add_argument("--trap-on-ebreak", action="store_true",
                   help="execute architectural breakpoint tests; requires finisher-based DUT halt macros")
    p.add_argument(
        "--jobs",
        type=int,
        default=max(1, (os.cpu_count() or 1) // 2),
        help="parallel simulator processes (default: half of CPUs)",
    )
    p.add_argument(
        "--mem-random-delay",
        type=int,
        default=0,
        help="maximum randomized AXI wait cycles per memory beat",
    )
    p.add_argument(
        "--mem-random-seed",
        type=int,
        default=1,
        help="reproducible randomized AXI timing seed",
    )
    args = p.parse_args()
    args.npc_bin = str(Path(args.npc_bin).resolve())
    if args.mrom_img:
        args.mrom_img = str(Path(args.mrom_img).resolve())
    if args.nemu_so:
        args.nemu_so = str(Path(args.nemu_so).resolve())
    if args.jobs < 1:
        p.error("--jobs must be at least 1")
    if args.timeout < 1:
        p.error("--timeout must be at least 1")
    if not Path(args.npc_bin).is_file() or not os.access(args.npc_bin, os.X_OK):
        p.error(f"NPC binary is missing or not executable: {args.npc_bin}")

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
    print(f"  Jobs:   {args.jobs}")
    print()

    def run(elf: Path) -> bool:
        return run_one(
            elf,
            elf_root=elf_dir,
            npc_bin=args.npc_bin,
            objcopy=args.objcopy,
            mrom_img=args.mrom_img,
            nemu_so=args.nemu_so or None,
            log_dir=log_dir,
            timeout=args.timeout,
            mem_random_delay=args.mem_random_delay,
            mem_random_seed=args.mem_random_seed,
            trap_on_ebreak=args.trap_on_ebreak,
        )

    if args.jobs == 1:
        failed = sum(run(elf) for elf in elfs)
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            failed = sum(pool.map(run, elfs))

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
