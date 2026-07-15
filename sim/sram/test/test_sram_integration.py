#!/usr/bin/env python3
"""Self-consistency tests for the OpenRAM SRAM integration.

These tests do *not* require yosys, slang, OpenRAM, or a PDK. They verify
the *contract* between the four pieces of the integration:

    1. sim/sram/configs/*.py            - macro shape definitions
    2. sim/sram/wrappers/rapt_sram_blackbox.v - Yosys blackbox declarations
    3. sim/sram/scripts/gen_stub_lib.py - placeholder Liberty/Verilog
    4. hdl/memory/rapt_sram_1r1w.sv     - RTL macro instantiations

If any of these drift out of sync (port width changes, missing pin,
shape removed from one file but not another), STA would either fail to
elaborate or silently mis-map. These tests catch that.

Run as:
  python3 test_sram_integration.py
or via:
    make -C sim/sram test

Exit code 0 = all pass; 1 = at least one failure.
"""
from __future__ import annotations

import math
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRAM = HERE.parent
RAPTOR = SRAM.parent.parent

# (macro_name, depth, data_width, write_size)
SHAPES = [
    ("rapt_openram_1r1w_32x32", 32, 32, 8),
    ("rapt_openram_1r1w_16x32", 16, 32, 8),
    ("rapt_openram_1r1w_16x64", 16, 64, 8),
]

BLACKBOX_V = SRAM / "wrappers" / "rapt_sram_blackbox.v"
STUB_GEN   = SRAM / "scripts" / "gen_stub_lib.py"
RTL_SRAM   = RAPTOR / "hdl" / "memory" / "rapt_sram_1r1w.sv"
CONFIG_DIR = SRAM / "configs"


# ---------------------------------------------------------------------------
# Tiny test harness (so we don't need pytest as a dep).
# ---------------------------------------------------------------------------
_failures: list[str] = []
_passes = 0


def check(cond: bool, msg: str) -> None:
    global _passes
    if cond:
        _passes += 1
        print(f"  PASS  {msg}")
    else:
        _failures.append(msg)
        print(f"  FAIL  {msg}")


def section(title: str) -> None:
    print(f"\n=== {title} ===")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def addr_width(depth: int) -> int:
    return max(1, math.ceil(math.log2(depth)))


def read(path: Path) -> str:
    return path.read_text()


# ---------------------------------------------------------------------------
# 1. Configs declare the right shapes
# ---------------------------------------------------------------------------
def test_configs():
    section("Configs (sim/sram/configs/*_sky130.py)")
    for name, depth, width, ws in SHAPES:
        # rapt_openram_1r1w_32x32 -> rapt_sram_32x32_1r1w_sky130.py
        shape = name.replace("rapt_openram_1r1w_", "")
        cfg = CONFIG_DIR / f"rapt_sram_{shape}_1r1w_sky130.py"
        check(cfg.is_file(), f"config exists: {cfg.name}")
        if not cfg.is_file():
            continue
        text = read(cfg)
        check(f"word_size  = {width}" in text or f"word_size = {width}" in text,
              f"{cfg.name} declares word_size={width}")
        check(f"num_words  = {depth}" in text or f"num_words = {depth}" in text,
              f"{cfg.name} declares num_words={depth}")
        check(f"write_size = {ws}" in text or f"write_size = {ws}" in text,
              f"{cfg.name} declares write_size={ws}")


# ---------------------------------------------------------------------------
# 2. Blackbox Verilog has one module per shape with the right ports
# ---------------------------------------------------------------------------
def test_blackbox():
    section("Blackbox Verilog (rapt_sram_blackbox.v)")
    check(BLACKBOX_V.is_file(), f"blackbox file exists: {BLACKBOX_V.name}")
    if not BLACKBOX_V.is_file():
        return
    text = read(BLACKBOX_V)
    for name, depth, width, ws in SHAPES:
        aw = addr_width(depth)
        bytes_ = width // ws
        # Find the module body
        mod_re = re.compile(
            rf"\(\*\s*blackbox\s*\*\)\s*module\s+{re.escape(name)}\s*\((.*?)\)\s*;",
            re.DOTALL,
        )
        m = mod_re.search(text)
        check(m is not None, f"{name}: (* blackbox *) module declaration present")
        if not m:
            continue
        body = m.group(1)
        # Required port widths
        port_specs = [
            ("clk0", None),
            ("csb0", None),
            ("web0", None),
            ("wmask0", bytes_),
            ("addr0", aw),
            ("din0", width),
            ("clk1", None),
            ("csb1", None),
            ("addr1", aw),
            ("dout1", width),
        ]
        for port, expect_w in port_specs:
            if expect_w is None:
                check(re.search(rf"\b{port}\b", body) is not None,
                      f"{name}: scalar port `{port}` present")
            else:
                wre = re.search(rf"\[(\d+):0\]\s+{port}\b", body)
                check(wre is not None,
                      f"{name}: bus port `{port}[{expect_w-1}:0]` present")
                if wre:
                    actual = int(wre.group(1)) + 1
                    check(actual == expect_w,
                          f"{name}: `{port}` width = {expect_w} (got {actual})")


# ---------------------------------------------------------------------------
# 3. RTL macro path instantiates each shape correctly
# ---------------------------------------------------------------------------
def test_rtl_macro_path():
    section("RTL macro path (rapt_sram_1r1w.sv)")
    check(RTL_SRAM.is_file(), f"RTL file exists: {RTL_SRAM.name}")
    if not RTL_SRAM.is_file():
        return
    text = read(RTL_SRAM)
    check("`ifdef RAPT_USE_SRAM_MACRO" in text,
          "macro path guarded by RAPT_USE_SRAM_MACRO")
    check("bypass_en_r" in text and "wdata_r" in text,
          "write-first bypass mux present (read-first macro -> write-first wrapper)")
    for name, depth, width, _ in SHAPES:
        # Find instantiation of this macro
        inst_re = re.compile(rf"{re.escape(name)}\s+\w+\s*\((.*?)\);", re.DOTALL)
        m = inst_re.search(text)
        check(m is not None, f"{name}: instantiated in generate-if cascade")
        if not m:
            continue
        body = m.group(1)
        for pin in ("clk0", "csb0", "web0", "wmask0", "addr0", "din0",
                    "clk1", "csb1", "addr1", "dout1"):
            check(f".{pin}(" in body, f"{name}: port `.{pin}(...)` connected")
        # Verify the generate-if guard matches the shape
        guard_re = re.compile(
            rf"DEPTH\s*==\s*{depth}\s*&&\s*DATA_WIDTH\s*==\s*{width}.*?{re.escape(name)}",
            re.DOTALL,
        )
        check(guard_re.search(text) is not None,
              f"{name}: guarded by DEPTH=={depth} && DATA_WIDTH=={width}")
    # Unsupported shape escape hatch
    check("$fatal" in text and "no OpenRAM macro" in text,
          "unsupported (DEPTH,WIDTH) triggers $fatal at elaboration")


# ---------------------------------------------------------------------------
# 4. Stub generator produces parseable Liberty with required arcs
# ---------------------------------------------------------------------------
def test_stub_lib():
    section("Stub Liberty (.lib) generated by gen_stub_lib.py")
    check(STUB_GEN.is_file(), f"generator exists: {STUB_GEN.name}")
    if not STUB_GEN.is_file():
        return
    out = HERE / "_tmp_libs"
    out.mkdir(exist_ok=True)
    for name, depth, width, ws in SHAPES:
        macro_dir = out / name
        rc = subprocess.run(
            [sys.executable, str(STUB_GEN), name,
             str(depth), str(width), str(ws), str(macro_dir)],
            capture_output=True, text=True,
        )
        check(rc.returncode == 0,
              f"{name}: gen_stub_lib.py exits 0 (stderr: {rc.stderr.strip()[:80]})")
        if rc.returncode != 0:
            continue
        lib = macro_dir / f"{name}.lib"
        check(lib.is_file(), f"{name}: .lib produced")
        v = macro_dir / f"{name}.v"
        check(v.is_file(), f"{name}: .v produced")
        if not lib.is_file():
            continue
        text = read(lib)
        # Mandatory liberty constructs
        for marker, label in [
            (f"library ({name})", "library() header"),
            (f"cell ({name})", "cell() block"),
            ("is_macro_cell : true", "is_macro_cell"),
            ("dont_touch : true", "dont_touch"),
            ("delay_model              : table_lookup", "delay_model"),
            ("pin (clk0)", "pin(clk0)"),
            ("pin (clk1)", "pin(clk1)"),
            ("pin (csb0)", "pin(csb0)"),
            ("pin (web0)", "pin(web0)"),
            ("bus (wmask0)", "bus(wmask0)"),
            ("bus (addr0)", "bus(addr0)"),
            ("bus (din0)", "bus(din0)"),
            ("pin (csb1)", "pin(csb1)"),
            ("bus (addr1)", "bus(addr1)"),
            ("bus (dout1)", "bus(dout1)"),
        ]:
            check(marker in text, f"{name}: {label} present")
        # Timing arcs: clk->Q on dout1 and setup/hold on at least one input
        check(text.count("timing_type : setup_rising") >= 6,
              f"{name}: >=6 setup arcs (csb0/web0/wmask0/addr0/din0/csb1/addr1)")
        check(text.count("timing_type : hold_rising") >= 6,
              f"{name}: >=6 hold arcs")
        check("timing_type : rising_edge" in text and "cell_rise" in text,
              f"{name}: clk1 -> dout1 propagation arc present")
        # Bus widths match
        aw = addr_width(depth)
        bytes_ = width // ws
        # bus name -> (Liberty type name, expected bit_width)
        bus_widths = {
            "wmask0": ("wmask0_bus_t", bytes_),
            "addr0":  ("addr0_bus_t",  aw),
            "din0":   ("data0_bus_t",  width),
            "addr1":  ("addr1_bus_t",  aw),
            "dout1":  ("data1_bus_t",  width),
        }
        for bus, (typ, expect) in bus_widths.items():
            m = re.search(
                rf"type\s*\({typ}\)\s*\{{[^}}]*bit_width\s*:\s*(\d+)",
                text, re.DOTALL,
            )
            check(m is not None and int(m.group(1)) == expect,
                  f"{name}: bus({bus}) -> type({typ}) width = {expect}")
        # Area annotation positive and within an order of magnitude of expected
        m = re.search(r"\barea\s*:\s*([\d.]+)", text)
        check(m is not None and float(m.group(1)) > 0,
              f"{name}: area annotation present and > 0")
        if m:
            expected = depth * width * 2.0 * 1.3
            actual = float(m.group(1))
            check(0.5 * expected <= actual <= 2.0 * expected,
                  f"{name}: area ~ depth*width*2.0*1.3 "
                  f"({expected:.0f}, got {actual:.0f})")


# ---------------------------------------------------------------------------
# 5. Cross-consistency: blackbox port widths match config + RTL guard
# ---------------------------------------------------------------------------
def test_cross_consistency():
    section("Cross-file consistency")
    # Every shape in SHAPES must be referenced by all four artefacts.
    if BLACKBOX_V.is_file():
        bb = read(BLACKBOX_V)
    else:
        bb = ""
    if RTL_SRAM.is_file():
        rtl = read(RTL_SRAM)
    else:
        rtl = ""
    for name, _, _, _ in SHAPES:
        in_bb = name in bb
        in_rtl = name in rtl
        in_cfg = (CONFIG_DIR / f"rapt_sram_{name.replace('rapt_openram_1r1w_','')}_1r1w_sky130.py").is_file()
        check(in_bb and in_rtl and in_cfg,
              f"{name}: appears in blackbox V, RTL, and configs")

    # No orphan macro names in blackbox V (declared but never instantiated)
    declared = set(re.findall(r"module\s+(rapt_openram_1r1w_\w+)\s*\(", bb))
    expected = {n for n, *_ in SHAPES}
    check(declared == expected,
          f"blackbox V module set == expected set "
          f"(extra={declared - expected}, missing={expected - declared})")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main() -> int:
    print(f"raptor-chip SRAM integration tests (root: {RAPTOR})")
    test_configs()
    test_blackbox()
    test_rtl_macro_path()
    test_stub_lib()
    test_cross_consistency()
    print()
    print(f"Results: {_passes} passed, {len(_failures)} failed")
    for f in _failures:
        print(f"  FAILED: {f}")
    return 0 if not _failures else 1


if __name__ == "__main__":
    sys.exit(main())
