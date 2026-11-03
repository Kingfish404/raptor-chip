#!/usr/bin/env python3
"""Apply incoming RTL patches to a private copy and run the pad-level SBA simulation."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from sources import BOARD, ROOT, fingerprint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--incoming", type=Path, default=ROOT / "job/incoming")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    patches = sorted(args.incoming.glob("*.patch")) + sorted(args.incoming.glob("*.diff"))
    if not patches:
        print("SBA_PENDING: no incoming RTL patch has arrived")
        return 77
    destination = args.out.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copytree(ROOT / "rtl", destination / "rtl")
    shutil.copytree(BOARD, destination / "fpga/arty-a7-t100",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(ROOT / "fpga/common", destination / "fpga/common")
    (destination / "abstract-machine").symlink_to(ROOT / "abstract-machine", target_is_directory=True)
    baseline = (ROOT / "rtl/configs/chip32-small/rapt_config.svh").read_bytes()
    commands = []
    for patch in patches:
        headers = [line[4:].split("\t", 1)[0] for line in patch.read_text().splitlines()
                   if line.startswith("+++ ") and line[4:] != "/dev/null"]
        strip = 1 if headers and all(name.startswith("b/") for name in headers) else 0
        for name in headers:
            path = Path(name.removeprefix("b/") if strip else name)
            if path.is_absolute() or ".." in path.parts or path.parts[0] != "rtl":
                raise ValueError(f"incoming patch must change only private-copy RTL: {name}")
        command = ["patch", "--batch", "--forward", "--no-backup-if-mismatch", f"-p{strip}",
                   "-i", str(patch.resolve())]
        commands.append(command)
        subprocess.run(command, cwd=destination, check=True)
    if (destination / "rtl/configs/chip32-small/rapt_config.svh").read_bytes() != baseline:
        raise ValueError("incoming patch changed the supplied preset")
    env = os.environ.copy()
    (destination / "tmp").mkdir()
    env["TMPDIR"] = str(destination / "tmp")
    build = destination / "build"
    command = ["make", "-C", str(destination / "fpga/arty-a7-t100"), "test", "payloads",
               f"OUT={build}", "JOIN=internal", "CROSS_COMPILE=riscv64-elf-"]
    commands.append(command)
    subprocess.run(command, env=env, check=True)
    command = ["python3", str(destination / "fpga/arty-a7-t100/scripts/regress.py"),
               "--out", str(build / "internal"), "--only", "sba"]
    commands.append(command)
    (destination / "incoming.json").write_text(json.dumps(
        {"patches": fingerprint(patches), "commands": commands}, indent=2) + "\n")
    return subprocess.run(command, env=env, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
