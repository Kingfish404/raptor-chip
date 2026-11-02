#!/usr/bin/env python3
"""Replay fingerprinted architectural checkpoints on a routed KU15P sampling build.

One persistent JTAG session shares a verified sparse RAM base across cases.
Before every replay, restore the pages that differ between checkpoints plus
DDR pages written by the CPU. CPU caches and translation/predictor state reset.
"""
from __future__ import annotations

import argparse
import base64
from contextlib import closing
import copy
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import threading
import time

from fpga_image import (PAGE, SRAM, SparseRam, dirty_pages, read_state, restore_image,
                        segment_digest, write_segments)
from pc_reference import ALGORITHM, PcReference
from run_model import validate_full_plan
from run_samples import load_capture, matched_window
from simpoints import digest, summarize, write_json

HERE = Path(__file__).resolve().parent
CONTROL = 0x1F000000


class Jtag:
    def __init__(self, args):
        self.transfer_timeout = args.transfer_timeout
        self.log = (args.output / "jtag.log").open("w")
        self.process = subprocess.Popen(
            [args.vivado, "-mode", "batch", "-source", str(HERE / "fpga_jtag.tcl"),
             "-tclargs", args.hw_target, args.part], cwd=args.output,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, start_new_session=True)
        self.queue = queue.Queue()
        self.identifier = 0
        self.thread = threading.Thread(target=self.receive, daemon=True)
        self.thread.start()
        try:
            self.await_reply(None, 180)
        except BaseException:
            self.close(force=True)
            raise

    def receive(self):
        try:
            for line in self.process.stdout:
                self.log.write(line)
                self.log.flush()
                if line.startswith("RPT_"):
                    self.queue.put(line.strip())
        finally:
            self.queue.put("EOF")

    def await_reply(self, identifier, timeout):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("JTAG command exceeded its deadline; see jtag.log")
            try:
                line = self.queue.get(timeout=min(remaining, 0.5))
            except queue.Empty:
                continue
            if line == "EOF":
                raise ValueError("Vivado exited before replying; see jtag.log")
            if identifier is None and line == "RPT_READY":
                return ""
            fields = line.split(" ", 3)
            if len(fields) < 3 or fields[:2] != ["RPT_REPLY", str(identifier)]:
                raise ValueError("JTAG protocol reply is out of order")
            result = base64.b64decode(fields[3] if len(fields) == 4 else "").decode()
            if fields[2] != "0":
                raise ValueError(f"JTAG transaction failed: {result}")
            return result

    def call(self, command, timeout=30):
        self.identifier += 1
        self.process.stdin.write(f"{self.identifier} {command}\n")
        self.process.stdin.flush()
        return self.await_reply(self.identifier, timeout)

    def read(self, address, words=1):
        return [int(word, 16) for word in self.call(f"R {address:x} {words}").split(",")]

    def write(self, address, value):
        self.call(f"W {address:x} {value:016x}")

    def wait(self, offset, predicate, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = self.read(CONTROL + offset)[0]
            if predicate(value):
                return value
            time.sleep(0.01)
        raise TimeoutError(f"Hardware status {offset:x} exceeded deadline")

    def hold(self):
        self.write(CONTROL + 8, 3)
        self.wait(8, lambda status: bool(status & 2), 30)

    def transfer(self, descriptor, dump=None, timeout=None):
        def encoded(path):
            return base64.b64encode(str(path.resolve()).encode()).decode()
        if timeout is None:
            timeout = self.transfer_timeout
        if dump is None:
            return int(self.call(f"UPLOAD {encoded(descriptor)}", timeout))
        return int(self.call(f"DUMP {encoded(descriptor)} {encoded(dump)}", timeout))

    def close(self, force=False):
        try:
            if force:
                raise TimeoutError("close during initialization")
            if self.process.poll() is None:
                self.call("QUIT", 10)
                self.process.wait(timeout=10)
        except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait()
        self.thread.join(timeout=5)
        self.log.close()


def check_build(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    result = json.loads((directory / "result.json").read_text())
    if (result.get("timing_pass") is not True or result["identity"] != manifest["sha256"] or
            not manifest["configuration"].get("sampling") or
            manifest["configuration"]["xlen"] != 64 or
            manifest["configuration"].get("memory") != "ddr"):
        raise ValueError("a fingerprinted, routed RV64 DDR sampling build is required")
    for name, expected in result["artifacts"].items():
        if digest(directory / name) != expected:
            raise ValueError(f"routed build artifact changed: {name}")
    return manifest, result


def config_words(state, point, mret_pc, cycle_limit, domain=None):
    domain = domain or {"mode": "all"}
    return {0x10: point["warmup"], 0x18: point["instructions"], 0x20: state["pc"],
            0x28: mret_pc, 0x30: state["csr_mepc"], 0x38: state["csr_mcycle"],
            0x40: state["csr_minstret"], 0x48: state["clint_mtime"],
            0x50: state["clint_mtimecmp"], 0x58: state["clint_msip"],
            0x60: cycle_limit, 0x98: state["csr_mstatus"],
            0xC8: int(domain["mode"] == "user"), 0xD0: int(domain.get("satp_root", "0"), 0),
            0xD8: int("thread_pointer" in domain), 0xE0: int(domain.get("thread_pointer", "0"), 0)}


def upload_verified(jtag, root, label, segments):
    descriptor, dumped = root / (label + ".segments"), root / (label + ".readback")
    write_segments(descriptor, segments)
    expected = segment_digest(segments)
    started = time.monotonic()
    written = jtag.transfer(descriptor)
    read = jtag.transfer(descriptor, dumped)
    if read != written or read != sum(segment[2] for segment in segments) or digest(dumped) != expected:
        raise ValueError("JTAG RAM readback checksum differs from the checkpoint")
    result = {"bytes": written, "sha256": expected,
              "wall_seconds": time.monotonic() - started,
              "descriptor_sha256": digest(descriptor), "readback_verified": True}
    dumped.unlink()
    return result


def observations(jtag, point, domain, timeout=300):
    status = jtag.wait(8, lambda value: bool(value & 12), timeout)
    error = jtag.read(CONTROL + 0x90)[0]
    if error or status & 8 or not status & 16:
        raise ValueError(f"FPGA replay failed: status={status:x}, error={error}")
    rows = jtag.read(CONTROL + 0x78)[0]
    if not 2 <= rows <= 131:
        raise ValueError("hardware reported an invalid boundary row count")
    raw = []
    for offset in range(0, rows * 4, 256):
        # AXI bursts cannot cross 4 KiB boundaries, even for control reads.
        count = min(rows * 4 - offset, 256, (4096 - ((offset * 8) & 4095)) // 8)
        raw += jtag.read(CONTROL + 0x1000 + offset * 8, count)
    actual_domain = {"mode": "user" if jtag.read(CONTROL + 0xC8)[0] else "all",
                     "satp_root": hex(jtag.read(CONTROL + 0xD0)[0]),
                     "include_kernel_cycles": True}
    if jtag.read(CONTROL + 0xD8)[0]:
        actual_domain["thread_pointer"] = hex(jtag.read(CONTROL + 0xE0)[0])
    if actual_domain["mode"] != domain["mode"] or (domain["mode"] == "user" and
            int(actual_domain["satp_root"], 0) != int(domain["satp_root"], 0)) or (
            "thread_pointer" in domain and
            int(actual_domain.get("thread_pointer", "0"), 0) != int(domain["thread_pointer"], 0)):
        raise ValueError("hardware used a different retirement domain")
    return {"schema": "raptor-window-v1", "complete": True,
            "warmup": jtag.read(CONTROL + 0x10)[0],
            "instructions": jtag.read(CONTROL + 0x18)[0],
            "start_pc": hex(jtag.read(CONTROL + 0xC0)[0]),
            "retirement_domain": actual_domain,
            "signature_algorithm": ALGORITHM,
            "boundaries": [{"instructions": raw[i], "cycle": raw[i + 1],
                            "last_pc": hex(raw[i + 2]), "signature": f"{raw[i + 3]:016x}"}
                           for i in range(0, len(raw), 4)]}


def failure_snapshot(jtag):
    """Read the failed controller before cleanup changes its state.

    These diagnostics never constitute an accepted measurement or authorize reset.
    Stop at the first transport error so a broken JTAG link cannot multiply timeouts.
    """
    snapshot = {}
    registers = {"status": 0x08, "elapsed_cycles": 0x68, "retired": 0x70,
                 "boundary_rows": 0x78, "error_code": 0x90,
                 "drain_cycles": 0xE8, "drain_ready": 0xF0}
    for name, offset in registers.items():
        try:
            snapshot[name] = jtag.read(CONTROL + offset)[0]
        except (OSError, ValueError, TimeoutError) as error:
            snapshot["read_error"] = str(error)
            break
    return snapshot


def prepare_transitions(cases, repetitions, initial):
    """Cache exact page differences for the scheduled checkpoint transitions."""
    previous, pairs = initial, set()
    for _case, _plan, points, checkpoints in cases:
        for _ in range(repetitions):
            for point in points:
                current = checkpoints[point["id"]]
                if current != previous:
                    pairs.add(tuple(sorted((previous, current))))
                previous = current
    changes = {}
    for left, right in sorted(pairs):
        with closing(SparseRam(left)) as before, closing(SparseRam(right)) as after:
            changes[(left, right)] = before.difference(after)
    return changes


def cycle_budget(case, default):
    limit = case.get("cycle_limit", default)
    if type(limit) is not int or not 1 <= limit < 1 << 64:
        raise ValueError("hardware cycle limit must be an unsigned, nonzero 64-bit integer")
    return limit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("spec", "native-build", "exporter", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--hw-target", required=True)
    parser.add_argument("--part", default="xcku15p")
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--cycle-limit", type=int, default=1000000000)
    parser.add_argument("--transfer-timeout", type=int, default=3600,
                        help="deadline in seconds for each complete JTAG upload or readback")
    args = parser.parse_args()
    overall_started = time.monotonic()
    result, jtag, base = None, None, None
    try:
        if min(args.repetitions, args.cycle_limit, args.transfer_timeout) < 1 or not args.hw_target:
            raise ValueError("positive replay budgets and an exact hardware target are required")
        cycle_budget({}, args.cycle_limit)
        args.output = args.output.resolve()
        args.output.mkdir(parents=True, exist_ok=False)
        build, routed = check_build(args.native_build)
        spec = json.loads(args.spec.read_text())
        if spec.get("schema") != "raptor-fpga-evaluation-spec-v1" or not spec.get("cases"):
            raise ValueError("invalid FPGA evaluation specification")
        cases, references = [], {}
        for case in spec["cases"]:
            plan_path, capture = (args.spec.parent / case[name] for name in ("plan", "capture"))
            plan, points, checkpoints = load_capture(plan_path, capture)
            if case["kind"] == "full":
                validate_full_plan(plan)
            if not re.fullmatch(r"[A-Za-z0-9][\w.-]*", case["id"]):
                raise ValueError("case ID must be a filename component")
            if case["kind"] not in ("full", "sample"):
                raise ValueError("FPGA case kind must be full or sample")
            cycle_budget(case, args.cycle_limit)
            if "pc_reference" in case:
                path = args.spec.parent / case["pc_reference"]
                references[case["id"]] = PcReference(path, plan["profile_sha256"],
                    plan.get("retirement_domain", {"mode": "all"}))
            cases.append((case, plan, points, checkpoints))
        if len({case[0]["id"] for case in cases}) != len(cases):
            raise ValueError("duplicate FPGA case IDs")
        result = {"schema": "raptor-fpga-evaluation-v1", "complete": False,
                  "spec_sha256": digest(args.spec), "build": build, "routed": routed,
                  "exporter_sha256": digest(args.exporter), "repetitions": args.repetitions,
                  "cases": [], "setup": [], "official_score": False}
        tooling = args.output / ".tooling"
        tooling.mkdir()
        result["tool_inputs"] = {}
        for name in ("fpga_replay.py", "fpga_jtag.tcl", "fpga_image.py", "run_model.py",
                     "run_samples.py", "simpoints.py", "execution.py", "pc_reference.py"):
            archived = tooling / name
            shutil.copyfile(HERE / name, archived)
            result["tool_inputs"][name] = digest(archived)
        reference_files = {}
        for case, plan, _points, _checkpoints in cases:
            if case["id"] not in references:
                continue
            key = plan["profile_sha256"]
            if key not in reference_files:
                archived = args.output / (key + ".bbv.jsonl")
                shutil.copyfile(args.spec.parent / case["pc_reference"], archived)
                if digest(archived) != key:
                    raise ValueError("native PC reference changed while being archived")
                reference_files[key] = str(archived)
        zero_file = args.output / "zero-page.bin"
        zero_file.write_bytes(bytes(PAGE))
        jtag = Jtag(args)
        if jtag.read(CONTROL)[0] != 0x5250545300010001:
            raise ValueError("hardware does not implement the replay ABI")
        identity = jtag.read(CONTROL + 0xB0, 2)
        if identity[0] | (identity[1] << 64) != int(build["sha256"][:32], 16):
            raise ValueError("connected bitstream differs from the routed build manifest")
        jtag.hold()
        # Check word ordering independently of bulk transfer/readback conversion.
        jtag.write(SRAM + 0x1FF0, 0x0123456789ABCDEF)
        jtag.write(SRAM + 0x1FF8, 0xFEDCBA9876543210)
        if jtag.read(SRAM + 0x1FF0, 2) != [0x0123456789ABCDEF, 0xFEDCBA9876543210]:
            raise ValueError("JTAG burst word order self-test failed")
        previous_directory, dirty = None, set()
        prepared = {}
        for case, plan, points, checkpoints in cases:
            root = args.output / case["id"]
            root.mkdir()
            setup_seconds = 0
            limit = cycle_budget(case, args.cycle_limit)
            timeout = max(300, limit / (build["configuration"]["clock_mhz"] * 1e6) + 60)
            if base is None:
                started = time.monotonic()
                base_directory = checkpoints[points[0]["id"]]
                base = SparseRam(base_directory)
                prepare_started = time.monotonic()
                prepared = {}
                transitions = prepare_transitions(cases, args.repetitions, base_directory)
                image_root = root / "prepared"
                image_root.mkdir()
                directories = {directory for _case, _plan, _points, sources in cases
                               for directory in sources.values()}
                for index, directory in enumerate(sorted(directories)):
                    state = read_state(directory / "state.txt")
                    trampoline = image_root / f"trampoline-{index}.bin"
                    subprocess.run([str(args.exporter.resolve()),
                                    f"--ckpt-export={directory / 'state.txt'},{trampoline}"],
                                   check=True, stdout=subprocess.DEVNULL)
                    image, mret_pc = restore_image(state, trampoline.read_bytes())
                    image_path = image_root / f"restore-{index}.bin"
                    image_path.write_bytes(image)
                    prepared[directory] = (state, image_path, mret_pc)
                preparation_wall = time.monotonic() - prepare_started
                jtag.write(CONTROL + 0xA0, 1)
                status = jtag.wait(0xA0, lambda value: not value & 2, 120)
                if status & 8 or not status & 4:
                    raise ValueError("DDR zero engine failed")
                transfer = upload_verified(jtag, root, "base", base.segments())
                setup_seconds = time.monotonic() - started
                result["setup"].append({"profile_sha256": plan["profile_sha256"],
                                         "shared_profiles": sorted({other["profile_sha256"]
                                             for _case, other, _points, _sources in cases}),
                                         "wall_seconds": setup_seconds, "transfer": transfer,
                                         "cached_checkpoint_transitions": len(transitions),
                                         "preparation_wall_seconds": preparation_wall})
                previous_directory, dirty = base_directory, set()
            case_result = {"id": case["id"], "kind": case["kind"], "settings": plan["settings"],
                           "plan_sha256": digest(args.spec.parent / case["plan"]),
                           "capture_sha256": digest(args.spec.parent / case["capture"]),
                           "retirement_domain": plan.get("retirement_domain", {"mode": "all"}),
                           "regions": [{key: value for key, value in row.items() if key != "points"}
                                       for row in plan["regions"]],
                           "profile_sha256": plan["profile_sha256"],
                           "profile_inputs": {name: value["sha256"] for name, value in
                                              plan.get("profile_inputs", {}).items()},
                           "cycle_limit": limit, "observation_timeout_seconds": timeout,
                           "setup_wall_seconds": setup_seconds, "runs": []}
            if case["id"] in references:
                case_result["pc_reference"] = {"path": reference_files[plan["profile_sha256"]],
                    "sha256": plan["profile_sha256"], "algorithm": ALGORITHM,
                    "scope": "ordered PC control flow; not ISA-state DiffTest"}
            result["cases"].append(case_result)
            for repetition in range(args.repetitions):
                measurements = []
                measured_plan = copy.deepcopy(plan)
                measured_points = {point["id"]: point for region in measured_plan["regions"]
                                   for point in region["points"]}
                for ordinal, point in enumerate(points):
                    started = time.monotonic()
                    work = root / f"repeat-{repetition}-point-{ordinal}"
                    work.mkdir()
                    directory = checkpoints[point["id"]]
                    state, prepared_image, mret_pc = prepared[directory]
                    target = SparseRam(directory)
                    try:
                        changed = set() if previous_directory == directory else transitions[
                            tuple(sorted((previous_directory, directory)))]
                        restored = dirty | changed
                        transfer = upload_verified(jtag, work, "delta",
                            target.segments(restored, zero_file=zero_file)) if restored else {
                                "bytes": 0, "wall_seconds": 0, "readback_verified": True}
                    finally:
                        target.close()
                    image_path = work / "restore.bin"
                    shutil.copyfile(prepared_image, image_path)
                    sram_transfer = upload_verified(jtag, work, "sram",
                        [(SRAM, 0, image_path.stat().st_size, image_path)])
                    domain = plan.get("retirement_domain", {"mode": "all"})
                    words = config_words(state, point, mret_pc, limit, domain)
                    for offset, value in words.items():
                        jtag.write(CONTROL + offset, value)
                    jtag.write(CONTROL + 0xA0, 2)
                    jtag.wait(0xA0, lambda value: bool(value & 32))
                    execution_started = time.monotonic()
                    result["active_window"] = {"case": case["id"], "repetition": repetition,
                                               "point": point["id"]}
                    jtag.write(CONTROL + 8, 1)
                    window = observations(jtag, point, domain, timeout)
                    execution_wall = time.monotonic() - execution_started
                    observed_retired = jtag.read(CONTROL + 0x70)[0]
                    gprs = []
                    if case.get("gpr", False):
                        for register in range(32):
                            jtag.write(CONTROL + 0x80, register)
                            gprs.append(hex(jtag.read(CONTROL + 0x80)[0]))
                    jtag.hold()
                    descriptor, bitmap = work / "dirty.segments", work / "dirty.bin"
                    size = base.size // PAGE // 8
                    write_segments(descriptor, [(CONTROL + 0x10000, 0, size, zero_file)])
                    jtag.transfer(descriptor, bitmap)
                    dirty = dirty_pages(bitmap.read_bytes(), base.size)
                    previous_directory = directory
                    write_json(work / "window.json", window)
                    audit = references[case["id"]].verify(window, point) \
                        if case["id"] in references else None
                    measured = matched_window(window, window, point)
                    measured_points[point["id"]]["start"] = measured["start"]
                    measurements.append({"id": point["id"], "profile": case["id"],
                                         "passed": True, "start": measured["start"],
                                         "instructions": measured["instructions"],
                                         "cycles": measured["baseline_cycles"]})
                    case_result["runs"].append({"id": point["id"], "repetition": repetition,
                        "point": point,
                        "window": window, "measurement": measured, "gpr": gprs,
                        "native_pc_audit": audit,
                        "observed_retired": observed_retired, "dirty_pages": len(dirty),
                        "checkpoint_changed_pages": len(changed),
                        "restored_pages": len(restored), "delta_transfer": transfer,
                        "sram_transfer": sram_transfer, "execution_wall_seconds": execution_wall,
                        "wall_seconds": time.monotonic() - started})
                    result.pop("active_window", None)
                    print(f"{case['id']} repeat={repetition} point={ordinal}: "
                          f"cycles={measured['baseline_cycles']} restored={len(restored)} pages", flush=True)
                    temporary = args.output / "progress.tmp"
                    write_json(temporary, result)
                    os.replace(temporary, args.output / "progress.json")
                estimate = summarize(measured_plan, measurements)
                if not estimate["complete"]:
                    raise ValueError("FPGA weighted estimate is incomplete")
                case_result.setdefault("estimates", []).append(estimate)
        result["complete"] = True
        result["wall_seconds"] = time.monotonic() - overall_started
        jtag.hold()
        write_json(args.output / "results.json", result)
    except (OSError, ValueError, KeyError, TypeError, TimeoutError,
            subprocess.CalledProcessError) as error:
        if result is not None:
            result.update(complete=False, error=str(error))
            if jtag is not None:
                result["failure_snapshot"] = failure_snapshot(jtag)
                try:
                    jtag.hold()
                except (OSError, ValueError, TimeoutError) as cleanup_error:
                    result["cleanup_error"] = str(cleanup_error)
            write_json(args.output / "results.json", result)
        parser.exit(1, f"{error}\n")
    finally:
        if jtag is not None:
            jtag.close()
        if base is not None:
            base.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
