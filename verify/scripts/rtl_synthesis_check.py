#!/usr/bin/env python3
"""Check native RTL elaboration and rejection of invalid parameter contracts.

Use default frontend limits. No ignore-initial/ignore-assertions switches or
assertion removal passes are permitted by this gate. Mapping/STA is separate.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "verify/build/rtl-synthesis-check"


def flow_manifest():
    paths = [ROOT / 'lspd/syn/Makefile', ROOT / 'lspd/modules.mk',
             *sorted((ROOT / 'lspd/hdl_wrapper').glob('*.sv'))]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths}


def source_manifest(hdl_root):
    if not (hdl_root / "rapt_pkg.sv").is_file():
        raise ValueError(f"not a complete HDL tree: {hdl_root}")
    return {
        str(Path("hdl") / p.relative_to(hdl_root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(hdl_root.rglob("*"))
        if p.is_file() and p.suffix in (".sv", ".svh")
    }


def contract_rejected(returncode, log, top):
    # Match the diagnostic, not an echoed source line containing the message.
    diagnostic = rf"\berror: \$error encountered: Invalid {re.escape(top)} configuration(?::|\s|$)"
    return returncode > 0 and re.search(diagnostic, log) is not None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hdl-root", type=Path, default=ROOT / "hdl",
                        help="optional frozen HDL tree for a shared worktree")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT,
                        help="isolate evidence from other in-flight or historical checks")
    parser.add_argument("--only", choices=("stream", "checkpoint", "issue", "execution", "lsu", "integration"),
                        help="run only the selected group; report remains explicitly scoped")
    parser.add_argument("--check-structure", action="store_true",
                        help="also run opt and check -assert; not technology mapping or STA")
    args = parser.parse_args()
    hdl_root = args.hdl_root.resolve()
    OUT = args.output.resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    result = {"complete": False, "scope": args.only or "all", "cases": [],
              "hdl_root": str(hdl_root), "check_structure": args.check_structure}
    # Invalidate a previous successful report before starting a new run.
    (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    result["source_sha256"] = source_manifest(hdl_root)
    result["flow_sha256"] = flow_manifest()
    # Preserve the failing input revision even if the first elaboration fails.
    (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    jobs = [
        ("soc-default", "soc", "default", ""),
        ("soc-rv64", "soc", "default", "-DRAPT_RV64"),
        ("soc-assert-isolation", "soc", "default", "-DRAPT_ASSERT_EN"),
        ("core-default", "core", "default", ""),
        ("core-rv64", "core", "default", "-DRAPT_RV64"),
        ("core-scaled", "core", "default", "-DRAPT_DISPATCH_WIDTH=3 -DRAPT_INTEGER_ISSUE_PORTS=4 -DRAPT_INTEGER_SYSTEM_PORT=2"),
        ("core-scaled-rv64", "core", "default", "-DRAPT_RV64 -DRAPT_DISPATCH_WIDTH=3 -DRAPT_INTEGER_ISSUE_PORTS=4 -DRAPT_INTEGER_SYSTEM_PORT=2"),
        ("core-rvfi", "core", "default", "-DRAPT_RVFI"),
        ("core-rvfi-rv64", "core", "default", "-DRAPT_RVFI -DRAPT_RV64"),
        ("core-small", "core", "small", ""),
        ("core-middle", "core", "middle", ""),
        ("core-large", "core", "large", ""),
        ("core-dispatch4", "core", "default", "-DRAPT_DISPATCH_WIDTH=4"),
        ("rou-scan8", "rou", "default", "-DRAPT_STEER_SCAN_ENTRIES=8"),
        # A frontend stress configuration, not a proposed 32-write-port core.
        ("prf-completion32", "prf", "default", "-GNumCompletions=32"),
        ("stream-single", "stream_queue", "default", "-GDepth=1 -GInWidth=1 -GOutWidth=1"),
        ("stream-odd-wide", "stream_queue", "default", "-GDepth=7 -GInWidth=7 -GOutWidth=7"),
        ("stream-deep", "stream_queue", "default", "-GDepth=128 -GInWidth=8 -GOutWidth=8"),
        ("checkpoint-single", "rename_checkpoint", "default", "-GEntries=1 -GRenameWidth=1 -GResolvePorts=1"),
        ("checkpoint-odd", "rename_checkpoint", "default", "-GEntries=7 -GPhysRegs=96"),
        ("checkpoint-wide-tags", "rename_checkpoint", "default", "-GEntries=7 -GCheckpointBits=4 -GMapBits=8"),
        ("checkpoint-scaled", "rename_checkpoint", "default", "-GEntries=32 -GRenameWidth=8 -GResolvePorts=8"),
        ("issue-capacity64", "issue_select", "default", "-GEntries=64 -GPorts=4"),
        ("issue-capacity128", "issue_select", "default", "-GEntries=128 -GPorts=4"),
        ("ieu-default", "ieu", "default", ""),
        ("ieu-rv64", "ieu", "default", "-DRAPT_RV64"),
        ("ieu-scaled", "ieu", "default", "-DRAPT_RV64 -DRAPT_DISPATCH_WIDTH=3 -DRAPT_INTEGER_ISSUE_PORTS=4 -DRAPT_INTEGER_SYSTEM_PORT=2 -GNumCompletions=7 -GALQ_SIZE=7"),
        ("feu-default", "feu", "default", ""),
        ("feu-rv64", "feu", "default", "-DRAPT_RV64"),
        ("feu-scaled", "feu", "default", "-DRAPT_RV64 -DRAPT_DISPATCH_WIDTH=3 -GNumCompletions=7 -GFPQ_SIZE=7"),
        ("lsu-default", "lsu", "default", ""),
        ("lsu-rv64", "lsu", "default", "-DRAPT_RV64"),
        ("lsu-scaled", "lsu", "default", "-DRAPT_RV64 -DRAPT_DISPATCH_WIDTH=3 -GNumCompletions=7 -GIOQ_SIZE=16 -GSQ_SIZE=32"),
    ]
    for name, module, config, defines in jobs:
        if args.only == "integration":
            if name not in ("core-default", "core-rv64", "core-scaled", "core-scaled-rv64"):
                continue
        elif args.only and module not in {"stream": ("stream_queue",), "checkpoint": ("rename_checkpoint",), "issue": ("issue_select",), "execution": ("ieu", "feu"), "lsu": ("lsu",)}[args.only]:
            continue
        command = ["make", "-C", str(ROOT / "lspd/syn"),
                   "structure-check" if args.check_structure else "elaborate",
                   f"MODULE={module if module != 'soc' else 'core'}",
                   f"HDL_ROOT={hdl_root}",
                   f"RAPT_CONFIG={config}", "SRAM_MODE=macro",
                   f"EXTRA_DEFINES={defines}", f"BUILD_DIR={OUT / name}"]
        if module == "soc":
            command.append("TOP=rapt")
        with (OUT / f"{name}.log").open("w") as log:
            run = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        if run.returncode:
            raise RuntimeError(f"{name} failed: {OUT / name / 'elaborate.log'}")
        result["cases"].append({"name": name, "command": command, "elaborates": True,
                                "structure_checked": args.check_structure})
        (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(f"PASS: {name}", flush=True)

    # A legal configuration must contain no assertion cells; an illegal one
    # must fail before generating hardware, including without --assert in sim.
    for name, top, source, parameter in [
        ("rank-invalid", "rapt_rank_select", "hdl/common/rapt_rank_select.sv", "NumSelect=0"),
        ("issue-invalid", "rapt_issue_select", "hdl/common/rapt_issue_select.sv", "Ports=0"),
        ("stream-zero-depth", "rapt_stream_queue", "hdl/common/rapt_stream_queue.sv", "Depth=0"),
        ("stream-zero-input", "rapt_stream_queue", "hdl/common/rapt_stream_queue.sv", "InWidth=0"),
        ("stream-zero-output", "rapt_stream_queue", "hdl/common/rapt_stream_queue.sv", "OutWidth=0"),
        ("stream-input-too-wide", "rapt_stream_queue", "hdl/common/rapt_stream_queue.sv", "InWidth=9"),
        ("stream-output-too-wide", "rapt_stream_queue", "hdl/common/rapt_stream_queue.sv", "OutWidth=9"),
        ("checkpoint-no-entries", "rapt_rename_checkpoint", "hdl/frontend/rapt_rename_checkpoint.sv", "Entries=0"),
        ("checkpoint-no-map", "rapt_rename_checkpoint", "hdl/frontend/rapt_rename_checkpoint.sv", "MapEntries=0"),
        ("checkpoint-no-rename", "rapt_rename_checkpoint", "hdl/frontend/rapt_rename_checkpoint.sv", "RenameWidth=0"),
        ("checkpoint-no-resolve", "rapt_rename_checkpoint", "hdl/frontend/rapt_rename_checkpoint.sv", "ResolvePorts=0"),
        ("checkpoint-short-map", "rapt_rename_checkpoint", "hdl/frontend/rapt_rename_checkpoint.sv", "MapBits=6"),
        ("checkpoint-short-id", "rapt_rename_checkpoint", "hdl/frontend/rapt_rename_checkpoint.sv", "Entries=8 -GCheckpointBits=2"),
    ]:
        if args.only and top not in {"stream": ("rapt_stream_queue",), "checkpoint": ("rapt_rename_checkpoint",), "issue": ("rapt_issue_select",), "execution": (), "lsu": (), "integration": ()}[args.only]:
            continue
        dependencies = ""
        if top in ("rapt_stream_queue", "rapt_rename_checkpoint"):
            dependencies = (f"-DSYNTHESIS -I{hdl_root / 'configs/default'} "
                            f"-I{hdl_root / 'include'} {hdl_root / 'rapt_pkg.sv'} ")
        command = ["yosys", "-Q", "-T", "-m", "slang", "-p",
                   f"read_slang --top {top} -G{parameter} {dependencies}"
                   f"{hdl_root / Path(source).relative_to('hdl')}"]
        run = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, timeout=30)
        (OUT / f"{name}.log").write_text(run.stdout)
        if not contract_rejected(run.returncode, run.stdout, top):
            raise RuntimeError(f"{name}: invalid configuration was not rejected by its contract")
        result["cases"].append({"name": name, "command": command, "rejected": True})
        print(f"PASS: {name} rejected", flush=True)
    if source_manifest(hdl_root) != result["source_sha256"]:
        raise RuntimeError("HDL file set or contents changed during elaboration matrix")
    if flow_manifest() != result["flow_sha256"]:
        raise RuntimeError("synthesis flow or wrappers changed during elaboration matrix")
    result["complete"] = True
    (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
