#!/usr/bin/env python3
"""Prove isolation of stale vector-memory response payloads; no liveness claim."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
YOSYS = os.environ.get("RAPTOR_YOSYS_REAL", "yosys")
SAT_SUCCESS = "SAT proof finished - no model found: SUCCESS!"
DUT = ROOT / "rtl/backend/vpu/rapt_vpu_memory.sv"
HARNESS = ROOT / "verification/vpu/formal_memory_response.sv"


def run(script, output, name, timeout):
    path = output / f"{name}.ys"
    path.write_text(script + "\n")
    log = output / f"{name}.log"
    with log.open("w") as stream:
        result = subprocess.run(
            [YOSYS, "-Q", "-T", "-m", "slang", "-s", str(path)],
            cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout,
        )
    if result.returncode:
        raise RuntimeError(f"{name}: Yosys failed; see {log}")
    return log.read_text()


def wrapper(source):
    """Reuse the complete current interface; fail if its expected shape changes."""
    head = source[source.index("module "):source.index(");") + 2]
    anchor = "module rapt_vpu_memory #("
    if head.count(anchor) != 1 or head.count("    output logic response_dropped") != 1:
        raise ValueError("Unsupported vector-memory public interface")
    head = head.replace(anchor, "module vpu_response_model #(\n    parameter bit Alternate = 0,")
    head = head.replace(
        "    output logic response_dropped",
        "    input logic [63:0] alternate_mem_rdata,\n"
        "    input logic [XLEN-1:0] alternate_mem_cause, alternate_mem_tval,\n"
        "    input logic alternate_mem_fault, alternate_mem_non_idempotent,\n"
        "    output logic response_dropped",
    )
    return head + """
  wire replace_payload = Alternate && mem_rsp_valid && !dut.accepted_response;
  rapt_vpu_memory #(.XLEN(XLEN), .VLEN(VLEN), .ELEN(ELEN), .TagBits(TagBits)) dut (
    .mem_rdata(replace_payload ? alternate_mem_rdata : mem_rdata),
    .mem_fault(replace_payload ? alternate_mem_fault : mem_fault),
    .mem_non_idempotent(replace_payload ? alternate_mem_non_idempotent : mem_non_idempotent),
    .mem_cause(replace_payload ? alternate_mem_cause : mem_cause),
    .mem_tval(replace_payload ? alternate_mem_tval : mem_tval),
    .*
  );
endmodule
"""


def register_bits(module):
    bits = set()
    for cell in module["cells"].values():
        kind = cell["type"]
        if "ff" in kind.lower():
            if kind not in ("$dff", "$dffe", "$sdff", "$sdffe", "$sdffce"):
                raise ValueError(f"Unsupported register primitive: {kind}")
            bits.update(cell["connections"]["Q"])
        elif "latch" in kind.lower() or kind.startswith("$mem"):
            raise ValueError(f"Unaccounted state primitive: {kind}")
    if not bits:
        raise ValueError("Vacuous equivalence: no register state")
    return bits


# Prove a one-step stale-payload relation through corresponding register state.
#
# All state aliases used as induction points must consist only of flop bits and
# constants. Arbitrary common combinational names are blacklisted. The caller
# separately proves reset correspondence and its public request-ledger invariant.
def prove_payload_relation(dut, output, name, xlen, elen, tag, base, timeout):
    """Compose reset base, public-ledger induction, and full-state equivalence."""
    for path in (dut, output):
        if any(char.isspace() or char in ';"' for char in str(path)):
            raise ValueError(f"Unsupported Yosys path: {path}")
    base_log = run(
        base + "sat -verify -seq 2 -set-at 1 reset 1 -prove correct 1",
        output, name + "-reset-base", timeout,
    )
    if SAT_SUCCESS not in base_log:
        raise RuntimeError("Missing reset-base proof")
    ownership = base.replace("-GOwnershipOnly=0", "-GOwnershipOnly=1")
    if ownership == base:
        raise ValueError("Missing ownership partition selector")
    ownership_log = run(
        ownership + "sat -verify -tempinduct -seq 2 -maxsteps 24 "
        "-set-at 1 reset 1 -prove correct 1",
        output, name + "-ownership", timeout,
    )
    if "Induction step proven: SUCCESS!" not in ownership_log:
        raise RuntimeError("Missing ledger/acceptance induction proof")
    model = output / (name + "-model.sv")
    model.write_text(wrapper(dut.read_text()))
    commands = []
    json_paths = {}
    for label, alternate in (("gold", 0), ("gate", 1)):
        path = output / f"{name}-{label}.json"
        json_paths[label] = path
        commands += [
            f"read_slang --single-unit -I{ROOT}/rtl/include --top vpu_response_model "
            f"-GAlternate={alternate} -GXLEN={xlen} -GELEN={elen} -GTagBits={tag} {dut} {model}",
            "prep -top vpu_response_model -flatten", "memory_map", "opt -full", "check -assert",
            f"write_json {path}", f"design -stash {label}",
        ]
    run(";\n".join(commands), output, name + "-prepare", timeout)
    modules = {
        label: json.loads(path.read_text())["modules"]["vpu_response_model"]
        for label, path in json_paths.items()
    }
    gold, gate = modules["gold"], modules["gate"]
    if gold["ports"].keys() != gate["ports"].keys():
        raise ValueError("Public interface mismatch")
    for port in gold["ports"]:
        left, right = gold["ports"][port], gate["ports"][port]
        if left["direction"] != right["direction"] or len(left["bits"]) != len(right["bits"]):
            raise ValueError(f"Public port shape mismatch: {port}")
    qbits = {label: register_bits(module) for label, module in modules.items()}
    common = gold["netnames"].keys() & gate["netnames"].keys()
    state_names = set()
    covered = {"gold": set(), "gate": set()}
    for net in common:
        values = {label: module["netnames"][net]["bits"] for label, module in modules.items()}
        if len(values["gold"]) != len(values["gate"]):
            continue
        is_state = all(
            any(bit in qbits[label] for bit in bits)
            and all(bit in qbits[label] or bit in ("0", "1") for bit in bits)
            for label, bits in values.items()
        )
        if is_state:
            state_names.add(net)
            for label, bits in values.items():
                covered[label].update(bit for bit in bits if bit in qbits[label])
    if any(covered[label] != qbits[label] for label in modules):
        raise ValueError("Not all register bits have corresponding-state proof points")
    allowed = state_names | gold["ports"].keys()
    blacklist = output / f"{name}-blacklist.txt"
    blacklist.write_text("\n".join(sorted(common - allowed)) + "\n")
    commands += [
        "design -copy-from gold -as gold vpu_response_model",
        "design -copy-from gate -as gate vpu_response_model",
        f"equiv_make -blacklist {blacklist} gold gate equiv", "hierarchy -top equiv",
        "opt_clean", "check -assert", "equiv_simple -undef -short", "equiv_induct -undef -seq 1",
        "equiv_status -assert",
    ]
    log = run(";\n".join(commands), output, name + "-equivalence", timeout)
    final = log.rsplit("Executing EQUIV_STATUS pass.", 1)[-1]
    match = re.search(
        r"Found (\d+) \$equiv cells in equiv:\s*"
        r"Of those cells (\d+) are proven and (\d+) are unproven\.", final,
    )
    if not match or "Equivalence successfully proven!" not in final:
        raise RuntimeError("Missing complete equivalence result")
    total, proven, unproven = map(int, match.groups())
    if not total or total != proven or unproven:
        raise RuntimeError("Vacuous or incomplete payload equivalence")
    return {
        "method": "reset base + ledger induction + corresponding-state one-step equivalence",
        "reset_base_depth": 2, "equivalence_cells": total, "proven_cells": proven,
        "register_bits": {label: len(bits) for label, bits in qbits.items()},
        "state_aliases": sorted(state_names),
        "public_outputs": sorted(
            name for name, port in gold["ports"].items() if port["direction"] == "output"
        ),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", type=Path, default=Path("/tmp/raptor-vpu-formal/memory-response"))
    ap.add_argument("--timeout", type=int, default=180, help="Per solver invocation timeout in seconds")
    ap.add_argument("--ownership-only", action="store_true",
                    help="Prove the request-ledger/response-acceptance partition only")
    args = ap.parse_args()
    out = args.build_dir.resolve()
    if out.exists() and any(out.iterdir()):
        ap.error("Output must be empty to preserve earlier proof evidence")
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").unlink(missing_ok=True)
    # The frontend cannot resolve a hierarchical enum literal. Validate the
    # state value used by the proved ledger invariant against current RTL.
    states = re.search(r"typedef enum logic \[4:0\] \{(.*?)\} state_t", DUT.read_text(), re.S)
    assert states and [x.strip() for x in states[1].split(",")].index("RESPONSE") == 11
    records = []
    bases = []
    files = [DUT, HARNESS, Path(__file__), ROOT / "rtl/include/rapt_sva.svh"]
    source_hashes = {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in files
    }
    for xlen, elen, tag in ((32,32,2),(64,64,10)):
        name = f"response-{xlen}-{elen}-{tag}"
        base = ("read_slang --top formal_vpu_memory_response -Irtl/include "
                f"-GOwnershipOnly={int(args.ownership_only)} -GXLEN={xlen} -GVLEN=128 -GELEN={elen} -GTagBits={tag} "
                f"{DUT} {HARNESS}; prep -top formal_vpu_memory_response; "
                "flatten; memory_map; opt; ")
        bases.append(base)
        composition = None
        if args.ownership_only:
            script = out / f"{name}.ys"
            script.write_text(base + "sat -verify -tempinduct -seq 2 -maxsteps 24 "
                              "-set-at 1 reset 1 -prove correct 1\n")
            with (out / f"{name}.log").open("w") as log:
                p = subprocess.run([YOSYS,"-Q","-T","-m","slang","-s",str(script)],
                                   cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   timeout=args.timeout)
            text = (out / f"{name}.log").read_text()
            if p.returncode or "Induction step proven: SUCCESS!" not in text:
                raise RuntimeError(f"{name} proof failed: {text[-3000:]}")
        else:
            composition = prove_payload_relation(
                DUT, out, name, xlen, elen, tag, base, args.timeout,
            )
        print(f"PASS induction {name}", flush=True)
        script = out / f"{name}-cover.ys"
        script.write_text(base + "sat -seq 20 -set reset 0 -set-at 1 reset 1 -set-at 20 witnessed_stale 1 "
                          "-set cmd_valid 1 -set cmd_insn 33554439 -set cmd_vl 1 "
                          "-set cmd_vtype 0 -set cmd_vstart 0 -set cmd_tag 1 "
                          "-set cmd_base 0 -set cmd_stride 0 -set mem_ready 1 "
                          "-set mem_rsp_valid 1 -set mem_rsp_tag 0 "
                          f"-show-inputs -show-outputs -dump_vcd {out/name}.vcd\n")
        with (out / f"{name}-cover.log").open("w") as log:
            p = subprocess.run([YOSYS,"-Q","-T","-m","slang","-s",str(script)],
                               cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        text = (out / f"{name}-cover.log").read_text()
        if p.returncode or "SAT solving finished - model found:" not in text:
            raise RuntimeError(f"{name} stale pending response unreachable")
        print(f"PASS stale response witness {name}", flush=True)
        records.append(dict(XLEN=xlen,VLEN=128,ELEN=elen,TagBits=tag,inductive_safety=True,
                            cover_depth=20,composition=composition))
    mutations = []
    if args.ownership_only:
        for field, signal in (("tag", "tag_q"), ("index", "index_q"),
                              ("field", "field_q"), ("probe", "probe_q")):
            source = DUT.read_text()
            old = f"mem_rsp_{field} == {signal}"
            assert source.count(old) == 1
            mutant = out / f"mutant-{field}.sv"
            mutant.write_text(source.replace(old, "1'b1"))
            prefix = ("read_slang --top formal_vpu_memory_response -Irtl/include "
                      "-GOwnershipOnly=1 -GXLEN=32 -GVLEN=128 -GELEN=32 -GTagBits=2 "
                      f"{mutant} {HARNESS}; prep -top formal_vpu_memory_response; "
                      "flatten; memory_map; opt; ")
            rsp = {k: 0 for k in ("tag", "index", "field", "probe")}
            rsp["tag"] = 1
            rsp[field] = 0 if field == "tag" else 1
            constraints = " ".join(f"-set mem_rsp_{k} {v}" for k,v in rsp.items())
            script = out / f"mutant-{field}.ys"
            script.write_text(prefix + "sat -seq 12 -set reset 0 -set-at 1 reset 1 "
                              "-set cmd_valid 1 -set cmd_insn 33554439 -set cmd_vl 1 "
                              "-set cmd_vtype 0 -set cmd_vstart 0 -set cmd_tag 1 "
                              "-set cmd_base 0 -set cmd_stride 0 -set mem_ready 1 "
                              "-set mem_rsp_valid 1 " + constraints +
                              f" -prove correct 1 -dump_vcd {out}/mutant-{field}.vcd\n")
            with (out / f"mutant-{field}.log").open("w") as log:
                p = subprocess.run([YOSYS,"-Q","-T","-m","slang","-s",str(script)],
                                   cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=args.timeout)
            text = (out / f"mutant-{field}.log").read_text()
            if p.returncode or "SAT proof finished - model found: FAIL!" not in text:
                raise RuntimeError(f"removed {field} comparison was not detected")
            mutations.append(field)
            print(f"PASS mutation detected missing {field} comparison", flush=True)
    else:
        source = DUT.read_text()
        old = "if (accepted_response && !fault_event) begin"
        if source.count(old) != 1:
            raise ValueError("Cannot locate stale-response mutation point")
        mutant = out / "mutant-stale-payload.sv"
        mutant.write_text(source.replace(old, "if (mem_rsp_valid && !fault_event) begin"))
        command = bases[0].replace(str(DUT), str(mutant))
        command += (
            "sat -seq 12 -set reset 0 -set-at 1 reset 1 "
            "-set cmd_valid 1 -set cmd_insn 33554439 -set cmd_vl 1 "
            "-set cmd_vtype 0 -set cmd_vstart 0 -set cmd_tag 1 "
            "-set cmd_base 0 -set cmd_stride 0 -set mem_ready 1 "
            "-set mem_rsp_valid 1 -set mem_rsp_tag 0 "
            "-set mem_rdata 0 -set alternate_mem_rdata 1 "
            "-set mem_fault 0 -set alternate_mem_fault 0 "
            "-set mem_non_idempotent 0 -set alternate_mem_non_idempotent 0 "
            f"-prove correct 1 -dump_vcd {out}/mutant-stale-payload.vcd"
        )
        text = run(command, out, "mutant-stale-payload", args.timeout)
        if "SAT proof finished - model found: FAIL!" not in text:
            raise RuntimeError("Stale-payload acceptance mutation was not detected")
        mutations.append("stale-payload-acceptance")
        print("PASS mutation detected stale response state/data update", flush=True)
    if any(hashlib.sha256(path.read_bytes()).hexdigest()
           != source_hashes[str(path.relative_to(ROOT))] for path in files):
        raise RuntimeError("Formal inputs changed during proof")
    method = ("SAT temporal induction with proved ledger/state invariants" if args.ownership_only
              else "reset base, ledger induction, and full-state one-step equivalence")
    result = {
        "complete": True,
        "yosys": subprocess.check_output([YOSYS, "-V"], text=True).strip(),
        "proof_method": method + "; first-edge reset only",
        "scope": ("request-ledger/response-acceptance consistency" if args.ownership_only
                  else "stale response payload isolation")
                 + "; not ownership freshness, external drain or liveness",
        "configurations": records, "detected_mutations": mutations, "sources": source_hashes,
    }
    (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print("FORMAL COMPOSITION COMPLETE: VPU memory response contract", flush=True)

if __name__ == "__main__":
    main()
