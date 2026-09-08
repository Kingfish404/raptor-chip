#!/usr/bin/env python3
"""Compare cycle counts on identical self-checking CPU-test binaries.

Run prebuilt simulators; do not build or change configuration. NEMU diff is
enabled. Reports cycle counts/IPC, not simulator wall time or a frequency claim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CASES = ["crc32", "matrix-mul", "quick-sort", "recursion", "bit", "mul-longlong"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_dispatch(output):
    """Read the final registered admission snapshot and reject inconsistent totals."""
    last_report = output.rfind("======== Rename/Dispatch Status ========")
    if last_report >= 0:
        output = output[last_report:]
    totals = re.findall(r"Dispatch accounting: cycles (\d+), width (\d+), accepted (\d+), unfilled (\d+)", output)
    if not totals:
        if "Dispatch stop " in output:
            raise ValueError("incomplete dispatch accounting report")
        return None  # Older simulators do not have the new probes.
    cycles, width, accepted, unfilled = map(int, totals[-1])
    stops = {}
    for name, count, slots, zero in re.findall(
            r"Dispatch stop ([a-z_]+): cycles (\d+), unfilled slots (\d+)(?:, zero-progress cycles (\d+))?", output):
        if name in stops:
            raise ValueError("duplicate dispatch stop reason")
        stops[name] = {"cycles": int(count), "unfilled_slots": int(slots)}
        if zero:
            stops[name]["zero_progress_cycles"] = int(zero)
    histogram = {int(n): int(c) for n, c in re.findall(r"Dispatch histogram (\d+): cycles (\d+)", output)}
    domains = {int(d): int(c) for d, c in re.findall(r"Dispatch endpoint domain (\d+): cycles (\d+)", output)}
    checks = [
        sum(r["cycles"] for r in stops.values()) == cycles,
        sum(r["unfilled_slots"] for r in stops.values()) == unfilled,
        accepted + unfilled == width * cycles,
        sum(histogram.values()) == cycles,
        sum(n * c for n, c in histogram.items()) == accepted,
        set(histogram) == set(range(width + 1)),
        sum(domains.values()) == stops.get("endpoint", {}).get("cycles"),
        stops.get("width", {}).get("cycles") == histogram.get(width),
        stops.get("width", {}).get("unfilled_slots") == 0,
    ]
    if stops and all("zero_progress_cycles" in r for r in stops.values()):
        checks.append(sum(r["zero_progress_cycles"] for r in stops.values()) == histogram.get(0))
        checks.extend(0 <= r["zero_progress_cycles"] <= r["cycles"] for r in stops.values())
    if not all(checks):
        raise ValueError("dispatch accounting conservation failed")
    return {"cycles": cycles, "width": width, "accepted": accepted, "unfilled_slots": unfilled,
            "stops": stops, "histogram": histogram, "endpoint_domains": domains}


def parse_rob_dispatch(output):
    """Parse the ROB-allocation/endpoint-steering decoupling metrics."""
    reports = re.findall(
        r"ROB dispatch steering: candidates (\d+), accepted (\d+), bypass (\d+), "
        r"oldest blocked (\d+), pending avg ([0-9]+(?:\.[0-9]+)?), peak (\d+)", output)
    if not reports:
        return None
    candidates, accepted, bypass, blocked, average, peak = reports[-1]
    domains = {int(d): int(c) for d, c in re.findall(
        r"ROB dispatch blocked domain (\d+): cycles (\d+)", output)}
    result = {
        "candidates": int(candidates),
        "accepted": int(accepted),
        "bypass": int(bypass),
        "oldest_blocked_cycles": int(blocked),
        "pending_average": float(average),
        "pending_peak": int(peak),
        "blocked_domains": domains,
    }
    reason_rows = re.findall(r"ROB branch capacity reason (\d+): cycles (\d+)", output)
    if reason_rows:
        # Select one complete final seven-bin report, never merge partial bins
        # across multiple periodic PMU dumps.
        last = reason_rows[-7:]
        reasons = {int(r): int(c) for r, c in last}
        if ([int(r) for r, _ in last] != list(range(7)) or reasons[0] != 0
                or sum(reasons.values()) != domains.get(1, 0)):
            raise ValueError("ROB branch capacity reason conservation failed")
        result["branch_capacity_reasons"] = reasons
    histogram = {int(n): int(cycles) for n, cycles in re.findall(
        r"ROB dispatch pending histogram (\d+): cycles (\d+)", output)}
    if histogram:
        histogram_cycles = sum(histogram.values())
        histogram_pending = sum(n * cycles for n, cycles in histogram.items())
        histogram_peak = max((n for n, cycles in histogram.items() if cycles), default=0)
        if (set(histogram) != set(range(max(histogram) + 1))
                or histogram_cycles == 0
                or histogram_peak != result["pending_peak"]
                or abs(histogram_pending / histogram_cycles
                       - result["pending_average"]) > 0.000501):
            raise ValueError("ROB dispatch pending histogram conservation failed")
        result["pending_histogram"] = histogram
        result["sample_cycles"] = histogram_cycles
    pending_domains = {int(domain): {"instruction_cycles": int(instruction_cycles),
                                     "peak": int(peak)}
                       for domain, instruction_cycles, peak in re.findall(
        r"ROB dispatch pending domain (\d+): instruction-cycles (\d+), peak (\d+)", output)}
    if pending_domains:
        if (not histogram
                or sum(row["instruction_cycles"] for row in pending_domains.values())
                   != histogram_pending
                or any(row["peak"] > result["pending_peak"] for row in pending_domains.values())):
            raise ValueError("ROB dispatch pending-domain conservation failed")
        result["pending_domains"] = pending_domains
    if (result["accepted"] > result["candidates"]
            or result["bypass"] > result["accepted"]
            or sum(domains.values()) != result["oldest_blocked_cycles"]):
        raise ValueError("ROB dispatch steering accounting conservation failed")
    return result


def parse_frontend(output):
    """Final aggregate probes; residual execution mispredicts are not raw IFU misses."""
    predictions = re.findall(
        r"BPU Success: (\d+), Fail: (\d+), Rate: [\d.]+% \(b: (\d+), j: (\d+), jr: (\d+)\), call: (\d+), ret: (\d+)",
        output)
    resteers = re.findall(r"Early resteer: (\d+) events", output)
    if not predictions:
        return None
    success, fail, branch, direct, indirect, calls, returns = map(int, predictions[-1])
    if fail != branch + direct + indirect:
        raise ValueError("branch failure accounting conservation failed")
    result = {"execution_prediction_success": success, "execution_prediction_fail": fail,
              "conditional_fail": branch, "direct_fail": direct, "indirect_fail": indirect,
              "calls": calls, "returns": returns}
    if resteers:
        result["decode_resteers"] = int(resteers[-1])
    return result


def parse_rename_checkpoints(output):
    """Parse the final rename-checkpoint pressure report when probes exist."""
    reports = re.findall(
        r"Rename checkpoints: pool full (\d+) cycles, allocation stalls (\d+) cycles, "
        r"occupancy avg ([0-9]+(?:\.[0-9]+)?), peak (\d+); recovery fence (\d+) cycles", output)
    legacy = False
    if not reports:
        reports = re.findall(
            r"Rename checkpoints: full (\d+) cycles, occupancy avg ([0-9]+(?:\.[0-9]+)?), "
            r"peak (\d+); recovery fence (\d+) cycles", output)
        legacy = bool(reports)
    if not reports:
        return None  # Older simulators do not expose checkpoint probes.
    if legacy:
        full, average, peak, fence = reports[-1]
        stall = None  # The legacy `full` probe mixed pressure with other blockers.
    else:
        full, stall, average, peak, fence = reports[-1]
    result = {"full_cycles": int(full), "occupancy_average": float(average),
              "occupancy_peak": int(peak), "recovery_fence_cycles": int(fence)}
    if stall is not None:
        result["allocation_stall_cycles"] = int(stall)
    if (result["occupancy_average"] < 0
            or result["occupancy_peak"] < result["occupancy_average"] - 0.001):
        raise ValueError("invalid rename-checkpoint occupancy report")
    return result


def parse_recovery_transaction(output):
    """Parse completion-time redirect opportunities from newer simulators."""
    reports = re.findall(
        r"Early recovery: redirects (\d+), pending-fence window (\d+) cycles", output)
    if not reports:
        return None
    redirects, window = map(int, reports[-1])
    return {"early_redirects": redirects, "pending_fence_cycles": window}


def parse_alq_selection(output):
    """Parse the final ALQ selector report, including optional port scaling probes."""
    reports = list(re.finditer(
        r"ALQ selection: ready-entry cycles (\d+), issued (\d+), rebalance extra issues (\d+)",
        output))
    if not reports:
        return None
    match = reports[-1]
    ready, issued, gain = map(int, match.groups())
    tail = output[match.end():]
    result = {"ready_entry_cycles": ready, "issued": issued, "rebalance_extra": gain}
    histogram = {int(n): int(cycles) for n, cycles in re.findall(
        r"ALQ issue histogram (\d+): cycles (\d+)", tail)}
    extra = re.search(r"ALQ extra physical ports \(index >= 2\): issues (\d+)", tail)
    if histogram:
        if set(histogram) != set(range(max(histogram) + 1)):
            raise ValueError("incomplete ALQ issue histogram")
        if sum(n * cycles for n, cycles in histogram.items()) != issued:
            raise ValueError("ALQ issue histogram conservation failed")
        result["issue_histogram"] = histogram
    if extra:
        result["extra_port_issues"] = int(extra.group(1))
        if result["extra_port_issues"] > issued:
            raise ValueError("extra-port ALQ issues exceed all ALQ issues")
    return result


def parse_recovery(output):
    start = output.rfind("Control lifecycle:")
    if start < 0:
        return None
    output = output[start:]
    pattern = (r"Control lifecycle: allocated (\d+), resolved (\d+), retired (\d+), traps (\d+), "
               r"killed unresolved (\d+), killed correct (\d+), killed wrong (\d+), reset discarded (\d+), live (\d+)")
    lifecycle = re.search(pattern, output)
    if lifecycle is None:
        raise ValueError("incomplete control lifecycle report")
    keys = ["allocated", "resolved", "retired", "traps", "killed_unresolved", "killed_correct",
            "killed_wrong", "reset_discarded", "live"]
    result = dict(zip(keys, map(int, lifecycle.groups())))
    latency = {}
    for name, count, cycles, maximum in re.findall(
            r"Control latency (\w+): count (\d+), cycles (\d+), max (\d+)", output):
        if name in latency:
            raise ValueError("duplicate control latency")
        hist = {int(b): int(n) for b, n in re.findall(
            rf"Control histogram {name} bucket (\d+): count (\d+)", output)}
        count, cycles, maximum = int(count), int(cycles), int(maximum)
        lower = [0, 1, 2, 4, 8, 16, 32, 64]
        if (set(hist) != set(range(8)) or sum(hist.values()) != count
                or cycles > count * maximum
                or sum(lower[b] * n for b, n in hist.items()) > cycles
                or maximum > cycles or (count == 0 and maximum != 0)):
            raise ValueError("invalid control latency histogram")
        latency[name] = {"count": count, "cycles": cycles, "max": maximum, "histogram": hist}
    if set(latency) != {"correct_retire", "wrong_retire", "wrong_killed"}:
        raise ValueError("missing control latency classes")
    pending = re.search(r"Control pending wrong: union cycles (\d+), instruction cycles (\d+), "
                        r"max concurrent (\d+), live (\d+)", output)
    if pending is None:
        raise ValueError("missing pending control report")
    union, integral, maximum, live = map(int, pending.groups())
    if (result["allocated"] != result["retired"] + result["killed_unresolved"]
            + result["killed_correct"] + result["killed_wrong"] + result["reset_discarded"] + result["live"]
            or result["retired"] != latency["correct_retire"]["count"] + latency["wrong_retire"]["count"] + result["traps"]
            or result["killed_wrong"] != latency["wrong_killed"]["count"]
            or integral < union or integral > union * maximum or live > result["live"]):
        raise ValueError("control lifecycle conservation failed")
    result["latency"] = latency
    result["pending_wrong"] = {"union_cycles": union, "instruction_cycles": integral,
                               "max_concurrent": maximum, "live": live}
    residual = re.search(r"Control pending residual: trap cycles (\d+), reset cycles (\d+), live cycles (\d+)", output)
    if residual:
        trap_age, reset_age, live_age = map(int, residual.groups())
        if integral != latency["wrong_retire"]["cycles"] + latency["wrong_killed"]["cycles"] + trap_age + reset_age + live_age:
            raise ValueError("pending residence-time conservation failed")
        result["residual_cycles"] = {"trap": trap_age, "reset": reset_age, "live": live_age}
    if "Control pending head" in output:
        waiting = {int(d): int(n) for d, n in re.findall(
            r"Control pending head domain (\d+): waiting cycles (\d+)", output)}
        head = re.search(r"Control pending head: ready cycles (\d+), empty cycles (\d+)", output)
        if head is None or not waiting:
            raise ValueError("missing pending head report")
        ready, empty = map(int, head.groups())
        if ready + empty + sum(waiting.values()) != union:
            raise ValueError("pending head partition failed")
        result["pending_head"] = {"ready": ready, "empty": empty, "waiting_domains": waiting}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", action="append", required=True, metavar="LABEL=BINARY")
    parser.add_argument("--output", type=Path, default=ROOT / "verify/build/width-evaluation")
    available_cases = sorted(path.stem for path in
                             (ROOT / "abstract-machine/app/am-kernels/tests/cpu-tests/tests").glob("*.c"))
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--case", dest="cases", action="append", choices=available_cases)
    selection.add_argument("--all-cases", action="store_true", help="run every CPU test listed by source, not just existing images")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=32)
    parser.add_argument("--mem-random-delay", type=int, default=0,
                        help="maximum added wait cycles per AXI memory beat")
    parser.add_argument("--mem-random-seed", type=int, default=1)
    parser.add_argument("--reference", type=Path,
                        help="reference library; defaults to the selected XLEN's NEMU library")
    parser.add_argument("--boot", type=Path,
                        help="boot image; defaults to the selected XLEN's spike ROM")
    parser.add_argument("--images", type=Path,
                        default=ROOT / "abstract-machine/app/am-kernels/tests/cpu-tests/build")
    args = parser.parse_args()
    if not 0 <= args.mem_random_delay < 1048575:
        parser.error("--mem-random-delay must be in [0, 1048574]")
    if not 1 <= args.mem_random_seed <= 0xffffffff:
        parser.error("--mem-random-seed must be a nonzero 32-bit integer")
    cases = available_cases if args.all_cases else args.cases or CASES
    if not cases:
        raise RuntimeError("no CPU tests discovered")
    args.output.mkdir(parents=True, exist_ok=True)
    report = args.output / "results.json"
    # A missing input or first-case failure must not leave an old PASS visible.
    report.write_text(json.dumps({"complete": False}) + "\n")
    ref = (args.reference or ROOT / f"nemu/build/riscv{args.xlen}-nemu-interpreter-so").resolve()
    boot = (args.boot or ROOT / f"sim/csrc/mem/mrom-data/build/rv{args.xlen}-spike-rv{args.xlen}ima/mrom-data.bin").resolve()
    images = args.images.resolve()
    results = {"schema_version": 1, "complete": False, "xlen": args.xlen,
               "memory_delay": {"max_cycles_per_beat": args.mem_random_delay,
                                "seed": args.mem_random_seed},
               "reference_sha256": digest(ref), "boot_sha256": digest(boot), "profiles": []}
    report.write_text(json.dumps(results, indent=2) + "\n")
    baseline = None
    labels = set()
    for specification in args.profile:
        label, binary = specification.split("=", 1)
        if not re.fullmatch(r"[A-Za-z0-9_-]+", label) or label in labels:
            raise ValueError("profile labels must be unique alphanumeric/underscore/hyphen names")
        labels.add(label)
        binary = Path(binary).resolve()
        profile = {"label": label, "binary": str(binary), "binary_sha256": digest(binary),
                   "complete": False, "cases": []}
        results["profiles"].append(profile)
        report.write_text(json.dumps(results, indent=2) + "\n")
        for case in cases:
            image = images / f"{case}-riscv{args.xlen}-npc.bin"
            image_sha256 = digest(image)
            command = [str(binary), "-b", "-n", "--no-lightsss", "-d", str(ref), "-r", str(boot), str(image)]
            if args.mem_random_delay:
                command[1:1] = [f"--mem-random-delay={args.mem_random_delay}",
                                f"--mem-random-seed={args.mem_random_seed}"]
            result = subprocess.run(command, cwd=ROOT / "sim", text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=args.timeout)
            log = args.output / f"{label}-{case}.log"
            log.write_text(result.stdout)
            # Reports must describe the bytes supplied to this run, not a
            # replacement written by a concurrent build while it executed.
            expected_inputs = {binary: profile["binary_sha256"],
                               ref: results["reference_sha256"],
                               boot: results["boot_sha256"], image: image_sha256}
            for path, expected_digest in expected_inputs.items():
                if digest(path) != expected_digest:
                    raise RuntimeError(f"test input changed during {label}/{case}: {path}")
            output = ANSI.sub("", result.stdout)
            if result.returncode or "HIT GOOD TRAP" not in output or re.search(r"Errors detected|ERROR!|\[ERROR\]", output):
                raise RuntimeError(f"{label}/{case} failed; see {log}")
            metrics = re.findall(r"#inst:\s*(\d+), cycle:\s*(\d+)", output)
            if not metrics:
                raise RuntimeError(f"missing instruction/cycle counters: {log}")
            instructions, cycles = map(int, metrics[-1])
            row = {"case": case, "image_sha256": image_sha256, "instructions": instructions,
                   "cycles": cycles, "ipc": instructions / cycles}
            selection = parse_alq_selection(output)
            if selection is not None:
                row["alq_selection"] = selection
            reclaim = re.findall(r"ALQ issue-slot reclaim: allocations (\d+)", output)
            if reclaim:
                row["alq_reclaim_allocations"] = int(reclaim[-1])
            admission = parse_dispatch(output)
            rob_dispatch = parse_rob_dispatch(output)
            frontend = parse_frontend(output)
            recovery = parse_recovery(output)
            checkpoints = parse_rename_checkpoints(output)
            if checkpoints is not None:
                if (checkpoints["full_cycles"] > cycles
                        or checkpoints.get("allocation_stall_cycles", 0) > cycles
                        or checkpoints["recovery_fence_cycles"] > cycles):
                    raise RuntimeError(f"rename-checkpoint cycles exceed sampled cycles: {log}")
                row["rename_checkpoints"] = checkpoints
            if recovery is not None:
                if recovery["pending_wrong"]["union_cycles"] > cycles:
                    raise RuntimeError("pending wrong union exceeds sampled cycles")
                row["recovery"] = recovery
            frontend_recovery = re.findall(
                r"Commit flush: branch (\d+), non-branch (\d+); branch recovery: (\d+) completed, "
                r"(\d+) wait cycles \([\d.]+ cycles/completed\), (\d+) overlaps", output)
            if frontend_recovery:
                row["frontend_recovery"] = dict(zip(
                    ["branch_flush", "nonbranch_flush", "completed", "wait_cycles", "overlaps"],
                    map(int, frontend_recovery[-1])))
            recovery_transaction = parse_recovery_transaction(output)
            if recovery_transaction is not None:
                if recovery_transaction["pending_fence_cycles"] > cycles:
                    raise RuntimeError("early-recovery window exceeds sampled cycles")
                row["recovery_transaction"] = recovery_transaction
            if frontend is not None:
                row["frontend"] = frontend
            if admission is not None:
                if admission["cycles"] != cycles:
                    raise RuntimeError(f"dispatch and execution counters disagree: {log}")
                row["dispatch"] = admission
            if rob_dispatch is not None:
                if ("sample_cycles" in rob_dispatch
                        and rob_dispatch["sample_cycles"] != cycles):
                    raise RuntimeError(f"ROB dispatch histogram cycle count disagrees: {log}")
                row["rob_dispatch"] = rob_dispatch
            if baseline is not None:
                old = next(x for x in baseline["cases"] if x["case"] == case)
                if old["instructions"] != instructions or old["image_sha256"] != row["image_sha256"]:
                    raise RuntimeError(f"instruction stream changed for {label}/{case}; not comparable")
                row["cycle_speedup"] = old["cycles"] / cycles
            profile["cases"].append(row)
            report.write_text(json.dumps(results, indent=2) + "\n")
            print(f"PASS: {label} {case}: {instructions} instructions, {cycles} cycles, IPC={row['ipc']:.3f}", flush=True)
        if baseline is None:
            baseline = profile
        profile["complete"] = True
        report.write_text(json.dumps(results, indent=2) + "\n")
    results["complete"] = True
    report.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
