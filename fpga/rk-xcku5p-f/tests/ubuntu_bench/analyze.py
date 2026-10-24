#!/usr/bin/env python3
"""Decode profile.c's PERF_SAMPLE_IP|TIME stream and summarize native runs."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import subprocess


def records(data):
    """Yield (kind, misc, payload), rejecting truncated or invalid records."""
    offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError("truncated perf header")
        kind, misc, size = struct.unpack_from("<IHH", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("invalid perf record size")
        payload = data[offset + 8:offset + size]
        if kind == 9 and len(payload) != 16:
            raise ValueError("expected IP|TIME sample")
        if kind == 2 and len(payload) != 16:
            raise ValueError("expected ID|LOST record")
        yield kind, misc, payload
        offset += size


def read_metrics(path):
    lines = path.read_text().splitlines()
    metrics = [json.loads(s.removeprefix("PROFILE_JSON ")) for s in lines
               if s.startswith("PROFILE_JSON ")]
    if len(metrics) != 1:
        raise ValueError(f"expected one metric record: {path}")
    result = metrics[0]
    result["cpi_hart_inclusive"] = result["hart_cycles"] / result["hart_instructions"]
    result["ipc_hart_inclusive"] = result["hart_instructions"] / result["hart_cycles"]
    result["cpu_fraction"] = (result["user_us"] + result["system_us"]) * 1000 / result["wall_ns"]
    result["validation"] = [s for s in lines if s.startswith("EMBENCH_VERIFY ") or
                            s.startswith("Correct operation validated")]
    return result


def executable_maps(path):
    result = []
    for line in path.read_text().splitlines():
        fields = line.split(maxsplit=5)
        if "x" not in fields[1]:
            continue
        start, end = (int(x, 16) for x in fields[0].split("-"))
        result.append((start, end, int(fields[2], 16), fields[5] if len(fields) > 5 else "[anonymous]"))
    return result


def symbolize(binary, addresses, cross):
    if not addresses:
        return {}
    addresses = sorted(addresses)
    output = subprocess.check_output([cross + "addr2line", "-f", "-C", "-e", str(binary),
                                      *[hex(x) for x in addresses]], text=True).splitlines()
    if len(output) != 2 * len(addresses):
        raise ValueError("unexpected addr2line response")
    return {ip: (output[2 * i], output[2 * i + 1]) for i, ip in enumerate(addresses)}


def containing_symbol(address, symbols):
    # Do not let addr2line's nearest exported symbol mislabel stripped libc code.
    return next((name for start, size, name in symbols if start <= address < start + size),
                "[unresolved text]")


def analyze_samples(binary, prefix, cross, rootfs=None):
    ips, modes = Counter(), Counter()
    lost, unknown = 0, Counter()
    for kind, misc, payload in records(prefix.with_suffix(".samples").read_bytes()):
        if kind == 9:
            ip, timestamp = struct.unpack("<QQ", payload)
            mode = misc & 7
            ips[(mode, ip)] += 1
            modes[mode] += 1
        elif kind == 2:
            lost += struct.unpack("<QQ", payload)[1]
        else:
            unknown[kind] += 1
    maps = executable_maps(prefix.with_suffix(".maps"))
    own = {ip for mode, ip in ips if mode == 2 and
           any(start <= ip < end and Path(name).name == binary.name for start, end, _, name in maps)}
    symbols = symbolize(binary, own, cross)
    libraries = {}
    if rootfs:
        for start, end, offset, name in maps:
            target = rootfs / name.lstrip("/")
            if not name.startswith("/") or Path(name).name == binary.name or not target.is_file():
                continue
            relative_ips = {ip - start + offset for mode, ip in ips
                            if mode == 2 and start <= ip < end}
            symbols_text = subprocess.check_output([cross + "nm", "-D", "-S", str(target)], text=True)
            exported = []
            for row in symbols_text.splitlines():
                fields = row.split()
                if len(fields) == 4 and fields[2] in ("T", "W", "t", "w"):
                    exported.append((int(fields[0], 16), int(fields[1], 16), fields[3].split("@")[0]))
            libraries.update({relative + start - offset:
                              (f"{Path(name).name}:{containing_symbol(relative, exported)}", "??:?")
                              for relative in relative_ips})
    functions, lines = Counter(), Counter()
    detailed = []
    for (mode, ip), count in ips.items():
        if ip in own and mode == 2:
            function, line = symbols[ip]
        elif ip in libraries and mode == 2:
            function, line = libraries[ip]
        elif mode == 2:
            function = next((name for start, end, _, name in maps if start <= ip < end), "[unmapped user]")
            line = function
        else:
            function = f"[perf mode {mode}]"
            line = function
        functions[function] += count
        lines[(function, line)] += count
        detailed.append({"pc": hex(ip), "mode": mode, "count": count, "function": function, "line": line})
    total = sum(modes.values())
    return {"samples": total, "mode_counts": dict(modes), "lost_records": lost,
            "unknown_records": dict(unknown),
            "functions": [{"name": name, "count": count, "percent": 100 * count / total}
                          for name, count in functions.most_common()],
            "lines": [{"function": fn, "line": line, "count": count, "percent": 100 * count / total}
                      for (fn, line), count in lines.most_common()],
            "pcs": sorted(detailed, key=lambda x: x["count"], reverse=True)}


def summarize(binaries, results, cross, rootfs=None):
    manifest = json.loads((binaries / "manifest.json").read_text())
    summary = {}
    for name in manifest["binaries"]:
        case = {}
        for stage in ("baseline", "profile", "baseline-long"):
            prefix = results / f"{name}-{stage}"
            if not prefix.with_suffix(".exit").exists():
                continue
            if prefix.with_suffix(".exit").read_text().strip() != "0":
                raise ValueError(f"benchmark failed: {prefix}")
            case[stage] = read_metrics(prefix.with_suffix(".log"))
            if stage == "profile":
                case["hotspots"] = analyze_samples(binaries / name, prefix, cross, rootfs)
        if "profile" in case and "baseline-long" in case:
            case["sampling_wall_delta_percent"] = 100 * (
                case["profile"]["wall_ns"] / case["baseline-long"]["wall_ns"] - 1)
        repeats = sorted(results.glob(f"{name}-control-repeat-*.log"))
        repeats += sorted(results.glob(f"{name}-repeat-*.log"))
        if repeats:
            case["extra_unsampled_runs"] = {p.name: read_metrics(p) for p in repeats}
        summary[name] = case
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cross", default="riscv64-linux-gnu-")
    parser.add_argument("--rootfs", type=Path, help="matching target rootfs, for shared-library symbols")
    args = parser.parse_args()
    summary = summarize(args.binaries, args.results, args.cross, args.rootfs)
    args.output.write_text(json.dumps(summary, indent=2) + "\n")
    for name, case in summary.items():
        if "hotspots" in case:
            metric = case.get("baseline-long", case["baseline"])
            top = "; ".join(f'{x["name"]} {x["percent"]:.1f}%' for x in case["hotspots"]["functions"][:4])
            print(f'{name:16} CPI={metric["cpi_hart_inclusive"]:.2f} samples={case["hotspots"]["samples"]} {top}')
