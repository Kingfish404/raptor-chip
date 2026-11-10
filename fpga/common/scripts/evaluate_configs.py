#!/usr/bin/env python3
"""Synthesize unmodified presets as OOC clusters; archive evidence outside the checkout.

These results measure CPU resources, not board overhead, routed timing or hardware boot.
"""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import time

from rtl_pack import pack
from vivado_reports_index import parse_timing, parse_utilization

REPO = Path(__file__).resolve().parents[3]
PARTS = {"arty": "xc7a100tcsg324-1", "rk": "xcku5p-ffvb676-2-i",
         "cu08": "xcku15p-ffva1156-2-e"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def source_identity():
    files = [Path(__file__), Path(__file__).with_name("rtl_pack.py")]
    for name in ("rtl", "sim/rtl", "sim/include"):
        files += [p for p in (REPO / name).rglob("*")
                  if p.is_file() and p.suffix in (".sv", ".svh", ".v", ".vh")]
    return {str(p.relative_to(REPO)): digest(p) for p in sorted(files)}


def evaluate(args, board, preset, bits, environment):
    out = args.output / board / preset / f"rv{bits}"
    out.mkdir(parents=True, exist_ok=True)
    ram_bytes = 0x10000000 if board == "arty" else 0x80000000
    flags = ("-DRAPT_LINUX -DRAPT_FPGA_DSP=1 -DRAPT_FPGA_LUTRAM=1 "
             "-DRAPT_CORE_CLOCK_MHZ=50 -DRAPT_MTIME_FREQ_MHZ=50 "
             f"-DRAPT_PMEM_BYTES={ram_bytes}")
    if preset == "default-w4":
        flags += " -DRAPT_FETCH_RESPONSE_STAGE=1"
    if bits == 64:
        flags += " -DRAPT_RV64"
    record = {"board": board, "part": PARTS[board], "preset": preset, "xlen": bits,
              "flags": flags, "scope": "rapt OOC synthesis; no board peripherals",
              "period_ns": args.period, "directive": args.directive,
              "timing_driven": False, "environment": environment}
    identity = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    result_path = out / "result.json"
    if result_path.exists():
        previous = json.loads(result_path.read_text())
        if previous.get("identity") != identity:
            raise RuntimeError(f"Inputs changed; choose a fresh output directory: {out}")
        for name, expected in previous.get("artifacts", {}).items():
            if digest(out / name) != expected:
                raise RuntimeError(f"Archived artifact changed: {out / name}")
        return previous
    record["identity"] = identity
    save(out / "inputs.json", record)
    header = (REPO / "rtl/configs" / preset / "rapt_config.svh").read_text()
    if bits == 64 and "is RV32 only:" in header:
        record["status"] = "unsupported XLEN (preset is RV32 only)"
        save(result_path, record)
        return record
    packed = pack(REPO, args.output / "pack", preset, flags, immutable=True)
    shutil.copyfile(packed, out / "rapt_pack.sv")
    shutil.copyfile(packed.with_suffix(".svh"), out / "rapt_pack.svh")
    tcl = f"""set_param general.maxThreads {args.threads}
read_verilog -sv rapt_pack.sv
synth_design -top rapt -mode out_of_context -part {PARTS[board]} \\
    -directive {args.directive} -no_timing_driven
create_clock -name cpu -period {args.period} [get_ports clock]
report_utilization -file utilization.rpt
report_utilization -hierarchical -file hierarchy.rpt
report_timing_summary -file timing.rpt
write_checkpoint -force synthesized.dcp
exit
"""
    (out / "synth.tcl").write_text(tcl)
    start = time.time()
    with (out / "console.log").open("w") as log:
        process = subprocess.Popen([args.vivado, "-mode", "batch", "-source", "synth.tcl",
                                    "-nojournal", "-nolog"], cwd=out,
                                   stdout=log, stderr=subprocess.STDOUT)
        save(out / "process.json", {"pid": process.pid, "started": start})
        status = process.wait()
    record.update(returncode=status, seconds=round(time.time() - start, 2))
    report = out / "utilization.rpt"
    if status == 0 and report.exists() and (out / "synthesized.dcp").exists():
        record["status"] = "synthesis passed"
        record["resources"] = parse_utilization(report.read_text())
        record["timing"] = parse_timing((out / "timing.rpt").read_text())
        record["capacity_exceeded"] = [
            label for label, data in record["resources"].items()
            if float(data["used"].replace(",", "")) >
            float(data["available"].replace(",", ""))]
    else:
        record["status"] = "synthesis failed"
    record["artifacts"] = {p.name: digest(p) for p in out.iterdir()
                           if p.suffix in (".tcl", ".sv", ".svh", ".rpt", ".dcp", ".log")}
    save(result_path, record)
    print(f"{board} {preset} RV{bits}: {record['status']} ({record['seconds']} s)", flush=True)
    return record


def write_summary(output, results):
    rows = ["# Preset OOC synthesis", "",
            "Scope: cluster only, FPGA DSP/LUTRAM enabled, 50 MHz mtime, no board peripherals.",
            "Synthesis fit does not establish board fit, routing closure or Linux boot.", "",
            "| Board | Preset | XLEN | Status | LUTs | FFs | BRAM36 | DSP | Capacity |",
            "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | --- |"]
    for r in sorted(results, key=lambda item: (item["preset"], item["xlen"], item["board"])):
        resources = r.get("resources", {})
        def value(*labels):
            for label in labels:
                if label in resources:
                    return resources[label]["used"]
            return "—"
        exceeded = r.get("capacity_exceeded", [])
        capacity = ", ".join(exceeded) + " exceeded" if exceeded else "CPU only fits"
        if "resources" not in r:
            capacity = "—"
        rows.append(f"| {r['board']} | {r['preset']} | {r['xlen']} | {r['status']} | "
                    f"{value('CLB LUTs', 'Slice LUTs')} | "
                    f"{value('CLB Registers', 'Slice Registers')} | "
                    f"{value('Block RAM Tile')} | {value('DSPs')} | {capacity} |")
    (output / "summary.md").write_text("\n".join(rows) + "\n")
    save(output / "summary.json", results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--boards", nargs="+", choices=tuple(PARTS), default=["arty", "rk", "cu08"])
    presets = sorted(p.parent.name for p in (REPO / "rtl/configs").glob("*/rapt_config.svh"))
    parser.add_argument("--presets", nargs="+", choices=presets, default=presets)
    parser.add_argument("--xlen", nargs="+", type=int, choices=(32, 64), default=[32, 64])
    parser.add_argument("--parallel", type=int, choices=range(1, 9), default=2)
    parser.add_argument("--threads", type=int, choices=range(1, 33), default=4)
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--period", type=float, default=20.0)
    parser.add_argument("--directive", choices=("default", "RuntimeOptimized", "AreaOptimized_high"),
                        default="RuntimeOptimized")
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.is_relative_to(REPO):
        parser.error("Archive FPGA results outside the source checkout")
    if args.period <= 0:
        parser.error("Clock period must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    lock = (args.output / ".evaluation.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("Another evaluator owns this output directory")
    environment = {"revision": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "inputs": source_identity(), "tool_version": subprocess.check_output(
            [args.vivado, "-version"], text=True), "host": platform.platform(),
        "python": platform.python_version(), "cpu_count": os.cpu_count()}
    save(args.output / "environment.json", environment)
    # Small and one-wide presets establish mapping before the wide experiments.
    priority = ["small", "chip32-small", "formal", "small-cache", "middle", "chip32-dff"]
    ordered = [p for p in priority if p in args.presets]
    ordered += [p for p in args.presets if p not in ordered]
    jobs = [(b, p, x) for p in ordered for x in args.xlen for b in args.boards]
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as executor:
        futures = [executor.submit(evaluate, args, *job, environment) for job in jobs]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
            write_summary(args.output, results)


if __name__ == "__main__":
    main()
