#!/usr/bin/env python3
"""Run Kconfig in a build-local working directory, never in the source tree."""
import argparse
import fcntl
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--defconfig")
    parser.add_argument("--default", default="o2_difftest_defconfig")
    parser.add_argument("--menu", action="store_true")
    parser.add_argument("--save", type=Path)
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    # Recursive make overrides intended for the simulator must not redirect
    # the Kconfig tool's own build or leak configuration into it.
    for name in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "KCONFIG_CONFIG",
                 "KCONFIG_AUTOCONFIG", "KCONFIG_AUTOHEADER"):
        env.pop(name, None)
    env.setdefault("NEMU_HOME", str(source.parent / "nemu"))
    tools = source / "tools/kconfig"
    (tools / "build").mkdir(parents=True, exist_ok=True)
    # Shared frontend compilation is the only shared write and is serialized;
    # distinct configurations and simulation builds remain independent.
    with (tools / "build/.build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for name in ("conf", "mconf") if args.menu else ("conf",):
            binary = tools / "build" / name
            if not binary.exists():
                subprocess.run(["make", "--no-print-directory", "-s", "-C", str(tools),
                                f"NAME={name}"], env=env, check=True)
    env.update(srctree=str(source), KCONFIG_CONFIG=str(output / ".config"),
               KCONFIG_AUTOCONFIG=str(output / "include/config/auto.conf"),
               KCONFIG_AUTOHEADER=str(output / "include/generated/autoconf.h"))
    kconfig = str(source / "Kconfig")
    conf = str(tools / "build/conf")
    with (output / ".config.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        tracked = [output / p for p in (".config", "include/config/auto.conf",
                   "include/config/auto.conf.cmd", "include/generated/autoconf.h")]
        before = {p: (p.read_bytes(), p.stat()) for p in tracked if p.exists()}
        if args.defconfig or not (output / ".config").exists():
            preset = source / "configs" / (args.defconfig or args.default)
            subprocess.run([conf, "-s", f"--defconfig={preset}", kconfig],
                           cwd=output, env=env, check=True)
        if args.menu:
            subprocess.run([str(tools / "build/mconf"), kconfig],
                           cwd=output, env=env, check=True)
        subprocess.run([conf, "-s", "--syncconfig", kconfig],
                       cwd=output, env=env, check=True)
        if args.save:
            subprocess.run([conf, "-s", f"--savedefconfig={args.save.resolve()}", kconfig],
                           cwd=output, env=env, check=True)
        # An idempotent configure must not trigger a full Verilator/C++ rebuild.
        for path, (content, stat) in before.items():
            if path.read_bytes() == content:
                os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    print(f"[sim] configuration: {output / '.config'}", flush=True)


if __name__ == "__main__":
    main()
