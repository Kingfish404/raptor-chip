"""Shared source selection and content fingerprints for the Arty vehicle."""

import hashlib
import pathlib
import os
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[3]
BOARD = ROOT / "fpga/arty-a7-t100"


def tool_environment():
    """Honor tool settings and tolerate a relocated Verilator installation."""
    env = os.environ.copy()
    executable = shutil.which("verilator")
    if "VERILATOR_ROOT" not in env and executable:
        result = subprocess.run([executable, "-getenv", "VERILATOR_ROOT"],
                                capture_output=True, text=True, check=True)
        configured = pathlib.Path(result.stdout.strip())
        candidate = pathlib.Path(executable).parent.parent / "share/verilator"
        if (not (configured / "include/verilated.mk").is_file()
                and (candidate / "include/verilated.mk").is_file()):
            env["VERILATOR_ROOT"] = str(candidate)
    return env


def rtl_sources():
    package = ROOT / "rtl/rapt_pkg.sv"
    rtl = sorted(p for p in (ROOT / "rtl").rglob("*.sv") if p != package)
    return [package] + rtl + sorted((ROOT / "synth/configs/pin-limited/rtl").glob("*.sv"))


def board_sources():
    return [ROOT / "fpga/common/rtl/rapt_xspi_target.sv"] + sorted(
        p for p in (BOARD / "rtl").glob("*.sv")
    )


def includes():
    return [ROOT / "rtl" / p for p in (
        "configs/chip32-small", "include", "include/npc", "include/dpic_mock"
    )]


def fingerprint(paths):
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(set(paths))}


def input_files():
    paths = rtl_sources() + board_sources()
    paths += list((ROOT / "rtl").rglob("*.svh"))
    paths += [p for p in BOARD.rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    return paths
