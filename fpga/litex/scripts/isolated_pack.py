#!/usr/bin/env python3
"""LiteX RTL export without invoking the simulator's mutable Kconfig Makefile."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def key(config, flags):
    return config + "-" + hashlib.sha256(json.dumps(shlex.split(flags)).encode()).hexdigest()[:20]


def pack(repo, root, config, flags):
    output = root / key(config, flags)
    config_dir = repo / "hdl/configs" / config
    if not (config_dir / "rapt_config.svh").is_file():
        raise ValueError(f"Unknown RTL preset: {config}")
    # Same package-first source set as sim/Makefile: no upstream SoC models,
    # and only the two supported generated instruction decoders.
    sources = sorted(p for p in (repo / "hdl").rglob("*.sv") if "generated" not in p.relative_to(repo / "hdl").parts)
    sources += sorted((repo / "sim/rtl").rglob("*.sv"))
    sources += [repo / "hdl/generated" / name for name in ("rapt_idu_decoder.sv", "rapt_idu_decoder_c.sv")]
    sources = [repo / "hdl/rapt_pkg.sv"] + [p for p in sources if p.name != "rapt_pkg.sv"]
    for source in sources:
        if not source.is_file():
            raise ValueError(f"Missing {source}; generate decoders with make verilog before building")
    includes = [config_dir, repo / "sim/include", repo / "hdl/include",
                repo / "hdl/include/npc", repo / "hdl/include/dpic_mock"]
    command = ["verilator", "-E", "-P", "-DSYNTHESIS", *shlex.split(flags),
               *(f"-I{p}" for p in includes), *map(str, sources)]
    digest = hashlib.sha256(json.dumps(command).encode())
    headers = sorted((repo / "hdl").rglob("*.svh")) + sorted((repo / "sim").glob("include/**/*.svh"))
    for source in sources + headers:
        digest.update(str(source).encode())
        digest.update(source.read_bytes())
    signature = digest.hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    with (output / ".lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stamp = output / ".signature"
        if stamp.exists() and stamp.read_text() == signature and all((output / n).is_file() for n in ("rapt_pack.sv", "rapt_pack.svh")):
            return output / "rapt_pack.sv"
        with tempfile.TemporaryDirectory(dir=output) as tmp:
            for name, extra in (("rapt_pack.sv", []), ("rapt_pack.svh", ["--dump-defines"])):
                with (Path(tmp) / name).open("wb") as dest:
                    subprocess.run(command[:1] + extra + command[1:], stdout=dest, check=True)
            for name in ("rapt_pack.sv", "rapt_pack.svh"):
                os.replace(Path(tmp) / name, output / name)
            (Path(tmp) / "signature").write_text(signature)
            os.replace(Path(tmp) / "signature", stamp)
    return output / "rapt_pack.sv"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--flags", default="")
    parser.add_argument("--path-only", action="store_true")
    args = parser.parse_args()
    if args.path_only:
        print(args.root / key(args.config, args.flags) / "rapt_pack.sv")
    else:
        print(pack(args.repo, args.root, args.config, args.flags))


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        # Verilator already printed the actual diagnostic on stderr. Avoid a
        # many-page Python argv traceback that hides its first error.
        print(f"RTL preprocessing failed (exit {exc.returncode}); see the Verilator diagnostics above.",
              file=sys.stderr)
        sys.exit(exc.returncode or 1)
