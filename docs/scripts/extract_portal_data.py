#!/usr/bin/env python3
"""Extract static portal data from RTL, config, Makefile, and docs.

The GitHub Pages site is static. This script walks the repository and writes
JSON the browser can render. Topology comes from SystemVerilog instantiations,
numeric defaults from the default preset plus module parameters, commands from
Makefile `##` help comments, and the documented pipeline overlay from the
root README mermaid diagram. Nothing is invented at random.
"""

from __future__ import annotations

import argparse
import ast
import json
import operator
import re
import shutil
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pipeline_model import simulate as simulate_pipeline

SKIP_TYPES = {
    "rapt_sram_1rw",
    "rapt_openram_1rw_2x32",
    "rapt_openram_1rw_8x32",
    "rapt_openram_1rw_32x32",
    "rapt_openram_1rw_64x32",
    "rapt_openram_1rw_16x32",
    "rapt_openram_1rw_16x64",
    "rapt_openram_1rw_512x32",
    "rapt_openram_1rw_2x128",
    "rapt_openram_1rw_8x128",
    "rapt_openram_1rw_16x128",
    "rapt_openram_1rw_32x128",
    "rapt_openram_1rw_64x128",
    "rapt_openram_1rw_2048x32",
    "rapt_openram_1rw_2048x64",
    "rapt_unsupported_sram_shape",
}

# Documented pipeline column for the explorer. Keys are RTL module types.
# Positions follow docs/uarch.md and the README mermaid subgraphs, not a
# force-directed layout.
STAGE_OF = {
    "rapt_bpu": 0,
    "rapt_bpu_btb": 0,
    "rapt_bpu_tage": 0,
    "rapt_bpu_pht": 0,
    "rapt_ras": 0,
    "rapt_predict_history": 0,
    "rapt_ifu": 0,
    "rapt_l1i": 0,
    "rapt_ifetch_io_guard": 0,
    "rapt_ifetch_translate": 0,
    "rapt_fqu": 1,
    "rapt_idu": 1,
    "rapt_decode_slot": 1,
    "rapt_idu_decoder": 1,
    "rapt_idu_decoder_c": 1,
    "rapt_rnu": 2,
    "rapt_rename_checkpoint": 2,
    "rapt_rename_admit": 2,
    "rapt_rnu_maptable": 2,
    "rapt_rnu_freelist": 2,
    "rapt_prf": 3,
    "rapt_fp_registers": 3,
    "rapt_rou": 3,
    "rapt_dpu": 3,
    "rapt_rob_dispatch_select": 3,
    "rapt_dispatch_admit": 3,
    "rapt_dispatch_iq_adapter": 3,
    "rapt_dispatch_ioq_adapter": 3,
    "rapt_ieu": 4,
    "rapt_feu": 4,
    "rapt_lsu": 4,
    "rapt_iq": 4,
    "rapt_execute_stage": 4,
    "rapt_cdb_arb": 5,
    "rapt_completion_stage": 5,
    "rapt_completion_guard": 5,
    "rapt_recovery_pending": 5,
    "rapt_cmu": 6,
    "rapt_csr": 6,
    "rapt_rvfi": 6,
    "rapt_l1d": 7,
    "rapt_pmp": 7,
    "rapt_pmp_state": 7,
    "rapt_pmp_permissions": 7,
    "rapt_tlb": 7,
    "rapt_ptw": 7,
    "rapt_bus": 8,
    "rapt_axi_master": 8,
    "rapt_l2": 8,
    "rapt_router": 8,
    "rapt_clint": 9,
    "rapt_plic": 9,
    "rapt_dm": 9,
    "rapt_dtm": 9,
    "rapt_core": 3,
    "rapt_frontend": 1,
    "rapt_backend": 4,
    "rapt": 4,
}

ARCH_SHORT = {
    "rapt": "cluster",
    "rapt_core": "core",
    "rapt_frontend": "FE",
    "rapt_backend": "BE",
    "rapt_bpu": "BPU",
    "rapt_ifu": "IFU",
    "rapt_fqu": "FQU",
    "rapt_idu": "IDU",
    "rapt_rnu": "RNU",
    "rapt_operand_stage": "OPS",
    "rapt_prf": "PRF",
    "rapt_fp_registers": "FPR",
    "rapt_rou": "ROU",
    "rapt_dpu": "DPU",
    "rapt_ieu": "IEU",
    "rapt_ieu_muldiv": "MDU",
    "rapt_feu": "FEU",
    "rapt_lsu": "LSU",
    "rapt_lsu_sq": "SQ",
    "rapt_cdb_arb": "CDB",
    "rapt_cmu": "CMU",
    "rapt_csr": "CSR",
    "rapt_l1i": "L1I",
    "rapt_l1d": "L1D",
    "rapt_l1d_mshr": "MSHR",
    "rapt_tlb": "TLB",
    "rapt_ptw": "PTW",
    "rapt_bus": "BUS",
    "rapt_axi_master": "AXI",
    "rapt_l2": "L2",
    "rapt_clint": "CLINT",
    "rapt_plic": "PLIC",
    "rapt_router": "RTR",
    "rapt_dm": "DM",
    "rapt_dtm": "DTM",
    "rapt_pmp_state": "PMP",
    "rapt_ifetch_io_guard": "IOG",
    "soc_uart": "UART",
    "soc_pmem": "PMEM",
}

# Drawn explorer blocks. Shells (rapt/core/FE/BE) and tiny helpers stay in
# the graph for inspect/tree but are omitted from the die so tiles do not stack.
DISPLAY_IDS = {
    "rapt_bpu",
    "rapt_l1i",
    "rapt_ifu",
    "rapt_fqu",
    "rapt_idu",
    "rapt_rnu",
    "rapt_operand_stage",
    "rapt_prf",
    "rapt_fp_registers",
    "rapt_rou",
    "rapt_dpu",
    "rapt_ieu",
    "rapt_ieu_muldiv",
    "rapt_feu",
    "rapt_lsu",
    "rapt_lsu_sq",
    "rapt_cdb_arb",
    "rapt_cmu",
    "rapt_csr",
    "rapt_l1d",
    "rapt_l1d_mshr",
    "rapt_tlb",
    "rapt_ptw",
    "rapt_pmp_state",
    "rapt_bus",
    "rapt_l2",
    "rapt_axi_master",
    "rapt_router",
    "rapt_clint",
    "rapt_plic",
    "rapt_dm",
    "soc_pmem",
    "soc_uart",
}

TILE_SCALE = 1.0
LAYOUT_GAP = 0.42
# 2D schematic grid, Intel/AMD-manual style: columns are pipeline stages.
CELL_W = 6.8
CELL_H = 4.4
GAP_X = 0.7
GAP_Y = 0.85
SCHEMATIC = {
    # (col, row, colspan, rowspan)
    # Pipeline: Frontend (through IDU) then Backend (RNU, operand stage, UOQ/ROB, DPU, exec).
    # Memory frame: caches, translation, MSHR, PMP, and device windows.
    "rapt_bpu": (0, 0, 1, 1),
    "rapt_l1i": (1, 0, 1, 1),
    "rapt_ifu": (2, 0, 1, 1),
    "rapt_fqu": (3, 0, 1, 1),
    "rapt_idu": (4, 0, 1, 1),
    "rapt_rnu": (5, 0, 1, 1),
    "rapt_operand_stage": (6, 0, 1, 1),
    "rapt_rou": (7, 0, 1, 2),
    "rapt_dpu": (8, 0, 1, 1),
    "rapt_ieu": (9, 0, 1, 1),
    "rapt_cdb_arb": (10, 0, 1, 1),
    "rapt_fp_registers": (4, 1, 1, 1),
    "rapt_prf": (5, 1, 1, 1),
    "rapt_ieu_muldiv": (9, 1, 1, 1),
    "rapt_cmu": (10, 1, 1, 1),
    "rapt_feu": (9, 2, 1, 1),
    "rapt_csr": (10, 2, 1, 1),
    "rapt_lsu_sq": (8, 3, 1, 1),
    "rapt_lsu": (9, 3, 1, 1),
    "rapt_l1d": (0, 4, 1, 1),
    "rapt_bus": (1, 4, 1, 1),
    "rapt_l2": (2, 4, 1, 1),
    "rapt_axi_master": (3, 4, 1, 1),
    "soc_pmem": (4, 4, 2, 1),
    "rapt_tlb": (6, 4, 1, 1),
    "rapt_ptw": (7, 4, 1, 1),
    "rapt_l1d_mshr": (8, 4, 1, 1),
    "rapt_pmp_state": (9, 4, 1, 1),
    "soc_uart": (0, 5, 1, 1),
    "rapt_clint": (1, 5, 1, 1),
    "rapt_plic": (2, 5, 1, 1),
    "rapt_router": (3, 5, 1, 1),
    "rapt_dm": (4, 5, 2, 1),
}

# Abstract occupancy costs, not an RTL timing simulation. Queue capacities and
# switches come from the default preset; PMEM/UART costs are placeholders.
LATENCY_NOTES = (
    "Default RAPT_FETCH_RESPONSE_STAGE=0: no extra IFU response register (docs/uarch.md).",
    "Default RAPT_IQ_RECLAIM_ON_ISSUE=1: an issued queue slot may be reused on that edge.",
    "RNQ and rename_pipe are inside RNU. rapt_operand_stage buffers renamed packets; ROU owns the operand-reading UOQ.",
    "Default integer, branch, and memory completions bypass the common register; MUL/DIV retains it. Scalar FP has local result buffering.",
    "L1D hit returns from the registered access state. ITLB/DTLB misses probe the shared 256-entry direct-mapped L2 TLB before rapt_ptw.",
    "Default write-back L1D has 4 MSHRs and 2 writeback buffers; translated misses replay through IOQ. L2 is passthrough unless RAPT_L2_EN is set.",
    "PMEM/UART cycle costs are abstract PMA-window delays, not board measurements.",
    "Animation uses simplified queues, one completion delay, and conservative retirement; it omits redirects, replay, and actual ALU bypass timing. Model IPC is not RTL IPC.",
)

DOMAIN_FROM_PATH = (
    ("hdl/frontend/branch_predictor", "bpu"),
    ("hdl/frontend", "frontend"),
    ("hdl/backend/ieu", "ieu"),
    ("hdl/backend/feu", "feu"),
    ("hdl/backend/lsu", "lsu"),
    ("hdl/backend/vpu", "vpu"),
    ("hdl/backend", "backend"),
    ("hdl/memory", "memory"),
    ("hdl/perip", "cluster"),
    ("hdl/common", "common"),
    ("hdl/generated", "frontend"),
)

COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT_RE = re.compile(r"//.*?$", re.M)
MODULE_RE = re.compile(
    r"\bmodule\s+(\w+)\s*(?:#\s*\((.*?)\))?\s*\((.*?)\)\s*;(.*?)endmodule",
    re.S,
)
INST_RE = re.compile(
    r"\b(rapt_[A-Za-z0-9_]+)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\))?\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)\s*;",
    re.S,
)
DEFINE_RE = re.compile(
    r"^[ \t]*`define[ \t]+(RAPT_[A-Z0-9_]+|L1[ID]_[A-Z0-9_]+)(?:[ \t]+([^\r\n]*))?",
    re.M,
)
PARAM_RE = re.compile(
    r"parameter\s+(?:int\s+unsigned\s+|unsigned\s+|int\s+|type\s+|logic\s+)?"
    r"(\w+)\s*=\s*([^,)\n]+)",
)
MAKE_TARGET_RE = re.compile(
    r"^([A-Za-z0-9_.-]+):.*##\s+(.*)$",
    re.M,
)
MAKE_SECTION_RE = re.compile(r"^# =+\n# (.+)\n# =+", re.M)
MERMAID_RE = re.compile(r"```mermaid\n(.*?)```", re.S)
TITLE_RE = re.compile(r"^#\s+(.+)$", re.M)


def repo_root_from(script: Path) -> Path:
    return script.resolve().parents[2]


def strip_sv_comments(text: str) -> str:
    text = COMMENT_RE.sub(" ", text)
    text = LINE_COMMENT_RE.sub(" ", text)
    return text


def domain_for(rel_path: str) -> str:
    posix = rel_path.replace("\\", "/")
    for prefix, domain in DOMAIN_FROM_PATH:
        if posix.startswith(prefix):
            return domain
    if posix.startswith("hdl/"):
        return "core"
    return "other"


def first_module_comment(raw: str) -> str:
    """Take the last contiguous `//` block immediately above `module`."""
    lines = raw.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"\s*module\s+\w+", line):
            block: list[str] = []
            j = i - 1
            while j >= 0 and lines[j].strip() == "":
                j -= 1
            while j >= 0:
                m = re.match(r"\s*//\s?(.*)$", lines[j])
                if not m:
                    break
                block.append(m.group(1).strip())
                j -= 1
            block.reverse()
            text = " ".join(p for p in block if p and not p.startswith("verilator"))
            return text[:280]
    return ""


def parse_sv_file(path: Path, repo: Path, module_name: str | None = None) -> dict[str, Any] | None:
    raw = path.read_text(encoding="utf-8", errors="replace")
    stripped = strip_sv_comments(raw)
    match = next((m for m in MODULE_RE.finditer(stripped)
                  if module_name is None or m.group(1) == module_name), None)
    if not match:
        return None
    name = match.group(1)
    param_blob = match.group(2) or ""
    body = match.group(4) or ""
    rel = path.relative_to(repo).as_posix()
    params: dict[str, str] = {}
    for pname, pval in PARAM_RE.findall(param_blob):
        params[pname] = re.sub(r"\s+", " ", pval.strip())
    instances = []
    for itype, iname, port_blob in INST_RE.findall(body):
        if itype in SKIP_TYPES:
            continue
        ports = re.findall(r"\.(\w+)\s*\(", port_blob)
        instances.append(
            {
                "type": itype,
                "name": iname,
                "ports": ports[:24],
            }
        )
    return {
        "id": name,
        "file": rel,
        "domain": domain_for(rel),
        "stage": STAGE_OF.get(name),
        "summary": first_module_comment(raw),
        "params": params,
        "instances": instances,
    }


def parse_defines(text: str) -> dict[str, str]:
    defines: dict[str, str] = {}
    for name, value in DEFINE_RE.findall(strip_sv_comments(text).replace("\\\n", " ")):
        defines[name] = (value or "1").strip()
    return defines


def parse_defines_ifdef(text: str, predef: set[str] | None = None) -> dict[str, str]:
    """Evaluate `define under a tiny `ifdef/`ifndef/`else/`endif stack."""
    defined = set(predef or [])
    macros: dict[str, str] = {}
    stack: list[bool] = []
    active = True
    for line in strip_sv_comments(text).replace("\\\n", " ").splitlines():
        stripped = line.strip()
        if stripped.startswith("`ifdef"):
            name = stripped.split()[1]
            stack.append(active)
            active = active and (name in defined)
            continue
        if stripped.startswith("`ifndef"):
            name = stripped.split()[1]
            stack.append(active)
            active = active and (name not in defined)
            continue
        if stripped.startswith("`else"):
            parent = stack[-1] if stack else True
            active = parent and not active
            continue
        if stripped.startswith("`endif"):
            active = stack.pop() if stack else True
            continue
        if not active:
            continue
        match = DEFINE_RE.match(line)
        if match:
            raw = match.group(2) or "1"
            macros[match.group(1)] = raw.strip()
            defined.add(match.group(1))
    return macros


def eval_simple_int(expr: str, env: dict[str, Any]) -> int | None:
    """Resolve integer constants and the small expression subset used in presets.

    Unsupported syntax returns None; expressions never execute Python code.
    """
    expr = str(expr).strip().rstrip(",")
    while expr.startswith("(") and expr.endswith(")"):
        depth = 0
        for i, char in enumerate(expr):
            depth += (char == "(") - (char == ")")
            if depth == 0:
                break
        if i != len(expr) - 1:
            break
        expr = expr[1:-1].strip()
    key = expr.lstrip("`")
    if key in env:
        return eval_simple_int(str(env[key]), {k: v for k, v in env.items() if k != key})
    if re.fullmatch(r"`[A-Za-z_]\w*", expr):
        return None
    # Preset bounds use a single conditional outside the parentheses.
    depth = 0
    question = colon = None
    for i, char in enumerate(expr):
        depth += (char == "(") - (char == ")")
        if depth == 0 and char == "?":
            question = i
        if depth == 0 and char == ":" and question is not None:
            colon = i
            break
    if question is not None and colon is not None:
        condition = eval_simple_int(expr[:question], env)
        if condition is None:
            return None
        return eval_simple_int(expr[question + 1:colon] if condition else expr[colon + 1:], env)
    def macro(match):
        value = eval_simple_int(match[0], env)
        return str(value) if value is not None else "unknown"
    expr = re.sub(r"`[A-Za-z_]\w*", macro, expr)
    expr = re.sub(r"(?:\d+)?'h([0-9a-fA-F_]+)", lambda m: str(int(m[1], 16)), expr)
    binary = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
              ast.Div: operator.floordiv, ast.FloorDiv: operator.floordiv,
              ast.LShift: operator.lshift, ast.RShift: operator.rshift}
    compare = {ast.Lt: operator.lt, ast.LtE: operator.le, ast.Gt: operator.gt,
               ast.GtE: operator.ge, ast.Eq: operator.eq}
    def visit(node):
        if isinstance(node, ast.Constant) and type(node.value) is int:
            return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in binary:
            return binary[type(node.op)](visit(node.left), visit(node.right))
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
            return (-1 if isinstance(node.op, ast.USub) else 1) * visit(node.operand)
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and type(node.ops[0]) in compare:
            return int(compare[type(node.ops[0])](visit(node.left), visit(node.comparators[0])))
        raise ValueError("unsupported integer expression")
    try:
        return visit(ast.parse(expr, mode="eval").body)
    except (SyntaxError, ValueError, ZeroDivisionError):
        return None


def cache_kib(sets_log2: int, ways: int, line_bytes: int) -> int:
    return (2**sets_log2 * ways * line_bytes) // 1024


def collect_config(repo: Path) -> dict[str, Any]:
    preset = (repo / "hdl/configs/default/rapt_config.svh").read_text(
        encoding="utf-8", errors="replace"
    )
    common = (repo / "hdl/include/rapt.svh").read_text(
        encoding="utf-8", errors="replace"
    )
    pkg = (repo / "hdl/rapt_pkg.sv").read_text(encoding="utf-8", errors="replace")
    defines = parse_defines_ifdef(preset)
    for name, value in parse_defines_ifdef(common, set(defines)).items():
        defines.setdefault(name, value)

    def ival(*names: str, default: int | None = None) -> int | None:
        for name in names:
            if name in defines:
                parsed = eval_simple_int(defines[name], defines)
                if parsed is not None:
                    return parsed
        return default

    line = ival("RAPT_CACHE_LINE_BYTES", default=64) or 64
    l1i_len = ival("RAPT_L1I_LEN", default=5) or 5
    l1d_len = ival("RAPT_L1D_LEN", default=5) or 5
    l1i_ways = ival("RAPT_L1I_N_WAYS", default=4) or 4
    l1d_ways = ival("RAPT_L1D_N_WAYS", default=4) or 4
    l2_enabled = "RAPT_L2_EN" in defines and not defines["RAPT_L2_EN"].startswith("/")

    completion_ports = None
    m = re.search(
        r"completion_ports:\s*`RAPT_INTEGER_ISSUE_PORTS\s*\+\s*(\d+)", pkg
    )
    issue_ports = ival("RAPT_INTEGER_ISSUE_PORTS", default=2) or 2
    extra = int(m.group(1)) if m else 4
    completion_ports = issue_ports + extra

    return {
        "preset": "hdl/configs/default/rapt_config.svh",
        "macros": {k: v for k, v in sorted(defines.items()) if not v.startswith("$")},
        "values": {
            "decode_width": ival("RAPT_DECODE_WIDTH", default=2),
            "rename_width": ival("RAPT_RENAME_WIDTH", default=2),
            "dispatch_width": ival("RAPT_DISPATCH_WIDTH", default=2),
            "commit_width": ival("RAPT_COMMIT_WIDTH", default=2),
            "integer_issue_ports": issue_ports,
            "completion_ports": completion_ports,
            "rob_entries": ival("RAPT_ROB_SIZE", default=32),
            "alq_entries": ival("RAPT_RS_SIZE", default=8),
            "fpq_entries": ival("RAPT_RS_SIZE", default=8),
            "ioq_entries": ival("RAPT_IOQ_SIZE", default=8),
            "sq_entries": ival("RAPT_SQ_SIZE", default=16),
            "phys_regs": ival("RAPT_PHY_SIZE", default=64),
            "arch_regs": ival("RAPT_REG_SIZE", default=32),
            "pht_entries": ival("RAPT_PHT_SIZE", default=256),
            "btb_entries": ival("RAPT_BTB_SIZE", default=128),
            "btb_ways": ival("RAPT_BTB_WAYS", default=2),
            "rsb_entries": ival("RAPT_RSB_SIZE", default=4),
            "itlb_entries": ival("RAPT_ITLB_ENTRIES", default=16),
            "l2tlb_entries": ival("RAPT_L2TLB_ENTRIES", default=0),
            "dtlb_entries": ival("RAPT_DTLB_ENTRIES", default=16),
            "branch_checkpoints": ival("RAPT_BRANCH_CHECKPOINTS", default=16),
            "steer_scan_entries": ival("RAPT_STEER_SCAN_ENTRIES"),
            "rnq_entries": ival("RAPT_RIQ_SIZE"),
            "uoq_entries": ival("RAPT_IIQ_SIZE"),
            "operand_spill_entries": ival("RAPT_OPERAND_SPILL_ENTRIES"),
            "store_follower": ival("RAPT_ROU_STORE_FOLLOWER", default=0),
            "load_response_stage": ival("RAPT_IOQ_LOAD_RESPONSE_STAGE", default=0),
            "cache_line_bytes": line,
            "l1i_kib": cache_kib(l1i_len, l1i_ways, line),
            "l1d_kib": cache_kib(l1d_len, l1d_ways, line),
            "l1i_ways": l1i_ways,
            "l1d_ways": l1d_ways,
            "l2_enabled": l2_enabled,
            "dirp": "TAGE" if "RAPT_BPU_DIRP_TAGE" in defines else "bimodal",
            "pmp_usable": ival("RAPT_PMP_NUM", default=8),
            "pmp_csr_slots": ival("RAPT_PMP_CSR_NUM", default=16),
            "fetch_response_stage": ival("RAPT_FETCH_RESPONSE_STAGE", default=0) or 0,
            "iq_reclaim_on_issue": ival("RAPT_IQ_RECLAIM_ON_ISSUE", default=1) or 0,
            "l1d_mshrs": ival("RAPT_L1D_MSHRS", default=0) or 0,
            "m_fast": 1 if "RAPT_M_FAST" in defines else 0,
        },
        "sources": {
            "brq_entries": {
                "file": "hdl/rapt_pkg.sv",
                "parameter": "BranchQueueEntries (rapt_ieu.BRQ_SIZE)",
            },
            "mdq_entries": {
                "file": "hdl/backend/ieu/rapt_ieu.sv",
                "parameter": "MDQ_SIZE",
            },
            "fpq_entries": {
                "file": "hdl/backend/feu/rapt_feu.sv",
                "parameter": "FPQ_SIZE",
            },
        },
    }


def parse_module_param_defaults(modules: list[dict[str, Any]], constants: dict[str, Any] | None = None) -> dict[str, int]:
    wanted = {"BRQ_SIZE": "brq_entries", "MDQ_SIZE": "mdq_entries", "FPQ_SIZE": "fpq_entries"}
    found: dict[str, int] = {}
    for mod in modules:
        for pname, pval in mod.get("params", {}).items():
            key = wanted.get(pname)
            if not key:
                continue
            parsed = eval_simple_int(pval, constants or {})
            if parsed is not None:
                found[key] = parsed
    return found


def parse_makefile(repo: Path) -> dict[str, Any]:
    text = (repo / "Makefile").read_text(encoding="utf-8", errors="replace")
    sections: list[tuple[int, str]] = [(m.start(), m.group(1)) for m in MAKE_SECTION_RE.finditer(text)]
    commands = []
    for m in MAKE_TARGET_RE.finditer(text):
        name, desc = m.group(1), m.group(2).strip()
        section = "Targets"
        for start, title in sections:
            if start < m.start():
                section = title
        commands.append({"name": name, "description": desc, "section": section})
    return {"file": "Makefile", "commands": commands}


MERMAID_OP_RE = re.compile(r"(-->|---|\.->|-\.->|-\.[^.]*\.->|==>)")
MERMAID_NODE_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]*")


def _mermaid_kind(op: str) -> str:
    if op == "---":
        return "undirected"
    if "-." in op or op.startswith("-.") or op == ".->":
        return "control"
    return "data"


def _mermaid_node_ids(chunk: str) -> list[str]:
    # Drop quoted labels and shape wrappers, keep identifiers.
    cleaned = re.sub(r'\[[^\]]*\]|\([^)]*\)|\{[^}]*\}|"[^"]*"|\'[^\']*\'', " ", chunk)
    return MERMAID_NODE_RE.findall(cleaned)


def parse_mermaid_edges(body: str) -> list[dict[str, str]]:
    edges: list[dict[str, str]] = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith(("subgraph", "direction", "end", "%%")):
            continue
        if not MERMAID_OP_RE.search(line):
            continue
        labels = re.findall(r"\|([^|]+)\|", line)
        unlabeled = re.sub(r"\|[^|]+\|", "", line)
        parts = MERMAID_OP_RE.split(unlabeled)
        if len(parts) < 3:
            continue
        label_i = 0
        for i in range(1, len(parts), 2):
            op = parts[i]
            srcs = _mermaid_node_ids(parts[i - 1])
            dsts = _mermaid_node_ids(parts[i + 1])
            if not srcs or not dsts:
                continue
            label = ""
            if labels and label_i < len(labels):
                label = labels[label_i].strip()
                label_i += 1
            kind = _mermaid_kind(op)
            # Fan-in/fan-out: every id on the left to every id on the right.
            for src in srcs:
                for dst in dsts:
                    edges.append({"from": src, "to": dst, "kind": kind, "label": label})
    seen: set[tuple[str, str, str, str]] = set()
    uniq: list[dict[str, str]] = []
    for edge in edges:
        key = (edge["from"], edge["to"], edge["kind"], edge["label"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(edge)
    return uniq


def parse_mermaid(repo: Path) -> dict[str, Any]:
    text = (repo / "README.md").read_text(encoding="utf-8", errors="replace")
    m = MERMAID_RE.search(text)
    if not m:
        return {"file": "README.md", "nodes": [], "edges": []}
    body = m.group(1)
    nodes = []
    for id_, label in re.findall(
        r'^\s*([A-Za-z0-9_]+)\[(?:\["])?(.+?)(?:\])?"?\]', body, re.M
    ):
        nodes.append({"id": id_, "label": label})
    return {"file": "README.md", "nodes": nodes, "edges": parse_mermaid_edges(body)}


def parse_docs(repo: Path) -> list[dict[str, Any]]:
    docs_dir = repo / "docs"
    pages = []
    skip = {"index.md", "explore.md"}
    for path in sorted(docs_dir.glob("*.md")):
        if path.name in skip:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if text.startswith("---"):
            end = text.find("\n---", 3)
            if end != -1:
                text = text[end + 4 :]
        title_m = TITLE_RE.search(text)
        title = title_m.group(1).strip() if title_m else path.stem
        para = ""
        for block in text.split("\n\n"):
            block = block.strip()
            if not block or block == "---":
                continue
            if block.startswith("#") or block.startswith("```") or block.startswith("|") or block.startswith("[!["):
                continue
            if block.startswith(">"):
                continue
            para = re.sub(r"\s+", " ", block)[:220]
            break
        slug = path.stem
        html = "index.html" if slug.upper() == "README" else f"{slug}.html"
        if slug == "README":
            html = "overview.html"
        pages.append(
            {
                "file": f"docs/{path.name}",
                "name": path.name,
                "title": title,
                "url": html,
                "summary": para,
            }
        )
    return pages


def size_hint(module_id: str, values: dict[str, Any], extra: dict[str, int]) -> int:
    mapping = {
        "rapt_rou": values.get("rob_entries") or 16,
        "rapt_prf": max(8, (values.get("phys_regs") or 32) // 8),
        "rapt_fp_registers": 12,
        "rapt_ieu": extra.get("alq_entries", values.get("alq_entries") or 8),
        "rapt_feu": extra.get("fpq_entries", 4),
        "rapt_lsu": values.get("sq_entries") or 8,
        "rapt_iq": values.get("alq_entries") or 8,
        "rapt_l1i": values.get("l1i_kib") or 8,
        "rapt_l1d": values.get("l1d_kib") or 8,
        "rapt_bpu": 10,
        "rapt_ifu": 8,
        "rapt_idu": values.get("decode_width") or 2,
        "rapt_rnu": values.get("rename_width") or 2,
        "rapt_dpu": values.get("dispatch_width") or 2,
        "rapt_cmu": values.get("commit_width") or 2,
        "rapt_frontend": 18,
        "rapt_backend": 22,
        "rapt_core": 28,
        "rapt": 14,
    }
    if module_id in mapping:
        return int(mapping[module_id])
    return 6


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def buffer_model(values: dict[str, Any], extra: dict[str, int]) -> dict[str, dict[str, Any]]:
    """Tile size and occupancy from the default preset; latency from documented RTL."""
    decode = values.get("decode_width") or 2
    rob = values.get("rob_entries") or 32
    alq = extra.get("alq_entries", values.get("alq_entries") or 8)
    fpq = extra.get("fpq_entries", values.get("fpq_entries") or 8)
    brq = extra.get("brq_entries", values.get("brq_entries") or 8)
    mdq = extra.get("mdq_entries", values.get("mdq_entries") or 4)
    sq = values.get("sq_entries") or 16
    ioq = values.get("ioq_entries") or 8
    prf = values.get("phys_regs") or 64
    l1i = values.get("l1i_kib") or 16
    l1d = values.get("l1d_kib") or 16
    btb = values.get("btb_entries") or 128
    pmp = values.get("pmp_usable") or 8
    fetch_stage = 1 if values.get("fetch_response_stage", 0) else 0
    mul_fast = 1 if values.get("m_fast", True) else 3
    l1d_hit = 2  # docs.agent/history/perf-iterations.md

    def tile(sx: float, sz: float, cap: int, latency: int, note: str, kind: str) -> dict[str, Any]:
        return {
            "sx": round(sx * TILE_SCALE, 3),
            "sz": round(sz * TILE_SCALE, 3),
            "sy": round(_clamp(0.22 + cap * 0.018, 0.28, 1.15) * TILE_SCALE, 3),
            "capacity": cap,
            "latency": latency,
            "note": note,
            "kind": kind,
        }

    return {
        "rapt_l1i": tile(1.2, 1.15, l1i, 1, f"{l1i} KiB 4-way I$; sequential hit ~1 cycle", "cache"),
        "rapt_bpu": tile(1.05, 0.95, btb, 1, "TAGE + 128-entry 2-way BTB", "predictor"),
        "rapt_ifu": tile(0.95, 0.85, decode, 1 + fetch_stage, f"fetch window; FETCH_RESPONSE_STAGE={fetch_stage}", "stage"),
        "rapt_fqu": tile(0.85, 0.8, decode * 2, 1, "fetch stream queue; DEPTH=2 times decode width", "queue"),
        "rapt_idu": tile(0.9, 0.85, decode, 1, f"decode width {decode}", "stage"),
        "rapt_rnu": tile(0.95, 0.9, values.get("rename_width") or 2, 1, "RNQ plus rename_pipe and checkpoints", "stage"),
        "rapt_operand_stage": tile(0.9, 0.85, values.get("rename_width") or 2, 1, "renamed-packet buffer before the ROU operand-reading UOQ", "queue"),
        "rapt_prf": tile(0.95, 1.15, prf, 1, f"integer PRF {prf}", "regfile"),
        "rapt_fp_registers": tile(0.9, 0.95, 32, 1, "ROB-backed FP renaming and committed FPR 32x64", "regfile"),
        "rapt_rou": tile(1.15, 1.55, rob, 1, f"ROB {rob}; UOQ {values.get('uoq_entries') or 8}; pending operands in a separate spill bank", "queue"),
        "rapt_dpu": tile(0.9, 0.85, values.get("dispatch_width") or 2, 1, "steer into ALQ/BRQ/MDQ/FPQ/IOQ", "stage"),
        "rapt_ieu": tile(1.05, 1.2, alq + brq, 1, f"ALQ {alq} + BRQ {brq}; same-edge reuse={values.get('iq_reclaim_on_issue', 1)}", "queue"),
        "rapt_ieu_muldiv": tile(1.0, 1.0, mdq, mul_fast, f"MDQ {mdq}; integer mul/div", "queue"),
        "rapt_feu": tile(0.95, 0.95, fpq, 3, f"FPQ {fpq}; overlapping F/D pipelines, variable latency", "queue"),
        "rapt_lsu": tile(1.1, 1.05, ioq, 1, f"IOQ {ioq}: address, store-order, and issue", "queue"),
        "rapt_lsu_sq": tile(1.0, 1.0, sq, 1, f"unified SQ {sq}; drains after commit", "queue"),
        "rapt_cdb_arb": tile(0.85, 0.85, 1, 1, "legacy standalone completion buffer; core FP endpoint is independent", "stage"),
        "rapt_cmu": tile(0.95, 0.9, values.get("commit_width") or 2, 1, "retire / CMU", "stage"),
        "rapt_csr": tile(0.85, 0.8, 8, 1, "CSR file; serializing system ops", "stage"),
        "rapt_l1d": tile(1.25, 1.2, l1d, l1d_hit, f"{l1d} KiB 4-way D$; hit from registered access", "cache"),
        "rapt_l1d_mshr": tile(0.9, 0.85, values.get("l1d_mshrs") or 2, 1, "L1D miss status holding registers", "queue"),
        "rapt_tlb": tile(0.95, 0.9, values.get("itlb_entries") or 16, 1, "ITLB and DTLB instances of rapt_tlb", "cache"),
        "rapt_ptw": tile(0.9, 0.85, 1, 1, "Sv32/Sv39 page-table walk", "stage"),
        "rapt_pmp_state": tile(0.85, 0.8, pmp, 1, f"{pmp} usable PMP entries; checks fetch, data, and PTW", "stage"),
        "rapt_bus": tile(1.0, 0.95, 8, 2, "outstanding reads up to 8", "bus"),
        "rapt_l2": tile(1.15, 1.1, 0, 0, "default combinational passthrough; default-l2 enables 512 KiB / 8 ways", "cache"),
        "rapt_axi_master": tile(1.0, 0.95, 8, 2, "AXI4 master", "bus"),
        "rapt_router": tile(0.95, 0.9, 4, 1, "cluster device router", "bus"),
        "rapt_clint": tile(0.9, 0.8, 3, 2, "CLINT mtime/mtimecmp/msip", "device"),
        "rapt_plic": tile(0.95, 0.85, 31, 2, "PLIC 31 sources", "device"),
        "rapt_dm": tile(0.85, 0.75, 1, 2, "RISC-V debug module", "device"),
        "soc_pmem": tile(1.45, 1.25, 64, 8, "PMEM 0x80000000 (abstract fill)", "memory"),
        "soc_uart": tile(0.9, 0.8, 1, 4, "UART MMIO 0x10000000 (abstract)", "device"),
        "_mul_fast": {"latency": mul_fast},
    }


def pack_floorplan(model: dict[str, dict[str, Any]]) -> dict[str, tuple[float, float, float]]:
    """2D schematic: x = pipeline stage, z = row. No 3D projection."""
    pos: dict[str, tuple[float, float, float]] = {}
    for nid, (col, row, cw, rh) in SCHEMATIC.items():
        pw = cw * CELL_W + (cw - 1) * GAP_X
        ph = rh * CELL_H + (rh - 1) * GAP_Y
        x = col * (CELL_W + GAP_X) + pw / 2
        z = row * (CELL_H + GAP_Y) + ph / 2
        pos[nid] = (round(x, 3), 0.0, round(z, 3))
        if nid in model:
            model[nid]["sx"] = round(pw, 3)
            model[nid]["sz"] = round(ph, 3)
    return pos


def boxes_overlap(a: dict[str, Any], b: dict[str, Any], pad: float = 0.04) -> bool:
    return (
        abs(a["x"] - b["x"]) + pad < (a["sx"] + b["sx"]) / 2
        and abs(a["z"] - b["z"]) + pad < (a["sz"] + b["sz"]) / 2
    )


def layout_nodes(modules: list[dict[str, Any]], values: dict[str, Any], extra: dict[str, int]) -> list[dict[str, Any]]:
    by_id = {m["id"]: m for m in modules}
    children: dict[str, list[str]] = defaultdict(list)
    parent: dict[str, str] = {}
    for m in modules:
        for inst in m["instances"]:
            if inst["type"] in by_id and inst["type"] != m["id"]:
                children[m["id"]].append(inst["type"])
                parent.setdefault(inst["type"], m["id"])

    domain_lane = {
        "bpu": -1.4,
        "frontend": -0.6,
        "backend": 0.4,
        "ieu": 0.9,
        "feu": 1.3,
        "lsu": 0.0,
        "memory": 1.8,
        "cluster": 2.4,
        "core": 0.2,
        "common": 0.0,
        "other": 2.8,
        "vpu": 1.6,
    }
    model = buffer_model(values, extra)
    floor = pack_floorplan(model)
    nodes = []
    domain_counts: dict[str, int] = defaultdict(int)
    for m in modules:
        if m["id"] in SKIP_TYPES or not str(m["id"]).startswith("rapt"):
            continue
        stage = m["stage"]
        if stage is None:
            stage = STAGE_OF.get(parent.get(m["id"], ""), 8)
        geom = model.get(m["id"])
        if m["id"] in floor:
            x, y, z = floor[m["id"]]
        else:
            lane = domain_lane.get(m["domain"], 0.0)
            n = domain_counts[m["domain"]]
            domain_counts[m["domain"]] += 1
            x = float(stage if stage is not None else 8)
            z = lane + (n % 5) * 0.22 - 0.4
            y = 0.0
        node = {
            "id": m["id"],
            "short": ARCH_SHORT.get(m["id"], m["id"].removeprefix("rapt_")),
            "file": m["file"],
            "domain": m["domain"],
            "stage": stage,
            "summary": m["summary"],
            "parent": parent.get(m["id"]),
            "display": m["id"] in DISPLAY_IDS,
            "x": round(float(x), 3),
            "y": round(float(y), 3),
            "z": round(float(z), 3),
            "h": size_hint(m["id"], values, extra),
            "child_count": len(children.get(m["id"], [])),
        }
        if geom:
            node.update(
                {
                    "sx": geom["sx"],
                    "sz": geom["sz"],
                    "sy": geom["sy"],
                    "latency": geom["latency"],
                    "capacity": geom["capacity"],
                    "kind": geom["kind"],
                    "model_note": geom["note"],
                }
            )
        nodes.append(node)
    if not any(n["id"] == "rapt_operand_stage" for n in nodes):
        geom = model["rapt_operand_stage"]
        x, y, z = floor["rapt_operand_stage"]
        nodes.append(
            {
                "id": "rapt_operand_stage",
                "short": "OPS",
                "file": "hdl/backend/rapt_rou.sv",
                "domain": "backend",
                "stage": 3,
                "summary": "Operand stage: registers one renamed group before the ROU UOQ reads PRF operands.",
                "parent": "rapt_backend",
                "display": True,
                "x": x,
                "y": y,
                "z": z,
                "h": geom["capacity"],
                "sx": geom["sx"],
                "sz": geom["sz"],
                "sy": geom["sy"],
                "latency": geom["latency"],
                "capacity": geom["capacity"],
                "kind": geom["kind"],
                "model_note": geom["note"],
                "child_count": 0,
            }
        )
    nodes.extend(soc_display_nodes(model, floor))
    return nodes


def soc_display_nodes(
    model: dict[str, dict[str, Any]],
    floor: dict[str, tuple[float, float, float]],
) -> list[dict[str, Any]]:
    """SoC windows named in rapt_pkg::addr_mapped, drawn as explorer targets."""
    specs = (
        (
            "soc_pmem",
            "memory",
            8,
            "Cacheable PMEM window at 0x80000000 from rapt_pkg::addr_mapped.",
        ),
        (
            "soc_uart",
            "cluster",
            9,
            "MMIO UART/GPIO window at 0x10000000 from rapt_pkg::addr_mapped; LiteX UART at 0x11001800.",
        ),
    )
    nodes = []
    for nid, domain, stage, summary in specs:
        geom = model[nid]
        x, y, z = floor[nid]
        nodes.append(
            {
                "id": nid,
                "short": ARCH_SHORT[nid],
                "file": "hdl/rapt_pkg.sv",
                "domain": domain,
                "stage": stage,
                "summary": summary,
                "parent": "rapt_l2" if nid == "soc_pmem" else "rapt_router",
                "display": True,
                "x": x,
                "y": y,
                "z": z,
                "h": geom["capacity"],
                "sx": geom["sx"],
                "sz": geom["sz"],
                "sy": geom["sy"],
                "latency": geom["latency"],
                "capacity": geom["capacity"],
                "kind": geom["kind"],
                "model_note": geom["note"],
                "child_count": 0,
            }
        )
    return nodes


def instantiation_edges(modules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    known = {m["id"] for m in modules}
    edges = []
    seen = set()
    for m in modules:
        for inst in m["instances"]:
            if inst["type"] not in known:
                continue
            key = (m["id"], inst["type"], inst["name"])
            if key in seen:
                continue
            seen.add(key)
            edges.append(
                {
                    "from": m["id"],
                    "to": inst["type"],
                    "instance": inst["name"],
                    "kind": "instance",
                    "ports": inst["ports"][:12],
                }
            )
    return edges


COREMARK_ELF = (
    "abstract-machine/app/am-kernels/benchmarks/coremark_eembc/"
    "build/coremark-riscv32-npc.elf"
)
COREMARK_LISTING = "docs/assets/generated/coremark-rv32.s"
COREMARK_FUNCS = (
    ("matrix_mul_matrix", 40),
    ("core_bench_list", 16),
    ("crc16", 12),
    ("putch", 8),
)

FRONTEND_PATH = [
    "rapt_l1i",
    "rapt_ifu",
    "rapt_fqu",
    "rapt_idu",
    "rapt_rnu",
    "rapt_rou",
    "rapt_dpu",
]
RETIRE_PATH = ["rapt_cdb_arb", "rapt_rou", "rapt_cmu"]

BRANCH_OPS = {
    "beq", "bne", "blt", "bge", "bltu", "bgeu",
    "beqz", "bnez", "bgtz", "blez", "bltz", "bgez",
    "bgt", "ble", "bgtu", "bleu",
    "jal", "jalr", "j", "jr", "ret", "call", "tail",
}
MEM_OPS = {
    "lb", "lh", "lw", "ld", "lbu", "lhu", "lwu",
    "sb", "sh", "sw", "sd",
    "flw", "fsw", "fld", "fsd",
    "c.lw", "c.sw", "c.ld", "c.sd", "c.lwsp", "c.swsp",
    "c.lh", "c.sh",
}
MUL_OPS = {
    "mul", "mulh", "mulhu", "mulhsu", "div", "divu", "rem", "remu",
    "mulw", "divw", "divuw", "remw", "remuw",
}
SYS_OPS = {
    "csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci",
    "csrw", "csrr", "csrs", "csrc", "csrwi", "csrsi", "csrci",
    "ecall", "ebreak", "mret", "sret", "wfi", "wrs.sto", "wrs.nto",
    "fence", "fence.i", "sfence.vma", "sinval.vma", "sfence.w.inval",
    "sfence.inval.ir",
}


def classify_mnemonic(mnem: str) -> str:
    root = mnem.lower()
    if root in BRANCH_OPS or root in {"ret", "c.j", "c.jal", "c.jr", "c.jalr", "c.beqz", "c.bnez"}:
        return "branch"
    if root in MEM_OPS or root.startswith(("lr.", "sc.", "amo")):
        return "memory"
    if root in MUL_OPS:
        return "mul"
    if root in SYS_OPS:
        return "system"
    if root.startswith("f") and root not in {"fence", "fence.i"}:
        return "fp"
    return "integer"


def kernel_of(func: str) -> str:
    if func == "putch":
        return "uart"
    if "list" in func:
        return "list"
    if "crc" in func:
        return "crc"
    return "matrix"


def classify_coremark(mnem: str, func: str) -> str:
    domain = classify_mnemonic(mnem)
    if func == "putch" and domain == "memory":
        return "mmio"
    return domain


def path_for_domain(domain: str, kernel: str = "") -> list[str]:
    if domain == "mmio":
        return FRONTEND_PATH + ["rapt_lsu", "rapt_bus", "rapt_axi_master", "rapt_l2", "rapt_router", "soc_uart"] + RETIRE_PATH
    if domain == "memory" and kernel == "list":
        return FRONTEND_PATH + ["rapt_lsu", "rapt_l1d", "rapt_bus", "rapt_axi_master", "rapt_l2", "soc_pmem"] + RETIRE_PATH
    if domain == "memory":
        return FRONTEND_PATH + ["rapt_lsu", "rapt_l1d"] + RETIRE_PATH
    if domain == "fp":
        return FRONTEND_PATH + ["rapt_feu"] + RETIRE_PATH
    if domain == "mul":
        return FRONTEND_PATH + ["rapt_ieu"] + RETIRE_PATH
    return FRONTEND_PATH + ["rapt_ieu"] + RETIRE_PATH


def select_xlen_lines(text: str, xlen: int = 32) -> str:
    """Keep the RV32 (default) side of `__riscv_xlen` ifdefs."""
    out: list[str] = []
    stack: list[bool] = []
    taking = True
    for line in text.splitlines():
        stripped = line.strip()
        compact = stripped.replace(" ", "")
        if stripped.startswith("#if"):
            stack.append(taking)
            if "xlen==64" in compact:
                taking = taking and xlen == 64
            elif "xlen==32" in compact:
                taking = taking and xlen == 32
            continue
        if stripped.startswith("#else"):
            parent = stack[-1] if stack else True
            taking = parent and not taking
            continue
        if stripped.startswith("#endif"):
            taking = stack.pop() if stack else True
            continue
        if stripped.startswith(("#ifdef", "#ifndef", "#elif")):
            stack.append(taking)
            continue
        if taking:
            out.append(line)
    return "\n".join(out)


OBJDUMP_INSN_RE = re.compile(
    r"^\s*[0-9a-f]+:\s+([A-Za-z.][A-Za-z0-9.]*)\s*(.*)$"
)
OBJDUMP_FUNC_RE = re.compile(r"^[0-9a-f]+ <([^>+]+)>(?:|:)")


def parse_objdump_functions(text: str) -> dict[str, list[tuple[str, str, str]]]:
    """Map function name -> [(mnemonic, operands, asm), ...]."""
    funcs: dict[str, list[tuple[str, str, str]]] = {}
    current = None
    for raw in text.splitlines():
        line = raw.strip()
        header = re.match(r"^[0-9a-f]+\s+<([^>]+)>:", line)
        if header:
            current = header.group(1)
            funcs.setdefault(current, [])
            continue
        if current is None:
            continue
        insn = OBJDUMP_INSN_RE.match(line)
        if not insn:
            continue
        mnem, rest = insn.group(1), insn.group(2).strip()
        rest = rest.split("#", 1)[0].strip()
        rest = re.sub(r"<[^>]*>", "", rest).strip().rstrip(",")
        asm = f"{mnem} {rest}".strip()
        funcs[current].append((mnem, rest, asm))
    return funcs


def disassemble_coremark(repo: Path) -> str | None:
    elf = repo / COREMARK_ELF
    listing = repo / COREMARK_LISTING
    dumpers = [
        "riscv64-linux-gnu-objdump",
        "riscv32-unknown-elf-objdump",
        "llvm-objdump",
    ]
    if elf.is_file():
        for tool in dumpers:
            exe = shutil.which(tool)
            if not exe:
                continue
            cmd = [exe, "-d", "--no-show-raw-insn", str(elf)]
            if "llvm" in tool:
                cmd = [exe, "-d", str(elf)]
            try:
                out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            except (OSError, subprocess.CalledProcessError):
                continue
            if "<matrix_mul_matrix>:" in out or "matrix_mul_matrix" in out:
                return out
    if listing.is_file():
        return listing.read_text(encoding="utf-8", errors="replace")
    return None


def parse_payload(repo: Path, xlen: int = 32) -> dict[str, Any]:
    """CoreMark RV32 tokens from the built NPC ELF (or a cached listing).

    matrix_mul_matrix is the integer/mul/memory kernel, core_bench_list the
    pointer-chasing loads, crc16 the ALU mix, putch the UART MMIO store at
    0x10000000. Paths follow the documented DPU split plus PMA windows in
    rapt_pkg.sv. This is not a cycle-accurate NPC trace.
    """
    dump = disassemble_coremark(repo)
    instructions: list[dict[str, Any]] = []
    source = COREMARK_ELF
    if dump:
        funcs = parse_objdump_functions(dump)
        cache_lines = []
        addr = 0
        for name, limit in COREMARK_FUNCS:
            kernel = kernel_of(name)
            rows = funcs.get(name, [])[:limit]
            cache_lines.append(f"{addr:08x} <{name}>:")
            for mnem, operands, asm in rows:
                cache_lines.append(f"   {addr:x}:\t{asm}")
                addr += 2
                domain = classify_coremark(mnem, name)
                instructions.append(
                    {
                        "asm": asm,
                        "mnemonic": mnem,
                        "operands": operands,
                        "domain": domain,
                        "kernel": kernel,
                        "path": path_for_domain(domain, kernel),
                    }
                )
        listing = repo / COREMARK_LISTING
        listing.parent.mkdir(parents=True, exist_ok=True)
        listing.write_text("\n".join(cache_lines) + "\n", encoding="utf-8")
    counts: dict[str, int] = {}
    for inst in instructions:
        counts[inst["domain"]] = counts.get(inst["domain"], 0) + 1
    return {
        "file": source,
        "listing": COREMARK_LISTING,
        "xlen": xlen,
        "benchmark": "CoreMark",
        "kernels": [name for name, _ in COREMARK_FUNCS],
        "note": (
            "RV32 CoreMark from the NPC ELF: matrix_mul_matrix, core_bench_list, "
            "crc16, and putch (UART MMIO at 0x10000000). Tokens follow the "
            "documented pipeline and PMA map. Not a live Verilator trace."
        ),
        "instructions": instructions,
        "counts": counts,
    }


def documented_flow() -> list[dict[str, str]]:
    """Instruction-flow overlay from docs/uarch.md / README mermaid.

    This is not inferred from combinational connectivity; it is the documented
    ordered path used by the explorer animation.
    """
    return [
        {"from": "rapt_l1i", "to": "rapt_ifu", "label": "fetch window"},
        {"from": "rapt_bpu", "to": "rapt_ifu", "label": "prediction"},
        {"from": "rapt_ifu", "to": "rapt_fqu", "label": "prefix"},
        {"from": "rapt_fqu", "to": "rapt_idu", "label": "queued fetch"},
        {"from": "rapt_idu", "to": "rapt_rnu", "label": "decoded uop"},
        {"from": "rapt_rnu", "to": "rapt_operand_stage", "label": "renamed uop"},
        {"from": "rapt_operand_stage", "to": "rapt_rou", "label": "UOQ / PRF read"},
        {"from": "rapt_rou", "to": "rapt_dpu", "label": "steer"},
        {"from": "rapt_dpu", "to": "rapt_ieu", "label": "integer"},
        {"from": "rapt_dpu", "to": "rapt_feu", "label": "fp"},
        {"from": "rapt_dpu", "to": "rapt_lsu", "label": "memory"},
        {"from": "rapt_ieu", "to": "rapt_rou", "label": "guarded integer / branch / MUL-DIV"},
        {"from": "rapt_feu", "to": "rapt_rou", "label": "guarded FP completion"},
        {"from": "rapt_lsu", "to": "rapt_rou", "label": "guarded memory completion"},
        {"from": "rapt_rou", "to": "rapt_cmu", "label": "retire"},
        {"from": "rapt_lsu", "to": "rapt_l1d", "label": "load/store"},
        {"from": "rapt_l1i", "to": "rapt_bus", "label": "fill"},
        {"from": "rapt_l1d", "to": "rapt_bus", "label": "fill"},
        {"from": "rapt_bus", "to": "rapt_axi_master", "label": "unified"},
        {"from": "rapt_axi_master", "to": "rapt_l2", "label": "AXI"},
        {"from": "rapt_l2", "to": "rapt_router", "label": "cluster"},
        {"from": "rapt_l2", "to": "soc_pmem", "label": "PMEM 0x80000000"},
        {"from": "rapt_router", "to": "rapt_clint", "label": "CLINT"},
        {"from": "rapt_router", "to": "rapt_plic", "label": "PLIC"},
        {"from": "rapt_router", "to": "soc_uart", "label": "UART 0x10000000"},
    ]


def build(repo: Path) -> dict[str, Any]:
    hdl_root = repo / "hdl"
    modules: list[dict[str, Any]] = []
    for path in sorted(hdl_root.rglob("*.sv")):
        if "chisel" in path.parts:
            continue
        for match in MODULE_RE.finditer(strip_sv_comments(path.read_text())):
            parsed = parse_sv_file(path, repo, match.group(1))
            if parsed:
                modules.append(parsed)
    config = collect_config(repo)
    package = strip_sv_comments((repo / "hdl/rapt_pkg.sv").read_text())
    constants = {f"rapt_pkg::{name}": value for name, value in re.findall(
        r"localparam\s+(?:int\s+)?unsigned\s+(\w+)\s*=\s*(\d+)\s*;", package)}
    constants["Cfg.iq_entries"] = str(config["values"]["alq_entries"])
    extra = parse_module_param_defaults(modules, constants)
    config["values"].update(extra)
    makefile = parse_makefile(repo)
    mermaid = parse_mermaid(repo)
    docs = parse_docs(repo)
    nodes = layout_nodes(modules, config["values"], extra)
    edges = instantiation_edges(modules)
    payload = parse_payload(repo)
    trace = (
        simulate_pipeline(payload["instructions"], config["values"])
        if payload.get("instructions")
        else None
    )
    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": {
            "rtl": "hdl/",
            "config": config["preset"],
            "makefile": "Makefile",
            "topology_doc": "README.md mermaid + docs/uarch.md",
        },
        "config": config,
        "modules": modules,
        "graph": {
            "nodes": nodes,
            "instance_edges": edges,
            "flow_edges": documented_flow(),
        },
        "model": {
            "notes": list(LATENCY_NOTES),
            "gap": LAYOUT_GAP,
            "cycle_seconds": 0.18,
        },
        "trace": trace,
        "makefile": makefile,
        "documented_topology": mermaid,
        "payload": payload,
        "docs": docs,
        "github": "https://github.com/Kingfish404/raptor-chip",
        "isa": "rv32/rv64imafdc_zba_zbb_zbs_zfhmin",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        type=Path,
        default=None,
        help="Repository root (default: two levels above this script)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output JSON path",
    )
    args = parser.parse_args()
    script = Path(__file__).resolve()
    repo = args.repo.resolve() if args.repo else repo_root_from(script)
    out = (
        args.out
        if args.out
        else repo / "docs/assets/generated/portal-data.json"
    )
    data = build(repo)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} ({len(data['modules'])} modules, {len(data['makefile']['commands'])} make targets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
