#!/usr/bin/env python3
"""Lint L1D address slices for every preset and XLEN.

Run from any directory with ``python3 verify/scripts/check_l1d_config_slices.py``.
The second pass forces the normally dormant inclusive write-back branch so
short-line presets cannot hide an invalid CBO address slice by constant folding.
The w4 and w8 presets also lint the full core for out-of-range selections.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
CONFIGS = ROOT / "hdl" / "configs"
REQUIRED_WIDE_CONFIGS = {"default-w4", "default-w8"}


def run(command: list[str], label: str) -> None:
    result = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode:
        print(f"FAIL: {label}\n{result.stdout}", file=sys.stderr)
        raise SystemExit(result.returncode)


def forced_l2_flags(config_text: str) -> list[str]:
    flags = []
    if not re.search(r"^\s*`define\s+RAPT_L2_EN\b", config_text, re.MULTILINE):
        flags.append("-DRAPT_L2_EN")
    # Some compact presets do not define L2 geometry at all. The fallback
    # values keep release mode off; this pass tests address selection only.
    for name, value in (
        ("RAPT_L2_N_WAYS", "1"),
        ("RAPT_L2_LEN", "8"),
        ("RAPT_L2_LINE_LEN", "1"),
    ):
        if not re.search(rf"^\s*`define\s+{name}\b", config_text, re.MULTILINE):
            flags.append(f"-D{name}={value}")
    return flags


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", action="append", help="preset to check; default: all")
    parser.add_argument("--xlen", type=int, choices=(32, 64), action="append", help="default: both")
    args = parser.parse_args()
    configs = args.config or sorted(
        path.name for path in CONFIGS.iterdir() if (path / "rapt_config.svh").is_file()
    )
    if args.config is None:
        missing = REQUIRED_WIDE_CONFIGS.difference(configs)
        if missing:
            parser.error(f"missing required wide configs: {', '.join(sorted(missing))}")
    xlens = args.xlen or [32, 64]

    with tempfile.TemporaryDirectory(prefix="rapt-l1d-slices-") as temp:
        for config in configs:
            config_path = CONFIGS / config / "rapt_config.svh"
            if not config_path.is_file():
                parser.error(f"unknown config: {config}")
            config_text = config_path.read_text()
            for xlen in xlens:
                for forced in (False, True):
                    mode = "forced-l2-writeback" if forced else "native"
                    label = f"{config} RV{xlen} {mode}"
                    build_dir = Path(temp) / config / f"rv{xlen}" / mode
                    flags = ["-DRAPT_RV64"] if xlen == 64 else []
                    if forced:
                        flags += forced_l2_flags(config_text)
                    run(
                        [
                            "make", "-s", "-C", "sim", "pack", f"RAPT_CONFIG={config}",
                            f"BUILD_DIR={build_dir}", f"VFLAGS={' '.join(flags)}",
                        ],
                        f"pack {label}",
                    )
                    lint = ["verilator", "--lint-only", "-Wno-fatal", "-Werror-SELRANGE"]
                    if forced:
                        lint.append("-GWriteBack=1")
                    lint += ["--top-module", "rapt_l1d", str(build_dir / "rapt_pack.sv")]
                    run(lint, f"lint {label}")
                    print(f"PASS: {label}")
                    if not forced and config in REQUIRED_WIDE_CONFIGS:
                        # Width scaling can expose unrelated out-of-range
                        # selects outside L1D, so lint the full core as well.
                        run(
                            [
                                "verilator", "--lint-only", "-Wno-fatal",
                                "-Werror-SELRANGE", "--top-module", "rapt",
                                str(build_dir / "rapt_pack.sv"),
                            ],
                            f"core lint {label}",
                        )
                        print(f"PASS: {config} RV{xlen} core slices")


if __name__ == "__main__":
    main()
