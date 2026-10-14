#!/usr/bin/env python3
"""Parse simulator logs and render GitHub job summaries for Raptor CI.

Every sub-command reads plain logs (ANSI colour is ignored), prints Markdown or
key=value lines on stdout and reports validation through its exit status, so a
workflow step is `python3 ci_report.py ... >> "$GITHUB_STEP_SUMMARY"`.

  metrics KIND LOG                 key=value metrics (coremark|microbench|archtest|sta)
  bench TITLE LABEL=KIND:LOG...    benchmark table (score, CoreMark/MHz, IPC, trap)
  archtest LABEL=LOG...            architecture-test pass/fail table
  sta XLEN PLATFORM LOG            STA Fmax/area/power table
  pmu LABEL LOG [LABEL LOG...]     collapsible PMU counter blocks
  boot TITLE LOG CHECK=MARKER...   boot-marker checks; fails if any marker is absent
  coremark-pk HELLO LOG ...        CRC-checked pk CoreMark (published CRC lines)
  coremark-am LOG                  CRC-checked AM CoreMark (CoreMark's own profile check)
  litex-coremark LOG               LiteX CoreMark smoke summary (never fails)
"""
import argparse
from pathlib import Path
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
NA = "N/A"
SHORT_RUN = "ERROR! Must execute for at least 10 secs for a valid result!"
# known_id=3 in CoreMark core_main.c: 2K, seeds 0/0/0x66.
EXPECTED_CRC = {"seedcrc": 0xE9F5, "crclist": 0xE714,
                "crcmatrix": 0x1FD7, "crcstate": 0x8E3A}


def read(path):
    path = Path(path)
    return ANSI.sub("", path.read_text(errors="replace")) if path.is_file() else ""


def first(pattern, text, flags=re.MULTILINE, default=NA):
    match = re.search(pattern, text, flags)
    return match.group(1) if match else default


def last(pattern, text, flags=re.MULTILINE, default=NA):
    matches = re.findall(pattern, text, flags)
    return matches[-1] if matches else default


def trap(log):
    return first(r"(HIT (?:GOOD|BAD) TRAP|NPC QUIT)", log, default="UNKNOWN")


def metrics(kind, log):
    """Key metrics of one log; unknown values are N/A, never an exception."""
    common = {"ipc": first(r"IPC:\s*([0-9.]+)", log),
              "cycles": first(r"cycle:\s*(\d+)", log),
              "insts": first(r"#inst:\s*(\d+)", log),
              "trap": trap(log)}
    if kind == "coremark":
        iterations = first(r"^\s*Iterations\s*:\s*(\d+)", log)
        per_mhz = last(r"^CoreMark/MHz\s*:\s*([0-9]+(?:\.[0-9]+)?)", log)
        if per_mhz == NA and iterations.isdigit() and common["cycles"].isdigit() \
                and int(common["cycles"]) > 0:
            per_mhz = f"{int(iterations) * 1e6 / int(common['cycles']):.4f}"
        score = first(r"CoreMark PASS\s+(\d+)", log)
        if score == NA:
            score = first(r"(\d+)(?:/1000)? Marks", log)
        return {"score": score, "iterations": iterations, "coremark_per_mhz": per_mhz,
                **common}
    if kind == "microbench":
        return {"result": first(r"MicroBench (PASS|FAIL)", log, default="UNKNOWN"),
                "score": last(r"(\d+)(?= Marks)", log), **common}
    if kind == "archtest":
        return {"pass": str(log.count("HIT GOOD TRAP")), "fail": str(log.count("HIT BAD TRAP"))}
    if kind == "sta":
        return {"freq_mhz": first(r"fmax\s*=\s*([0-9.]+)", log),
                "area": first(r"Chip area for module.*?:\s*([0-9.]+)", log),
                "power": first(r"^Total\s+\S+\s+\S+\s+\S+\s+(\S+)", log)}
    raise ValueError(f"unknown metrics kind: {kind}")


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows]
    return "\n".join(lines)


def split_spec(spec, sep):
    label, _, rest = spec.partition("=")
    if not rest or (sep and sep not in rest):
        raise SystemExit(f"malformed row {spec!r}")
    return (label, *rest.split(sep, 1)) if sep else (label, rest)


def cmd_bench(args):
    rows = []
    for spec in args.rows:
        label, kind, path = split_spec(spec, ":")
        m = metrics(kind, read(path))
        per_mhz = (f"{m['coremark_per_mhz']} ({m['iterations']} iterations)"
                   if kind == "coremark" else NA)
        rows.append([label, m["score"], per_mhz, m["ipc"], m["cycles"], m["insts"], m["trap"]])
    print(f"\n## {args.title}\n")
    print(table(["Benchmark", "Score", "CoreMark/MHz", "IPC", "Cycles", "Instructions",
                 "Status"], rows))
    return 0


def cmd_archtest(args):
    rows = []
    for spec in args.rows:
        label, path = split_spec(spec, None)
        m = metrics("archtest", read(path))
        rows.append([label, m["pass"], m["fail"]])
    print("\n## RISC-V Architecture Tests\n")
    print(table(["Target", "Passed", "Failed"], rows))
    return 0


def cmd_sta(args):
    m = metrics("sta", read(args.log))
    print(f"\n## STA Results ({args.xlen} / {args.platform})\n")
    print(table(["Metric", "Value"], [["ISA", args.xlen], ["PDK", args.platform],
                                      ["Fmax", f"{m['freq_mhz']} MHz"], ["Area", m["area"]],
                                      ["Power", f"{m['power']} W"]]))
    return 0


def pmu_block(label, log):
    lines = [re.sub(r"^.*?pmu\.cc:\d+ \S+ ", "", line)
             for line in log.splitlines() if re.search(r"pmu\.cc:\d+ \S+ ", line)]
    if not lines:
        return ""
    return "\n".join(["<details>", f"<summary>PMU Details: {label}</summary>", "", "```",
                      *lines, "```", "</details>", ""])


def cmd_pmu(args):
    if len(args.pairs) % 2:
        raise SystemExit("pmu expects LABEL LOG pairs")
    for label, path in zip(args.pairs[::2], args.pairs[1::2]):
        block = pmu_block(label, read(path))
        if block:
            print(block)
    return 0


def cmd_boot(args):
    log = read(args.log)
    checks = [split_spec(spec, None) for spec in args.checks]
    rows = [[name, "PASS" if marker in log else "FAIL"] for name, marker in checks]
    print(f"\n## {args.title}\n")
    print(table(["Check", "Status"], rows))
    m = metrics("coremark", log)
    if any(m[key] != NA for key in ("ipc", "insts", "cycles")):
        print()
        print(table(["Metric", "Value"], [["IPC", m["ipc"]], ["Instructions", m["insts"]],
                                          ["Cycles", m["cycles"]]]))
    print()
    return 0 if all(row[1] == "PASS" for row in rows) else 1


def field(log, label, pattern=r"\d+", base=10, spaced=False):
    padding = r"\s+" if spaced else r"\s*"
    matches = re.findall(r"^" + re.escape(label) + padding + r":\s*(" + pattern + r")\s*$",
                         log, re.MULTILINE)
    return int(matches[0], base) if len(matches) == 1 else None


def good_trap(log):
    return re.findall(r"HIT (?:GOOD|BAD) TRAP", log) == ["HIT GOOD TRAP"]


def evaluate_pk(log, expected_iterations, allow_short, timebase_hz=10_000_000):
    """Validate the 2K profile from the pk port's published CRC/timing lines."""
    errors = []
    # The outer Makefile prints another Iterations/score table after the run.
    measurement = log.partition("CoreMark: done.")[0]
    if not good_trap(log):
        errors.append("missing, duplicate, or bad final trap")
    for name, expected in EXPECTED_CRC.items():
        label = name if name == "seedcrc" else "[0]" + name
        if field(measurement, label, r"0x[0-9a-fA-F]+", 16) != expected:
            errors.append(f"{name} missing or mismatched")
    final_crc = field(measurement, "[0]crcfinal", r"0x[0-9a-fA-F]+", 16)
    if final_crc is None:
        errors.append("missing final CRC")
    if field(measurement, "CoreMark Size") != 666:
        errors.append("unexpected CoreMark size")
    iterations = field(measurement, "Iterations", spaced=True)
    if iterations != expected_iterations:
        errors.append("unexpected iteration count (possibly stale binary)")
    if iterations == 1 and final_crc != EXPECTED_CRC["crclist"]:
        errors.append("one-iteration final CRC mismatched")
    cycles = field(measurement, "CoreMark ROI cycles")
    instructions = field(measurement, "CoreMark ROI instructions")
    if not cycles or not instructions:
        errors.append("missing or zero ROI counters")
    ticks = field(measurement, "Total ticks")
    seconds = field(measurement, "Total time (secs)")
    timer_hz = field(measurement, "CoreMark timer Hz")
    if (timer_hz != timebase_hz or ticks is None or ticks <= 0
            or seconds is None or seconds != ticks // timebase_hz):
        errors.append("missing or inconsistent timer frequency/timing")
    lines = log.splitlines()
    short = lines.count(SHORT_RUN) == 1 and seconds is not None and 0 <= seconds < 10
    diagnostics = [line for line in lines if re.search(r"ERROR|Errors detected|Cannot validate", line)]
    if short:
        if not allow_short:
            errors.append("run shorter than the standard 10-second requirement")
        if diagnostics != [SHORT_RUN, "Errors detected"]:
            errors.append("additional or incomplete CoreMark error diagnostics")
        if "Correct operation validated" in log:
            errors.append("conflicting validation results")
    elif (diagnostics or "Correct operation validated" not in log
          or seconds is None or seconds < 10):
        errors.append("standard validation missing or failed")
    if lines.count("CoreMark: done.") != 1:
        errors.append("missing or duplicate completion marker")
    return {"errors": errors, "short": short, "iterations": iterations,
            "ticks": ticks, "timer_hz": timer_hz, "seconds": seconds, "cycles": cycles,
            "instructions": instructions}


def cmd_coremark_pk(args):
    hello_ok = good_trap(read(args.hello))
    result = evaluate_pk(read(args.log), args.expected_iterations, args.allow_short,
                         args.timebase_hz)
    ok = not result["errors"]
    status = ("SMOKE PASS" if result["short"] else "PASS") if ok else "FAIL"
    standard = ("NOT VALID (less than 10 seconds)" if result["short"]
                else ("VALID" if ok else "NOT VALID"))
    # Use the measured loop interval, excluding pk startup and reporting.
    estimate = f'{result["iterations"] * 1e6 / result["cycles"]:.4f}' if ok else NA
    estimate_label = ("Smoke estimate (iterations × 1e6 / ROI cycles)" if result["short"]
                      else "CoreMark/MHz")
    rows = [["Standard CoreMark validation", standard], [estimate_label, estimate]]
    rows += [[key, NA if result[key] is None else result[key]]
             for key in ("iterations", "timer_hz", "ticks", "seconds", "cycles", "instructions")]
    print("\n## App Tests — CoreMark (pk on sim)\n")
    print(table(["Test", "Status"], [["Hello", "PASS" if hello_ok else "FAIL"],
                                     ["CoreMark functional check", status]]))
    print()
    print(table(["Metric", "Value"], rows))
    print("\n" + "".join(f"- {error}\n" for error in result["errors"]))
    return 0 if hello_ok and ok else 1


def evaluate_am(log, iterations=1):
    """AM klib cannot print %04x CRCs; rely on CoreMark's internal profile check."""
    errors = []
    for label, value in (("Iterations", str(iterations)), ("CoreMark Size", "666")):
        found = re.findall(r"^" + re.escape(label) + r"\s*:\s*(\S+)\s*$", log, re.M)
        if not found or any(item.lower() != value for item in found):
            errors.append(f"{label}={found}, expected {value}")
    if not good_trap(log):
        errors.append("missing, duplicate, or bad final trap")
    if "2K performance run parameters for coremark." not in log:
        errors.append("no known CRC validation profile selected")
    if any("ERROR!" in line and line.strip() != SHORT_RUN for line in log.splitlines()):
        errors.append("additional CoreMark validation error")
    if SHORT_RUN in log:
        if log.count(SHORT_RUN) != 1 or log.count("Errors detected") != 1:
            errors.append("incomplete short-run validation summary")
    elif log.count("Correct operation validated.") != 1 or "Errors detected" in log:
        errors.append("CRC validation failed")
    return errors


def cmd_coremark_am(args):
    errors = evaluate_am(read(args.log), args.iterations)
    verdict = "PASS" if not errors else "FAIL"
    print(f"\nCoreMark CRC smoke ({args.iterations} iteration(s); not a benchmark score): "
          f"{verdict}\n" + "".join(f"- {error}\n" for error in errors))
    return 0 if not errors else 1


def cmd_litex_coremark(args):
    log = read(args.log)
    iterations = first(r"Iterations\s*:\s*(\d+)", log)
    if "Correct operation validated" in log:
        validation = "PASS"
    elif iterations == "2":
        validation = "SMOKE (score validation skipped)"
    else:
        validation = "FAIL"
    print("\n## LiteX CoreMark Results\n")
    print(table(["Metric", "Value"], [
        ["CPU", first(r"CPU:\s*(.+)", log)],
        ["CoreMark Score (Iter/s)", first(r"Iterations/Sec\s*:\s*([0-9.]+)", log)],
        ["Iterations", iterations],
        ["Total Ticks", first(r"Total ticks\s*:\s*(\d+)", log)],
        ["Total Time (s)", first(r"Total time \(secs\):\s*([0-9.]+)", log)],
        ["Validation", validation]]))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("metrics")
    p.add_argument("kind", choices=("coremark", "microbench", "archtest", "sta"))
    p.add_argument("log")
    p = sub.add_parser("bench")
    p.add_argument("title")
    p.add_argument("rows", nargs="+", metavar="LABEL=KIND:LOG")
    p = sub.add_parser("archtest")
    p.add_argument("rows", nargs="+", metavar="LABEL=LOG")
    p = sub.add_parser("sta")
    p.add_argument("xlen")
    p.add_argument("platform")
    p.add_argument("log")
    p = sub.add_parser("pmu")
    p.add_argument("pairs", nargs="+", metavar="LABEL LOG")
    p = sub.add_parser("boot")
    p.add_argument("title")
    p.add_argument("log")
    p.add_argument("checks", nargs="+", metavar="CHECK=MARKER")
    p = sub.add_parser("coremark-pk")
    p.add_argument("hello")
    p.add_argument("log")
    p.add_argument("--expected-iterations", type=int, required=True)
    p.add_argument("--timebase-hz", type=int, default=10_000_000,
                   help="expected CLINT/DTS timebase (default sim: 10 MHz)")
    p.add_argument("--allow-short", action="store_true",
                   help="accept CRC-checked smoke runs; never certify a standard score")
    p = sub.add_parser("coremark-am")
    p.add_argument("log")
    p.add_argument("--iterations", type=int, default=1)
    p = sub.add_parser("litex-coremark")
    p.add_argument("log")
    args = parser.parse_args(argv)
    if args.command == "metrics":
        for key, value in metrics(args.kind, read(args.log)).items():
            print(f"{key}={value}")
        return 0
    if args.command == "coremark-pk":
        if args.timebase_hz <= 0 or args.expected_iterations <= 0:
            parser.error("--timebase-hz and --expected-iterations must be positive")
    handler = {"bench": cmd_bench, "archtest": cmd_archtest, "sta": cmd_sta, "pmu": cmd_pmu,
               "boot": cmd_boot, "coremark-pk": cmd_coremark_pk, "coremark-am": cmd_coremark_am,
               "litex-coremark": cmd_litex_coremark}[args.command]
    return handler(args)


if __name__ == "__main__":
    sys.exit(main())
