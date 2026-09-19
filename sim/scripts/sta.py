#!/usr/bin/env python3
"""Run the existing Yosys/OpenSTA flow in an isolated workspace with an explicit memory model."""
import argparse
import os
from pathlib import Path
import re
import subprocess


def prepare(backend: Path, work: Path, platform: str) -> None:
    if not (backend / "platforms" / platform / "platform.mk").is_file():
        raise SystemExit(f"Unknown STA platform: {platform} (backend: {backend})")
    work.mkdir(parents=True, exist_ok=True)
    for name in ("Makefile", "scripts", "platforms", "third_party"):
        source = backend / name
        target = work / name
        if not source.exists():
            raise SystemExit(f"Missing backend dependency: {source}; prepare STA dependencies first")
        if target.is_symlink() and target.resolve() == source.resolve():
            continue
        if target.exists() or target.is_symlink():
            raise SystemExit(f"Refusing to replace existing workspace path: {target}")
        target.symlink_to(source, target_is_directory=source.is_dir())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--frequency", type=float, required=True)
    parser.add_argument("--memory", choices=("dff", "sram"), default="dff")
    parser.add_argument("--lib", action="append", type=Path, default=[])
    parser.add_argument("--detail", action="store_true")
    args = parser.parse_args()
    if not 0 < args.frequency < float("inf"):
        parser.error("frequency must be finite and positive")
    backend, work, rtl = args.backend.resolve(), args.work_dir.resolve(), args.rtl.resolve()
    if not rtl.is_file():
        parser.error(f"missing packed RTL: {rtl}")
    if args.memory == "dff" and args.lib:
        parser.error("DFF STA must not load SRAM macro libraries")
    if args.memory == "sram" and not args.lib:
        parser.error("SRAM STA requires explicit macro libraries")
    for lib in args.lib:
        if not lib.is_file():
            parser.error(f"missing SRAM library: {lib}")
    prepare(backend, work, args.platform)
    # Do not inherit outer Make command-line settings (especially BUILD_DIR,
    # RESULT_DIR, DESIGN, or EXTRA_LIB_FILES) into this independent backend.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("MAKE") and k != "MFLAGS"}
    frequency = format(args.frequency, "g")
    print(f"{args.memory.upper()} STA workspace: {work}", flush=True)
    command = ["make", "-j1", "-C", str(work), "sta",
               *(["sta-detail"] if args.detail else []), "show",
               "DESIGN=rapt", f"PLATFORM={args.platform}",
               f"CLK_FREQ_MHZ={frequency}", f"RTL_FILES={rtl}",
               f"EXTRA_LIB_FILES={' '.join(str(p.resolve()) for p in args.lib)}", "EXTRA_BLACKBOX_V_FILES=",
               f"SYNTH_HIERARCHICAL={int(args.memory == 'sram')}", "SYNTH_SHARE=0", "SYNTH_MEMORY_DFF=0"]
    result = subprocess.run(command, env=env, check=False)
    if result.returncode == 0:
        # OpenSTA can print an error yet exit zero; never report that as PASS.
        result_dir = work / "result" / f"{args.platform}-rapt-{frequency}MHz"
        logs = ["sta.log"] + (["sta_detail.log"] if args.detail else [])
        for name in logs:
            log = result_dir / name
            if not log.is_file() or re.search(r"^\s*Error(?:\s+\d+)?[: ]", log.read_text(), re.MULTILINE):
                raise SystemExit(f"STA failed or missing report: {log}")
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
