#!/usr/bin/env python3
"""Content-addressed module FPGA evaluation and conservative report collection."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

SCRIPTS = Path(__file__).resolve().parent
RESOURCE_COLUMNS = ("Total LUTs", "FFs", "RAMB36", "RAMB18", "URAM", "DSP Blocks")
REQUIRED_ARTIFACTS = {
    "export": ("elaborated.v", "run.profile"),
    "synth": ("synth.dcp", "utilization.rpt", "timing.rpt", "constraints.rpt", "run.profile"),
    "place": ("place.dcp", "utilization.rpt", "timing.rpt", "context.tsv", "run.profile"),
    "route": ("route.dcp", "utilization.rpt", "timing.rpt", "context.tsv", "run.profile"),
}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def file_hash(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def hashes(paths):
    return {path: file_hash(path) for path in sorted({str(Path(p).resolve()) for p in paths})}


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


@contextmanager
def lock(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError(f"Output is already in use: {directory}") from exc
        yield


def valid_entry(directory, key):
    try:
        record = json.loads((directory / "complete.json").read_text())
        return (
            record["key"] == key
            and bool(record["artifacts"])
            and all(file_hash(directory / name) == sha for name, sha in record["artifacts"].items())
        )
    except (OSError, ValueError, KeyError):
        return False


def cached_phase(cache, name, specification, action, inputs):
    key = digest(specification)
    directory = cache / name / key
    with lock(directory):
        if valid_entry(directory, key):
            print(f"[fpga-eval] reuse {name} {key[:12]}", flush=True)
            return directory, True
        # Retain logs from failed attempts until the next explicit retry.
        for child in directory.iterdir():
            if child.name == ".lock":
                continue
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
        write_json(directory / "input.json", specification)
        print(f"[fpga-eval] run {name} {key[:12]}", flush=True)
        action(directory)
        for artifact in REQUIRED_ARTIFACTS.get(name, ()):
            if not (directory / artifact).is_file() or (directory / artifact).stat().st_size == 0:
                raise RuntimeError(f"Missing required {name} artifact: {directory / artifact}")
        if any(file_hash(path) != sha for path, sha in inputs.items()):
            raise RuntimeError(f"Sources changed during {name}; incomplete result: {directory}")
        artifacts = {
            str(path.relative_to(directory)): file_hash(path)
            for path in sorted(directory.iterdir())
            if path.is_file() and path.name != ".lock"
        }
        write_json(directory / "complete.json", {"key": key, "artifacts": artifacts})
        return directory, False


def execute(command, directory, env, timeout, time_tool):
    command = [time_tool, "-o", str(directory / "run.profile"),
               "-f", "status=%x\nelapsed_sec=%e\nmax_rss_kb=%M", *command]
    with (directory / "console.log").open("w") as log:
        process = subprocess.Popen(command, cwd=directory, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout or None)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise RuntimeError(f"Stopped or timed out; incomplete result: {directory}")
    if code:
        tail = "\n".join((directory / "console.log").read_text(errors="replace").splitlines()[-35:])
        raise RuntimeError(f"Command failed ({code}): {directory}\n{tail}")


def resources(report, top):
    header = None
    for line in report.read_text().splitlines():
        if not line.startswith("|"):
            continue
        row = [cell.strip() for cell in line.strip("|").split("|")]
        if row[0] == "Instance" and "Total LUTs" in row:
            header = row
        elif header and row[0] == top and len(row) == len(header):
            values = dict(zip(header, row))
            return {key: int(values[key].replace(",", "")) for key in RESOURCE_COLUMNS}
    raise ValueError(f"Missing resource row for {top}: {report}")


def timing(report):
    lines = report.read_text().splitlines()
    for index, line in enumerate(lines):
        if line.strip().startswith("WNS(ns)") and "TNS(ns)" in line:
            for candidate in lines[index + 1:index + 6]:
                values = candidate.split()
                if len(values) >= 8:
                    try:
                        result = {key: float(values[col]) for key, col in
                                  (("wns_ns", 0), ("tns_ns", 1), ("whs_ns", 4), ("ths_ns", 5))}
                        if all(math.isfinite(value) for value in result.values()):
                            return result
                    except ValueError:
                        pass
    # A combinational/empty design may have no timed paths. Do not turn N/A into a pass.
    return {key: None for key in ("wns_ns", "tns_ns", "whs_ns", "ths_ns")}


def profile(directory):
    data = dict(line.split("=", 1) for line in (directory / "run.profile").read_text().splitlines())
    return {"elapsed_sec": float(data["elapsed_sec"]), "max_rss_kb": int(data["max_rss_kb"])}


def validate_context(path):
    # Ignore comment-only lines, which commonly describe a clock "source".
    commands = "\n".join(line for line in path.read_text().splitlines()
                         if not line.lstrip().startswith("#"))
    if re.search(r"\b(source|read_xdc|read_checkpoint)\b", commands):
        raise ValueError("FPGA_CONTEXT_XDC must be self-contained (no source/read_xdc/read_checkpoint)")


def configuration():
    names = ("root", "module", "top", "config", "xlen", "part", "period", "io_frac",
             "clock", "threads", "synth_directive", "flags", "sources", "headers",
             "yosys", "vivado", "time")
    config = {name: os.environ["EVAL_" + name.upper()] for name in names}
    if config["xlen"] not in ("32", "64"):
        raise ValueError("FPGA_XLEN must be 32 or 64")
    if not 1 <= int(config["threads"]) <= 8:
        raise ValueError("FPGA_THREADS must be between 1 and 8")
    period, fraction = float(config["period"]), float(config["io_frac"])
    if not math.isfinite(period) or period <= 0 or not 0 <= fraction < 0.5:
        raise ValueError("Invalid period or IO delay fraction")
    flags = shlex.split(config["flags"])
    rv64 = [flag for flag in flags if flag == "-DRAPT_RV64" or flag.startswith("-DRAPT_RV64=")]
    if (config["xlen"] == "32" and rv64) or any(flag == "-URAPT_RV64" for flag in flags):
        raise ValueError("EXTRA_DEFINES conflicts with FPGA_XLEN")
    return config


def run(args):
    config = configuration()
    if args.timeout < 0 or not math.isfinite(args.timeout):
        raise ValueError("FPGA_PHASE_TIMEOUT must be finite and nonnegative")
    output, cache = args.output.resolve(), args.cache.resolve()
    if output == cache or cache in output.parents or output in cache.parents:
        raise ValueError("Result and cache directories must not contain each other")
    with lock(output):
        (output / "status.txt").write_text("status incomplete\n")
        started = time.monotonic()
        sources = shlex.split(config["sources"])
        headers = shlex.split(config["headers"])
        root = Path(config["root"])
        flow_files = [SCRIPTS / "fpga_eval.py", SCRIPTS / "fpga_synth.tcl",
                      SCRIPTS / "fpga_impl.tcl", SCRIPTS / "check_fpga_ram_mapping.py",
                      SCRIPTS.parent / "fpga_ram_expectations.tsv",
                      SCRIPTS.parent / "Makefile", SCRIPTS.parent / "fpga_eval.mk",
                      root / "lspd/modules.mk"]
        flow_files.extend(sorted((root / "lspd/hdl_wrapper").glob("*.sv")))
        context = Path(args.context_xdc).resolve() if args.context_xdc else None
        # A context file is deliberately self-contained so its hash covers the constraints.
        if context:
            validate_context(context)
        inputs = hashes([*sources, *headers, *flow_files, *([context] if context else [])])
        tool_versions = {}
        for name, option in (("yosys", "-V"), ("vivado", "-version")):
            tool_versions[name] = subprocess.check_output(
                [*shlex.split(config[name]), option], text=True, stderr=subprocess.STDOUT).strip()
        common = {name: config[name] for name in
                  ("module", "top", "config", "xlen", "part", "period", "io_frac",
                   "clock", "threads", "synth_directive")}
        common["defines"] = [flag for flag in shlex.split(config["flags"]) if not flag.startswith("-I")]
        common["memory_model"] = "behavioral"
        common["tools"] = tool_versions
        env = dict(os.environ)
        env.update({"FPGA_TOP": config["top"], "FPGA_PART": config["part"],
                    "FPGA_THREADS": config["threads"], "FPGA_CLOCK": config["clock"],
                    "FPGA_PERIOD": config["period"], "FPGA_IO_FRAC": config["io_frac"],
                    "FPGA_SYNTH_DIRECTIVE": config["synth_directive"]})
        stages = {}

        def evaluate(name, spec, action):
            directory, reused = cached_phase(cache, name, spec, action, inputs)
            stages[name] = {"directory": str(directory), "key": directory.name,
                            "reused": reused, **profile(directory)}
            return directory

        def export_action(directory):
            # Match the existing Slang flow; filenames in this Make source list
            # cannot contain whitespace or Yosys command separators.
            if any(re.search(r'[\s;"\\]', path) for path in sources):
                raise ValueError("Unsupported source filename in Slang input list")
            files = " ".join(sources)
            program = (f'read_slang {config["flags"]} --top {config["top"]} {files}; '
                       f'hierarchy -check -top {config["top"]}; '
                       'select -assert-none t:$check t:$assert t:$assume t:$cover; '
                       'proc; opt; bwmuxmap; check -assert; write_verilog elaborated.v')
            execute([*shlex.split(config["yosys"]), "-Q", "-T", "-m", "slang", "-p", program],
                    directory, env, args.timeout, config["time"])

        exported = evaluate("export", {"sources": hashes([*sources, *headers]),
                                      "flags": config["flags"], "top": config["top"],
                                      "yosys": tool_versions["yosys"],
                                      "driver": inputs[str(SCRIPTS / "fpga_eval.py")]}, export_action)

        def vivado(directory, script, extra):
            execute([*shlex.split(config["vivado"]), "-mode", "batch", "-nojournal",
                     "-log", "vivado.log", "-source", str(script)], directory,
                    {**env, "FPGA_OUT": str(directory), **extra}, args.timeout, config["time"])

        def synth_action(directory):
            shutil.copyfile(exported / "elaborated.v", directory / "elaborated.v")
            vivado(directory, SCRIPTS / "fpga_synth.tcl", {})
            subprocess.run([sys.executable, str(SCRIPTS / "check_fpga_ram_mapping.py"),
                            "--manifest", str(SCRIPTS.parent / "fpga_ram_expectations.tsv"),
                            "--report", str(directory / "utilization.rpt"), "--module", config["module"],
                            "--config", config["config"], "--xlen", config["xlen"],
                            "--top", config["top"], "--defines=" + config["flags"]], check=True)

        synth_spec = {"config": common, "netlist": file_hash(exported / "elaborated.v"),
                      "flow": hashes([SCRIPTS / "fpga_synth.tcl", SCRIPTS / "fpga_eval.py",
                                      SCRIPTS / "check_fpga_ram_mapping.py",
                                      SCRIPTS.parent / "fpga_ram_expectations.tsv"])}
        final = evaluate("synth", synth_spec, synth_action)
        for stage in ("place", "route"):
            if args.stage == "synth" or (stage == "route" and args.stage == "place"):
                break
            input_dcp = final / ("synth.dcp" if stage == "place" else "place.dcp")
            spec = {"checkpoint": file_hash(input_dcp), "mode": args.mode, "stage": stage,
                    "context": file_hash(context) if context else None,
                    "threads": config["threads"], "tools": tool_versions,
                    "clock": config["clock"],
                    "flow": hashes([SCRIPTS / "fpga_impl.tcl", SCRIPTS / "fpga_eval.py"])}

            def impl_action(directory):
                if context:
                    shutil.copyfile(context, directory / "context.xdc")
                vivado(directory, SCRIPTS / "fpga_impl.tcl",
                       {"FPGA_INPUT_DCP": str(input_dcp), "FPGA_IMPL_STAGE": stage,
                        "FPGA_IMPL_MODE": args.mode,
                        "FPGA_CONTEXT_XDC": str(directory / "context.xdc") if context else ""})

            final = evaluate(stage, spec, impl_action)
        if any(file_hash(path) != sha for path, sha in inputs.items()):
            raise RuntimeError("Sources changed during evaluation; result remains incomplete")
        context_metrics = {}
        if args.stage != "synth":
            context_metrics = dict(line.split("\t", 1) for line in
                                   (final / "context.tsv").read_text().splitlines())
        record = {"schema": 1, "config": common, "stage": args.stage, "mode": args.mode,
                  "context_sha256": file_hash(context) if context else None,
                  "source_manifest": inputs,
                  "flow_sha256": digest({str(path): inputs[str(path)] for path in flow_files}),
                  "rtl_sha256": digest(hashes([p for p in [*sources, *headers]
                                               if Path(p).is_relative_to(root / "hdl")])),
                  "revision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"],
                                                      text=True).strip(),
                  "stages": stages, "resources": resources(final / "utilization.rpt", config["top"]),
                  "timing": timing(final / "timing.rpt"), "context": context_metrics,
                  "wall_sec": round(time.monotonic() - started, 3),
                  "reports": str(final)}
        write_json(output / "result.json", record)
        (output / "status.txt").write_text("status ok\n")
        print(f"[fpga-eval] complete ({args.stage}, {args.mode}): {output / 'result.json'}")


def load_result(directory):
    if (directory / "status.txt").read_text().strip() != "status ok":
        raise ValueError(f"Incomplete evaluation: {directory}")
    record = json.loads((directory / "result.json").read_text())
    if record["schema"] != 1 or not record["stages"]:
        raise ValueError(f"Unsupported or empty result: {directory}")
    for stage in record["stages"].values():
        if not valid_entry(Path(stage["directory"]), stage["key"]):
            raise ValueError(f"Missing or modified cache artifacts: {stage['directory']}")
    return record


def sum_compositions(records):
    # This is the only known disjoint registry cut; arbitrary leaves can overlap.
    if sorted(row["config"]["module"] for row in records) != ["backend", "frontend", "memory"]:
        return None
    comparable = []
    for row in records:
        config = {key: value for key, value in row["config"].items() if key not in ("module", "top")}
        comparable.append((config, row["stage"], row["mode"], row["rtl_sha256"], row.get("flow_sha256")))
    if any(item != comparable[0] for item in comparable[1:]):
        return None
    return {key: sum(row["resources"][key] for row in records) for key in RESOURCE_COLUMNS}


def routing_result(row):
    if row["stage"] != "route":
        return "not routed"
    context = row.get("context", {})
    if context.get("route_errors") == "1":
        return "ERRORS (review report)"
    if context.get("routed_fully") != "1":
        return "incomplete/unverified"
    if context.get("partpin_ports") != context.get("interface_ports"):
        return "internal only"
    return "complete OOC (review DRC)"


def summary(args):
    records, errors, lines = [], [], ["# FPGA module evaluation", "",
        "Module screening evidence only. WNS/TNS are never added or converted to whole-core Fmax.", "",
        "| Module | RV | Config | Stage/mode | Routing | Context XDC | LUT | FF | BRAM36/18 | DSP | WNS ns | TNS ns | WHS ns | Run s | Cached phases |",
        "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    def number(value):
        return "N/A" if value is None else f"{value:.3f}"

    for directory in args.runs:
        try:
            row = load_result(directory)
        except (OSError, ValueError, KeyError) as exc:
            errors.append(f"{directory}: {exc}")
            continue
        records.append(row)
        config, res, slack = row["config"], row["resources"], row["timing"]
        reused = ",".join(name for name, phase in row["stages"].items() if phase["reused"]) or "none"
        lines.append(f"| {config['module']} | {config['xlen']} | {config['config']} | "
                     f"{row['stage']}/{row['mode']} | {routing_result(row)} | "
                     f"{str(row['context_sha256'] or 'none')[:12]} | "
                     f"{res['Total LUTs']} | {res['FFs']} | {res['RAMB36']}/{res['RAMB18']} | "
                     f"{res['DSP Blocks']} | {number(slack['wns_ns'])} | {number(slack['tns_ns'])} | "
                     f"{number(slack['whs_ns'])} | {row['wall_sec']} | {reused} |")
    total = sum_compositions(records) if not errors else None
    if total:
        lines.extend(["", "Disjoint frontend + backend + memory resource sum (independent OOC estimates, "
                      "not whole-core utilization; excludes board logic and cross-module optimization):",
                      "", ", ".join(f"{key}: {value}" for key, value in total.items()) + "."])
    else:
        lines.extend(["", "No resource total: requires exactly frontend/backend/memory with matching "
                      "RTL, configuration, tools, stage and strategy. Never mix parent and child scopes."])
    for row in records:
        lines.extend(["", f"## {row['config']['module']} ({row['reports']})", "",
                      f"Revision: `{row['revision']}`; RTL SHA256: `{row['rtl_sha256']}`.",
                      f"Flow/wrappers SHA256: `{row.get('flow_sha256', 'legacy-unrecorded')}`.",
                      f"Constraints: {row['config']['part']}, {row['config']['period']} ns, "
                      f"IO fraction {row['config']['io_frac']}; defines: `{row['config']['defines']}`.",
                      f"Context coverage: `{row['context']}`.",
                      "Phase cost (original execution, not cache lookup): " + "; ".join(
                          f"{name}: {phase['elapsed_sec']} s, peak {phase['max_rss_kb']} KiB"
                          for name, phase in row["stages"].items()) + "."])
    lines.extend(["", "Without HD.PARTPIN constraints, OOC interface nets are not routed. Even with "
                  "context constraints, review coverage, DRC, route status and cross-module paths in the "
                  "composition/full design. A completed tool run does not certify timing closure."])
    if errors:
        lines.extend(["", "## Rejected results", "", *[f"- {error}" for error in errors]])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n")
    print(args.output)
    if errors:
        raise ValueError("Some requested results were incomplete or invalid; see summary")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    runner = commands.add_parser("run")
    runner.add_argument("--stage", choices=("synth", "place", "route"), default="place")
    runner.add_argument("--mode", choices=("screen", "closure"), default="screen")
    runner.add_argument("--cache", type=Path, required=True)
    runner.add_argument("--output", type=Path, required=True)
    runner.add_argument("--context-xdc", default="")
    runner.add_argument("--timeout", type=float, default=0)
    collector = commands.add_parser("summary")
    collector.add_argument("--output", type=Path, required=True)
    collector.add_argument("runs", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        (run if args.command == "run" else summary)(args)
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"[fpga-eval] ERROR: {exc}\n")


if __name__ == "__main__":
    main()
