#!/usr/bin/env python3
"""Install RV64 Linux app/ suites into a Raptor FPGA Linux rootfs."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import sys


PERF_SYSCTL_CONF = "kernel.perf_user_access = 2\n"

APPS_PROFILE_SH = (
    'case ":$PATH:" in\n'
    '    *:/opt/raptor/bin:*) ;;\n'
    '    *) [ -d /opt/raptor/bin ] && export PATH="$PATH:/opt/raptor/bin" ;;\n'
    'esac\n'
)

PERF_BOOT_SNIPPET = (
    "\nif [ -w /proc/sys/kernel/perf_user_access ]; then\n"
    "    echo 2 > /proc/sys/kernel/perf_user_access || true\n"
    "fi\n"
)


def atomic_copy_exec(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".{dst.name}.{os.getpid()}.tmp")
    shutil.copy2(src, tmp)
    tmp.chmod(0o755)
    tmp.replace(dst)


def atomic_symlink(target: str, link_path: Path) -> None:
    link_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = link_path.with_name(f".{link_path.name}.{os.getpid()}.lnk")
    if tmp.exists() or tmp.is_symlink():
        tmp.unlink()
    tmp.symlink_to(target)
    tmp.replace(link_path)


def atomic_write_text(dst: Path, content: str, mode: int = 0o644) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".{dst.name}.{os.getpid()}.tmp")
    tmp.write_text(content)
    tmp.chmod(mode)
    tmp.replace(dst)


def ensure_contained(rootfs: Path, rel: str) -> Path:
    parts = Path(rel).parts
    if Path(rel).is_absolute() or ".." in parts:
        raise RuntimeError(f"invalid relative path: {rel}")
    cur = rootfs
    root_real = rootfs.resolve()
    for part in parts[:-1]:
        cur = cur / part
        if cur.exists() or cur.is_symlink():
            if not cur.resolve().is_relative_to(root_real):
                raise RuntimeError(f"path escapes rootfs: {rel}")
    return rootfs / rel


def collect_binaries(build_root: Path, llm_profile: str) -> list[tuple[Path, str, str]]:
    """Return list of (host_elf_path, rel_under_opt_raptor_app, bin_alias_stem)."""
    entries: list[tuple[Path, str, str]] = []

    def add_glob(subdir: str, dest_dir: str, prefix: str = "") -> None:
        src_dir = build_root / subdir
        if not src_dir.is_dir():
            raise RuntimeError(f"missing build directory: {src_dir}")
        elfs = sorted(src_dir.glob("*.elf"))
        if not elfs:
            raise RuntimeError(f"no .elf files in {src_dir}")
        for elf in elfs:
            stem = prefix + elf.stem
            entries.append((elf, f"{dest_dir}/{elf.name}", stem))

    add_glob("tests/hello", "tests/hello")
    add_glob("tests/isa", "tests/isa")
    add_glob("tests/memory", "tests/memory")
    add_glob("tests/algo", "tests/algo")
    add_glob("security", "security")
    add_glob("demos", "demos")

    cm_full = build_root / "coremark/coremark.elf"
    cm_quick = build_root / "coremark-quick/coremark.elf"
    if not cm_full.is_file() or not cm_quick.is_file():
        raise RuntimeError("missing CoreMark Linux ELFs (coremark / coremark-quick)")
    entries.append((cm_full, "benchmarks/coremark/coremark.elf", "coremark"))
    entries.append((cm_quick, "benchmarks/coremark/coremark-quick.elf", "coremark-quick"))

    add_glob("coremark-pro/linux/bin", "benchmarks/coremark-pro")

    embench_root = build_root / "embench"
    if not embench_root.is_dir():
        raise RuntimeError(f"missing Embench directory: {embench_root}")
    embench_elfs = sorted(embench_root.glob("*/*.elf"))
    if not embench_elfs:
        raise RuntimeError(f"no Embench .elf files in {embench_root}")
    used_stems = {stem for _, _, stem in entries}
    for elf in embench_elfs:
        alias = f"embench-{elf.stem}" if elf.stem in used_stems else elf.stem
        used_stems.add(alias)
        entries.append((elf, f"benchmarks/embench/{elf.name}", alias))

    add_glob(f"benchmarks/llm/{llm_profile}", "benchmarks/llm")
    add_glob("benchmarks/agent", "benchmarks/agent")
    add_glob("microbench", "benchmarks/microbench")
    add_glob("memprobe", "benchmarks/memprobe")
    return entries


def build_readme(entries: list[tuple[Path, str, str]]) -> str:
    lines = [
        "# Raptor RV64 Linux Application & Benchmark Suite",
        "",
        "Static RV64GCV (`lp64d`) Linux executables built from `app/`.",
        "All `<name>.elf` commands (and non-conflicting `<name>` aliases) are",
        "available directly on `PATH` via `/usr/local/bin` and `/opt/raptor/bin`.",
        "",
        "## Quick Examples",
        "",
        "```sh",
        "spectre-v1.elf            # Bounds-check bypass microarch test",
        "spectre-v2.elf            # Branch-target injection microarch test",
        "spec-store-bypass.elf     # Speculative store-bypass test",
        "cache-timing.elf          # L1D reload hit vs miss latency",
        "bpu-collision.elf         # BPU alias / mispredict penalty",
        "fence-timing.elf          # fence / fence.i latency",
        "sysinfo.elf               # CPU / CSR / memory overview",
        "coremark-quick.elf        # ~1.3s CoreMark smoke run (1 MHz timebase)",
        "coremark.elf              # Official >=10s CoreMark run",
        "llm-ops.elf               # RLLMBench operator suite",
        "agent-tools.elf           # RAgentBench tool-dispatch suite",
        "RAPTOR_READ_CSR=1 memprobe.elf  # L1D/L2/DDR4 pointer-chase latency",
        "```",
        "",
        "## Installed Programs",
        "",
        f"Total binaries: {len(entries)}",
        "",
    ]
    by_dir: dict[str, list[str]] = {}
    for _, rel, alias in entries:
        parent = str(Path(rel).parent)
        label = Path(rel).name
        if alias != Path(rel).stem:
            label += f" (PATH alias: `{alias}.elf`)"
        by_dir.setdefault(parent, []).append(label)
    for folder in sorted(by_dir):
        lines.append(f"- `{folder}/`: " + ", ".join(by_dir[folder]))
    lines.append("")
    return "\n".join(lines)


def maybe_reexec_sudo(rootfs: Path) -> None:
    if os.geteuid() == 0:
        return
    probe = rootfs / "opt"
    check_dir = probe if probe.exists() else rootfs
    if os.access(check_dir, os.W_OK):
        return
    cmd = ["sudo", "-n", sys.executable, *sys.argv]
    os.execvp("sudo", cmd)


def system_has_binary(rootfs: Path, stem: str) -> bool:
    for d in ("usr/bin", "bin", "usr/sbin", "sbin"):
        cand = rootfs / d / stem
        if cand.exists() or cand.is_symlink():
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--llm-profile", required=True)
    args = parser.parse_args()

    build_root = args.build_root.resolve()
    rootfs = args.rootfs.resolve()
    if not (rootfs / "etc").is_dir() or not (rootfs / "usr").is_dir():
        raise SystemExit(f"error: {rootfs} does not look like a Linux rootfs")

    entries = collect_binaries(build_root, args.llm_profile)
    maybe_reexec_sudo(rootfs)

    app_base = ensure_contained(rootfs, "opt/raptor/app")
    bin_base = ensure_contained(rootfs, "opt/raptor/bin")
    local_bin = ensure_contained(rootfs, "usr/local/bin")
    app_base.mkdir(parents=True, exist_ok=True)
    bin_base.mkdir(parents=True, exist_ok=True)
    local_bin.mkdir(parents=True, exist_ok=True)

    for src, rel, alias in entries:
        dst = ensure_contained(rootfs, f"opt/raptor/app/{rel}")
        atomic_copy_exec(src, dst)
        target_abs = f"/opt/raptor/app/{rel}"
        atomic_symlink(target_abs, bin_base / f"{alias}.elf")
        atomic_symlink(target_abs, bin_base / alias)
        atomic_symlink(target_abs, local_bin / f"{alias}.elf")
        if not system_has_binary(rootfs, alias):
            atomic_symlink(target_abs, local_bin / alias)

    cmp_lic_src = build_root / "coremark-pro/linux/licenses"
    if cmp_lic_src.is_dir():
        cmp_lic_dst = ensure_contained(
            rootfs, "opt/raptor/app/benchmarks/coremark-pro/licenses"
        )
        cmp_lic_dst.mkdir(parents=True, exist_ok=True)
        for item in sorted(cmp_lic_src.iterdir()):
            if item.is_file():
                atomic_write_text(cmp_lic_dst / item.name, item.read_text(), 0o644)

    atomic_write_text(app_base / "README.md", build_readme(entries), 0o644)

    root_home = ensure_contained(rootfs, "root")
    if root_home.is_dir():
        atomic_symlink("/opt/raptor/app", root_home / "app")

    sysctl_dst = ensure_contained(rootfs, "etc/sysctl.d/90-raptor-perf.conf")
    atomic_write_text(sysctl_dst, PERF_SYSCTL_CONF, 0o644)

    prof_dst = ensure_contained(rootfs, "etc/profile.d/raptor-apps.sh")
    atomic_write_text(prof_dst, APPS_PROFILE_SH, 0o644)

    boot_env = ensure_contained(rootfs, "usr/local/sbin/raptor-boot-env")
    if boot_env.is_file() and "perf_user_access" not in boot_env.read_text():
        atomic_write_text(boot_env, boot_env.read_text() + PERF_BOOT_SNIPPET, 0o755)

    print(
        f"Installed {len(entries)} RV64 Linux programs to {app_base} "
        f"(and PATH links in {local_bin})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
