#!/usr/bin/env python3
"""Compose multiply, divide and mixed-stream arithmetic and transport proofs."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from yosys_common import ROOT, run_bounded, run_yosys as execute_yosys, run_yosys_check


SAT_PASS = "SAT proof finished - no model found: SUCCESS!"

SAT_FAIL = "SAT proof finished - model found: FAIL!"

INDUCT_PASS = "Induction step proven: SUCCESS!"

DUT = ROOT / "rtl/backend/ieu/rapt_ieu_mul.sv"

FORMAL = ROOT / "verification/formal"

YOSYS = os.environ.get("RAPTOR_YOSYS_REAL", "yosys")


def invoke(command, output, name, timeout, success):
    row = run_yosys_check(command, output, name, timeout, success)
    row.update(script=str(output / row['script']), log=str(output / row['log']))
    return row


def read(top, source, params):
    return (
        f"read_slang --threads 1 --single-unit -DFORMAL -I{ROOT}/rtl/configs/default "
        f"-I{ROOT}/rtl/include --top {top} -DRAPT_{top.upper()} {params} "
        f"{source} {FORMAL / 'formal_ieu_mul.sv'}; "
        f"chformal -assume -lower; prep -top {top} -flatten; "
    )


def arithmetic(source, xlen, operation, word, dsp):
    params = f"-GXLEN={xlen} -GOperation={operation} -GWord={word} -GUseDsp={dsp}"
    command = read("formal_mul_datapath", source, params)
    for lhs, rhs in (
        ("m1_s1", "a"), ("m1_s2", "b"),
        ("m1_op", "selected_op"), ("m1_word", str(word)),
    ):
        if lhs == "m1_word" and xlen == 32:
            continue
        command += (
            f"select -assert-count 1 w:dut.{lhs}; "
            f"delete w:dut.{lhs} %ci1 t:*dff* %i; "
            f"connect -set dut.{lhs} {rhs}; "
        )
    return command + (
        "opt -full; check -assert; "
        "select -assert-none t:$dff t:$dffe t:$sdff t:$sdffe t:$sdffce; "
        "select -assert-count 1 w:mismatch; "
    )


def transport(source, xlen, tag, dsp):
    command = read(
        "formal_mul_transport", source, f"-GXLEN={xlen} -GTagBits={tag} -GUseDsp={dsp}",
    )
    return command + (
        "select -assert-count 1 w:dut.mul_r_comb; "
        "cutpoint w:dut.mul_r_comb; opt -full; check -assert; "
        "select -assert-none t:$mul; select -assert-count 1 t:$anyseq; "
    )


def multiply_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty to preserve earlier proof evidence")
    output.mkdir(parents=True, exist_ok=True)
    if any(char.isspace() or char in ';"' for char in str(output)):
        parser.error("Yosys output path cannot contain spaces, quotes or semicolons")
    files = [DUT, Path(__file__), Path(__file__).with_name("yosys_common.py"),
             FORMAL / "formal_ieu_mul.sv"]
    files += sorted((ROOT / "rtl/include").rglob("*.svh"))
    files += sorted((ROOT / "rtl/configs/default").rglob("*.svh"))

    def hashes():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in files}

    result = {
        "complete": False, "sources": hashes(), "arithmetic": [], "transport": [],
        "covers": [], "negative_controls": [],
        "scope": "MUL/MULH/MULHSU/MULHU/MULW; all operand values; pure multiply streams; "
                 "arbitrary reset, flush and per-tag cancellation; both DSP attribute paths; "
                 "not DIV/REM arithmetic, mixed multiply/divide arbitration or the parent MDQ",
        "composition": "exhaustive combinational stage-one arithmetic + unbounded registered "
                       "operand/opcode/word/tag ownership and result transport",
    }
    report = output / "results.json"

    def save():
        report.write_text(json.dumps(result, indent=2) + "\n")

    save()
    for xlen in (32, 64):
        cases = [(op, 0) for op in range(4)] + ([(0, 1)] if xlen == 64 else [])
        for operation, word in cases:
            for dsp in (0, 1):
                name = f"arithmetic-{xlen}-{operation}-{word}-{dsp}"
                row = invoke(
                    arithmetic(DUT, xlen, operation, word, dsp)
                    + "sat -verify -prove mismatch 0 -set-def-inputs",
                    output, name, args.timeout, SAT_PASS,
                )
                row.update(xlen=xlen, operation=operation, word=word, dsp=dsp)
                result["arithmetic"].append(row)
                save()
        for tag in (1, 2, 3):
            for dsp in (0, 1):
                name = f"transport-{xlen}-{tag}-{dsp}"
                row = invoke(
                    transport(DUT, xlen, tag, dsp)
                    + "sat -verify -tempinduct -seq 2 -maxsteps 8 -set-at 1 reset 1 "
                    "-set-assumes -prove correct 1",
                    output, name, args.timeout, INDUCT_PASS,
                )
                row.update(xlen=xlen, tag_bits=tag, dsp=dsp)
                result["transport"].append(row)
                save()
        events = [0, 1, 2, 3, 5, 6, 7, 8] + ([4] if xlen == 64 else [])
        for event in events:
            name = f"cover-{xlen}-{event}"
            row = invoke(
                transport(DUT, xlen, 2, 0)
                + f"sat -seq 8 -set-at 1 reset 1 -set-at 8 witnessed[{event}] 1 "
                f"-set-assumes -show-inputs -show-outputs -dump_vcd {output/name}.vcd",
                output, name, args.timeout, "SAT solving finished - model found:",
            )
            row.update(xlen=xlen, event=event)
            result["covers"].append(row)
            save()
        print(f"PASS: RV{xlen} full-operand arithmetic + inductive transport + covers", flush=True)
    text = DUT.read_text()
    arithmetic_mutant = output / "mutant-signedness.sv"
    anchor = "m1_sext_a = 1'b1;"
    if text.count(anchor) != 2:
        raise ValueError("Cannot locate multiply signedness mutation point")
    arithmetic_mutant.write_text(text.replace(anchor, "m1_sext_a = 1'b0;", 1))
    transport_mutant = output / "mutant-result-stage.sv"
    anchor = "m2_r <= mul_r_comb;"
    if text.count(anchor) != 1:
        raise ValueError("Cannot locate multiply register mutation point")
    transport_mutant.write_text(text.replace(anchor, "m2_r <= '0;"))
    for name, command, goal in (
        ("signedness", arithmetic(arithmetic_mutant, 32, 1, 0, 0), "mismatch 0"),
        ("result-stage", transport(transport_mutant, 32, 2, 0), "correct 1"),
    ):
        row = invoke(
            command + f"sat -seq 6 -set-at 1 reset 1 -set-assumes -prove {goal} "
            f"-show-inputs -show-outputs -dump_vcd {output}/negative-{name}.vcd",
            output, "negative-" + name, args.timeout, SAT_FAIL,
        )
        result["negative_controls"].append(dict(name=name, **row))
        save()
    if hashes() != result["sources"]:
        raise RuntimeError("Formal source changed during proof")
    result["complete"] = True
    result["yosys"] = subprocess.check_output([YOSYS, "-V"], text=True).strip()
    save()
    print("FORMAL COMPOSITION COMPLETE: multiply arithmetic and transport", flush=True)


HARNESS = FORMAL / "formal_div_refinement.sv"

INDUCTION = "Induction step proven: SUCCESS!"

MODEL = "SAT solving finished - model found:"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def divide_read(source, xlen, tag=2, dsp=0, wrapper=None):
    top = "formal_div_fixed" if wrapper else "formal_div_refinement"
    params = "" if wrapper else f"-GXLEN={xlen} -GTagBits={tag} -GUseDsp={dsp}"
    files = f"{source} {HARNESS}" + (f" {wrapper}" if wrapper else "")
    return (
        f"read_slang --threads 1 --single-unit -DFORMAL -I{ROOT}/rtl/configs/default "
        f"-I{ROOT}/rtl/include --top {top} {params} {files}; "
        f"chformal -assume -lower; prep -top {top} -flatten; memory_map; opt; "
        "check -assert; select -assert-none t:$div t:$mod t:$anyconst t:$anyseq; "
    )


def fixed_wrapper(output, name, xlen, operation, word, a, b):
    mask = (1 << xlen) - 1
    source = output / f"{name}.sv"
    source.write_text(f"""module formal_div_fixed (
    input logic clock, reset, flush, valid,
    input logic [3:0] cancel,
    output logic correct,
    output logic [9:0] witnessed
);
  formal_div_refinement #(.XLEN({xlen}), .TagBits(2)) uut (
    .clock, .reset, .flush, .valid, .cancel,
    .word(1'b{word}), .operation(2'd{operation}), .tag(2'd1),
    .a({xlen}'h{a & mask:x}), .b({xlen}'h{b & mask:x}), .correct, .witnessed
  );
endmodule
""")
    return source


def divide_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--z3", default=os.environ.get("RAPTOR_Z3", "z3"))
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty to preserve earlier proof evidence")
    for path in (ROOT, output):
        if any(char.isspace() or char in ';"' for char in str(path)):
            parser.error("Yosys paths cannot contain spaces, quotes or semicolons")
    output.mkdir(parents=True, exist_ok=True)
    lemmas = [FORMAL / "lemmas/div.smt2"]
    files = [HARNESS, Path(__file__), Path(__file__).with_name("yosys_common.py")] + lemmas
    files += sorted(p for p in (ROOT / "rtl").rglob("*")
                    if p.suffix in {".sv", ".svh", ".v", ".vh"})

    def fingerprints():
        return {str(path.relative_to(ROOT)): sha(path) for path in files}

    result = {
        "complete": False, "sources": fingerprints(), "lemmas": [], "refinement": [],
        "covers": [], "negative_controls": [],
        "scope": "DIV/DIVU/REM/REMU and RV64 W forms; all operands; pure division streams; "
                 "arbitrary reset/flush, blocked presentations and per-tag cancellation; "
                 "not mixed multiply/divide arbitration or parent MDQ composition",
        "composition": [
            "Zero prefix satisfies Euclidean decomposition for every positive divisor",
            "Each canonical bit step preserves decomposition and remainder bounds",
            "The quotient/remainder pair is unique; signed correction truncates toward zero",
            "RTL refines the canonical steps without truncation; prefix equals dividend at end",
            "Zero divisor and XLEN/W modular encoding are checked directly by refinement",
            "A decreasing remaining-bit count and age invariant prove bounded completion",
        ],
        "assumptions": ["First-edge reset", "RV32 has no W-form operations"],
    }

    def save():
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    save()
    lemma = lemmas[0]
    copied = output / lemma.name
    copied.write_bytes(lemma.read_bytes())
    log = output / "div-lemmas.log"
    with log.open("w") as stream:
        process = run_bounded([args.z3, str(copied)], stdout=stream,
                              stderr=subprocess.STDOUT, timeout=args.timeout)
    text = log.read_text()
    if (process.returncode or not text.startswith("unsat\n") or "(error" in text
            or text.splitlines().count("unsat") != 4 or text.count("(proof") != 4):
        raise RuntimeError("Incomplete mathematical lemma bundle")
    result["lemmas"] = [dict(name="div_" + name, log=log.name)
                        for name in ("base", "sign", "step", "unique")]
    save()
    for xlen in (32, 64):
        for tag in (1, 2, 3):
            for dsp in (0, 1):
                name = f"refinement-{xlen}-tag{tag}-dsp{dsp}"
                row = run_yosys_check(
                    divide_read(DUT, xlen, tag, dsp)
                    + "sat -verify -tempinduct -seq 1 -maxsteps 1 -set-at 1 reset 1 "
                    "-set-assumes -prove correct 1",
                    output, name, args.timeout, INDUCTION,
                )
                result["refinement"].append(dict(xlen=xlen, tag_bits=tag, dsp=dsp, **row))
                save()
        cases = [(f"op{op}", op, 0, 37, 5, op, 12) for op in range(4)]
        if xlen == 64:
            for op in range(4):
                a = 0xDEADBEEFFFFFF_FFDB if not op & 1 else 0xDEADBEEF8000000B
                b = 0x0123456700000005 if not op & 1 else 0x0123456700000001
                cases.append((f"word-op{op}", op, 1, a, b, 4, 24))
            cases.append(("word-remu-zero", 3, 1, 0x123456788000000B, 0, 5, 24))
        cases += [
            ("zero-dividend", 0, 0, 0, 7, 0, 8),
            ("zero-divisor", 0, 0, 37, 0, 5, 12),
            ("negative-a", 0, 0, -37, 5, 0, 12),
            ("negative-b", 2, 0, 37, -5, 2, 12),
            ("both-negative", 2, 0, -37, -5, 6, 12),
            ("signed-overflow", 0, 0, 1 << (xlen - 1), -1, 9, xlen // 2 + 6),
            ("cancel-busy", 0, 0, 37, 5, 7, 8),
            ("flush-busy", 0, 0, 37, 5, 8, 8),
        ]
        for label, op, word, a, b, event, depth in cases:
            name = f"cover-{xlen}-{label}"
            wrapper = fixed_wrapper(output, name, xlen, op, word, a, b)
            controls = "" if label == "cancel-busy" else "-set cancel 0 "
            if label != "flush-busy":
                controls += "-set flush 0 "
            row = run_yosys_check(
                divide_read(DUT, xlen, wrapper=wrapper)
                + f"sat -seq {depth} -set reset 0 -set-at 1 reset 1 -set valid 1 "
                + controls + f"-set-assumes -set-at {depth} witnessed[{event}] 1 "
                + f"-show-inputs -show-outputs -dump_vcd {output/name}.vcd",
                output, name, args.timeout, MODEL,
            )
            result["covers"].append(dict(xlen=xlen, case=label, depth=depth, event=event, **row))
            save()
        print(f"PASS: RV{xlen} divider refinement, progress and cover witnesses", flush=True)

    text = DUT.read_text()
    sign_anchor = ("assign div_q_signed = (div_sign == 2'b00 || div_sign == 2'b11) "
                   "? div_quotient : -div_quotient;")
    mutations = [
        ("normalization", "div_normalized << 1", "div_normalized << 2", 37, 5),
        ("signed-result", sign_anchor, "assign div_q_signed = div_quotient;", -37, 5),
        ("zero-divisor", "if (div_s2 == 0) div_out_r <= ~'h0;",
         "if (div_s2 == 0) div_out_r <= '0;", 37, 0),
    ]
    for name, old, new, a, b in mutations:
        if old not in text:
            raise ValueError("Missing mutation anchor: " + name)
        source = output / ("mutant-" + name + ".sv")
        source.write_text(text.replace(old, new, 1))
        wrapper = fixed_wrapper(output, "negative-" + name, 32, 0, 0, a, b)
        row = run_yosys_check(
            divide_read(source, 32, wrapper=wrapper)
            + "sat -seq 12 -set reset 0 -set-at 1 reset 1 -set valid 1 -set cancel 0 "
            + "-set flush 0 -set-assumes -prove correct 1 -show-public "
            + f"-dump_vcd {output}/negative-{name}.vcd",
            output, "negative-" + name, args.timeout, SAT_FAIL,
        )
        if not (output / f"negative-{name}.vcd").stat().st_size:
            raise RuntimeError("Missing mutation counterexample: " + name)
        result["negative_controls"].append(dict(name=name, **row))
        save()
    if fingerprints() != result["sources"]:
        raise RuntimeError("Divider proof source changed during the run")
    result["yosys"] = subprocess.check_output([YOSYS, "-V"], text=True).strip()
    result["z3"] = subprocess.check_output([args.z3, "-version"], text=True).strip()
    result["complete"] = True
    save()
    print("FORMAL COMPOSITION COMPLETE: DIV/REM numerical refinement and transport", flush=True)


def run_yosys(command, output, name, timeout, marker):
    script, log = output / (name + ".ys"), output / (name + ".log")
    script.write_text(command + "\n")
    text = execute_yosys(command, log, timeout)
    if marker not in text or "ERROR:" in text:
        raise RuntimeError(f"Incomplete mixed MUL/DIV proof: {name}; see {log}")
    return {"script": script.name, "log": log.name, "exit": 0}


def prerequisite(path, kind, output):
    report = json.loads(path.read_text())
    if not report.get("complete"):
        raise ValueError("Incomplete arithmetic prerequisite: " + kind)
    for name, digest in report["sources"].items():
        if sha(ROOT / name) != digest:
            raise ValueError("Stale arithmetic prerequisite: " + name)
    variants = {(xlen, tag, dsp) for xlen in (32, 64)
                for tag in (1, 2, 3) for dsp in (0, 1)}
    transport = report["transport" if kind == "multiply" else "refinement"]
    if {(row["xlen"], row["tag_bits"], row["dsp"]) for row in transport} != variants:
        raise ValueError("Missing arithmetic parameter variants: " + kind)
    rows = [(row, INDUCTION) for row in transport]
    if kind == "multiply":
        expected = {(x, op, word, dsp) for x in (32, 64) for dsp in (0, 1)
                    for op, word in ([(op, 0) for op in range(4)]
                                     + ([(0, 1)] if x == 64 else []))}
        actual = {(r["xlen"], r["operation"], r["word"], r["dsp"])
                  for r in report["arithmetic"]}
        if actual != expected:
            raise ValueError("Incomplete multiplication arithmetic")
        rows += [(row, SAT_PASS) for row in report["arithmetic"]]
    else:
        if {r["name"] for r in report["lemmas"]} != {
                "div_base", "div_step", "div_unique", "div_sign"}:
            raise ValueError("Missing Euclidean division lemmas")
        rows += [(row, "unsat\n") for row in report["lemmas"]]
    rows += [(row, MODEL) for row in report["covers"]]
    rows += [(row, SAT_FAIL) for row in report["negative_controls"]]
    destination = output / "prerequisites" / kind
    destination.mkdir(parents=True)
    shutil.copy2(path, destination / "results.json")
    for row, marker in rows:
        # Reports may have been retrieved from another host. The basename is
        # stable; absolute execution paths remain preserved in their reports.
        log = path.parent / Path(row["log"]).name
        text = log.read_text()
        if marker not in text or "ERROR:" in text or "(error" in text:
            raise ValueError("Invalid arithmetic proof log: " + str(log))
        shutil.copy2(log, destination / log.name)
        if "script" in row:
            script = path.parent / Path(row["script"]).name
            shutil.copy2(script, destination / script.name)
    return report["sources"]


def mixed_read(source, xlen, tag=2, dsp=0, wrapper=None):
    if wrapper:
        return read_wrapper(source, wrapper)
    top = "formal_div_refinement"
    params = f"-GAllowMultiply=1 -GXLEN={xlen} -GTagBits={tag} -GUseDsp={dsp}"
    files = f"{source} {HARNESS}"
    return (
        f"read_slang --threads 1 --single-unit -DFORMAL -I{ROOT}/rtl/configs/default "
        f"-I{ROOT}/rtl/include --top {top} {params} {files}; "
        f"chformal -assume -lower; prep -top {top} -flatten; memory_map; opt; "
        "check -assert; select -assert-none t:$div t:$mod t:$anyseq t:$anyconst; "
        "select -assert-count 1 w:dut.mul_r_comb; cutpoint w:dut.mul_r_comb; "
        "opt; check -assert; select -assert-none t:$mul; "
        "select -assert-count 1 t:$anyseq; "
    )


def read_wrapper(source, wrapper):
    # Constant-operand covers retain the actual multiplier. In particular a
    # zero product may be optimized to a constant, which is not a cutpoint.
    command = (
        f"read_slang --threads 1 --single-unit -DFORMAL -I{ROOT}/rtl/configs/default "
        f"-I{ROOT}/rtl/include --top formal_muldiv_fixed {source} {HARNESS} {wrapper}; "
        "chformal -assume -lower; prep -top formal_muldiv_fixed -flatten; memory_map; opt; "
        "check -assert; select -assert-none t:$div t:$mod t:$anyseq t:$anyconst; "
    )
    return command


def mixed_fixed_wrapper(output, name, xlen, word, a, b):
    path = output / (name + ".sv")
    mask = (1 << xlen) - 1
    path.write_text(f"""module formal_muldiv_fixed (
    input logic clock, reset, flush, valid,
    input logic [2:0] operation,
    input logic [1:0] tag,
    input logic [3:0] cancel,
    output logic correct,
    output logic [17:0] witnessed
);
  formal_div_refinement #(.AllowMultiply(1), .XLEN({xlen}), .TagBits(2)) uut (
    .clock, .reset, .flush, .valid, .operation, .tag, .cancel,
    .a({xlen}'h{a & mask:x}), .b({xlen}'h{b & mask:x}), .word(1'b{word}),
    .correct, .witnessed
  );
endmodule
""")
    return path


def mixed_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--multiply-evidence", type=Path, required=True)
    parser.add_argument("--divide-evidence", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty to preserve earlier proof evidence")
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error("Yosys paths cannot contain whitespace, quotes or semicolons")
    output.mkdir(parents=True, exist_ok=True)
    inputs = {}
    for kind, path in (("multiply", args.multiply_evidence), ("divide", args.divide_evidence)):
        inputs.update(prerequisite(path.resolve(), kind, output))
    for path in (Path(__file__), HARNESS, Path(__file__).with_name("yosys_common.py")):
        inputs[str(path.relative_to(ROOT))] = sha(path)
    result = {"complete": False, "sources": inputs, "proofs": [], "covers": [],
              "negative_controls": [],
              "scope": "All eight MUL/DIV/REM opcodes, legal RV32/RV64 W forms, mixed streams; "
                       "operand/opcode/tag capture, arbitrary blocked presentations, no output "
                       "collision or loss, per-tag cancellation/reuse, reset/flush and division "
                       "completion. Parent MDQ, architectural retirement and FPU are excluded.",
              "abstraction": "One free combinational multiplier value, discharged by the "
                             "current exhaustive arithmetic prerequisite; no internal progress "
                             "assumption. Canonical division state remains concrete.",
              "assumptions": ["First-edge reset", "Valid RV32 operations have word=0",
                              "Valid RV64 multiply W operations select MULW"],
              "yosys": subprocess.check_output([YOSYS, "-V"], text=True).strip()}

    def save():
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    save()
    for xlen in (32, 64):
        for tag in (1, 2, 3):
            for dsp in (0, 1):
                name = f"mixed-{xlen}-tag{tag}-dsp{dsp}"
                row = run_yosys(
                    mixed_read(DUT, xlen, tag, dsp)
                    + "sat -verify -tempinduct -seq 1 -maxsteps 3 -set-at 1 reset 1 "
                    "-set-assumes -prove correct 1", output, name, args.timeout, INDUCTION,
                )
                result["proofs"].append(dict(xlen=xlen, tag_bits=tag, dsp=dsp, **row))
                save()
        cases = [(f"event{event}", event, 0, 37, 5, 16, "") for event in range(10, 18)]
        cases += [("zero-shortcut", 13, 0, 0, 0, 12, "-set cancel 0 -set flush 0 "),
                  ("full-width-divide", 13, 0, (1 << xlen)-1, 3, xlen//2+10,
                   "-set cancel 0 -set flush 0 -set-at 2 operation 4 -set-at 3 operation 1 ")]
        if xlen == 64:
            cases += [(f"word-event{event}", event, 1, 37, 5, 16, "") for event in (13, 14)]
        for label, event, word, a, b, depth, controls in cases:
            name = f"cover-{xlen}-{label}"
            wrapper = mixed_fixed_wrapper(output, name, xlen, word, a, b)
            row = run_yosys(
                mixed_read(DUT, xlen, wrapper=wrapper)
                + f"sat -seq {depth} -set reset 0 -set-at 1 reset 1 -set valid 1 "
                + controls + f"-set-assumes -set-at {depth} witnessed[{event}] 1 "
                + f"-show-inputs -show-outputs -dump_vcd {output/name}.vcd",
                output, name, args.timeout, MODEL,
            )
            result["covers"].append(dict(xlen=xlen, event=event, case=label, depth=depth, **row))
            save()
        print(f"PASS: RV{xlen} mixed MUL/DIV refinement, arbitration and covers", flush=True)
    text = DUT.read_text()
    for name, old, new in (
        ("ready-while-busy", "assign in_ready = !div_active;", "assign in_ready = 1'b1;"),
        ("multiply-starts-divider", "in_ready && in_is_div && !cancel_tags[in_tag]",
         "in_ready && !cancel_tags[in_tag]"),
        ("drop-older-multiply", "if (m1_v && !cancel_tags[m1_tag]) begin",
         "if (m1_v && !accept_div && !cancel_tags[m1_tag]) begin"),
    ):
        if text.count(old) != 1:
            raise ValueError("Missing mixed-stream mutation anchor: " + name)
        source = output / ("mutant-" + name + ".sv")
        source.write_text(text.replace(old, new))
        row = run_yosys(
            mixed_read(source, 32) + "sat -seq 8 -set reset 0 -set-at 1 reset 1 "
            "-set-assumes -prove correct 1 -show-inputs -show-outputs "
            + f"-dump_vcd {output}/negative-{name}.vcd",
            output, "negative-" + name, args.timeout, SAT_FAIL,
        )
        if not (output / ("negative-" + name + ".vcd")).stat().st_size:
            raise RuntimeError("Missing mixed-stream mutation counterexample")
        result["negative_controls"].append(dict(name=name, **row))
        save()
    if any(sha(ROOT / name) != digest for name, digest in inputs.items()):
        raise RuntimeError("Mixed-stream proof input changed during the run")
    result["prerequisite_artifacts"] = {
        str(path.relative_to(output)): sha(path)
        for path in (output / "prerequisites").rglob("*") if path.is_file()}
    result["complete"] = True
    save()
    print("FORMAL COMPOSITION COMPLETE: mixed MUL/DIV arithmetic and arbitration", flush=True)


ENTRY_POINTS = {
    'multiply': multiply_main,
    'divide': divide_main,
    'mixed': mixed_main,
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
