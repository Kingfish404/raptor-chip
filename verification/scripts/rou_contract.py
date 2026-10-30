#!/usr/bin/env python3
"""Prove retirement metadata and concrete or composed ROU/RVFI transport."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import threading
from yosys_common import ROOT, run_yosys


FORMAL = ROOT / 'verification/formal'

HARNESS = FORMAL / 'formal_rou.sv'

DUT = ROOT / 'rtl/backend/rapt_rou.sv'

MUTATIONS = {
    'bank-row': ("write_row = RowBits'(int'(rob_alloc[s]) / RetireBanks);",
                 "write_row = RowBits'(int'(rob_alloc[s]) / RetireBanks) ^ 1'b1;"),
    'read-bank': ("read_data[c][int'(retire_read_index[c])%RetireBanks]",
                  'read_data[c][0]'),
    'pc': ('result.pc = u.pc[PcW-1:1];', "result.pc = u.pc[PcW-1:1] ^ 1'b1;"),
    'rvfi-identity': ('result.rvfi_inst = u.rvfi_inst;', 'result.rvfi_inst = u.inst;'),
    'serial-immediate': ('serial_imm <= allocation[s].uop.imm[11:0];',
                         "serial_imm <= allocation[s].uop.imm[11:0] ^ 12'h001;"),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def retire_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--presets', nargs='+', default=['formal'])
    parser.add_argument('--xlens', nargs='+', type=int, choices=[32, 64], default=[32, 64])
    parser.add_argument('--metadata', nargs='+', choices=['functional', 'instruction', 'rvfi'],
                        default=['functional', 'instruction', 'rvfi'])
    parser.add_argument('--validation-modes', nargs='+', type=int, choices=[0, 1], default=[0, 1])
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--depth', type=int, default=4)
    parser.add_argument('--cover-depth', type=int, default=160)
    parser.add_argument('--solver', choices=['yices', 'bitwuzla', 'z3'], default='yices')
    parser.add_argument('--negative-controls', choices=['run', 'skip'], default='run')
    args = parser.parse_args()
    if min(args.jobs, args.timeout, args.depth, args.cover_depth) < 1:
        parser.error('Jobs, timeout and depths must be positive')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty to preserve evidence')
    for values in (args.presets, args.xlens, args.metadata, args.validation_modes):
        if len(values) != len(set(values)):
            parser.error('Duplicate matrix elements')
    for preset in args.presets:
        if not preset.replace('-', '').replace('_', '').isalnum():
            parser.error('Invalid preset name')
        if not (ROOT / 'rtl/configs' / preset / 'rapt_config.svh').is_file():
            parser.error('Unknown preset: ' + preset)
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Yosys paths cannot contain whitespace, quotes or semicolons')
    output.mkdir(parents=True, exist_ok=True)
    rtl = [ROOT / 'rtl/rapt_pkg.sv']
    rtl += sorted(p for p in (ROOT / 'rtl').rglob('*.sv') if p not in rtl)
    sources = rtl + [HARNESS, Path(__file__), Path(__file__).with_name('yosys_common.py'),
                     FORMAL / 'yosys-rvfi-compat.sh']
    sources += sorted((ROOT / 'rtl/include').rglob('*.svh'))
    for preset in set(args.presets) | {'formal'}:
        sources += sorted((ROOT / 'rtl/configs' / preset).rglob('*.svh'))
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    result = {
        'complete': False, 'whole_rtl_signoff': False, 'sources': fingerprints,
        'assumptions': ['First sampled edge resets'], 'cases': [], 'negative_controls': [],
        'scope': 'Uncut production ROU retirement banks and independent allocation histories: '
                 'every stored metadata word, all commit/lookahead reads, full PC/instruction '
                 'widths, live-owner history and serialized immediate. Raw producer requests, '
                 'rename, CSR and backpressure remain free. Local-validation mode receives '
                 'raw completions; production mode composes actual ownership guards with the '
                 'ROU. The added guard on the backend trusted memory port is an explicit '
                 'composition boundary: the LSU memory-producer ownership contract is not '
                 'proved here. Undriven invalid-index memory-map leaves remain unconstrained; '
                 'no sequential state is cut. Core execution, memory, rename correctness and '
                 'ISA are separate.',
        'yosys': subprocess.check_output(
            [os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'), '-V'], text=True).strip(),
        'solver': args.solver, 'negative_control_policy': args.negative_controls,
    }
    lock = threading.Lock()

    def save():
        temporary = output / 'results.tmp'
        temporary.write_text(json.dumps(result, indent=2) + '\n')
        temporary.replace(output / 'results.json')

    def run(case):
        preset, xlen, metadata, validate, mutation = case
        label = ('negative-' + mutation if mutation else
                 f'{preset}-rv{xlen}-{metadata}-v{validate}')
        directory = output / label
        directory.mkdir()
        files = list(rtl)
        if mutation:
            text = DUT.read_text()
            old, new = MUTATIONS[mutation]
            if text.count(old) != 1:
                raise ValueError('Missing ROU mutation anchor: ' + mutation)
            source = directory / 'mutant.sv'
            source.write_text(text.replace(old, new))
            files[files.index(DUT)] = source
        defines = ('-DRAPT_RV64 ' if xlen == 64 else '')
        if metadata == 'rvfi':
            defines += '-DRAPT_RVFI '
        elif metadata == 'instruction':
            defines += '-DRAPT_KEEP_UOP_INST '
        read = ('plugin -i slang\nread_slang --threads 1 --single-unit '
                '--allow-toplevel-iface-ports -DSYNTHESIS ' + defines
                + f'-GValidateCompletionInputs={validate} '
                + f'-I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include '
                + f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock '
                + '--top formal_rou_retire -DRAPT_FORMAL_ROU_RETIRE ' + ' '.join(map(str, files + [HARNESS])))
        script = (read + '\nprep -top formal_rou_retire -flatten\nasync2sync\n'
                  'memory_map\nopt\nselect -assert-count 1 t:$assume\n'
                  'select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n'
                  'setundef -undriven -anyseq\ncheck -assert\n'
                  'select -assert-any t:$assert\nselect -assert-any t:$cover\n')
        tasks = '[tasks]\nprove\n' + ('' if mutation else 'cover\n')
        options = '[options]\nprove: mode ' + ('bmc\n' if mutation else 'prove\n')
        options += f'prove: depth {12 if mutation else args.depth}\n'
        if not mutation:
            options += f'cover: mode cover\ncover: depth {args.cover_depth}\n'
        config = (tasks + options + f'timeout {args.timeout}\n[engines]\n'
                  f'smtbmc {args.solver}\n[script]\n' + script)
        (directory / 'contract.sby').write_text(config)
        bundled = ROOT / 'third_party/oss-cad-suite/bin'
        env = dict(os.environ, PATH=str(bundled) + os.pathsep + os.environ['PATH'])
        log = directory / 'run.log'
        command = [str(bundled / 'sby'), '--yosys', str(FORMAL / 'yosys-rvfi-compat.sh'),
                   'contract.sby']
        with log.open('w') as stream:
            process = subprocess.run(command, cwd=directory, env=env, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=args.timeout + 120)
        row = dict(preset=preset, xlen=xlen, metadata=metadata, validate=validate,
                   exit=process.returncode, log=str(log.relative_to(output)), log_sha256=sha(log))
        for task in (('prove',) if mutation else ('prove', 'cover')):
            status = directory / ('contract_' + task) / 'status'
            row[task] = status.read_text().split()[0] if status.exists() else 'ERROR'
        trace_folder = directory / ('contract_prove' if mutation else 'contract_cover') / 'engine_0'
        traces = sorted(trace_folder.glob('trace*.vcd'))
        row['witnesses'] = {str(p.relative_to(output)): sha(p) for p in traces}
        if mutation:
            row['name'] = mutation
            row['passed'] = (row['prove'] == 'FAIL' and 'Assert failed' in log.read_text()
                             and 'ERROR:' not in log.read_text() and bool(traces)
                             and all(p.stat().st_size for p in traces))
        else:
            row['passed'] = (process.returncode == 0 and row['prove'] == 'PASS'
                             and row['cover'] == 'PASS' and bool(traces)
                             and all(p.stat().st_size for p in traces))
        row['artifacts'] = {str(p.relative_to(directory)): sha(p) for p in directory.iterdir()
                            if p.is_file()}
        with lock:
            result['negative_controls' if mutation else 'cases'].append(row)
            save()
        print(label, 'PASS' if row['passed'] else 'INCOMPLETE', flush=True)
        return row['passed']

    save()
    cases = [(p, x, m, v, None) for p in args.presets for x in args.xlens
             for m in args.metadata for v in args.validation_modes]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, cases))
        if args.negative_controls == 'run':
            passed += list(pool.map(run, [('formal', 32, 'rvfi', 0, m) for m in MUTATIONS]))
    if fingerprints != {str(p.relative_to(ROOT)): sha(p) for p in sources}:
        raise RuntimeError('ROU retirement proof inputs changed during execution')
    result['complete'] = all(passed)
    save()
    if not all(passed):
        raise SystemExit('Incomplete ROU retirement contract')
    print('FORMAL COMPLETE: ROU immutable retirement metadata and serialized immediate')


TOP = "formal_rou_rvfi"

FF_TYPES = {"$dff", "$dffe", "$sdff", "$sdffe", "$sdffce", "$adff", "$adffe"}

KEEP_PREFIX = (
    "known", "from_memory_port", "past_valid", "expected_address[", "expected_physical[",
    "expected_result[", "expected_write[", "dut_rou.rvfi_mem_addr[", "dut_rou.rvfi_mem_data[",
    "dut_rou.rvfi_mem_result[",
)

COMPOSED_MUTATIONS = {
    "physical-address": ("rvfi_mem_addr[entry] <= completion[p].tval;",
                         "rvfi_mem_addr[entry] <= completion[p].sq_waddr;"),
    "lost-read-result": ("rvfi_mem_result[entry] <= completion[p].result;",
                         "rvfi_mem_result[entry] <= '0;"),
    "invented-write": ("rou_cmu.slot[c].rvfi_mem_wen = rob_entry[commit_index[c]].wen;",
                       "rou_cmu.slot[c].rvfi_mem_wen = 1'b1;"),
}


def select_control_state(module):
    """Select only identifiable DUT FFs disjoint from payload/history/monitor state."""
    keep_bits, aliases = set(), {}
    for name, wire in module["netnames"].items():
        for bit in wire["bits"]:
            if not isinstance(bit, int):
                continue
            if name.startswith(KEEP_PREFIX):
                keep_bits.add(bit)
            if name.startswith(("dut_rou.", "dut_trace.")):
                aliases.setdefault(bit, []).append(name)
    cut, kept = [], []
    for name, cell in module["cells"].items():
        if cell["type"] not in FF_TYPES:
            continue
        bits = cell["connections"]["Q"]
        source = cell.get("attributes", {}).get("src", "")
        identified = bits and all(isinstance(b, int) and b in aliases for b in bits)
        if (not identified or set(bits) & keep_bits or "formal_rou.sv:" in source):
            kept.append(name)
            continue
        cut.append({"name": name, "type": cell["type"], "q_bits": bits,
                    "aliases": sorted({a for b in bits for a in aliases[b]})})
    if not cut or not kept:
        raise ValueError("Missing identifiable control state or retained state")
    return cut, kept


def audit_abstraction(before, after, cut):
    """Check a bijective old-net mapping and exact preservation of every uncut cell.

    This establishes a graph-level state overapproximation: only selected FF
    drivers disappear; each former Q receives one free value at every step.
    Original trajectories are included by choosing their original Q values.
    """
    mapping, reverse = {}, {}
    for name, wire in before["netnames"].items():
        changed = after["netnames"].get(name)
        if changed is None or wire.get("attributes", {}) != changed.get("attributes", {}):
            raise ValueError("Original wire or its initial attributes changed: " + name)
        if len(wire["bits"]) != len(changed["bits"]):
            raise ValueError("Wire width changed: " + name)
        for old, new in zip(wire["bits"], changed["bits"]):
            if isinstance(old, int):
                if not isinstance(new, int) or mapping.get(old, new) != new:
                    raise ValueError("Net alias changed: " + name)
                if reverse.get(new, old) != old:
                    raise ValueError("Distinct original nets were merged")
                mapping[old], reverse[new] = new, old
            elif old != new:
                raise ValueError("A constant changed: " + name)

    def bits(values):
        return [mapping[b] if isinstance(b, int) else b for b in values]

    for name, port in before["ports"].items():
        other = after["ports"].get(name, {})
        if other.get("direction") != port["direction"] or other.get("bits") != bits(port["bits"]):
            raise ValueError("A top-level port changed: " + name)
    if set(before["ports"]) != set(after["ports"]):
        raise ValueError("Top-level ports were added or removed")
    removed = {row["name"] for row in cut}
    expected = set(before["cells"]) - removed
    if not expected <= set(after["cells"]):
        raise ValueError("An unselected cell was removed")
    for name in expected:
        original, changed = before["cells"][name], after["cells"][name]
        for key in ("type", "parameters", "attributes", "port_directions"):
            if original.get(key, {}) != changed.get(key, {}):
                raise ValueError("An unselected cell changed: " + name)
        connections = {port: bits(value) for port, value in original["connections"].items()}
        if connections != changed["connections"]:
            raise ValueError("An unselected connection changed: " + name)
    if removed & set(after["cells"]):
        raise ValueError("Selected FFs were not removed")
    fresh = [c for n, c in after["cells"].items() if n not in before["cells"]]
    if any(c["type"] not in ("$anyseq", "$scopeinfo") for c in fresh):
        raise ValueError("Unexpected logic was introduced by state abstraction")
    actual = sorted(tuple(c["connections"]["Y"]) for c in fresh if c["type"] == "$anyseq")
    wanted = sorted(tuple(bits(row["q_bits"])) for row in cut)
    if actual != wanted:
        raise ValueError("Free-state drivers differ from the selected FF outputs")
    return {"cut_registers": len(cut), "cut_bits": sum(len(r["q_bits"]) for r in cut),
            "unchanged_cells": len(expected), "new_free_drivers": len(actual),
            "all_properties_and_assumptions_preserved": True,
            "all_original_initial_attributes_preserved": True}


def composed_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--presets", nargs="+", default=["formal"])
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--cover-depth", type=int, default=8)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty to preserve previous evidence")
    if args.jobs < 1 or args.timeout < 1 or args.cover_depth < 8:
        parser.error("Require positive jobs/timeout and cover depth >= 8")
    if len(set(args.presets)) != len(args.presets):
        parser.error("Duplicate presets")
    for preset in args.presets:
        if not preset.replace("-", "").replace("_", "").isalnum():
            parser.error("Invalid preset name")
        if not (ROOT / "rtl/configs" / preset / "rapt_config.svh").is_file():
            parser.error("Unknown preset: " + preset)
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error("Yosys paths cannot contain whitespace, quotes or semicolons")
    output.mkdir(parents=True, exist_ok=True)
    rtl = [ROOT / "rtl/rapt_pkg.sv"]
    rtl += sorted(p for p in (ROOT / "rtl").rglob("*.sv") if p not in rtl)
    sources = rtl + [HARNESS, Path(__file__), Path(__file__).with_name("yosys_common.py"),
                     FORMAL / "yosys-rvfi-compat.sh"]
    sources += sorted((ROOT / "rtl/include").rglob("*.svh"))
    for preset in set(args.presets) | {"formal"}:
        sources += sorted((ROOT / "rtl/configs" / preset).rglob("*.svh"))
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    result = {"complete": False, "whole_rtl_signoff": False, "sources": fingerprints,
              "cases": [], "negative_controls": [],
              "assumptions": ["Reset on the first sampled edge only"],
              "scope": "Same ROU/RVFI safety properties as formal_rou_rvfi. Control-state "
                       "FFs are replaced by free values after a graph-preservation audit. "
                       "Payload, reference history and assertion-monitor FFs remain concrete. "
                       "This overapproximates original trajectories; reset reachability is "
                       "checked separately with covers on the uncut RTL. Both local completion "
                       "validation and the production externally accepted completion binding "
                       "are checked. No execution, decoder, bus-data, translation or complete "
                       "architectural/ISA correctness claim.",
              "yosys": subprocess.check_output(
                  [os.environ.get("RAPTOR_YOSYS_REAL", "yosys"), "-V"], text=True).strip()}
    lock = threading.Lock()
    bundled = ROOT / "third_party/oss-cad-suite/bin"
    env = dict(os.environ, PATH=str(bundled) + os.pathsep + os.environ["PATH"])

    def save():
        temporary = output / "results.tmp"
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(output / "results.json")

    def run_sby(directory, name, model, mode, depth):
        config = (f"[options]\nmode {mode}\ndepth {depth}\ntimeout {args.timeout}\n"
                  "[engines]\nsmtbmc yices\n[script]\n"
                  f"read_rtlil model.il\nprep -top {TOP}\ncheck -assert\n"
                  "[files]\nmodel.il " + str(model) + "\n")
        path = directory / (name + ".sby")
        path.write_text(config)
        log = directory / (name + ".log")
        command = [str(bundled / "sby"), "--yosys", str(FORMAL / "yosys-rvfi-compat.sh"),
                   "--prefix", str(directory / name), str(path)]
        with log.open("w") as stream:
            process = subprocess.run(command, cwd=directory, env=env, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=args.timeout + 120)
        status = directory / name / "status"
        return {"status": status.read_text().split()[0] if status.exists() else "ERROR",
                "exit": process.returncode, "log": str(log.relative_to(output)),
                "log_sha256": sha(log)}

    def run(case):
        preset, xlen, validate, mutation = case
        label = (f"negative-{mutation}-v{validate}" if mutation else
                 f"{preset}-rv{xlen}-v{validate}")
        directory = output / label
        directory.mkdir()
        files = list(rtl)
        if mutation:
            original = ROOT / "rtl/backend/rapt_rou.sv"
            old, new = COMPOSED_MUTATIONS[mutation]
            text = original.read_text()
            if text.count(old) != 1:
                raise ValueError("Missing ROU mutation anchor: " + mutation)
            source = directory / "mutant.sv"
            source.write_text(text.replace(old, new))
            files[files.index(original)] = source
        define = "-DRAPT_RV64 " if xlen == 64 else ""
        script = ("read_slang --threads 1 --single-unit --allow-toplevel-iface-ports "
                  "-DSYNTHESIS -DRAPT_RVFI " + define
                  + f"-I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include "
                  + f"-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock "
                  + f"--top {TOP} -DRAPT_FORMAL_ROU_RVFI -GValidateCompletionInputs={validate} "
                  + " ".join(map(str, files + [HARNESS]))
                  + f"; prep -top {TOP} -flatten; async2sync; memory_map; opt; check -assert; "
                  + "select -assert-count 1 t:$assume; "
                  + "select -assert-none t:$anyseq t:$anyconst A:blackbox=1; "
                  + f"write_json {directory}/concrete.json; "
                  + f"write_rtlil {directory}/concrete.il;")
        (directory / "prepare.ys").write_text(script + "\n")
        run_yosys(script, directory / "prepare.log", args.timeout)
        before = json.loads((directory / "concrete.json").read_text())["modules"][TOP]
        cut, kept = select_control_state(before)
        selection = directory / "control.sel"
        selection.write_text("".join(TOP + "/" + row["name"] + "\n" for row in cut))
        script = (f"read_rtlil {directory}/concrete.il; select -read {selection}; "
                  f"select -assert-count {len(cut)} %; select -set control_state %; select -clear; "
                  f"cutpoint @control_state; select -assert-count {len(cut)} t:$anyseq; "
                  f"check -assert; write_json {directory}/cut.json; "
                  f"opt_clean; check -assert; write_rtlil {directory}/abstract.il;")
        (directory / "abstract.ys").write_text(script + "\n")
        run_yosys(script, directory / "abstract.log", args.timeout)
        after = json.loads((directory / "cut.json").read_text())["modules"][TOP]
        audit = audit_abstraction(before, after, cut)
        (directory / "abstraction-audit.json").write_text(json.dumps(
            {"audit": audit, "selected": cut, "retained_ff": kept}, indent=2) + "\n")
        row = {"preset": preset, "xlen": xlen, "validate_completion_inputs": validate,
               "commit_width": len(before["netnames"]["valid"]["bits"]),
               "rob_entries": len(before["netnames"]["known"]["bits"]),
               "audit": audit}
        mode = "bmc" if mutation else "prove"
        row["safety"] = run_sby(directory, "safety", directory / "abstract.il", mode,
                                6 if mutation else 3)
        if mutation:
            log = directory / "safety.log"
            witnesses = sorted((directory / "safety/engine_0").glob("trace*.vcd"))
            row.update(name=mutation, mutant_sha256=sha(source))
            row["counterexamples"] = {str(p.relative_to(output)): sha(p) for p in witnesses}
            row["passed"] = (row["safety"]["status"] == "FAIL"
                             and "Assert failed" in log.read_text()
                             and "ERROR:" not in log.read_text()
                             and witnesses and all(p.stat().st_size for p in witnesses))
            row["passed"] = bool(row["passed"])
            # A mutation must also fail on the reset-reachable, uncut model.
            # A spurious abstract counterexample alone does not qualify it.
            row["concrete_counterexample"] = run_sby(
                directory, "concrete-negative", directory / "concrete.il", "bmc", 8)
            concrete_log = directory / "concrete-negative.log"
            traces = sorted((directory / "concrete-negative/engine_0").glob("trace*.vcd"))
            row["concrete_counterexamples"] = {
                str(p.relative_to(output)): sha(p) for p in traces}
            row["passed"] &= (row["concrete_counterexample"]["status"] == "FAIL"
                              and "Assert failed" in concrete_log.read_text()
                              and "ERROR:" not in concrete_log.read_text()
                              and bool(traces) and all(p.stat().st_size for p in traces))
        else:
            row["reachability"] = run_sby(directory, "reachability", directory / "concrete.il",
                                          "cover", args.cover_depth)
            witnesses = sorted((directory / "reachability/engine_0").glob("trace*.vcd"))
            row["activation_traces"] = {str(p.relative_to(output)): sha(p) for p in witnesses}
            row["passed"] = (row["safety"]["status"] == "PASS"
                             and row["reachability"]["status"] == "PASS"
                             and all(row[k]["exit"] == 0 for k in ("safety", "reachability"))
                             and bool(witnesses) and all(p.stat().st_size for p in witnesses))
        row["artifacts"] = {str(p.relative_to(directory)): sha(p) for p in directory.iterdir()
                            if p.is_file()}
        with lock:
            result["negative_controls" if mutation else "cases"].append(row)
            save()
        print(label, "PASS" if row["passed"] else "INCOMPLETE", flush=True)
        return row["passed"]

    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        cases = [(p, x, v, None) for p in args.presets for x in (32, 64) for v in (0, 1)]
        passed = list(pool.map(run, cases))
        controls = [("formal", 32, v, m) for v in (0, 1) for m in COMPOSED_MUTATIONS]
        passed += list(pool.map(run, controls))
    if fingerprints != {str(p.relative_to(ROOT)): sha(p) for p in sources}:
        raise RuntimeError("ROU/RVFI proof inputs changed during execution")
    result["complete"] = all(passed)
    save()
    if not all(passed):
        raise SystemExit("Incomplete ROU/RVFI abstraction qualification")
    print("FORMAL COMPOSITION COMPLETE: ROU/RVFI safety and uncut activation", flush=True)


def rvfi_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--presets", nargs="+", default=["formal"])
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--depth", type=int, default=12)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty to preserve previous evidence")
    if args.jobs < 1 or args.timeout < 1 or args.depth < 8:
        parser.error("Require positive jobs/timeout and depth >= 8")
    for preset in args.presets:
        if not preset.replace("-", "").replace("_", "").isalnum():
            parser.error("Invalid preset name")
        if not (ROOT / "rtl/configs" / preset / "rapt_config.svh").is_file():
            parser.error("Unknown preset: " + preset)
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error("Yosys paths cannot contain whitespace, quotes or semicolons")
    output.mkdir(parents=True, exist_ok=True)
    rtl = [ROOT / "rtl/rapt_pkg.sv"]
    rtl += sorted(p for p in (ROOT / "rtl").rglob("*.sv") if p not in rtl)
    sources = rtl + [HARNESS, Path(__file__), Path(__file__).with_name("yosys_common.py"),
                     FORMAL / "yosys-rvfi-compat.sh"]
    sources += sorted((ROOT / "rtl/include").rglob("*.svh"))
    # Negative controls always use the formal preset, including when only
    # production presets are selected for the positive proofs.
    for preset in set(args.presets) | {"formal"}:
        sources += sorted((ROOT / "rtl/configs" / preset).rglob("*.svh"))
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    result = {"complete": False, "whole_rtl_signoff": False, "sources": fingerprints,
              "assumptions": ["Reset on the first sampled edge only"],
              "scope": "Uncut actual ROU and RVFI adapter: accepted memory-completion "
                       "payload retention until retirement, effective address versus physical "
                       "address, x0 read data, write permission versus actual scalar store "
                       "commit, and contiguous retirement prefix. Rename, completions, CSR, "
                       "PRF data and backpressure are arbitrary. Covers are reachable under "
                       "these hostile block inputs; they do not prove core-level reachability. "
                       "Decoder/producer legality, execution/bus data, memory contents, "
                       "translation/PMP and whole-core ISA correctness remain separate.",
              "cases": [], "negative_controls": [],
              "yosys": subprocess.check_output(
                  [os.environ.get("RAPTOR_YOSYS_REAL", "yosys"), "-V"], text=True).strip()}
    lock = threading.Lock()

    def save():
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    mutations = {
        "physical-address": ("rvfi_mem_addr[entry] <= completion[p].tval;",
                             "rvfi_mem_addr[entry] <= completion[p].sq_waddr;"),
        "lost-read-result": ("rvfi_mem_result[entry] <= completion[p].result;",
                             "rvfi_mem_result[entry] <= '0;"),
        "invented-write": ("rou_cmu.slot[c].rvfi_mem_wen = rob_entry[commit_index[c]].wen;",
                           "rou_cmu.slot[c].rvfi_mem_wen = 1'b1;"),
    }

    def run(case):
        preset, xlen, mutant = case
        label = "negative-" + mutant if mutant else f"{preset}-rv{xlen}"
        directory = output / label
        directory.mkdir()
        files = list(rtl)
        if mutant:
            original = ROOT / "rtl/backend/rapt_rou.sv"
            text = original.read_text()
            old, new = mutations[mutant]
            if text.count(old) != 1:
                raise ValueError("Missing ROU mutation anchor: " + mutant)
            source = directory / "mutant.sv"
            source.write_text(text.replace(old, new))
            files[files.index(original)] = source
        define = "-DRAPT_RV64 " if xlen == 64 else ""
        read = ("plugin -i slang\nread_slang --threads 1 --single-unit "
                "--allow-toplevel-iface-ports -DSYNTHESIS -DRAPT_RVFI " + define
                + f"-I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include "
                + f"-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock "
                + "--top formal_rou_rvfi -DRAPT_FORMAL_ROU_RVFI " + " ".join(map(str, files + [HARNESS])))
        script = (read + "\nprep -top formal_rou_rvfi -flatten\nasync2sync\n"
                  "memory_map\nopt\ncheck -assert\nselect -assert-count 1 t:$assume\n"
                  "select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n"
                  "select -assert-any t:$assert\nselect -assert-any t:$cover\n")
        tasks = ("[tasks]\nprove\n[options]\nprove: mode bmc\n" if mutant else
                 "[tasks]\nprove\ncover\n[options]\nprove: mode prove\ncover: mode cover\n")
        config = (tasks + f"depth {args.depth}\ntimeout {args.timeout}\n"
                  "[engines]\nsmtbmc yices\n[script]\n" + script)
        (directory / "contract.sby").write_text(config)
        bundled = ROOT / "third_party/oss-cad-suite/bin"
        env = dict(os.environ)
        env["PATH"] = str(bundled) + os.pathsep + env["PATH"]
        command = [str(bundled / "sby"), "--yosys", str(FORMAL / "yosys-rvfi-compat.sh"),
                   "contract.sby"]
        log = directory / "run.log"
        with log.open("w") as stream:
            process = subprocess.run(command, cwd=directory, env=env, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=args.timeout + 120)
        row = {"preset": preset, "xlen": xlen, "exit": process.returncode,
               "log": str(log.relative_to(output)), "log_sha256": sha(log)}
        for task in (("prove",) if mutant else ("prove", "cover")):
            status = directory / ("contract_" + task) / "status"
            row[task] = status.read_text().split()[0] if status.exists() else "ERROR"
        traces = sorted((directory / "contract_cover/engine_0").glob("trace*.vcd"))
        row["activation_traces"] = {str(p.relative_to(output)): sha(p) for p in traces}
        if mutant:
            witnesses = sorted((directory / "contract_prove/engine_0").glob("trace*.vcd"))
            row["name"] = mutant
            row["mutant_sha256"] = sha(source)
            row["counterexamples"] = {str(p.relative_to(output)): sha(p) for p in witnesses}
            row["passed"] = (process.returncode != 0 and row["prove"] == "FAIL"
                             and "Assert failed" in log.read_text()
                             and "ERROR:" not in log.read_text() and bool(witnesses))
        else:
            row["passed"] = (process.returncode == 0 and row["prove"] == "PASS"
                             and row["cover"] == "PASS" and bool(traces))
        with lock:
            result["negative_controls" if mutant else "cases"].append(row)
            save()
        print(f"{label}: prove={row['prove']} cover={row.get('cover', 'n/a')}", flush=True)
        return row["passed"]

    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, [(p, x, None) for p in args.presets for x in (32, 64)]))
        passed += list(pool.map(run, [("formal", 32, m) for m in mutations]))
    if fingerprints != {str(p.relative_to(ROOT)): sha(p) for p in sources}:
        raise RuntimeError("ROU/RVFI proof sources changed during execution")
    result["all_cases_passed"] = all(passed)
    result["complete"] = all(passed)
    save()
    if not all(passed):
        raise SystemExit("Incomplete ROU/RVFI checks; inspect results.json")


ENTRY_POINTS = {
    'retire': retire_main,
    'composed': composed_main,
    'rvfi': rvfi_main,
}


def main():
    import sys

    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command not in ENTRY_POINTS:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('command', choices=ENTRY_POINTS)
        parser.parse_args()
    del sys.argv[1]
    return ENTRY_POINTS[command]()


if __name__ == '__main__':
    raise SystemExit(main())
