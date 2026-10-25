#!/usr/bin/env python3
"""Compare deterministic FPGA evaluation logs without treating incomplete runs as passes."""

import argparse
import json
import math
import re
from pathlib import Path

BENCHMARKS = """aha-mont64 crc32 depthconv edn huffbench matmult-int md5sum nettle-aes
nettle-sha256 nsichneu picojpeg qrduino sglib-combined slre statemate tarfind ud
wikisort xgboost""".split()
LINUX_MARKERS = (
    "Linux version",
    "Run /init as init process",
    "Run /bin/sh as init process",
    "Starting syslogd",
    "Starting klogd",
    "Please press Enter to activate this console",
    "login:",
    "can't access tty; job control turned off",
    "CAL_USER_BEGIN", "CAL_USER_EXEC_DONE", "CAL_USER_ALLOC_DONE", "CAL_USER_DONE",
)
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
LOG_PREFIX = r"(?:[\w.-]+\.cc:\d+ \S+\s+)?"
COREMARK_SHORT_WARNING = "ERROR! Must execute for at least 10 secs for a valid result!"
# The published image uses two iterations of the 2K performance workload.
# EEMBC's seed/list/matrix/state checks and a separate host run agree on this tuple.
COREMARK_SHORT_CRC = {"seedcrc": 0xe9f5, "crclist": 0xe714, "crcmatrix": 0x1fd7,
                      "crcstate": 0x8e3a, "crcfinal": 0x72be}


def canonical_marker(marker):
    return marker.rstrip(":") if marker.startswith(("Starting syslogd", "Starting klogd")) else marker


def pmu_snapshots(text):
    """Keep whole cumulative snapshots; never add snapshots or call them ROI deltas."""
    snapshots = []
    current = None
    for line in text.splitlines():
        content = re.sub(r"^pmu\.cc:\d+ \S+\s+", "", line)
        # Instrumented reports start with AXI, followed by either the verbose
        # section header or compact #inst row. Legacy reports have no AXI prelude.
        start = (content.startswith("AXI handshakes:") or
                 content.startswith(("======== Instruction Analysis", "#inst:"))
                 and (current is None or current["cycles"] is not None))
        if start:
            current = {"scope": "cumulative task counters (not ROI deltas)",
                       "complete": False, "lines": [], "insts": None, "cycles": None}
            snapshots.append(current)
        if current is None:
            continue
        if content.startswith("Simulate time:"):
            current["complete"] = current["cycles"] is not None
            current = None
            continue
        # Every PMU row belongs to the same snapshot, including numeric tables.
        if line.startswith("pmu.cc:") or content == line and not re.match(
                r".*\.cc:\d+ |rc=|wall_seconds=", line):
            current["lines"].append(content)
            match = re.match(r"#inst: (\d+), cycle: (\d+)", content)
            if match:
                current.update(insts=int(match[1]), cycles=int(match[2]))
    return snapshots


def read_log(path):
    text = ANSI.sub("", path.read_text(errors="replace"))
    rc = re.findall(r"^rc=(-?\d+)\s*$", text, re.M)
    rc = int(rc[-1]) if rc else None
    failed = rc not in (None, 0) or bool(re.search(
        r"HIT BAD TRAP|Program execution has aborted|\[FAIL(?:\]| )|Assertion .* failed|"
        r"PAGEFAULT validation failed|PAGEFAULT verify=0|"
        r"(?m:^[ \t]*(?:\[[^\]\r\n]*\][ \t]*)*Kernel panic - not syncing)", text))
    status = "FAILED" if failed else "PARTIAL"
    good = "HIT GOOD TRAP" in text
    metrics = {}
    memprobe_details = {}
    intervals = {}
    validation = {}
    kind = path.stem
    if kind == "mp":
        for operation, size, value in re.findall(
                r"MEMPROBE (chase|store) (\d+) cycles_per_access=(\d+(?:\.\d+)?)", text):
            metrics[f"memprobe {operation} {int(size)} B"] = float(value)
        for operation, fields in re.findall(r"^MEMPROBE detail (chase|store) ([^\r\n]+)", text, re.M):
            values = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", fields)}
            if "bytes" in values:
                memprobe_details[f"memprobe {operation} {values['bytes']} B"] = values
        if rc == 0 and good and "MEMPROBE verify=1" in text and not failed:
            status = "PASS"
    elif kind == "cm":
        match = re.search(r"CoreMark ROI cycles\s*:\s*(\d+)", text)
        if match:
            metrics["CoreMark ROI cycles"] = int(match[1])
        errors = [line.strip() for line in text.splitlines()
                  if re.match(r"\s*(?:\[\d+\])?\s*(?:ERROR|Errors detected)", line)]
        iterations = re.search(r"^Iterations\s*:\s*(\d+)\s*$", text, re.M)
        crc = {name: int(value, 16) for name, value in re.findall(
            r"^(?:\[0\])?(seedcrc|crclist|crcmatrix|crcstate|crcfinal)\s*:\s*0x([0-9a-fA-F]+)\s*$",
            text, re.M)}
        short_warning = COREMARK_SHORT_WARNING in errors
        duration_only = sorted(errors) == sorted([COREMARK_SHORT_WARNING, "Errors detected"])
        short_crc_valid = (crc == COREMARK_SHORT_CRC and iterations is not None
                           and int(iterations[1]) == 2)
        validated = "Correct operation validated" in text and not errors
        validation = {"official_valid": bool(validated and rc == 0 and good and match and not failed),
                      "crc_valid": validated or short_crc_valid,
                      "iterations": int(iterations[1]) if iterations else None, "crc": crc,
                      "errors": errors}
        other_errors = any(line not in (COREMARK_SHORT_WARNING, "Errors detected") for line in errors)
        wrong_short_crc = short_warning and len(crc) == 5 and not short_crc_valid
        if other_errors or wrong_short_crc or ("Errors detected" in errors and not short_warning):
            status = "FAILED"
        elif rc == 0 and good and match and int(match[1]) > 0 and not failed and validated:
            status = "PASS"
        elif rc == 0 and good and match and int(match[1]) > 0 and not failed and duration_only and short_crc_valid:
            status = "PASS (CRC-valid short ROI)"
    elif kind == "pf":
        phases = {}
        for phase, fields in re.findall(r"PAGEFAULT (demand|resident|hot) ([^\r\n]+)", text):
            values = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", fields)}
            phases[phase] = values
            if "cycles" in values:
                metrics[f"Pagefault {phase} cycles"] = values["cycles"]
        expected = {"demand": {"pages": 64, "faults": 64},
                    "resident": {"pages": 64, "accesses": 4096},
                    "hot": {"pages": 8, "accesses": 4096}}
        complete = all(phase in phases and phases[phase].get("cycles", 0) > 0 and
                       all(phases[phase].get(key) == value for key, value in fields.items())
                       for phase, fields in expected.items())
        verified = "[PASS]" in text or "PAGEFAULT verify=1" in text
        if rc == 0 and good and verified and complete and not failed:
            status = "PASS"
    elif kind.startswith("eb-"):
        match = re.search(r"^Cycles:\s*(\d+)", text, re.M)
        if match:
            metrics[f"Embench {kind[3:]} cycles"] = int(match[1])
        if rc == 0 and good and "[PASS]" in text and match and int(match[1]) > 0 and not failed:
            status = "PASS"
    elif kind == "lx":
        exact = re.findall(r"^" + LOG_PREFIX
                           + r"serial milestone: cycles=(\d+) insts=(\d+) text=([^\r\n]+)$",
                           text, re.M)
        for cycles, insts, marker in exact:
            marker = canonical_marker(marker)
            metrics.setdefault(f"Linux {marker} cycles", int(cycles))
            metrics.setdefault(f"Linux {marker} insts", int(insts))
        # Without instrumentation the marker lies between adjacent progress reports.
        # Do not infer an exact timestamp from the nearest heartbeat or final PMU.
        progress = [(m.start(), int(m[1]), int(m[2])) for m in re.finditer(
            r"progress: (\d+) cycles, (\d+) insts", text)]
        for marker in LINUX_MARKERS:
            key = f"Linux {marker} cycles"
            if key in metrics:
                continue
            # Ignore command-line echoes, which can contain marker text before boot.
            matches = [m for m in re.finditer(re.escape(marker), text)
                       if not any(word in text[text.rfind('\n', 0, m.start()) + 1:m.start()]
                                  for word in ("--serial-", "ARGS=", "text=", "milestone reached:",
                                               "Kernel command line:", "bootargs", " -c "))]
            if not matches:
                continue
            position = matches[0].start()
            before = [p for p in progress if p[0] < position]
            after = [p for p in progress if p[0] > position]
            lower = before[-1][1:] if before else (0, 0)
            upper = after[0][1:] if after else (None, None)
            for i, unit in enumerate(("cycles", "insts")):
                intervals[f"Linux {marker} {unit}"] = [lower[i], upper[i]]
        # Exit logging happens immediately on the matching UART byte, before a
        # guest newline; its source prefix may therefore follow a login prompt.
        exits = []
        for line in text.splitlines():
            if any(token in line for token in ("--serial-", "ARGS=", "Kernel command line:", "bootargs")):
                continue
            match = re.search(r"(?:^|mmio-serial\.cc:\d+ serial_write_host_byte\s+)"
                              r"serial exit milestone reached: (.+)$", line)
            if match:
                exits.append(match[1])
        validation["exit_marker"] = exits[-1] if exits else None
        if exits and rc == 0 and not failed:
            status = "PASS (serial exit)"
        elif not failed and (metrics or intervals):
            status = "PARTIAL (milestones reached)"
    snapshots = pmu_snapshots(text)
    final_pmu = snapshots[-1] if snapshots and snapshots[-1]["complete"] and rc is not None else None
    return {"status": status, "rc": rc, "metrics": metrics, "intervals": intervals,
            "memprobe_details": memprobe_details,
            "validation": validation,
            "pmu": final_pmu["lines"] if final_pmu else [], "pmu_final": final_pmu,
            "pmu_snapshots": snapshots, "path": str(path)}


def load_tag(root, tag):
    paths = sorted(path for path in (root / tag).rglob("*.log")
                   if path.stem in ("mp", "pf", "cm", "lx") or path.stem.startswith("eb-"))
    directories = sorted({path.parent for path in paths})
    if not directories:
        return [{"name": tag, "logs": {}, "metrics": {}, "intervals": {}}]
    runs = []
    for directory in directories:
        manifest = directory / "manifest.json"
        try:
            metadata = json.loads(manifest.read_text()) if manifest.is_file() else None
            if not isinstance(metadata, dict):
                metadata = None
        except (ValueError, OSError):
            metadata = None
        logs = {path.stem: read_log(path) for path in paths if path.parent == directory}
        metrics = {key: value for log in logs.values() for key, value in log["metrics"].items()}
        intervals = {key: value for log in logs.values() for key, value in log["intervals"].items()}
        passed = [logs.get("eb-" + bench, {}).get("status") == "PASS" for bench in BENCHMARKS]
        if all(passed):
            metrics["Embench geomean cycles (19/19)"] = math.exp(sum(
                math.log(metrics[f"Embench {bench} cycles"]) for bench in BENCHMARKS) / len(BENCHMARKS))
        suffix = "/" + str(directory.relative_to(root / tag)) if len(directories) > 1 else ""
        runs.append({"name": tag + suffix, "logs": logs, "metrics": metrics,
                     "intervals": intervals, "metadata": metadata})
    return runs


def format_number(value):
    if isinstance(value, int) or value == int(value):
        return f"{value:,.0f}"
    return f"{value:,.2f}"


def metric_status(run, metric):
    if metric.startswith("Embench geomean"):
        return "PASS"
    name = ("mp" if metric.startswith("memprobe") else "cm" if metric.startswith("CoreMark")
            else "pf" if metric.startswith("Pagefault")
            else "lx" if metric.startswith("Linux") else "eb-" + metric.split()[1])
    return run["logs"].get(name, {}).get("status", "MISSING")


def comparison_metadata(run, reference, key):
    current, baseline = run.get("metadata"), reference.get("metadata")
    if not current or not baseline:
        return "unverified metadata"
    for field in ("read_latency", "write_latency", "xlen", "memory_args"):
        if field not in current or field not in baseline:
            return "unverified " + field
        if current[field] != baseline[field]:
            return "mismatched " + field
    if key.startswith("Linux"):
        field = "dtb_source_sha256"
        if not current.get(field) or not baseline.get(field):
            return "unverified " + field
        if current[field] != baseline[field]:
            return "mismatched " + field
    workloads = (['eb-' + bench for bench in BENCHMARKS] if key.startswith("Embench geomean")
                 else ["mp" if key.startswith("memprobe") else "cm" if key.startswith("CoreMark")
                       else "pf" if key.startswith("Pagefault")
                       else "lx" if key.startswith("Linux") else "eb-" + key.split()[1]])
    for workload in workloads:
        current_hash = current.get("images", {}).get(workload, {}).get("sha256")
        baseline_hash = baseline.get("images", {}).get(workload, {}).get("sha256")
        if not current_hash or not baseline_hash:
            return "unverified image " + workload
        if current_hash != baseline_hash:
            return "mismatched image " + workload
    return None


def cell(run, key, reference):
    status = metric_status(run, key)
    suffix = " [FAILED]" if status == "FAILED" else " [partial]" if status.startswith("PARTIAL") else ""
    if key in run["intervals"]:
        low, high = run["intervals"][key]
        value = f"[{format_number(low)}, {format_number(high)}]" if high is not None else f">={format_number(low)}"
        return value + " (bound)" + suffix
    value = run["metrics"].get(key)
    if value is None:
        return "—"
    display = format_number(value)
    base = reference["metrics"].get(key)
    comparable = (status.startswith("PASS") and metric_status(reference, key).startswith("PASS"))
    # A recorded Linux milestone is itself a completed phase even if boot continues.
    if key.startswith("Linux"):
        comparable = status != "FAILED" and metric_status(reference, key) != "FAILED"
    if run is not reference and base and comparable:
        mismatch = comparison_metadata(run, reference, key)
        if mismatch:
            display += f" [{mismatch}]"
        else:
            ratio = value / base
            if key.startswith("memprobe"):
                detail = run["logs"].get("mp", {}).get("memprobe_details", {}).get(key, {})
                ref_detail = reference["logs"].get("mp", {}).get("memprobe_details", {}).get(key, {})
                if all(data.get(field, 0) > 0 for data in (detail, ref_detail)
                       for field in ("cycles", "steps")):
                    ratio = (detail["cycles"] * ref_detail["steps"] /
                             (ref_detail["cycles"] * detail["steps"]))
            display += f" ({(ratio - 1) * 100:+.2f}%)"
    return display + suffix


def provenance_note(run, reference):
    current, baseline = run.get("metadata") or {}, reference.get("metadata") or {}
    if current.get("binary_sha256") and current["binary_sha256"] == baseline.get("binary_sha256"):
        return "identical simulator binary"
    sources, ref_sources = current.get("source_sha256"), baseline.get("source_sha256")
    if not sources or not ref_sources:
        return "simulator source provenance unavailable; timing-model equivalence requires review"
    changed = [path for path in sources.keys() | ref_sources.keys()
               if path.startswith("sim/") and sources.get(path) != ref_sources.get(path)]
    if changed:
        return "simulator source changes require review: " + ", ".join(sorted(changed))
    return "matching simulator sources; hardware/configuration or build may differ"


def render(runs, verbose=False):
    reference = runs[0]
    lines = ["Values are cycles unless specified; percentages are change versus the first column "
             "(negative is faster). Memprobe values are cycles/access. Bounds are not exact timings.", ""]
    if any(run["logs"].get("mp", {}).get("memprobe_details") for run in runs):
        lines += ["Memprobe cells retain the printed values; ratios use raw cycles/steps when both "
                  "runs provide valid details, otherwise the printed values. Truncated cell values "
                  "may not reproduce the raw-count ratio.", ""]
    lines += ["| Workload status | " + " | ".join(run["name"] for run in runs) + " |",
              "|---|" + "---|" * len(runs)]
    for workload in ("mp", "pf", "cm", "eb", "lx"):
        states = []
        for run in runs:
            if workload == "eb":
                logs = [run["logs"].get("eb-" + bench, {}) for bench in BENCHMARKS]
                counts = {status: sum(log.get("status", "MISSING") == status for log in logs)
                          for status in ("PASS", "PARTIAL", "FAILED", "MISSING")}
                states.append(", ".join(f"{n} {status.lower()}" for status, n in counts.items() if n))
            else:
                states.append(run["logs"].get(workload, {}).get("status", "MISSING"))
        lines.append("| " + workload + " | " + " | ".join(states) + " |")
    keys = set().union(*(run["metrics"].keys() | run["intervals"].keys() for run in runs))
    if not verbose:
        keys = {key for key in keys if not key.startswith("Embench ") or "geomean" in key}
    lines += ["", "| Metric | " + " | ".join(run["name"] for run in runs) + " |",
              "|---|" + "---:|" * len(runs)]
    for key in sorted(keys):
        lines.append("| " + key.replace("|", "\\|") + " | "
                     + " | ".join(cell(run, key, reference) for run in runs) + " |")
    lines += ["", "Embench geomeans require all 19 benchmark logs to pass. Missing/failed runs "
              "never become zero-cycle results. Partial bare-metal runs receive no ratios. "
              "Exact Linux milestones remain valid completed phases when boot is partial; "
              "ratios require matching latency, memory options, XLEN, and image hashes in "
              "manifest.json. Missing or mismatched metadata retains raw values only."]
    if len(runs) > 1:
        lines += ["", "Simulator provenance versus the first column (separate from workload checks):"]
        lines += ["- " + run["name"] + ": " + provenance_note(run, reference) for run in runs[1:]]
    if any(run["logs"].get("cm", {}).get("status") == "PASS (CRC-valid short ROI)" for run in runs):
        lines += ["", "CoreMark short ROIs have verified two-iteration CRCs, but fail the official "
                  "10-second duration rule. Their cycles are timing comparisons, not official scores."]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tags", nargs="+", help="reference tag followed by comparison tags")
    parser.add_argument("-v", "--verbose", action="store_true", help="include each Embench benchmark")
    parser.add_argument("--logs-root", type=Path, default=Path(__file__).resolve().parent.parent / "logs")
    parser.add_argument("--json", action="store_true", help="emit structured metrics and PMU excerpts")
    args = parser.parse_args()
    reference = load_tag(args.logs_root, args.tags[0])
    if len(reference) != 1:
        parser.error("reference tag has multiple run directories; select one with tag/subdirectory")
    runs = reference + [run for tag in args.tags[1:] for run in load_tag(args.logs_root, tag)]
    print(json.dumps(runs, indent=2) if args.json else render(runs, args.verbose))


if __name__ == "__main__":
    main()
