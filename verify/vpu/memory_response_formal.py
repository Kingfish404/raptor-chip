#!/usr/bin/env python3
"""Prove isolation of stale vector-memory response payloads; no liveness claim."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / "hdl/backend/vpu/rapt_vpu_memory.sv"
HARNESS = ROOT / "verify/vpu/formal_memory_response.sv"

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", type=Path, default=ROOT / "verify/build/vpu/formal-memory-response")
    ap.add_argument("--timeout", type=int, default=180, help="Per solver invocation timeout in seconds")
    ap.add_argument("--ownership-only", action="store_true", help="Prove the request-ledger/response-acceptance partition only")
    args = ap.parse_args()
    out = args.build_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").unlink(missing_ok=True)
    # The frontend cannot resolve a hierarchical enum literal. Validate the
    # state value used by the proved ledger invariant against current RTL.
    states = re.search(r"typedef enum logic \[4:0\] \{(.*?)\} state_t", DUT.read_text(), re.S)
    assert states and [x.strip() for x in states[1].split(",")].index("RESPONSE") == 11
    records = []
    for xlen, elen, tag in ((32,32,2),(64,64,10)):
        name = f"response-{xlen}-{elen}-{tag}"
        base = ("read_slang --top formal_vpu_memory_response -Ihdl/include "
                f"-GOwnershipOnly={int(args.ownership_only)} -GXLEN={xlen} -GVLEN=128 -GELEN={elen} -GTagBits={tag} "
                f"{DUT} {HARNESS}; prep -top formal_vpu_memory_response; "
                "flatten; memory_map; opt; ")
        script = out / f"{name}.ys"
        script.write_text(base + "sat -verify -tempinduct -seq 2 -maxsteps 24 "
                          "-set-at 1 reset 1 -prove correct 1\n")
        with (out / f"{name}.log").open("w") as log:
            p = subprocess.run(["yosys","-Q","-T","-m","slang","-s",str(script)],
                               cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        text = (out / f"{name}.log").read_text()
        if p.returncode or "Induction step proven: SUCCESS!" not in text:
            raise RuntimeError(f"{name} proof failed: {text[-3000:]}")
        print(f"PASS induction {name}", flush=True)
        script = out / f"{name}-cover.ys"
        script.write_text(base + "sat -seq 20 -set reset 0 -set-at 1 reset 1 -set-at 20 witnessed_stale 1 "
                          "-set cmd_valid 1 -set cmd_insn 33554439 -set cmd_vl 1 "
                          "-set cmd_vtype 0 -set cmd_vstart 0 -set cmd_tag 1 "
                          "-set cmd_base 0 -set cmd_stride 0 -set mem_ready 1 "
                          "-set mem_rsp_valid 1 -set mem_rsp_tag 0 "
                          f"-show-inputs -show-outputs -dump_vcd {out/name}.vcd\n")
        with (out / f"{name}-cover.log").open("w") as log:
            p = subprocess.run(["yosys","-Q","-T","-m","slang","-s",str(script)],
                               cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        text = (out / f"{name}-cover.log").read_text()
        if p.returncode or "SAT solving finished - model found:" not in text:
            raise RuntimeError(f"{name} stale pending response unreachable")
        print(f"PASS stale response witness {name}", flush=True)
        records.append(dict(XLEN=xlen,VLEN=128,ELEN=elen,TagBits=tag,inductive_safety=True,cover_depth=20))
    mutations = []
    if args.ownership_only:
        for field, signal in (("tag", "tag_q"), ("index", "index_q"),
                              ("field", "field_q"), ("probe", "probe_q")):
            source = DUT.read_text()
            old = f"mem_rsp_{field} == {signal}"
            assert source.count(old) == 1
            mutant = out / f"mutant-{field}.sv"
            mutant.write_text(source.replace(old, "1'b1"))
            prefix = ("read_slang --top formal_vpu_memory_response -Ihdl/include "
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
                p = subprocess.run(["yosys","-Q","-T","-m","slang","-s",str(script)],
                                   cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=args.timeout)
            text = (out / f"mutant-{field}.log").read_text()
            if p.returncode or "SAT proof finished - model found: FAIL!" not in text:
                raise RuntimeError(f"removed {field} comparison was not detected")
            mutations.append(field)
            print(f"PASS mutation detected missing {field} comparison", flush=True)
    files=[DUT,HARNESS,Path(__file__),ROOT/"hdl/include/rapt_sva.svh"]
    result=dict(yosys=subprocess.check_output(["yosys","-V"],text=True).strip(), proof_method="SAT temporal induction with proved ledger/state invariants; first-edge reset only", scope=("request-ledger/response-acceptance consistency" if args.ownership_only else "stale response payload isolation")+"; not ownership freshness, external drain or liveness",
                configurations=records,detected_mutations=mutations,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    (out/"summary.json").write_text(json.dumps(result,indent=2)+"\n")

if __name__ == "__main__":
    main()
