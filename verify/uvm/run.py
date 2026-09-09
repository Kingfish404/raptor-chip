#!/usr/bin/env python3
"""Reproducible whole-chip UVM build/regression, independent of sim/.config."""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CASES = ("smoke", "pipeline", "memory", "traps", "supervisor", "pmp", "mmu",
         "ifetch_mmu", "fp", "irq", "debug", "external", "faults", "reset")
RNP_CASES = tuple(c for c in CASES if c not in ("irq", "debug", "external", "faults"))
MUTATIONS = {"rid": "R", "rlast": "RLAST", "rdata": "RDATA", "wlast": "WLAST"}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_logged(command: list[str], log: Path, timeout: int) -> int:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as out:
        out.write("COMMAND " + json.dumps(command) + "\n")
        out.flush()
        try:
            with subprocess.Popen(command, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT,
                                  start_new_session=True) as process:
                try:
                    return process.wait(timeout=timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt):
                    # Reap compiler/simulator children too, so a timed-out build
                    # cannot continue modifying the next run's output directory.
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    raise
        except subprocess.TimeoutExpired:
            out.write("\nHOST_TIMEOUT\n")
            return 124


def successful(code: int, text: str) -> bool:
    return (code == 0 and bool(re.search(r"UVM_INFO .*\[CHIP_PASS\] all chip checks passed", text))
            and not re.search(r"^UVM_(?:ERROR|FATAL)\s+(?!:)\S", text, re.M)
            and not re.search(r"^UVM_(?:ERROR|FATAL)\s*:\s*[1-9]", text, re.M)
            and "HOST_TIMEOUT" not in text and "%Error" not in text)


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise RuntimeError(f"required tool not found: {name}")
    return path


def version(command: str) -> str:
    return subprocess.check_output([command, "--version"], text=True).splitlines()[0]


@contextlib.contextmanager
def exclusive(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError(f"another run owns {directory}") from exc
        yield


def build(args, directory: Path, preset: str, xlen: int, top: str) -> tuple[Path, dict]:
    uvm = Path(args.uvm_home).expanduser().resolve()
    if not (uvm / "src/uvm_pkg.sv").is_file():
        raise RuntimeError("set UVM_HOME or --uvm-home to Accellera UVM sources (src/uvm_pkg.sv)")
    verilator = require_tool(args.verilator)
    gcc = require_tool(args.cross_compile + "gcc")
    objcopy = require_tool(args.cross_compile + "objcopy")
    hdl = ROOT / "hdl"
    if not (hdl / "configs" / preset / "rapt_config.svh").is_file():
        raise RuntimeError(f"unknown preset {preset}")
    top_name = "tb_rapt_chip" if top == "axi" else "tb_rapt_chip_rnp"
    rtl = [hdl / "rapt_pkg.sv"] + sorted(p for p in hdl.rglob("*.sv") if p.name != "rapt_pkg.sv")
    if top == "rnp":
        if xlen != 32 or re.search(r"^`define\s+RAPT_L2_EN\b", (hdl / "configs" / preset / "rapt_config.svh").read_text(), re.M):
            # The wrapper has one 32-bit word per transfer and cannot carry L2 bursts.
            raise RuntimeError("RNP requires RV32 and a preset without RAPT_L2_EN")
        rtl.append(ROOT / "sim/rtl/wrap_rnp_soc.sv")
    bench = [HERE / "chip/rapt_chip_if.sv", HERE / "chip/rapt_chip_pkg.sv",
             HERE / f"chip/{top_name}.sv"]
    includes = [hdl / "configs" / preset, hdl / "include", hdl / "include/npc",
                hdl / "include/dpic_mock", HERE / "chip", uvm / "src"]
    command = [verilator, "--binary", "--timing", "--assert", "-j", str(args.jobs),
               "--top-module", top_name, "-Wno-fatal", "-Wno-TIMESCALEMOD",
               "+define+UVM_NO_DPI", "+define+RAPT_ASSERT_EN"]
    if xlen == 64:
        command += ["+define+RAPT_RV64"]
    command += ["-I" + str(p) for p in includes]
    command += [str(uvm / "src/uvm_pkg.sv")] + [str(p) for p in rtl + bench]
    command += ["--Mdir", str(directory / "obj")]
    sources = sorted(set(rtl + bench + list(hdl.rglob("*.svh")) +
                         list((HERE / "chip").glob("*.svh")) +
                         list((uvm / "src").rglob("*.sv")) + list((uvm / "src").rglob("*.svh"))))
    inputs = {str(p): sha(p) for p in sources}
    metadata = {"preset": preset, "xlen": xlen, "top": top, "inputs": inputs,
                "command": command, "verilator": version(verilator), "gcc": version(gcc),
                "uvm_home": str(uvm), "objcopy": objcopy}
    digest = hashlib.sha256(json.dumps(metadata, sort_keys=True).encode()).hexdigest()
    metadata["digest"] = digest
    manifest = directory / "build.json"
    binary = directory / "obj" / ("V" + top_name)
    cached = manifest.exists() and binary.exists() and json.loads(manifest.read_text()).get("digest") == digest
    if not cached:
        if args.no_build:
            raise RuntimeError(f"no current build for {directory}; remove --no-build")
        print(f"BUILD {preset} rv{xlen} {top} (log: {directory / 'build.log'})", flush=True)
        code = run_logged(command, directory / "build.log", args.build_timeout)
        if code != 0 or not binary.is_file():
            raise RuntimeError(f"build failed ({code}): {directory / 'build.log'}")
        metadata["binary_sha256"] = sha(binary)
        manifest.write_text(json.dumps(metadata, indent=2) + "\n")
    else:
        metadata = json.loads(manifest.read_text())
        if sha(binary) != metadata["binary_sha256"]:
            raise RuntimeError(f"binary hash differs from build manifest: {binary}")
    return binary, metadata


def firmware(args, directory: Path, xlen: int, case: str) -> tuple[Path, dict]:
    source = HERE / ("chip/firmware.S" if case in ("smoke", "reset") else f"chip/firmware/{case}.S")
    elf = directory / "firmware" / f"{case}.elf"
    image = elf.with_suffix(".bin")
    command = [require_tool(args.cross_compile + "gcc"), f"-march=rv{xlen}imafdc_zicsr_zifencei_zfhmin",
               "-mabi=" + ("lp64" if xlen == 64 else "ilp32"), "-nostdlib", "-nostartfiles",
               "-Wl,--no-relax", "-T", str(HERE / "chip/link.ld"), str(source), "-o", str(elf)]
    code = run_logged(command, elf.with_suffix(".log"), 60)
    if code != 0:
        raise RuntimeError(f"firmware compilation failed: {elf.with_suffix('.log')}")
    subprocess.run([require_tool(args.cross_compile + "objcopy"), "-O", "binary", str(elf), str(image)], check=True)
    return image, {"command": command, "sha256": sha(image), "source_sha256": sha(source),
                   "common_sha256": sha(HERE / "chip/firmware/common.h"),
                   "link_sha256": sha(HERE / "chip/link.ld")}


def run_config(args, preset: str, xlen: int, top: str) -> dict:
    directory = Path(args.output).resolve() / f"chip-{preset}-rv{xlen}-{top}"
    allowed = CASES if top == "axi" else RNP_CASES
    selected = allowed if args.cases == ["all"] else tuple(args.cases)
    if any(c not in allowed for c in selected):
        raise RuntimeError(f"unsupported case for {top}: {selected}; supported: {allowed}")
    result = {"preset": preset, "xlen": xlen, "top": top, "runs": []}
    with exclusive(directory):
        binary, metadata = build(args, directory, preset, xlen, top)
        result["build_digest"] = metadata["digest"]
        result["verilator"] = metadata["verilator"]
        if args.build_only:
            return result
        for case in selected:
            changed = [path for path, digest in metadata["inputs"].items() if sha(Path(path)) != digest]
            if changed:
                raise RuntimeError(f"sources changed during regression: {changed}")
            image, fw_meta = firmware(args, directory, xlen, case)
            for seed in args.seeds:
                for delay in args.delays:
                    command = [str(binary), f"+IMG={image}", f"+CASE={case}", f"+SEED={seed}",
                               f"+MAX_DELAY={delay}", f"+MAX_CYCLES={args.max_cycles}", "+UVM_NO_RELNOTES"]
                    log = directory / "runs" / f"{case}-seed{seed}-delay{delay}.log"
                    start = time.monotonic()
                    code = run_logged(command, log, args.timeout)
                    text = log.read_text(errors="replace")
                    passed = successful(code, text)
                    coverage = re.findall(r"\[CHIP_COVERAGE\] ([^\n]+)", text)
                    entry = {"case": case, "seed": seed, "delay": delay, "passed": passed,
                             "returncode": code, "elapsed": time.monotonic() - start,
                             "log": str(log), "command": command, "firmware": fw_meta, "coverage": coverage}
                    result["runs"].append(entry)
                    (directory / "results.json").write_text(json.dumps(result, indent=2) + "\n")
                    print(f"{'PASS' if passed else 'FAIL'} {preset}/rv{xlen}/{top} {case} seed={seed} delay={delay}", flush=True)
                    if not passed:
                        print("\n".join(line for line in text.splitlines() if "UVM_ERROR" in line or "UVM_FATAL" in line or "FIRMWARE_DIAG" in line), flush=True)
                        if not args.keep_going:
                            raise RuntimeError(f"scenario failed: {log}")
        if args.negative:
            image, fw_meta = firmware(args, directory, xlen, "smoke")
            for mutation, expected_id in MUTATIONS.items():
                command = [str(binary), f"+IMG={image}", "+CASE=smoke", f"+MUTATE={mutation}",
                           "+SEED=1", "+MAX_DELAY=7", "+MAX_CYCLES=100000", "+UVM_NO_RELNOTES"]
                log = directory / "runs" / f"negative-{mutation}.log"
                code = run_logged(command, log, args.timeout)
                text = log.read_text(errors="replace")
                detected = bool(re.search(r"UVM_ERROR .*\[" + re.escape(expected_id) + r"\]", text))
                passed = detected and not successful(code, text) and "[CHIP_PASS]" not in text
                result["runs"].append({"case": f"negative-{mutation}", "passed": passed,
                                       "expected_error": expected_id, "log": str(log), "returncode": code,
                                       "command": command, "firmware": fw_meta})
                print(f"{'PASS' if passed else 'FAIL'} checker sensitivity {mutation}", flush=True)
        changed = [path for path, digest in metadata["inputs"].items() if sha(Path(path)) != digest]
        if changed:
            raise RuntimeError(f"sources changed during regression: {changed}")
        (directory / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uvm-home", default=os.environ.get("UVM_HOME", ""))
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--cross-compile", default=os.environ.get("CROSS_COMPILE", "riscv64-elf-"))
    parser.add_argument("--preset", default="default")
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=32)
    parser.add_argument("--top", choices=("axi", "rnp"), default="axi")
    parser.add_argument("--matrix", action="store_true", help="default RV32/RV64, small RV32, large RV64, RNP RV32")
    parser.add_argument("--cases", nargs="+", default=["all"], choices=("all",) + CASES)
    parser.add_argument("--seeds", nargs="+", type=int, default=[1, 42])
    parser.add_argument("--delays", nargs="+", type=int, default=[0, 7, 31])
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--build-timeout", type=int, default=1200)
    parser.add_argument("--max-cycles", type=int, default=1000000)
    parser.add_argument("--negative", action="store_true")
    parser.add_argument("--keep-going", action="store_true", help="continue other cases after a failed simulation")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--output", default=str(ROOT / "verify/build/uvm"))
    args = parser.parse_args()
    if any(n < 0 or n > 10000 for n in args.delays) or any(n < 1 or n > 0xffffffff for n in args.seeds):
        parser.error("delays must be 0..10000 and seeds 1..2^32-1")
    if min(args.jobs, args.timeout, args.build_timeout, args.max_cycles) < 1:
        parser.error("job counts and timeouts must be positive")
    matrix = [("default",32,"axi"),("default",64,"axi"),("small",32,"axi"),
              ("large",64,"axi"),("default",32,"rnp")] if args.matrix else [(args.preset,args.xlen,args.top)]
    report = {"runner_sha256": sha(Path(__file__)), "build_only": args.build_only, "git_head": subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
              "git_status": subprocess.check_output(["git","status","--short"],cwd=ROOT,text=True),
              "configurations": []}
    try:
        for config in matrix:
            report["configurations"].append(run_config(args,*config))
    except (RuntimeError, subprocess.SubprocessError, OSError) as exc:
        report["error"] = str(exc)
        print(f"ERROR: {exc}",file=sys.stderr)
    report["passed"] = "error" not in report and all(r["passed"] for c in report["configurations"] for r in c["runs"])
    name = "regression.json" if args.matrix else f"regression-{args.preset}-rv{args.xlen}-{args.top}.json"
    output = Path(args.output).resolve() / name
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(report,indent=2) + "\n")
    print(f"Report: {output}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
