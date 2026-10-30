#!/usr/bin/env python3
"""Prove self-contained RTL unit contracts with fingerprinted evidence.

Subcommands: `nru` (cache NRU replacement), `recovery` (recovery request
selection), `stream-queue` (banked queue against its flop reference), `sram`
(1RW SRAM wrapper shapes) and `l1d-data` (L1D diagonal data banks). Every run
writes `results.json` into an empty output directory, checks that its sources
did not change during the run, and includes negative controls (mutants that
must fail).
"""
import argparse
from concurrent.futures import as_completed, ThreadPoolExecutor
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import threading

from yosys_common import ROOT, run_sby, run_yosys

FORMAL = ROOT / "verification/formal"
SVA = ROOT / "rtl/include/rapt_sva.svh"
SRAM_DIR = ROOT / "sim/sram"
SRAM_RTL = ROOT / "rtl/sram/rapt_sram_1rw.sv"
SRAM_GENERATOR = SRAM_DIR / "scripts/gen_stub_lib.py"
DRIVERS = [Path(__file__), Path(__file__).with_name("yosys_common.py")]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(paths):
    return {str(p.relative_to(ROOT)): sha(p) for p in paths}


def prepare_output(parser, args, yosys_paths=False):
    """Validate common arguments; return the resolved, empty output directory."""
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty to preserve previous evidence")
    if args.jobs < 1 or args.timeout < 1:
        parser.error("Jobs and timeout must be positive")
    if yosys_paths:
        for path in (ROOT, output):
            if any(c.isspace() or c in ';"' for c in str(path)):
                parser.error("Yosys paths cannot contain whitespace, quotes or semicolons")
    return output


def evidence_writer(output, report):
    def save():
        temporary = output / "results.tmp"
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(output / "results.json")
    return save


def mutate(text, old, new, what):
    if text.count(old) != 1:
        raise ValueError("Missing mutation anchor: " + what)
    return text.replace(old, new)


def load_sram_generator():
    spec = importlib.util.spec_from_file_location("sram_stub", SRAM_GENERATOR)
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    return generator


# --- NRU replacement: priority, epoch rollover and invalidation for every set ---

NRU_RTL = ROOT / "rtl/memory/rapt_cache_nru.sv"
NRU_HARNESS = FORMAL / "formal_cache_nru.sv"
NRU_MUTATIONS = {
    "epoch": ("assign next_recent = (&touched) ? (Ways'(1) << update_way) : touched;",
              "assign next_recent = touched;"),
    "priority": ("for (int way = Ways - 1; way >= 0; way--)",
                 "for (int way = 0; way < Ways; way++)"),
    "invalidate": ("if (reset || invalidate) initialized <= '0;",
                   "if (reset) initialized <= '0;"),
}


def nru(parser, args):
    output = prepare_output(parser, args)
    output.mkdir(parents=True, exist_ok=True)
    sources = [NRU_RTL, NRU_HARNESS, FORMAL / "yosys-rvfi-compat.sh", SVA, *DRIVERS]
    fingerprints = fingerprint(sources)
    report = {"complete": False, "whole_rtl_signoff": False, "sources": fingerprints,
              "proofs": [], "negative_controls": [],
              "assumptions": ["First sampled edge resets the DUT", "Only observer set is stable"],
              "scope": "All NRU way marks, lowest-cold priority, epoch renewal, reset and "
                       "invalidate, every symbolic set, every read port and arbitrary updates. "
                       "Only activation covers use a deterministic external touch/invalidate "
                       "sequence; safety and mutation proofs use unconstrained DUT inputs. "
                       "Cache hit/install arbitration, tags, data and coherence are separate."}
    lock = threading.Lock()
    save = evidence_writer(output, report)

    def run(case):
        ways, bits, ports, mutant = case
        name = "negative-" + mutant if mutant else f"w{ways}-s{bits}-p{ports}"
        directory = output / name
        directory.mkdir()
        text = NRU_RTL.read_text()
        if mutant:
            text = mutate(text, *NRU_MUTATIONS[mutant], "NRU " + mutant)
        (directory / "rapt_cache_nru.sv").write_text(text)
        (directory / "formal_cache_nru.sv").write_bytes(NRU_HARNESS.read_bytes())
        (directory / "rapt_sva.svh").write_bytes(SVA.read_bytes())
        tasks = "[tasks]\nprove\n" + ("" if mutant else "cover\n")
        options = "[options]\nprove: mode bmc\n" if mutant else (
            "[options]\nprove: mode prove\ncover: mode cover\n")
        read = ("read_slang --threads 1 --single-unit --top formal_cache_nru "
                f"-GWays={ways} -GSetBits={bits} -GReadPorts={ports} ")
        files = "rapt_cache_nru.sv formal_cache_nru.sv\n"
        commands = "prove: " + read + "-GGuidedCover=0 " + files
        depth = f"prove: depth {ways + 6 if mutant else 4}\n"
        if not mutant:
            commands += "cover: " + read + "-GGuidedCover=1 " + files
            depth += f"cover: depth {ways + 6}\n"
        config = (tasks + options + depth + f"timeout {args.timeout}\n"
                  "[engines]\nsmtbmc yices\n[script]\nplugin -i slang\n" + commands
                  + "prep -top formal_cache_nru -flatten\nasync2sync\ncheck -assert\n"
                  "prove: select -assert-count 2 t:$assume\n"
                  + ("" if mutant else "cover: select -assert-min 4 t:$assume\n")
                  + "select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n"
                  "[files]\nrapt_cache_nru.sv\nformal_cache_nru.sv\nrapt_sva.svh\n")
        (directory / "contract.sby").write_text(config)
        log = directory / "run.log"
        check, traces = run_sby(directory, args.timeout, negative=bool(mutant))
        row = {"ways": ways, "set_bits": bits, "read_ports": ports,
               "log": str(log.relative_to(output)), "log_sha256": sha(log), **check}
        if mutant:
            row["name"] = mutant
        row["witnesses"] = {str(p.relative_to(output)): sha(p) for p in traces}
        row["artifacts"] = {str(p.relative_to(directory)): sha(p) for p in directory.iterdir()
                            if p.is_file()}
        with lock:
            report["negative_controls" if mutant else "proofs"].append(row)
            save()
        print(name, "PASS" if row["passed"] else "INCOMPLETE", flush=True)
        return row["passed"]

    save()
    cases = [(w, s, p, None) for w in (2, 4, 8, 16, 32) for s in (1, 6) for p in (1, 2)]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, cases))
        passed += list(pool.map(run, [(4, 1, 2, m) for m in NRU_MUTATIONS]))
    if fingerprints != fingerprint(sources):
        raise RuntimeError("NRU proof sources changed during execution")
    report["complete"] = all(passed)
    save()
    if not all(passed):
        raise SystemExit("Incomplete NRU contract; inspect results.json")
    print("FORMAL COMPLETE: NRU priority, epoch and invalidation", flush=True)


# --- Recovery selection: masks, held ties, cancellation and target transport ---

RECOVERY_RTL = ROOT / "rtl/backend/rapt_recovery_pending.sv"
RECOVERY_HARNESS = FORMAL / "formal_recovery_pending.sv"
RECOVERY_MUTATIONS = {
    "port-mask": ("localparam int Port = active_port(leaf - 1);",
                  "localparam int Port = leaf - 1;"),
    "held-tie": ("tree_age[2*node] <= tree_age[2*node+1]",
                 "tree_age[2*node] < tree_age[2*node+1]"),
    "owner-generation": ("owner_generation[owner] == generation", "1'b1"),
}
INDUCTION = "Induction step proven: SUCCESS!"
MODEL = "SAT solving finished - model found:"
FAIL = "SAT proof finished - model found: FAIL!"


def recovery(parser, args):
    output = prepare_output(parser, args)
    output.mkdir(parents=True, exist_ok=True)
    inputs = [RECOVERY_RTL, RECOVERY_HARNESS, *DRIVERS]
    fingerprints = fingerprint(inputs)
    report = {"complete": False, "whole_rtl_signoff": False, "sources": fingerprints,
              "proofs": [], "negative_controls": [],
              "assumptions": ["First sampled edge resets", "ROB head is below Entries"],
              "scope": "Oldest live matching-generation request, enabled ports only, held "
                       "request tie priority, port priority, arbitrary reset/flush, stale-owner "
                       "cancellation and complete owner/target/generation payload. ROU "
                       "publication, checkpoint restoration and redirect application are separate."}
    lock = threading.Lock()
    save = evidence_writer(output, report)

    def run(case):
        entries, ports, mask, bits, mutation = case
        label = "negative-" + mutation if mutation else f"e{entries}-p{ports}-m{mask:x}-x{bits}"
        directory = output / label
        directory.mkdir()
        source = RECOVERY_RTL
        if mutation:
            text = mutate(RECOVERY_RTL.read_text(), *RECOVERY_MUTATIONS[mutation],
                          "recovery " + mutation)
            source = directory / "mutant.sv"
            source.write_text(text)
        base = ("read_slang --threads 1 --single-unit -DFORMAL --top formal_recovery_pending "
                f"-GEntries={entries} -GPorts={ports} -GPortMask={mask} -GXlen={bits} "
                f"{source} {RECOVERY_HARNESS}; select -assert-none t:$assert; "
                "chformal -assume -lower; prep -top formal_recovery_pending -flatten; "
                "memory_map; opt; check -assert; select -assert-count 1 t:$assume; "
                "select -assert-none t:$anyseq t:$anyconst A:blackbox=1; ")

        def invoke(name, command, marker):
            script, log = directory / (name + ".ys"), directory / (name + ".log")
            script.write_text(command + "\n")
            text = run_yosys(command, log, args.timeout)
            if marker not in text or "ERROR:" in text:
                raise RuntimeError("Incomplete recovery check: " + str(log))
            return dict(script=script.name, log=log.name, log_sha256=sha(log))

        row = dict(entries=entries, ports=ports, port_mask=mask, target_bits=bits,
                   generation_bits=4, directory=label)
        if mutation:
            witness = directory / "counterexample.vcd"
            row["check"] = invoke("negative", base + "sat -seq 5 -set-def-inputs "
                "-set-at 1 reset 1 -set-assumes -prove correct 1 -show-inputs -show-outputs "
                f"-dump_vcd {witness}", FAIL)
            if not witness.exists() or not witness.stat().st_size:
                raise RuntimeError("Missing recovery counterexample")
            row.update(name=mutation, witness_sha256=sha(witness))
        else:
            row["check"] = invoke("proof", base + "sat -verify -tempinduct -seq 2 -maxsteps 4 "
                "-set-def-inputs -set-at 1 reset 1 -set-assumes -prove correct 1", INDUCTION)
            events = [0] + ([1, 2, 3, 4, 6] if mask else [])
            if mask != (1 << ports) - 1:
                events.append(5)
            row["covers"] = []
            for event in events:
                witness = directory / f"event{event}.vcd"
                check = invoke(f"event{event}", base + "sat -seq 5 -set-def-inputs "
                    "-set reset 0 -set-at 1 reset 1 -set-assumes -set correct 1 "
                    f"-set-at 5 activated[{event}] 1 -show-inputs -show-outputs "
                    f"-dump_vcd {witness}", MODEL)
                if not witness.exists() or not witness.stat().st_size:
                    raise RuntimeError("Missing recovery activation")
                row["covers"].append(dict(event=event, witness_sha256=sha(witness), **check))
        with lock:
            report["negative_controls" if mutation else "proofs"].append(row)
            save()
        print(label, "PASS", flush=True)

    save()
    dimensions = [(1, 1, 1, 8), (7, 3, 7, 8), (7, 3, 5, 8), (8, 5, 3, 32),
                  (128, 5, 31, 8), (127, 8, 85, 40)]
    for entries, ports, mask in ((32, 6, 7), (32, 7, 15), (64, 8, 31),
                                  (128, 8, 31), (32, 6, 0)):
        dimensions += [(entries, ports, mask, bits) for bits in (32, 40)]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(run, [(*case, None) for case in dimensions]))
        list(pool.map(run, [(7, 3, 5, 8, m) for m in RECOVERY_MUTATIONS]))
    if fingerprints != fingerprint(inputs):
        raise RuntimeError("Recovery proof sources changed during execution")
    report["complete"] = True
    save()
    print("FORMAL COMPLETE: recovery port masks, ordering, generation and transport", flush=True)


# --- Stream queue: banked/prefetched payloads equal the original flop reference ---

QUEUE_RTL = ROOT / "rtl/common/rapt_stream_queue.sv"
QUEUE_HARNESS = FORMAL / "formal_stream_queue.sv"
QUEUE_SHADOW = ROOT / "verification/xsim/stream_queue_shadow.sv"
QUEUE_MUTATIONS = {
    "collision-forward": ("forward_q_valid ? forward_q : read_q", "read_q"),
    "bank-write-row": ("assign write_row = tail_bank > BankBits'(b) ? next_tail_row : tail_row;",
                       "assign write_row = tail_row;"),
    "flush": ("if (reset || flush) begin\n      head <= '0;",
              "if (reset) begin\n      head <= '0;"),
}


def stream_queue(parser, args):
    output = prepare_output(parser, args, yosys_paths=True)
    output.mkdir(parents=True, exist_ok=True)
    sources = [QUEUE_RTL, QUEUE_HARNESS, QUEUE_SHADOW, ROOT / "rtl/rapt_pkg.sv",
               FORMAL / "yosys-rvfi-compat.sh", *DRIVERS]
    for folder in ("rtl/include", "rtl/configs/formal"):
        sources += sorted((ROOT / folder).rglob("*.svh"))
    fingerprints = fingerprint(sources)
    result = {"complete": False, "whole_rtl_signoff": False, "sources": fingerprints,
              "proofs": [], "negative_controls": [],
              "assumptions": ["First edge resets", "Observer bit is in range and stable"],
              "scope": "Uncut equivalence to pre-banking flop reference: leading-prefix "
                       "transfers, capacity, pointers, ready/valid, every known stored word, "
                       "visible payload, reset/flush, wrap and collision forwarding. "
                       "A universally quantified stable bit covers every payload bit. "
                       "DUT inputs and initial payloads remain free. Undriven memory-map "
                       "leaves for invalid addresses remain unconstrained, never tied off. "
                       "Packet formation, "
                       "core-level flush delivery and ISA ordering are separate."}
    lock = threading.Lock()
    save = evidence_writer(output, result)

    def run(case):
        depth, incoming, outgoing, width, reclaim, bram, mutation = case
        name = ("negative-" + mutation if mutation else
                f"d{depth}-i{incoming}-o{outgoing}-w{width}-r{reclaim}-b{bram}")
        directory = output / name
        directory.mkdir()
        source = QUEUE_RTL
        if mutation:
            text = mutate(QUEUE_RTL.read_text(), *QUEUE_MUTATIONS[mutation], "queue " + mutation)
            source = directory / "mutant.sv"
            source.write_text(text)
        read = ("read_slang --threads 1 --single-unit --top formal_stream_queue "
                f"-DRAPT_FPGA_STREAM_BRAM={bram} -GDepth={depth} -GInWidth={incoming} "
                f"-GOutWidth={outgoing} -GItemBits={width} -GReclaimSameCycle={reclaim} "
                f"-I{ROOT}/rtl/configs/formal -I{ROOT}/rtl/include "
                f"{ROOT}/rtl/rapt_pkg.sv {source} {QUEUE_SHADOW} {QUEUE_HARNESS}\n")
        tasks = "[tasks]\nprove\n" + ("" if mutation else "cover\n")
        options = "[options]\nprove: mode " + ("bmc\n" if mutation else "prove\n")
        options += "" if mutation else "cover: mode cover\n"
        options += f"prove: depth {12 if mutation else 4}\n"
        options += "" if mutation else f"cover: depth {3*depth+6}\n"
        config = (tasks + options + f"timeout {args.timeout}\n[engines]\nsmtbmc {args.solver}\n"
                  "[script]\nplugin -i slang\n" + read
                  + "prep -top formal_stream_queue -flatten\nasync2sync\nmemory_map\nopt\n"
                  "select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n"
                  "setundef -undriven -anyseq\ncheck -assert\n"
                  "select -assert-count 3 t:$assume\n")
        (directory / "contract.sby").write_text(config)
        log = directory / "run.log"
        check, traces = run_sby(directory, args.timeout, negative=bool(mutation))
        row = dict(depth=depth, incoming=incoming, outgoing=outgoing, item_bits=width,
                   reclaim_same_cycle=reclaim, block_ram=bram, solver=args.solver,
                   log=str(log.relative_to(output)), log_sha256=sha(log), **check)
        if mutation:
            row["name"] = mutation
        row["witnesses"] = {str(p.relative_to(output)): sha(p) for p in traces}
        row["artifacts"] = {str(p.relative_to(directory)): sha(p) for p in directory.iterdir()
                            if p.is_file()}
        with lock:
            result["negative_controls" if mutation else "proofs"].append(row)
            save()
        print(name, "PASS" if row["passed"] else "INCOMPLETE", flush=True)
        return row["passed"]

    geometries = [(1, 1, 1), (3, 1, 2), (3, 3, 3), (6, 3, 3), (7, 3, 4),
                  (8, 1, 4), (8, 4, 1), (8, 3, 3), (8, 4, 4), (16, 8, 8)]
    cases = [(d, i, o, 8, r, b, None) for d, i, o in geometries for r in (0, 1)
             for b in ((0, 1) if i == o and i >= 4 and r == 0 else (0,))]
    cases += [(8, 4, 4, 97, 0, b, None) for b in (0, 1)]
    cases += [(16, 8, 8, 97, 0, 1, None)]
    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, cases))
        controls = [(8, 4, 4, 8, 0, 1, "collision-forward"),
                    (8, 3, 3, 8, 0, 0, "bank-write-row"), (8, 4, 4, 8, 0, 1, "flush")]
        passed += list(pool.map(run, controls))
    if fingerprints != fingerprint(sources):
        raise RuntimeError("Stream queue proof sources changed during execution")
    result["complete"] = all(passed)
    save()
    if not all(passed):
        raise SystemExit("Incomplete stream queue contract")
    print("FORMAL COMPLETE: stream queue payload, flush, wrap and collision forwarding", flush=True)


# --- SRAM: every registered 1RW shape against a symbolic-word contract ---
# The macro cases use the repository's ideal functional stub, not characterized
# OpenRAM timing or a physical macro implementation. The only assumption holds
# the observer address stable; DUT transactions and initial contents are free.

SRAM_HARNESS = FORMAL / "formal_sram_word.sv"
SRAM_MUTATIONS = {
    "byte-mask": ("if (bwe[b])", "if (bwe[0])"),
    "output-hold": ("if (en && !wen) rdata <= mem[addr];", "if (en) rdata <= mem[addr];"),
    "macro-polarity": (".web0(~wen)", ".web0(wen)"),
}


def sram_shapes():
    rows = re.findall(r"rapt_openram_1rw_(\d+x\d+),(\d+),(\d+),(\d+)",
                      (SRAM_DIR / "Makefile").read_text())
    result = [(int(d), int(w), int(s)) for _, d, w, s in rows]
    if not result or len(set(result)) != len(result):
        raise ValueError("Empty or duplicate SRAM shape registry")
    # The largest behavioral memory is implemented by four 4096x64 macros.
    result.append((16384, 64, 8))
    return result


def sram_observation(depth, width, macro):
    if not macro:
        expression = "dut.mem[watched_address]"
    elif depth == 16384:
        expression = " : ".join(
            f"(watched_address[13:12] == 2'd{i}) ? "
            f"dut.g_16384x64.g_segment[{i}].u_sram.mem[watched_address[11:0]]"
            for i in range(3)
        )
        expression += " : dut.g_16384x64.g_segment[3].u_sram.mem[watched_address[11:0]]"
    else:
        branch = f"g_{depth}x{width}." + ("g_full_word." if width == 22 else "")
        expression = f"dut.{branch}u_sram.mem[watched_address]"
    return "wire [DataBits-1:0] observed_word =\n    " + expression + ";\n"


def sram_case(case, output, timeout, model_generator, mutant=None):
    depth, width, write_size, bwe, macro = case
    name = f"{depth}x{width}-bwe{bwe}-" + ("macro" if macro else "behavioral")
    if mutant:
        name = "negative-" + mutant
    directory = output / name
    directory.mkdir()
    (directory / "formal_sram_word.sv").write_text(SRAM_HARNESS.read_text())
    text = SRAM_RTL.read_text()
    if mutant:
        # Mutate every instance: macro polarity is repeated once per macro shape.
        old, new = SRAM_MUTATIONS[mutant]
        if old not in text:
            raise ValueError("Missing mutation anchor: " + mutant)
        text = text.replace(old, new)
    (directory / "rapt_sram_1rw.sv").write_text(text)
    (directory / "formal_sram_observe.svh").write_text(sram_observation(depth, width, macro))
    files = ["formal_sram_word.sv", "rapt_sram_1rw.sv", "formal_sram_observe.svh"]
    if macro:
        macro_depth = 4096 if depth == 16384 else depth
        model = model_generator.emit_v(
            f"rapt_openram_1rw_{macro_depth}x{width}", macro_depth, width, write_size)
        (directory / "macro.v").write_text(model)
        files.append("macro.v")
    define = "-DRAPT_USE_SRAM_MACRO " if macro else ""
    # Lower checks before auditing: no internal assumptions, free-state cells or
    # blackboxes may hide behind a frontend's representation of formal syntax.
    memories = 4 if macro and depth == 16384 else 1
    config = (
        "[tasks]\nprove\n" + ("" if mutant else "cover\n")
        + "[options]\nprove: mode prove\n"
        + ("" if mutant else "cover: mode cover\n")
        + f"depth 6\ntimeout {timeout}\n[engines]\nsmtbmc yices\n[script]\n"
        + "plugin -i slang\nread_slang --threads 1 --single-unit --top formal_sram_word "
        + f"-GAddrBits={int(math.log2(depth))} -GDataBits={width} -GUseBwe={bwe} "
        + define + " ".join(f for f in files if not f.endswith("svh")) + "\n"
        + "prep -top formal_sram_word -flatten\nasync2sync\ncheck -assert\n"
        + "select -assert-count 1 t:$assume\n"
        + f"select -assert-count {memories} t:$mem_v2\n"
        + "select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n"
        + "[files]\n" + "\n".join(files) + "\n"
    )
    (directory / "contract.sby").write_text(config)
    check, _ = run_sby(directory, timeout, negative=bool(mutant), force=True, grace=45)
    if not check["passed"]:
        raise RuntimeError("Incomplete SRAM contract or missing witness: " + name)
    log = (directory / "run.log").read_text()
    if not mutant and ("successful proof by k-induction" not in log or "reached cover" not in log):
        raise RuntimeError("Missing inductive/non-vacuous evidence: " + name)
    return {"case": name, "depth": depth, "width": width, "use_bwe": bwe,
            "macro": bool(macro), "proof": check["proof"], "log": str(directory / "run.log"),
            "artifacts": {str(p.relative_to(directory)): sha(p)
                          for p in directory.rglob("*") if p.is_file()}}


def sram(parser, args):
    output = prepare_output(parser, args)
    output.mkdir(parents=True, exist_ok=True)
    generator = load_sram_generator()
    paths = [SRAM_RTL, SRAM_HARNESS, SRAM_DIR / "Makefile", SRAM_GENERATOR,
             FORMAL / "yosys-rvfi-compat.sh", *DRIVERS]
    fingerprints = fingerprint(paths)
    result = {"complete": False, "sources": fingerprints, "proofs": [], "negative_controls": [],
              "assumption": "Only the symbolic observer address is stable after the first edge",
              "scope": "1RW masked/full writes, every symbolic row, synchronous read and "
                       "output hold; macro cases use ideal functional stubs, not physical macros"}
    save = evidence_writer(output, result)
    save()
    cases = [(d, w, s, bwe, macro) for d, w, s in sram_shapes()
             for bwe in ((0,) if w == 22 else (0, 1)) for macro in (0, 1)]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(sram_case, case, output, args.timeout, generator)
                   for case in cases]
        try:
            for future in as_completed(futures):
                row = future.result()
                result["proofs"].append(row)
                save()
                print("PASS: " + row["case"], flush=True)
        except BaseException:
            for future in futures:
                future.cancel()
            raise
    for name in SRAM_MUTATIONS:
        case = (8, 32, 8, 1, int(name == "macro-polarity"))
        result["negative_controls"].append(sram_case(case, output, args.timeout, generator, name))
        save()
    if fingerprints != fingerprint(paths):
        raise RuntimeError("SRAM proof source changed during the run")
    result["complete"] = True
    save()
    print("SRAM CONTRACT COMPLETE: all shapes, induction, covers and negative controls", flush=True)


# --- L1D data: diagonal banks for every production geometry and memory binding ---

L1D_DATA_RTL = ROOT / "rtl/memory/rapt_l1d_data.sv"
L1D_DATA_HARNESS = FORMAL / "formal_l1d_data.sv"
L1D_DATA_MUTATIONS = {
    "byte-mask": [(" : write_strobe);", " : {WordBytes{write_strobe[0]}});")],
    "read-bank": [("ChunkBits'(Lane - int'(read_way) % Chunks)", "ChunkBits'(Lane)")],
    "read-row": [("BankAddrBits'(int'(read_chunk) % GroupWays)", "BankAddrBits'(0)")],
    "late-block": [(".en(!bank_write || !write_blocked)", ".en(1'b1)"),
                   (".wen(bank_write && !write_blocked)", ".wen(bank_write)")],
    "read-valid": [("if (reset || bank_write)", "if (reset || (bank_write && !write_blocked))")],
    "line-mask": [("write_line ? write_mask[word_offset]", "write_line ? 1'b1")],
}


def l1d_label(geometry, macro):
    xlen, sets, words, ways = geometry
    return f"x{xlen}-s{sets}-w{words}-a{ways}-" + ("macro" if macro else "behavioral")


def l1d_discover(preset, xlen, directory, defines=()):
    directory.mkdir()
    source = directory / "geometry.sv"
    source.write_text("""`include "rapt.svh"
module formal_l1d_geometry(output wire [31:0] xlen, set_bits, word_bits, ways);
  assign xlen = `RAPT_XLEN;
  assign set_bits = `RAPT_L1D_LEN;
  assign word_bits = `RAPT_L1D_LINE_LEN;
  assign ways = `RAPT_L1D_N_WAYS;
endmodule
""")
    define = ("-DRAPT_RV64 " if xlen == 64 else "")
    define += "".join("-D" + value + " " for value in defines)
    result = directory / "geometry.json"
    command = ("read_slang --threads 1 --single-unit --top formal_l1d_geometry " + define
               + f"-I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include {source}; "
               + "prep -top formal_l1d_geometry; " + f"write_json {result}")
    log = directory / "run.log"
    run_yosys(command, log, 60)
    module = json.loads(result.read_text())["modules"]["formal_l1d_geometry"]
    values = []
    for name in ("xlen", "set_bits", "word_bits", "ways"):
        bits = module["ports"][name]["bits"]
        if not bits or any(b not in ("0", "1") for b in bits):
            raise ValueError("Geometry output is not a constant: " + name)
        values.append(int("".join(reversed(bits)), 2))
    if values[0] != xlen or min(values[1:]) < 1:
        raise ValueError("Invalid production L1D geometry: " + repr(values))
    return tuple(values), {p.name: sha(p) for p in directory.iterdir() if p.is_file()}


def l1d_data(parser, args):
    output = prepare_output(parser, args, yosys_paths=True)
    presets = args.presets or sorted(p.parent.name for p in
                                    (ROOT / "rtl/configs").glob("*/rapt_config.svh"))
    if len(set(presets)) != len(presets):
        parser.error("Duplicate presets")
    for preset in presets:
        if not preset.replace("-", "").replace("_", "").isalnum():
            parser.error("Invalid preset name")
        if not (ROOT / "rtl/configs" / preset / "rapt_config.svh").is_file():
            parser.error("Unknown preset: " + preset)
    # Geometry reuse is valid only while these primitives have no other
    # configuration-sensitive behavior. New directives/macros fail this audit.
    conditional = set()
    macro_calls = set()
    for path in (L1D_DATA_RTL, SRAM_RTL):
        text = path.read_text()
        conditional.update(re.findall(r"`(?:ifdef|ifndef|elsif)\s+(\w+)", text))
        macro_calls.update(re.findall(r"`(\w+)", text))
    plain_macros = {"include", "ifdef", "else", "endif"}
    if conditional != {"RAPT_USE_SRAM_MACRO"} or macro_calls - plain_macros:
        raise ValueError("Primitive configuration dependencies changed; audit profile reuse")
    output.mkdir(parents=True, exist_ok=True)
    sources = [L1D_DATA_RTL, SRAM_RTL, L1D_DATA_HARNESS, *DRIVERS, SRAM_GENERATOR,
               SRAM_DIR / "Makefile", FORMAL / "yosys-rvfi-compat.sh"]
    sources += sorted((ROOT / "rtl/include").rglob("*.svh"))
    for preset in presets:
        sources += sorted((ROOT / "rtl/configs" / preset).rglob("*.svh"))
    # The common proof frontend uses the formal header; native preset geometry
    # is independently elaborated above and both SRAM branches are proved.
    sources += sorted((ROOT / "rtl/configs/formal").rglob("*.svh"))
    fingerprints = fingerprint(sources)
    result = {
        "complete": False, "whole_rtl_signoff": False, "sources": fingerprints,
        "profiles": [], "proofs": [], "negative_controls": [],
        "assumptions": ["Observer coordinates are stable", "Observer way is legal",
                        "Read and write ways are legal"],
        "scope": "Uncut L1D diagonal data banks plus real SRAM wrapper. Every symbolic "
                 "set/way/word/byte, partial and line writes, blocked-port reservation, "
                 "synchronous word/line reads, bank validity and output hold. No reset or "
                 "initial-memory assumption. Macro branch uses ideal generated functional "
                 "stubs; physical macro equivalence, tags, arbitration, coherence and "
                 "architectural memory ordering remain separate.",
        "geometry_reuse_audit": {"conditional_macros": sorted(conditional),
                                 "macro_calls": sorted(macro_calls)},
        "arithmetic_lowering": "Standard Yosys techmap for div/mod operands narrower than "
                               "log2(Chunks), avoiding an opt_expr small-operand slicing "
                               "failure. This preserves all sequential state and memories.",
        "yosys": subprocess.check_output(
            [os.environ.get("RAPTOR_YOSYS_REAL", "yosys"), "-V"], text=True).strip(),
    }
    lock = threading.Lock()
    save = evidence_writer(output, result)

    discovery = output / "geometry"
    discovery.mkdir()
    geometries = set()
    for preset in presets:
        for xlen in (32, 64):
            variants = [()]
            if preset == "default":
                variants += [(f"RAPT_L1D_N_WAYS={ways}", f"RAPT_L1D_NRU={nru}")
                             for ways in (8, 16) for nru in (0, 1)]
            for defines in variants:
                name = f"{preset}-rv{xlen}"
                if defines:
                    name += "-" + "-".join(defines)
                geometry, artifacts = l1d_discover(preset, xlen, discovery / name, defines)
                geometries.add(geometry)
                result["profiles"].append(dict(preset=preset, xlen=xlen, defines=defines,
                    geometry=geometry, directory="geometry/" + name, artifacts=artifacts,
                    bindings={m: l1d_label(geometry, m == "sram") for m in ("dff", "sram")}))
    if not args.production_only:
        geometries.update((x, 1, w, a) for x in (32, 64) for w in (1, 2, 3, 4)
                          for a in (1, 2, 4, 8))
        geometries.update(((32, 1, 4, 16), (64, 1, 3, 16)))
    generator = load_sram_generator()
    shapes = {(int(d), int(w)) for d, w in re.findall(
        r"rapt_openram_1rw_\d+x\d+,(\d+),(\d+),\d+", (SRAM_DIR / "Makefile").read_text())}

    def run(case):
        geometry, macro, mutation = case
        xlen, sets, words, ways = geometry
        chunks = (2 ** words) * xlen // 64
        banks = ((ways + chunks - 1) // chunks) * chunks
        rows = 2 ** sets * min(ways, chunks)
        name = "negative-" + mutation if mutation else l1d_label(geometry, macro)
        directory = output / name
        directory.mkdir()
        source = L1D_DATA_RTL
        if mutation:
            text = L1D_DATA_RTL.read_text()
            for old, new in L1D_DATA_MUTATIONS[mutation]:
                text = mutate(text, old, new, mutation + ": " + old)
            source = directory / "mutant.sv"
            source.write_text(text)
        branch = f"g_{rows}x64.u_sram." if macro else ""
        observe = directory / "formal_l1d_data_observe.svh"
        observe.write_text("for (genvar b = 0; b < Banks; b++) begin : g_observe\n"
            f"  wire [63:0] word_value = dut.g_bank[b].u_sram.{branch}mem[observed_row];\n"
            "  assign physical_byte[b] = word_value[observed_byte_lane*8+:8];\nend\n")
        files = [source, SRAM_RTL, L1D_DATA_HARNESS]
        defines = "-DRAPT_RV64 " if xlen == 64 else ""
        if macro:
            if (rows, 64) not in shapes:
                raise ValueError("Unregistered production bank macro: " + str(rows))
            stub = directory / "macro.v"
            stub.write_text(generator.emit_v(f"rapt_openram_1rw_{rows}x64", rows, 64, 8))
            files.append(stub)
            defines += "-DRAPT_USE_SRAM_MACRO "
        read = ("read_slang --threads 1 --single-unit --top formal_l1d_data -DSYNTHESIS "
                + defines + f"-GXlen={xlen} -GSetBits={sets} -GWordBits={words} -GWays={ways} "
                + f"-I{ROOT}/rtl/configs/formal -I{ROOT}/rtl/include -I{directory} "
                + " ".join(map(str, files)))
        tasks = "[tasks]\nprove\n" + ("" if mutation else "cover\n")
        options = "[options]\nprove: mode " + ("bmc\n" if mutation else "prove\n")
        options += "depth 6\n" + ("" if mutation else "cover: mode cover\n")
        narrow_limit = int(math.log2(chunks))
        arithmetic = ""
        if narrow_limit >= 3:
            arithmetic = (f"techmap t:$div t:$mod %u r:A_WIDTH<{narrow_limit} %i\n"
                          "select -clear\nopt\n")
        config = (tasks + options + f"timeout {args.timeout}\n[engines]\nsmtbmc yices\n"
                  "[script]\nplugin -i slang\n" + read
                  + "\nprep -top formal_l1d_data -flatten\nasync2sync\n"
                  "select -assert-count 3 t:$assume\n"
                  "select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n"
                  + arithmetic
                  + "check -assert\n"
                  "select -assert-min 1 t:$assume\nselect -assert-max 3 t:$assume\n"
                  + f"select -assert-count {banks} t:$mem_v2\n"
                  "select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n")
        (directory / "contract.sby").write_text(config)
        bundled = ROOT / "third_party/oss-cad-suite/bin"
        env = dict(os.environ, PATH=str(bundled) + os.pathsep + os.environ["PATH"])
        log = directory / "run.log"
        command = [str(bundled / "sby"), "--yosys", str(FORMAL / "yosys-rvfi-compat.sh"),
                   "contract.sby"]
        with log.open("w") as stream:
            process = subprocess.run(command, cwd=directory, env=env, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=args.timeout + 60)
        row = dict(geometry=geometry, macro=macro, banks=banks, rows_per_bank=rows,
                   narrow_arithmetic_threshold=narrow_limit if arithmetic else None,
                   exit=process.returncode, log=str(log.relative_to(output)), log_sha256=sha(log))
        for task in (("prove",) if mutation else ("prove", "cover")):
            status = directory / ("contract_" + task) / "status"
            row[task] = status.read_text().split()[0] if status.exists() else "ERROR"
        folder = directory / ("contract_prove" if mutation else "contract_cover") / "engine_0"
        traces = sorted(folder.glob("trace*.vcd"))
        row["witnesses"] = {str(p.relative_to(output)): sha(p) for p in traces}
        if mutation:
            row["name"] = mutation
            row["passed"] = (row["prove"] == "FAIL" and "Assert failed" in log.read_text()
                             and "ERROR:" not in log.read_text() and bool(traces)
                             and all(p.stat().st_size for p in traces))
        else:
            row["case"] = name
            row["passed"] = (process.returncode == 0 and row["prove"] == "PASS"
                             and row["cover"] == "PASS" and bool(traces)
                             and all(p.stat().st_size for p in traces))
        row["artifacts"] = {p.name: sha(p) for p in directory.iterdir() if p.is_file()}
        with lock:
            result["negative_controls" if mutation else "proofs"].append(row)
            save()
        print(name, "PASS" if row["passed"] else "INCOMPLETE", flush=True)
        return row["passed"]

    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, [(g, m, None) for g in sorted(geometries) for m in (0, 1)]))
        passed += list(pool.map(run, [((32, 1, 2, 2), 0, m) for m in L1D_DATA_MUTATIONS]))
    if fingerprints != fingerprint(sources):
        raise RuntimeError("L1D data contract inputs changed during execution")
    result["complete"] = all(passed)
    save()
    if not all(passed):
        raise SystemExit("Incomplete L1D data bank contract")
    print("FORMAL COMPLETE: L1D diagonal data mapping, masked writes, blocking and reads")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    contracts = parser.add_subparsers(dest="contract", required=True)
    commands = {}
    for name, function, timeout, summary in (
            ("nru", nru, 180, "NRU priority, epoch rollover and invalidation"),
            ("recovery", recovery, 120, "Recovery selection, ties, cancellation, transport"),
            ("stream-queue", stream_queue, 180, "Banked stream queue equals flop reference"),
            ("sram", sram, 120, "Every registered 1RW SRAM shape"),
            ("l1d-data", l1d_data, 120, "L1D diagonal data banks for every geometry")):
        command = contracts.add_parser(name, help=summary, description=summary)
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--jobs", type=int, default=2)
        command.add_argument("--timeout", type=int, default=timeout)
        commands[name] = (command, function)
    commands["stream-queue"][0].add_argument("--solver", choices=("bitwuzla", "yices", "z3"),
                                             default="bitwuzla")
    commands["l1d-data"][0].add_argument("--presets", nargs="+")
    commands["l1d-data"][0].add_argument("--production-only", action="store_true")
    args = parser.parse_args()
    command, function = commands[args.contract]
    function(command, args)


if __name__ == "__main__":
    main()
