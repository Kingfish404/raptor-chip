#!/usr/bin/env python3
"""Patch the ACT4 checkout for the Sail version used by Raptor."""

from __future__ import annotations

import argparse
from pathlib import Path


REQUIRED_SAIL_VERSION = 'REQUIRED_SAIL_VERSION = "0.10"'
PATCHED_SAIL_VERSION = 'REQUIRED_SAIL_VERSION = "0.13.1"'
ORIGINAL_CONFIG_ARGS = 'sail_cmd.extend(["--config", str(sail_config_path)])'
PATCHED_CONFIG_ARGS = (
    'sail_cmd.extend((["--rv32"] if xlen == 32 else []) + ["--config-override", str(sail_config_path)])'
)
ORIGINAL_COVERAGE_ARGS = '''        "--config",
        str(config.dut_include_dir / "sail.json"),'''
PATCHED_COVERAGE_ARGS = '''        *(["--rv32"] if xlen == 32 else []),
        "--config-override",
        str(config.dut_include_dir / "sail.json"),'''


def replace_once(path: Path, original: str, replacement: str, legacy: str | None = None) -> None:
    text = path.read_text(encoding="utf-8")
    if replacement in text:
        return
    if legacy is not None and legacy in text:
        original = legacy
    if text.count(original) != 1:
        raise SystemExit(f"[act4-sail] unexpected upstream content in {path}")
    path.write_text(text.replace(original, replacement, 1), encoding="utf-8")
    print(f"[act4-sail] patched {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    args = parser.parse_args()

    source_dir = args.repo / "framework/src/act"
    replace_once(
        source_dir / "config.py",
        REQUIRED_SAIL_VERSION,
        PATCHED_SAIL_VERSION,
    )
    build_plan = source_dir / "build_plan.py"
    replace_once(build_plan, ORIGINAL_CONFIG_ARGS, PATCHED_CONFIG_ARGS,
                 'sail_cmd.extend(["--rv32", "--config-override", str(sail_config_path)])')
    replace_once(build_plan, ORIGINAL_COVERAGE_ARGS, PATCHED_COVERAGE_ARGS,
                 '''        "--rv32",
        "--config-override",
        str(config.dut_include_dir / "sail.json"),''')
    replace_once(build_plan,
                 '''    fast: bool = False,
) -> list[BuildTask]:
    """Generate BuildTasks for RVVI trace generation''',
                 '''    fast: bool = False,
    xlen: int = 32,
) -> list[BuildTask]:
    """Generate BuildTasks for RVVI trace generation''')
    replace_once(build_plan,
                 '''                    config,
                    sail_inputs,
                    fast,
                )''',
                 '''                    config,
                    sail_inputs,
                    fast,
                    xlen=xlen,
                )''')


if __name__ == "__main__":
    main()
