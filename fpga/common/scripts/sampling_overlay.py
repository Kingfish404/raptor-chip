#!/usr/bin/env python3
"""Materialize the intrusive FPGA replay experiment outside the production RTL."""
from contextlib import contextmanager
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

COMMON = Path(__file__).resolve().parents[1]
OVERLAY = COMMON / "sampling/core.patch"
INTERFACE = COMMON / "rtl/rapt_sample_if.svh"
TREES = ("rtl", "sim/include", "sim/rtl")
HOOKS = ("rtl/rapt.sv", "rtl/rapt_core.sv", "rtl/backend/rapt_backend.sv",
         "rtl/frontend/rapt_csr.sv", "rtl/perip/rapt_clint.sv", "rtl/include/rapt_if.svh")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(repo):
    result = hashlib.sha256()
    for name in TREES:
        for path in sorted((repo / name).rglob("*")):
            if path.is_file():
                result.update(path.relative_to(repo).as_posix().encode() + b"\0")
                result.update(path.read_bytes())
    return result.hexdigest()


@contextmanager
def sampling_sources(repo):
    """Yield a disposable source tree and a receipt; never patch the checkout.

    Exact state restoration is intentionally confined to this experimental
    variant. This isolates source changes; the resulting FPGA core is still
    instrumented and must not be described as non-intrusive hardware.
    """
    repo = Path(repo).resolve()
    patch_tool = shutil.which("patch")
    if not patch_tool:
        raise RuntimeError("FPGA replay overlay requires the patch utility")
    targets = [line[6:] for line in OVERLAY.read_text().splitlines()
               if line.startswith("+++ b/")]
    if sorted(targets) != sorted(HOOKS):
        raise RuntimeError("Unexpected FPGA overlay targets")
    before, patch_sha, interface_sha = source_digest(repo), digest(OVERLAY), digest(INTERFACE)
    with tempfile.TemporaryDirectory(prefix="raptor-replay-rtl-") as temporary:
        shadow = Path(temporary)
        for name in TREES:
            shutil.copytree(repo / name, shadow / name)
        shutil.copyfile(INTERFACE, shadow / "rtl/include/rapt_sample_if.svh")
        result = subprocess.run(
            [patch_tool, "--batch", "--fuzz=0", "--no-backup-if-mismatch",
             "--reject-file=-", "-p1", "-i", str(OVERLAY)],
            cwd=shadow, capture_output=True, text=True, check=False)
        if result.returncode:
            raise RuntimeError("FPGA replay overlay no longer matches production RTL:\n" +
                               result.stdout + result.stderr)
        receipt = {"schema": "raptor-fpga-replay-overlay-v1", "intrusive_hardware": True,
                   "production_source_sha256": before, "overlay_sha256": patch_sha,
                   "interface_sha256": interface_sha,
                   "files": {name: {"before": digest(repo / name), "after": digest(shadow / name)}
                             for name in HOOKS}}
        yield shadow, receipt
        if (source_digest(repo) != before or digest(OVERLAY) != patch_sha or
                digest(INTERFACE) != interface_sha):
            raise RuntimeError("FPGA replay inputs changed during export; retry the build")
