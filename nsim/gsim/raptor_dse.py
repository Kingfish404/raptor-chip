"""Config parsing and ChampSim-style DSE normalization for raptor_se.py."""

from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path


def _die(msg: str, code: int = 2) -> "NoReturn":  # type: ignore[name-defined]
    """Print *msg* and exit with an integer code.

    NEVER use ``raise SystemExit(<string>)`` in this codebase: gem5's C++
    ``main()`` reads the Python interpreter's exit value via
    ``pybind11::cast<int>``; a non-numeric ``SystemExit`` argument turns a
    clean error into ``pybind11::cast_error`` + ``abort()`` (gem5 prints a
    libc backtrace and ``Program aborted at tick 0`` — the symptom that
    motivated this helper). Always exit with an int.
    """
    print(msg, file=sys.stderr)
    sys.exit(code)


SUPPORTED_BP_KINDS: tuple[str, ...] = (
    "local",
    "bimode",
    "gshare",
    "tournament",
    "tage",
    "ltage",
    "tage_sc_l_8kb",
    "tage_sc_l_64kb",
    "mpp_8kb",
    "mpp_64kb",
    "mpp_tage_8kb",
    "mpp_tage_64kb",
)


def _parse_int(tok: str) -> int:
    """Accept decimal, hex (0x..), and Verilog literals like 'h1, 'h40141105."""
    tok = tok.strip()
    m = re.match(r"^'h([0-9a-fA-F_]+)$", tok)
    if m:
        return int(m.group(1).replace("_", ""), 16)
    if tok.lower().startswith("0x"):
        return int(tok, 16)
    return int(tok)


def parse_rapt_config(svh_path: Path, rv64: bool) -> dict:
    """Extract `define RAPT_<KEY> <int>` from a rapt_config.svh.

    Honors `ifdef RAPT_RV64` / `ifndef` blocks for the XLEN/MISA selection.
    Boolean knobs (RAPT_DUAL_ISSUE, RAPT_DUAL_COMMIT) are tracked as flags
    when defined without a value.
    """
    cfg: dict = {"RAPT_DUAL_ISSUE": False, "RAPT_DUAL_COMMIT": False}
    define_re = re.compile(r"^\s*`define\s+(RAPT_\w+)(?:\s+(.*?))?\s*$")
    cond_stack: list[bool] = [True]

    def cond_active() -> bool:
        return all(cond_stack)

    with svh_path.open() as f:
        for raw in f:
            line = raw.split("//", 1)[0]
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("`ifdef"):
                tok = stripped.split()[1]
                cond_stack.append(rv64 if tok == "RAPT_RV64" else True)
                continue
            if stripped.startswith("`ifndef"):
                tok = stripped.split()[1]
                cond_stack.append(not rv64 if tok == "RAPT_RV64" else True)
                continue
            if stripped.startswith("`else"):
                cond_stack[-1] = not cond_stack[-1]
                continue
            if stripped.startswith("`endif"):
                if len(cond_stack) > 1:
                    cond_stack.pop()
                continue
            if not cond_active():
                continue

            m = define_re.match(stripped)
            if not m:
                continue
            key, val = m.group(1), m.group(2)
            if val is None or val == "":
                cfg[key] = True
                continue
            try:
                cfg[key] = _parse_int(val.split()[0])
            except ValueError:
                cfg[key] = val.strip()
    return cfg


def derive_uarch(cfg: dict) -> dict:
    """Translate a parsed rapt_config dict into gem5 O3 parameters."""

    def cache_geom(line_len, sets_len, ways):
        line_bytes = 4 << int(line_len)
        sets = 1 << int(sets_len)
        size = line_bytes * sets * int(ways)
        return line_bytes, int(ways), size

    l1i_line, l1i_assoc, l1i_size = cache_geom(
        cfg["RAPT_L1I_LINE_LEN"], cfg["RAPT_L1I_LEN"], cfg["RAPT_L1I_N_WAYS"]
    )
    l1d_line, l1d_assoc, l1d_size = cache_geom(
        cfg["RAPT_L1D_LINE_LEN"], cfg["RAPT_L1D_LEN"], cfg["RAPT_L1D_N_WAYS"]
    )
    line_bytes = max(l1i_line, l1d_line)

    issue_w = 2 if cfg.get("RAPT_DUAL_ISSUE") else 1
    commit_w = 2 if cfg.get("RAPT_DUAL_COMMIT") else issue_w

    iq_entries = int(cfg["RAPT_RS_SIZE"]) + int(cfg["RAPT_IOQ_SIZE"])
    phys_int = int(cfg["RAPT_PHY_SIZE"])
    phys_fp = max(phys_int, 64)

    return dict(
        l1i_size=f"{l1i_size}B",
        l1i_assoc=l1i_assoc,
        l1d_size=f"{l1d_size}B",
        l1d_assoc=l1d_assoc,
        line_bytes=line_bytes,
        fetch_buffer_size=line_bytes,
        rob=int(cfg["RAPT_ROB_SIZE"]),
        iq=iq_entries,
        sq=int(cfg["RAPT_SQ_SIZE"]),
        lq=int(cfg["RAPT_SQ_SIZE"]),
        phys_int=phys_int,
        phys_fp=phys_fp,
        fetch_w=issue_w,
        decode_w=issue_w,
        rename_w=issue_w,
        dispatch_w=issue_w,
        issue_w=issue_w,
        wb_w=issue_w,
        commit_w=commit_w,
        squash_w=issue_w,
        btb_entries=int(cfg["RAPT_BTB_SIZE"]),
        btb_assoc=int(cfg["RAPT_BTB_WAYS"]),
        # Mirror rapt_bpu_btb.sv (BTB_TAG_LEN=7); JSON/SET can override.
        btb_tag_bits=7,
        pht_size=int(cfg["RAPT_PHT_SIZE"]),
        pht_ctr_bits=2,
        rsb_size=int(cfg["RAPT_RSB_SIZE"]),
        m_fast=bool(cfg.get("RAPT_M_FAST", 0)),
    )


DEFAULT_SIM_CFG: dict = {
    "clk_freq": "1GHz",
    "mem_size": "512MiB",
    "mem_latency": "30ns",
    "mshrs": 1,
    "bp": "local",
    "bp_params": {},
    "use_ras": True,
    "use_indirect": False,
    "indirect_sets": 256,
    "indirect_ways": 2,
    "indirect_tag_bits": 16,
    "indirect_path_length": 3,
    "indirect_ghr_bits": 13,
    "indirect_hash_ghr": True,
    "indirect_hash_targets": True,
    "storeset": False,
    "with_l2": False,
    "cpu": "o3",
    "rv64": False,
    "equalize_budget": True,
}


def _bool(v) -> bool:
    return bool(v) if isinstance(v, bool) else str(v).lower() in ("1", "true", "yes", "on")


_UARCH_TYPES: dict = {
    "l1i_assoc": int,
    "l1d_assoc": int,
    "line_bytes": int,
    "fetch_buffer_size": int,
    "rob": int,
    "iq": int,
    "sq": int,
    "lq": int,
    "phys_int": int,
    "phys_fp": int,
    "fetch_w": int,
    "decode_w": int,
    "rename_w": int,
    "dispatch_w": int,
    "issue_w": int,
    "wb_w": int,
    "commit_w": int,
    "squash_w": int,
    "btb_entries": int,
    "btb_assoc": int,
    "btb_tag_bits": int,
    "pht_size": int,
    "pht_ctr_bits": int,
    "rsb_size": int,
    "m_fast": _bool,
}

_SIM_TYPES: dict = {
    "mshrs": int,
    "use_ras": _bool,
    "use_indirect": _bool,
    "indirect_sets": int,
    "indirect_ways": int,
    "indirect_tag_bits": int,
    "indirect_path_length": int,
    "indirect_ghr_bits": int,
    "indirect_hash_ghr": _bool,
    "indirect_hash_targets": _bool,
    "storeset": _bool,
    "with_l2": _bool,
    "rv64": _bool,
    "bp_params": dict,
    "equalize_budget": _bool,
}

_CHAMPSIM_TOP_LEVEL: set[str] = {
    "_comment",
    "executable_name",
    "block_size",
    "page_size",
    "heartbeat_frequency",
    "num_cores",
    "ooo_cpu",
    "DIB",
    "L1I",
    "L1D",
    "L2C",
    "LLC",
    "ITLB",
    "DTLB",
    "STLB",
    "PTW",
    "BTB",
    "PHT",
    "RAS",
    "branch_predictor",
    "indirect_branch_predictor",
    "physical_memory",
    "virtual_memory",
    "simulation",
    "gem5",
    "uarch",
    "sim",
}

_BP_ALIASES: dict[str, str] = {
    "bimodal": "local",
    "bimodal-no-ras": "local",
    "2bit": "local",
    "2bit_local": "local",
    "bi_mode": "bimode",
    "bi-mode": "bimode",
    "tage-sc-l-8kb": "tage_sc_l_8kb",
    "tage-sc-l-64kb": "tage_sc_l_64kb",
    "mpp-8kb": "mpp_8kb",
    "mpp-64kb": "mpp_64kb",
    "mpp-tage-8kb": "mpp_tage_8kb",
    "mpp-tage-64kb": "mpp_tage_64kb",
    # Friendly family names → default gem5 variants.
    "perceptron": "mpp_8kb",
    "mpp": "mpp_8kb",
    "mpp_perceptron": "mpp_8kb",
    "multiperspective_perceptron": "mpp_8kb",
    "mpp_tage": "mpp_tage_8kb",
    "multiperspective_perceptron_tage": "mpp_tage_8kb",
    "tage_sc_l": "tage_sc_l_8kb",
}

SUPPORTED_BP_INPUTS: tuple[str, ...] = tuple(
    sorted(set(SUPPORTED_BP_KINDS).union(_BP_ALIASES.keys()))
)


def canonical_bp_name(name) -> str:
    raw = str(name).strip().lower()
    return _BP_ALIASES.get(raw, raw)


def _mhz_to_clock(freq) -> str:
    if isinstance(freq, str):
        return freq if any(ch.isalpha() for ch in freq) else f"{freq}MHz"
    return f"{freq}MHz"


def _first_cpu(ooo_cpu) -> dict:
    if ooo_cpu is None:
        return {}
    if isinstance(ooo_cpu, list):
        if len(ooo_cpu) > 1:
            _die("[raptor_se] only single-core ooo_cpu[0] configs are supported")
        return ooo_cpu[0] if ooo_cpu else {}
    if isinstance(ooo_cpu, dict):
        if "0" in ooo_cpu and isinstance(ooo_cpu["0"], dict):
            return ooo_cpu["0"]
        return ooo_cpu
    _die("[raptor_se] ooo_cpu must be an object or a one-element array")


def _cache_size(section: dict, line_bytes: int) -> str | None:
    if "size" in section:
        return section["size"]
    if "sets" in section and "ways" in section:
        return f"{int(section['sets']) * int(section['ways']) * int(line_bytes)}B"
    return None


def _put_if(dst: dict, dst_key: str, src: dict, src_key: str) -> None:
    if src_key in src:
        dst[dst_key] = src[src_key]


def _merge_dict(dst: dict, src: dict) -> dict:
    for key, val in src.items():
        if isinstance(val, dict) and isinstance(dst.get(key), dict):
            _merge_dict(dst[key], val)
        else:
            dst[key] = val
    return dst


def _normalize_bp_capacity(section: dict, out: dict) -> None:
    """Map ChampSim-like branch predictor capacity fields to raptor knobs."""
    if not isinstance(section, dict):
        if section is not None:
            out["sim"]["bp"] = canonical_bp_name(section)
        return

    for name_key in ("kind", "type", "name", "branch_predictor", "predictor"):
        if name_key in section:
            out["sim"]["bp"] = canonical_bp_name(section[name_key])
            break

    btb = section.get("btb") or section.get("BTB")
    if isinstance(btb, dict):
        _put_if(out["uarch"], "btb_entries", btb, "entries")
        _put_if(out["uarch"], "btb_assoc", btb, "ways")
        _put_if(out["uarch"], "btb_tag_bits", btb, "tag_bits")

    pht = section.get("pht") or section.get("PHT")
    if isinstance(pht, dict):
        _put_if(out["uarch"], "pht_size", pht, "entries")
        _put_if(out["uarch"], "pht_ctr_bits", pht, "counter_bits")

    ras = section.get("ras") or section.get("RAS")
    if isinstance(ras, dict):
        _put_if(out["uarch"], "rsb_size", ras, "entries")
        if "enabled" in ras:
            out["sim"]["use_ras"] = ras["enabled"]

    indirect = section.get("indirect") or section.get("indirect_branch_predictor")
    if isinstance(indirect, dict):
        if "enabled" in indirect:
            out["sim"]["use_indirect"] = indirect["enabled"]
        _put_if(out["sim"], "indirect_sets", indirect, "sets")
        _put_if(out["sim"], "indirect_ways", indirect, "ways")
        _put_if(out["sim"], "indirect_tag_bits", indirect, "tag_bits")
        _put_if(out["sim"], "indirect_path_length", indirect, "path_length")
        _put_if(out["sim"], "indirect_ghr_bits", indirect, "ghr_bits")
        _put_if(out["sim"], "indirect_hash_ghr", indirect, "hash_ghr")
        _put_if(out["sim"], "indirect_hash_targets", indirect, "hash_targets")

    bp_params = out["sim"].setdefault("bp_params", {})
    for key in (
        "tage",
        "ltage",
        "tage_sc_l",
        "tage_sc_l_8kb",
        "tage_sc_l_64kb",
        "mpp_tage",
        "mpp_tage_8kb",
        "mpp_tage_64kb",
        "loop",
        "statistical_corrector",
        "perceptron",
        "capacity",
    ):
        if isinstance(section.get(key), dict):
            _merge_dict(bp_params.setdefault(key, {}), section[key])
    if "budget_bits" in section:
        bp_params.setdefault("capacity", {})["budget_bits"] = section["budget_bits"]


def normalize_dse_config(data: dict) -> dict:
    """Normalize ChampSim-style JSON into `{uarch: {...}, sim: {...}}`.

    Accepted formats:
      1. Legacy normalized: {"uarch": {...}, "sim": {...}}
      2. ChampSim-style: top-level `ooo_cpu`, `L1I`, `L1D`, `BTB`, `PHT`,
         `RAS`, `physical_memory`, `simulation`, etc.

    Unsupported-but-common ChampSim sections (DIB, TLBs, PTW, LLC) are accepted
    and ignored so configs can stay visually close to ChampSim's schema.
    """
    unknown = sorted(k for k in data if k not in _CHAMPSIM_TOP_LEVEL)
    if unknown:
        _die(
            f"[raptor_se] unknown JSON section(s): {unknown}; "
            f"allowed: {sorted(_CHAMPSIM_TOP_LEVEL)}"
        )
    if int(data.get("num_cores", 1)) != 1:
        _die("[raptor_se] only num_cores=1 is supported")

    out: dict = {"uarch": {}, "sim": {}}
    if isinstance(data.get("uarch"), dict):
        out["uarch"].update(data["uarch"])
    if isinstance(data.get("sim"), dict):
        out["sim"].update(data["sim"])

    line_bytes = data.get("block_size", out["uarch"].get("line_bytes"))
    if line_bytes is not None:
        out["uarch"]["line_bytes"] = int(line_bytes)
        line_bytes = int(line_bytes)
    else:
        line_bytes = 16

    cpu = _first_cpu(data.get("ooo_cpu"))
    if cpu:
        _put_if(out["uarch"], "fetch_buffer_size", cpu, "ifetch_buffer_size")
        _put_if(out["uarch"], "phys_int", cpu, "register_file_size")
        if "register_file_size" in cpu and "phys_fp" not in out["uarch"]:
            out["uarch"]["phys_fp"] = max(int(cpu["register_file_size"]), 64)
        _put_if(out["uarch"], "rob", cpu, "rob_size")
        _put_if(out["uarch"], "lq", cpu, "lq_size")
        _put_if(out["uarch"], "sq", cpu, "sq_size")
        _put_if(out["uarch"], "fetch_w", cpu, "fetch_width")
        _put_if(out["uarch"], "decode_w", cpu, "decode_width")
        _put_if(out["uarch"], "rename_w", cpu, "rename_width")
        _put_if(out["uarch"], "dispatch_w", cpu, "dispatch_width")
        _put_if(out["uarch"], "issue_w", cpu, "execute_width")
        _put_if(out["uarch"], "wb_w", cpu, "writeback_width")
        _put_if(out["uarch"], "commit_w", cpu, "retire_width")
        _put_if(out["uarch"], "squash_w", cpu, "squash_width")
        _put_if(out["uarch"], "iq", cpu, "scheduler_size")
        _put_if(out["uarch"], "m_fast", cpu, "m_fast")
        if "frequency" in cpu:
            out["sim"]["clk_freq"] = _mhz_to_clock(cpu["frequency"])
        if "branch_predictor" in cpu:
            out["sim"]["bp"] = canonical_bp_name(cpu["branch_predictor"])

    for section_name, size_key, assoc_key in (
        ("L1I", "l1i_size", "l1i_assoc"),
        ("L1D", "l1d_size", "l1d_assoc"),
    ):
        section = data.get(section_name)
        if isinstance(section, dict):
            size = _cache_size(section, line_bytes)
            if size is not None:
                out["uarch"][size_key] = size
            if "ways" in section:
                out["uarch"][assoc_key] = section["ways"]

    l1_mshrs = [
        int(data[name]["mshr_size"])
        for name in ("L1I", "L1D")
        if isinstance(data.get(name), dict) and "mshr_size" in data[name]
    ]
    if l1_mshrs:
        out["sim"]["mshrs"] = max(l1_mshrs)

    btb = data.get("BTB")
    if isinstance(btb, dict):
        _put_if(out["uarch"], "btb_entries", btb, "entries")
        _put_if(out["uarch"], "btb_assoc", btb, "ways")
        _put_if(out["uarch"], "btb_tag_bits", btb, "tag_bits")

    pht = data.get("PHT")
    if isinstance(pht, dict):
        _put_if(out["uarch"], "pht_size", pht, "entries")
        _put_if(out["uarch"], "pht_ctr_bits", pht, "counter_bits")
        if "branch_predictor" in pht:
            out["sim"]["bp"] = canonical_bp_name(pht["branch_predictor"])

    ras = data.get("RAS")
    if isinstance(ras, dict):
        _put_if(out["uarch"], "rsb_size", ras, "entries")
        if "enabled" in ras:
            out["sim"]["use_ras"] = ras["enabled"]

    indirect = data.get("indirect_branch_predictor")
    if isinstance(indirect, dict):
        if "enabled" in indirect:
            out["sim"]["use_indirect"] = indirect["enabled"]
        _put_if(out["sim"], "indirect_sets", indirect, "sets")
        _put_if(out["sim"], "indirect_ways", indirect, "ways")
        _put_if(out["sim"], "indirect_tag_bits", indirect, "tag_bits")
        _put_if(out["sim"], "indirect_path_length", indirect, "path_length")
        _put_if(out["sim"], "indirect_ghr_bits", indirect, "ghr_bits")
        _put_if(out["sim"], "indirect_hash_ghr", indirect, "hash_ghr")
        _put_if(out["sim"], "indirect_hash_targets", indirect, "hash_targets")

    _normalize_bp_capacity(data.get("branch_predictor"), out)

    pmem = data.get("physical_memory")
    if isinstance(pmem, dict):
        _put_if(out["sim"], "mem_size", pmem, "size")
        _put_if(out["sim"], "mem_latency", pmem, "latency")

    for section_name in ("simulation", "gem5"):
        section = data.get(section_name)
        if isinstance(section, dict):
            for key in DEFAULT_SIM_CFG:
                if key in section:
                    out["sim"][key] = section[key]
            if "bp" in section:
                out["sim"]["bp"] = canonical_bp_name(section["bp"])
            if "branch_predictor" in section:
                out["sim"]["bp"] = canonical_bp_name(section["branch_predictor"])

    return out


def _coerce(section: str, key: str, val):
    table = _UARCH_TYPES if section == "uarch" else _SIM_TYPES
    fn = table.get(key)
    if fn is None:
        return val
    try:
        return fn(val)
    except (TypeError, ValueError) as e:
        _die(f"[raptor_se] bad value for {section}.{key}={val!r}: {e}")


def load_json_config(path: Path) -> dict:
    """Read and normalize a ChampSim-style JSON DSE file."""
    with path.open() as f:
        data = json.load(f)
    if not isinstance(data, dict):
        _die(f"[raptor_se] JSON root must be an object: {path}")
    return normalize_dse_config(data)


def apply_overrides(u: dict, sim: dict, overrides: dict) -> None:
    """Merge a normalized `{uarch: {...}, sim: {...}}` dict into u/sim in-place."""
    for key, val in overrides.get("uarch", {}).items():
        if key not in u:
            _die(
                f"[raptor_se] unknown uarch knob {key!r} "
                f"(valid: {sorted(u.keys())})"
            )
        u[key] = _coerce("uarch", key, val)
    for key, val in overrides.get("sim", {}).items():
        if key not in sim:
            _die(
                f"[raptor_se] unknown sim knob {key!r} "
                f"(valid: {sorted(sim.keys())})"
            )
        if key == "bp_params" and isinstance(val, dict):
            _merge_dict(sim.setdefault("bp_params", {}), val)
        else:
            sim[key] = _coerce("sim", key, val)


def parse_set_flags(set_args: list[str]) -> dict:
    """Convert repeated --set key.path=value into normalized overrides."""
    out: dict = {"uarch": {}, "sim": {}}
    champsim_raw: dict = {}

    def insert_dotted(root: dict, dotted: str, value) -> None:
        cur = root
        parts = [p for p in dotted.split(".") if p]
        for part in parts[:-1]:
            cur = cur.setdefault(part, {})
            if not isinstance(cur, dict):
                _die(f"[raptor_se] conflicting --set path {dotted!r}")
        cur[parts[-1]] = value

    for raw in set_args or []:
        if "=" not in raw:
            _die(f"[raptor_se] --set expects key.path=value, got {raw!r}")
        kpath, val = raw.split("=", 1)
        kpath = kpath.strip()
        val = val.strip()
        try:
            parsed = json.loads(val)
        except json.JSONDecodeError:
            parsed = val

        if "." not in kpath:
            out["uarch"][kpath] = parsed
            continue
        section, key = kpath.split(".", 1)
        if section in ("uarch", "sim"):
            if "." in key:
                insert_dotted(out[section], key, parsed)
            else:
                out[section][key] = parsed
        else:
            insert_dotted(champsim_raw, kpath, parsed)

    mapped = normalize_dse_config(champsim_raw) if champsim_raw else {"uarch": {}, "sim": {}}
    out["uarch"].update(mapped["uarch"])
    out["sim"].update(mapped["sim"])
    return out


def dump_effective_config(path: Path, u: dict, sim: dict, meta: dict) -> None:
    """Persist the merged config so a run can be reproduced via --json-config."""
    blob = {
        "_meta": meta,
        "uarch": copy.deepcopy(u),
        "sim": copy.deepcopy(sim),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(blob, f, indent=2, sort_keys=True)
    print(f"[raptor_se] effective config -> {path}")


# ----------------------------------------------------------------------------
# BP storage-budget equalization
# ----------------------------------------------------------------------------
# The default TAGE config in dse-config.json (mirroring rapt_bpu_tage.sv) uses
#   bimodal base : 256 entries x 2 bits           = 512  bits
#   tagged tbl T1: 128 entries x (tag7+ctr3+u1)   = 1408 bits
#   tagged tbl T2: 128 entries x (tag7+ctr3+u1)   = 1408 bits
#   tagged tbl T3: 128 entries x (tag8+ctr3+u1)   = 1536 bits
#   -----------------------------------------------------------
#   total directional storage                     = 4864 bits
# plus ~640 bits of history/metadata overhead -> the dse-config.json
# `branch_predictor.capacity.budget_bits = 5504` reference figure.
#
# When the user switches to another BP family (`local`, `gshare`, `bimode`,
# `tournament`, `ltage`, `perceptron`/`mpp_8kb`, `mpp_tage_8kb`), we resize
# its tables so the directional-predictor storage stays in the same order of
# magnitude. BTB / RAS / indirect predictor sizing is shared across all BPs
# (driven by `u[btb_*]`, `u[rsb_size]`, `sim[indirect_*]`) and is NOT touched
# here -- only the conditional-branch direction predictor is equalized.
#
# gem5 classes with fixed internal table geometry (`tage_sc_l_8kb`,
# `tage_sc_l_64kb`, `mpp_64kb`, `mpp_tage_64kb`) cannot be shrunk via Python
# params; we emit a notice for those. Use `--set sim.equalize_budget=false`
# (or set `bp_params.capacity.budget_bits=0`) to skip equalization entirely.
DEFAULT_BP_BUDGET_BITS: int = 5504


def _pow2_le(x: int, lo: int = 2) -> int:
    """Largest power of two <= x, clamped to >= lo (gem5 needs >= 2)."""
    x = max(int(x), lo)
    n = 1
    while n * 2 <= x:
        n *= 2
    return max(n, lo)


def equalize_bp_budget(u: dict, sim: dict, *, verbose: bool = True) -> None:
    """Size the selected BP family to ~`budget_bits` of directional storage.

    Default budget = `DEFAULT_BP_BUDGET_BITS` (matches the TAGE reference in
    dse-config.json). Override via `sim['bp_params']['capacity']['budget_bits']`
    or disable via `sim['equalize_budget'] = False`.

    Operates on a single key per family (typically `u['pht_size']`) so that
    later `--set uarch.pht_size=...` overrides remain effective if the user
    explicitly resizes after equalization (callers must re-apply overrides
    after equalize_bp_budget if that ordering is required).
    """
    if sim.get("equalize_budget", True) is False:
        return

    bp_params = sim.setdefault("bp_params", {})
    cap = bp_params.setdefault("capacity", {})
    budget_raw = cap.get("budget_bits", DEFAULT_BP_BUDGET_BITS)
    try:
        budget = int(budget_raw)
    except (TypeError, ValueError):
        return
    if budget <= 0:
        return  # 0 / negative => caller opts out

    bp = canonical_bp_name(sim.get("bp", "local"))
    ctr = max(1, int(u.get("pht_ctr_bits", 2)))

    def _note(msg: str) -> None:
        if verbose:
            print(f"[raptor_se] equalize_bp_budget({bp}, {budget} bits): {msg}")

    if bp == "local":
        # PC-indexed 2-bit table: budget = pht_size * ctr_bits.
        u["pht_size"] = _pow2_le(budget // ctr)
        _note(f"pht_size={u['pht_size']} (LocalBP {u['pht_size']*ctr} bits)")
    elif bp == "gshare":
        # GshareBP: single global table, PC ^ GHR indexed, 2-bit counters.
        u["pht_size"] = _pow2_le(budget // ctr)
        _note(f"pht_size={u['pht_size']} (GshareBP {u['pht_size']*ctr} bits)")
    elif bp == "bimode":
        # BiModeBP: taken-predictor + not-taken-predictor + choice predictor,
        # all of `pht_size` entries with `ctr` bits each => 3 * pht_size * ctr.
        u["pht_size"] = _pow2_le(budget // (3 * ctr))
        _note(
            f"pht_size={u['pht_size']} "
            f"(BiModeBP {3 * u['pht_size'] * ctr} bits)"
        )
    elif bp == "tournament":
        # TournamentBP: local-history-table + local-predictor + global-predictor
        # + choice-predictor (all ~pht_size, 2-bit) plus a small local-history
        # SRAM. Approximate total storage as 4 * pht_size * ctr.
        u["pht_size"] = _pow2_le(budget // (4 * ctr))
        _note(
            f"pht_size={u['pht_size']} "
            f"(TournamentBP ~{4 * u['pht_size'] * ctr} bits)"
        )
    elif bp == "tage":
        # Report-only: gem5 TAGE has many interlocked VectorParams
        # (nHistoryTables, logTagTableSizes, tagTableTagWidths, histLengths...)
        # that must be co-resized; partial overrides crash TAGEBase::init().
        # The dse-config.json defaults are already aligned to ~5.4Kbit.
        tage = bp_params.get("tage")
        if isinstance(tage, dict) and isinstance(tage.get("log_table_sizes"), list):
            log_sizes = tage["log_table_sizes"]
            tag_widths = tage.get("tag_table_tag_widths", [7] * len(log_sizes))
            ctr_bits = int(tage.get("counter_bits", 3))
            u_bits = int(tage.get("u_bits", 1))
            bimodal_bits = max(2, int(u.get("pht_size", 256))) * ctr
            tagged_bits = sum(
                (1 << int(log_sizes[i])) * (int(tag_widths[i]) + ctr_bits + u_bits)
                for i in range(min(len(log_sizes), len(tag_widths)))
            )
            _note(
                f"tage directional storage ~= {bimodal_bits + tagged_bits} bits "
                f"({bimodal_bits} base + {tagged_bits} tagged)"
            )
        else:
            _note("using gem5 TAGE defaults (no per-table override in bp_params)")
    elif bp == "ltage":
        # Report-only for the same reason as `tage`: do NOT poke individual
        # TAGEBase params here -- gem5 panics on partial vector mismatches.
        # The default gem5 LTAGE size is ~ same order as TAGE plus a small
        # loop predictor (<300 bits at log_size=3).
        _note(
            "using gem5 LTAGE defaults (TAGEBase vector params are interlocked; "
            "tune them together via JSON `branch_predictor.ltage.*` if needed)"
        )
    elif bp in ("mpp_8kb", "mpp_tage_8kb"):
        # Report-only: gem5 MultiperspectivePerceptron* classes ship with
        # cross-referenced VectorParams (tunedHistoryLengths, recipes for
        # imli_mask*, etc.) sized to the class-specified budget. Forcing
        # `budgetbits` here trips `ValueError: vector` during elaboration.
        _note(
            "MultiperspectivePerceptron* tables are coupled to the class's "
            "built-in budget (~8 Kbit for *_8KB, ~64 Kbit for *_64KB); "
            "comparable to TAGE only at the 8KB variant. "
            "Use bp_params.perceptron.* via JSON to retune coherently."
        )
    elif bp in ("tage_sc_l_8kb", "tage_sc_l_64kb", "mpp_64kb", "mpp_tage_64kb"):
        _note(
            f"gem5 {bp!r} has hard-coded ~8KB/64KB internal tables; "
            "cannot equalize to a smaller budget. "
            "Consider using `tage`/`ltage`/`mpp_8kb` for area-matched studies."
        )
    else:
        _note(f"no budget mapping for bp={bp!r}; leaving defaults")
