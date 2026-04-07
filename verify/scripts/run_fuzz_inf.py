#!/usr/bin/env python3
"""
Continuous fuzz testing until Ctrl-C or failure.

Generates and runs batches of random programs in an infinite loop.
Stops on: SIGINT (Ctrl-C), SIGTERM, or first test failure.
Prints a summary on exit.

Usage (called by Makefile):
    python3 run_fuzz_inf.py --npc-bin <path> --nemu-so <path> ...
"""

import argparse
import os
import re
import signal
import shutil
import subprocess
import sys
import time


class CoverageTracker:
    """Track instruction-pair (bigram) coverage across fuzz batches.

    Parses generated .S files to extract instruction opcodes, then records
    which unique opcodes and which unique consecutive-opcode pairs have been
    seen.  When no new pairs are discovered for several consecutive batches
    the exploration space is considered saturated.
    """

    _INSN_RE = re.compile(r"^\s+([a-z]\w*)")

    def __init__(self):
        self.seen_opcodes: set[str] = set()
        self.seen_bigrams: set[tuple[str, str]] = set()
        self.stale_batches = 0
        self.batch_history: list[tuple[int, int]] = []  # (new_ops, new_pairs)

    @classmethod
    def extract_opcodes(cls, path: str) -> list[str]:
        """Return ordered list of instruction mnemonics from a .S file."""
        opcodes: list[str] = []
        with open(path) as f:
            for line in f:
                m = cls._INSN_RE.match(line)
                if m:
                    opcodes.append(m.group(1))
        return opcodes

    def update_from_batch(self, batch_dir: str, names: list[str]):
        """Ingest a batch of .S files.  Returns (new_opcodes, new_bigrams)."""
        new_ops = 0
        new_bigs = 0
        for name in names:
            src = os.path.join(batch_dir, f"{name}.S")
            if not os.path.isfile(src):
                continue
            opcodes = self.extract_opcodes(src)
            for op in opcodes:
                if op not in self.seen_opcodes:
                    self.seen_opcodes.add(op)
                    new_ops += 1
            for a, b in zip(opcodes, opcodes[1:]):
                pair = (a, b)
                if pair not in self.seen_bigrams:
                    self.seen_bigrams.add(pair)
                    new_bigs += 1
        self.batch_history.append((new_ops, new_bigs))
        if new_bigs > 0:
            self.stale_batches = 0
        else:
            self.stale_batches += 1
        return new_ops, new_bigs

    def is_saturated(self, stale_limit: int) -> bool:
        """True when no new bigrams for *stale_limit* consecutive batches."""
        if stale_limit <= 0:
            return False
        return self.stale_batches >= stale_limit

    @property
    def total_opcodes(self):
        return len(self.seen_opcodes)

    @property
    def total_bigrams(self):
        return len(self.seen_bigrams)


class FuzzInfRunner:
    def __init__(self, args):
        self.npc_bin = args.npc_bin
        self.nemu_so = args.nemu_so
        self.mrom_img = args.mrom_img
        self.fuzz_dir = args.fuzz_dir
        self.timeout = args.timeout
        self.cc = args.cc
        self.objcopy = args.objcopy
        self.march = args.march
        self.mabi = args.mabi
        self.xlen = args.xlen
        self.fuzz_gen = args.fuzz_gen
        self.batch_size = args.batch_size
        self.fuzz_len = args.fuzz_len
        self.linker = args.linker
        self.stale_limit = args.stale_limit

        self.passed = 0
        self.failed = 0
        self.errors = 0
        self.total = 0
        self.batch = 0
        self.fail_list = []
        self.stop = False
        self.start_time = time.time()
        self.last_fail_link = os.path.join(self.fuzz_dir, "last_fail")
        self._progress_line_len = 0
        self.coverage = CoverageTracker()

    def _clear_progress_line(self):
        if self._progress_line_len > 0:
            sys.stdout.write("\r" + (" " * self._progress_line_len) + "\r")
            sys.stdout.flush()
            self._progress_line_len = 0

    def _render_progress(self, done_in_batch, total_in_batch, status):
        elapsed = int(time.time() - self.start_time)
        rate = self.total / elapsed if elapsed > 0 else 0.0
        frac = (done_in_batch / total_in_batch) if total_in_batch > 0 else 1.0

        cols = shutil.get_terminal_size((120, 20)).columns
        bar_width = 28
        filled = int(bar_width * frac)
        bar = "#" * filled + "-" * (bar_width - filled)

        cov = self.coverage.total_bigrams
        line = (
            f"[batch {self.batch:04d}] [{bar}] {done_in_batch:>3}/{total_in_batch:<3} "
            f"| pass={self.passed} fail={self.failed} err={self.errors} "
            f"| cov={cov} pairs | rate={rate:4.1f}/s | {status}"
        )
        if len(line) > cols - 1:
            line = line[: cols - 2]

        sys.stdout.write("\r" + line)
        sys.stdout.flush()
        self._progress_line_len = len(line)

    def _log_event(self, message):
        self._clear_progress_line()
        print(message)

    def mark_last_fail(self, batch_dir):
        """Create/update symlink pointing to the failing batch directory."""
        try:
            if os.path.islink(self.last_fail_link):
                os.remove(self.last_fail_link)
            os.symlink(os.path.basename(batch_dir), self.last_fail_link)
        except OSError:
            pass
        self._log_event(f"[fuzz-inf] Failing batch saved: {batch_dir}")
        self._log_event(f"[fuzz-inf] Replay with:  make fuzz-replay")
        self._log_event(
            f"[fuzz-inf]           or: make fuzz-run FUZZ_SRC_DIR={batch_dir}"
        )

    def print_summary(self):
        elapsed = int(time.time() - self.start_time)
        hours, rem = divmod(elapsed, 3600)
        mins, secs = divmod(rem, 60)
        rate = self.total // elapsed if elapsed > 0 and self.total > 0 else 0

        print()
        print("================================================================")
        print("[fuzz-inf] Summary")
        print(f"  Batches:  {self.batch}")
        print(f"  Total:    {self.total} tests")
        print(f"  Passed:   {self.passed}")
        print(f"  Failed:   {self.failed}")
        print(f"  Errors:   {self.errors}")
        print(f"  Duration: {hours}h {mins}m {secs}s")
        print(f"  Rate:     {rate} tests/s")
        print(
            f"  Coverage: {self.coverage.total_opcodes} unique opcodes, "
            f"{self.coverage.total_bigrams} unique instruction pairs"
        )
        if self.stale_limit > 0:
            if self.coverage.is_saturated(self.stale_limit):
                print(f"  Saturated: yes (stale for {self.stale_limit} batches)")
            else:
                print(
                    f"  Saturated: no "
                    f"(stale: {self.coverage.stale_batches}/{self.stale_limit})"
                )
        if self.fail_list:
            print(f"  Failed tests: {' '.join(self.fail_list)}")
            print()
            print("  Replay:   make fuzz-replay")
            print("  Single:   make fuzz-run-one SRC=<path-to-failing.S>")
        if self.failed == 0 and self.errors == 0:
            print("  Status:   ALL PASS")
        else:
            print("  Status:   FAILURE DETECTED")
        print("================================================================")

    def on_signal(self, signum, frame):
        self._clear_progress_line()
        print("[fuzz-inf] Interrupted - printing summary...")
        self.stop = True

    def compile_test(self, src, elf, batch_dir, name):
        """Compile a single .S file. Returns True on success."""
        log = os.path.join(batch_dir, f"{name}.compile.log")
        with open(log, "w") as f:
            ret = subprocess.run(
                [
                    self.cc,
                    f"-march={self.march}",
                    f"-mabi={self.mabi}",
                    "-nostdlib",
                    "-nostartfiles",
                    "-T",
                    self.linker,
                    "-o",
                    elf,
                    src,
                ],
                stdout=f,
                stderr=f,
            )
        return ret.returncode == 0

    def run_test(self, bin_file, run_log):
        """Run a single binary. Returns (exit_code, log_content)."""
        try:
            result = subprocess.run(
                [
                    self.npc_bin,
                    "-b",
                    "-n",
                    "-d",
                    self.nemu_so,
                    "-r",
                    self.mrom_img,
                    bin_file,
                ],
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
            log_content = result.stdout + result.stderr
            with open(run_log, "w") as f:
                f.write(log_content)
            return result.returncode, log_content
        except subprocess.TimeoutExpired:
            with open(run_log, "w") as f:
                f.write("TIMEOUT\n")
            return 124, "TIMEOUT"

    def run_batch(self, batch_dir):
        """Run all tests in a batch directory. Returns True if all pass."""
        manifest = os.path.join(batch_dir, "manifest.txt")
        with open(manifest) as f:
            names = [line.strip() for line in f if line.strip()]

        total_in_batch = len(names)
        self._render_progress(0, total_in_batch, "batch ready")
        for idx, name in enumerate(names, start=1):
            if self.stop:
                break

            self.total += 1
            self._render_progress(idx - 1, total_in_batch, f"running {name}")
            src = os.path.join(batch_dir, f"{name}.S")
            elf = os.path.join(batch_dir, f"{name}.elf")
            bin_file = os.path.join(batch_dir, f"{name}.bin")
            run_log = os.path.join(batch_dir, f"{name}.run.log")

            if not os.path.isfile(src):
                self._log_event(f"  [SKIP] batch{self.batch}/{name}")
                self.errors += 1
                continue

            if not self.compile_test(src, elf, batch_dir, name):
                if self.stop:
                    break
                self._log_event(f"  [CERR] batch{self.batch}/{name}")
                self.errors += 1
                continue

            subprocess.run(
                [self.objcopy, "-O", "binary", elf, bin_file],
                check=True,
                capture_output=True,
            )

            rc, log = self.run_test(bin_file, run_log)

            if rc == 0:
                if re.search(r"BAD TRAP|ABORT", log, re.IGNORECASE):
                    self._log_event(f"  [FAIL] batch{self.batch}/{name} - BAD TRAP")
                    self.failed += 1
                    self.fail_list.append(f"batch{self.batch}/{name}")
                    for line in log.strip().splitlines()[-3:]:
                        self._log_event(f"         {line}")
                    self.mark_last_fail(batch_dir)
                    return False
                else:
                    self.passed += 1
                    self._render_progress(idx, total_in_batch, f"passed {name}")
            elif rc == 124:
                self._log_event(f"  [TIME] batch{self.batch}/{name}")
                self.failed += 1
                self.fail_list.append(f"batch{self.batch}/{name}(timeout)")
                self.mark_last_fail(batch_dir)
                return False
            else:
                self._log_event(f"  [FAIL] batch{self.batch}/{name} - exit {rc}")
                self.failed += 1
                self.fail_list.append(f"batch{self.batch}/{name}")
                for line in log.strip().splitlines()[-5:]:
                    self._log_event(f"         {line}")
                self.mark_last_fail(batch_dir)
                return False

        self._clear_progress_line()
        return True

    def run(self):
        signal.signal(signal.SIGINT, self.on_signal)
        signal.signal(signal.SIGTERM, self.on_signal)

        print("================================================================")
        print("[fuzz-inf] Continuous fuzz testing (Ctrl-C to stop)")
        print(f"  NPC:        {self.npc_bin}")
        print(f"  NEMU:       {self.nemu_so}")
        print(f"  Batch size: {self.batch_size} programs")
        print(f"  Inst/prog:  {self.fuzz_len}")
        print(f"  Timeout:    {self.timeout}s per test")
        print(f"  XLEN:       {self.xlen}")
        print(f"  Stale lim:  {self.stale_limit} batches (0=disabled)")
        print(f"  Output:     {self.fuzz_dir}")
        print("================================================================")

        os.makedirs(self.fuzz_dir, exist_ok=True)

        while not self.stop:
            self.batch += 1
            seed = int(time.time() * 1000) + self.batch
            batch_dir = os.path.join(self.fuzz_dir, f"batch_{self.batch}")
            os.makedirs(batch_dir, exist_ok=True)

            # Generate batch
            subprocess.run(
                [
                    sys.executable,
                    self.fuzz_gen,
                    "--seed",
                    str(seed),
                    "--num",
                    str(self.batch_size),
                    "--length",
                    str(self.fuzz_len),
                    "--xlen",
                    str(self.xlen),
                    "--outdir",
                    batch_dir,
                ],
                capture_output=True,
                check=True,
            )

            # --- Coverage feedback ---
            manifest = os.path.join(batch_dir, "manifest.txt")
            with open(manifest) as f:
                names = [line.strip() for line in f if line.strip()]
            new_ops, new_pairs = self.coverage.update_from_batch(batch_dir, names)
            if new_pairs > 0:
                self._log_event(
                    f"[cov] batch {self.batch:3d}: +{new_ops:3d} opcodes, +{new_pairs:5d} pairs "
                    f"(total: {self.coverage.total_opcodes:3d} ops, "
                    f"{self.coverage.total_bigrams:5d} pairs)"
                )

            all_pass = self.run_batch(batch_dir)

            if not self.stop and all_pass:
                # Clean passing batch to save disk
                if self.failed == 0:
                    shutil.rmtree(batch_dir, ignore_errors=True)

            # Check coverage saturation
            if not self.stop and self.coverage.is_saturated(self.stale_limit):
                self._log_event(
                    f"[fuzz-inf] Coverage saturated: no new instruction pairs "
                    f"for {self.stale_limit} consecutive batches."
                )
                self._log_event(
                    f"[fuzz-inf] Total: {self.coverage.total_opcodes} unique opcodes, "
                    f"{self.coverage.total_bigrams} unique instruction pairs."
                )
                self._log_event(
                    f"[fuzz-inf] Stopping. "
                    f"(Use --stale-limit 0 or FUZZ_STALE_LIMIT=0 to disable.)"
                )
                self.stop = True

        self._clear_progress_line()
        self.print_summary()
        sys.exit(0 if self.failed == 0 and self.errors == 0 else 1)


def main():
    parser = argparse.ArgumentParser(
        description="Continuous fuzz testing for Raptor Chip RISC-V processor"
    )
    parser.add_argument("--npc-bin", required=True, help="Path to NPC simulator binary")
    parser.add_argument("--nemu-so", required=True, help="Path to NEMU reference SO")
    parser.add_argument("--mrom-img", required=True, help="Path to MROM binary image")
    parser.add_argument(
        "--fuzz-dir", required=True, help="Output directory for fuzz artifacts"
    )
    parser.add_argument(
        "--timeout", type=int, default=30, help="Per-test timeout in seconds"
    )
    parser.add_argument("--cc", default="riscv64-elf-gcc", help="Cross compiler")
    parser.add_argument("--objcopy", default="riscv64-elf-objcopy", help="objcopy tool")
    parser.add_argument(
        "--march", default="rv32imac_zicsr_zifencei", help="Target -march"
    )
    parser.add_argument("--mabi", default="ilp32", help="Target -mabi")
    parser.add_argument("--xlen", type=int, default=32, help="XLEN (32 or 64)")
    parser.add_argument("--fuzz-gen", required=True, help="Path to riscv_fuzz_gen.py")
    parser.add_argument("--batch-size", type=int, default=20, help="Programs per batch")
    parser.add_argument(
        "--fuzz-len", type=int, default=200, help="Instructions per program"
    )
    parser.add_argument("--linker", required=True, help="Linker script path")
    parser.add_argument(
        "--stale-limit",
        type=int,
        default=10,
        help="Stop after N batches with no new coverage (0=disable)",
    )

    args = parser.parse_args()
    runner = FuzzInfRunner(args)
    runner.run()


if __name__ == "__main__":
    main()
