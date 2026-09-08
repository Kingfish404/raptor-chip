#!/usr/bin/env python3
"""Common-current-state induction for stale memory-response payload isolation.

The projection shares corresponding current registers, exposes every original
DFF D expression as next state, and removes clocks. It checks that *all* DUT
DFF outputs are paired; missing/changed state fails rather than being omitted.
The arbitrary shared current state is the induction premise, not an input-
traffic restriction. Original RTL reset and ownership proofs provide the base
and ledger invariant; combinational checks prove next-state and output equality.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT/"hdl/backend/vpu/rapt_vpu_memory.sv"
HARNESS = ROOT/"verify/vpu/formal_memory_response.sv"
LEDGER = ROOT/"verify/vpu/memory_response_formal.py"

def project(model, target, source):
    j=json.loads(model.read_text());m=j['modules']['formal_vpu_memory_response']
    assert all(c['type']=='$dff' or not any(k in c['type'] for k in ('dff','latch'))
               for c in m['cells'].values()), "unsupported sequential cell"
    ff={n:c for n,c in m['cells'].items() if c['type']=='$dff'}
    qd={q:d for c in ff.values() for q,d in zip(c['connections']['Q'],c['connections']['D'])}
    assert len(qd)==sum(len(c['connections']['Q']) for c in ff.values()), "multiple Q drivers"
    names='state insn_q tag_q base_q stride_q vl_q segment_base type_q index_q limit_q field_q fields_q group_q data_size_q index_size_q probe_q data_q done_trap done_update done_fof done_cause done_tval done_vl done_vstart'.split()
    # Preserve every next-state expression before identifying the current Q
    # bits. Sharing D expressions here would make the induction check vacuous.
    remap={};pairs=[];covered=set()
    for name in names:
     a=m['netnames']['dut.'+name]['bits'];b=m['netnames']['other.'+name]['bits'];assert len(a)==len(b)
     for x,y in zip(a,b):
      assert (x in qd or isinstance(x,str)) and (y in qd or isinstance(y,str)), name
      covered.update(z for z in (x,y) if z in qd)
      if x!=y:
       assert isinstance(x,int) and isinstance(y,int), "asymmetric constant state"
       assert y not in remap or remap[y]==x
       remap[y]=x
       pairs.append((qd.get(x,x),qd.get(y,y)))
    assert all(source.name+':' in c['attributes'].get('src','')
               or HARNESS.name+':' in c['attributes'].get('src','') for c in ff.values()), "unknown state origin"
    dutq={q for c in ff.values() if source.name+':' in c['attributes'].get('src','') for q in c['connections']['Q']}
    assert dutq==covered,(len(dutq),len(covered),dutq-covered)
    def mapped(x):
     while x in remap:x=remap[x]
     return x
    # Clocks disappear only in this single-transition projection. The original
    # sequential design is still used for reset and ledger proofs.
    for n in ff:del m['cells'][n]
    for c in m['cells'].values():
     for n,v in c['connections'].items():c['connections'][n]=[mapped(x) for x in v]
    for c in m['netnames'].values():c['bits']=[mapped(x) for x in c['bits']];c['attributes'].pop('init',None)
    for c in m['ports'].values():c['bits']=[mapped(x) for x in c['bits']]
    # All remaining current registers, including the ledger, are free inputs.
    # Only the independently proved ledger relation constrains the normal step.
    state=sorted(set(mapped(q) for q in qd if isinstance(mapped(q),int)))
    m['ports']['formal_state']={'direction':'input','bits':state}
    a=[mapped(x) for x,y in pairs];b=[mapped(y) for x,y in pairs]
    newbit=max([bit for c in m['netnames'].values() for bit in c['bits'] if isinstance(bit,int)]
               +[bit for c in m['cells'].values() for port in c['connections'].values()
                 for bit in port if isinstance(bit,int)]+state)+1
    m['cells']['proof_next_equal_cell']={'hide_name':0,'type':'$eq','parameters':{'A_SIGNED':'0','B_SIGNED':'0','A_WIDTH':format(len(a),'032b'),'B_WIDTH':format(len(b),'032b'),'Y_WIDTH':format(1,'032b')},'attributes':{},'port_directions':{'A':'input','B':'input','Y':'output'},'connections':{'A':a,'B':b,'Y':[newbit]}}
    m['ports']['next_equal']={'direction':'output','bits':[newbit]}
    m['netnames']['next_equal']={'hide_name':0,'bits':[newbit],'attributes':{}}
    target.write_text(json.dumps(j))
    return dict(paired_register_bits=len(covered),shared_state_bits=len(state),next_bit_comparisons=len(a))

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",type=Path,default=ROOT/"verify/build/vpu/formal-memory-isolation")
    ap.add_argument("--timeout",type=int,default=120)
    args=ap.parse_args()
    out=args.build_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/"summary.json").unlink(missing_ok=True)
    def run(name, script, expected="SAT proof finished - no model found: SUCCESS!"):
        path=out/f"{name}.ys";path.write_text(script+"\n")
        with (out/f"{name}.log").open("w") as log:
            result=subprocess.run(["yosys","-Q","-T","-m","slang","-s",str(path)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=args.timeout)
        text=(out/f"{name}.log").read_text()
        if result.returncode or (expected and expected not in text):
            raise RuntimeError(f"{name}: {text[-2000:]}")
    # Independently prove the ledger premise against unchanged sequential RTL.
    with (out/"ledger.log").open("w") as log:
        subprocess.run(["python3",str(LEDGER),"--ownership-only","--timeout",str(args.timeout),
                        "--build-dir",str(out/"ledger")],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
    reports=[]
    def build(name, source, xlen, elen, tag):
        model=out/f"{name}.json"
        script=("read_slang --top formal_vpu_memory_response -Ihdl/include "
                f"-GOwnershipOnly=0 -GXLEN={xlen} -GVLEN=128 -GELEN={elen} -GTagBits={tag} "
                f"{source} {HARNESS}; prep -top formal_vpu_memory_response; flatten; memory_map; opt; dffunmap; ")
        run(name+"-export",script+f"write_json {model}",None)
        target=out/f"{name}-step.json"
        stats=project(model,target,source)
        return model,target,stats
    for xlen,elen,tag in ((32,32,2),(64,64,10)):
        name=f"isolation-{xlen}-{elen}-{tag}"
        model,target,stats=build(name,DUT,xlen,elen,tag)
        run(name+"-base",f"read_json {model}; sat -verify -seq 2 -set-at 1 reset 1 -set-at 2 reset 0 -prove correct 1")
        prefix=f"read_json {target}; hierarchy -top formal_vpu_memory_response; opt -full; check -assert; "
        run(name+"-normal",prefix+"sat -verify -set reset 0 -set ledger_correct 1 -prove next_equal 1")
        run(name+"-reset",prefix+"sat -verify -set reset 1 -prove next_equal 1")
        run(name+"-observable",prefix+"sat -verify -prove observable_equal 1")
        reports.append(dict(XLEN=xlen,VLEN=128,ELEN=elen,TagBits=tag,**stats))
        print(f"PASS reset base, normal/reset induction and observation {name}",flush=True)
    mutations={
        "unguarded_data":("      if (fault_event) begin",
                          "      if (mem_rsp_valid) data_q <= mem_rdata;\n      if (fault_event) begin"),
        "unguarded_fault":("if (accepted_response && mem_fault)", "if (mem_rsp_valid && mem_fault)"),
    }
    for name,(old,new) in mutations.items():
        source=DUT.read_text();assert source.count(old)==1
        mutant=out/f"mutant-{name}.sv";mutant.write_text(source.replace(old,new))
        _,target,_=build("mutant-"+name,mutant,32,32,2)
        run("mutant-"+name+"-check",
            f"read_json {target}; hierarchy -top formal_vpu_memory_response; opt -full; check -assert; "
            f"sat -set reset 0 -set ledger_correct 1 -prove next_equal 1 -dump_vcd {out}/mutant-{name}.vcd",
            "SAT proof finished - model found: FAIL!")
        print(f"PASS mutation detected {name}",flush=True)
    files=[DUT,HARNESS,LEDGER,Path(__file__),ROOT/"hdl/include/rapt_sva.svh"]
    result=dict(scope="stale response payload noninterference after reset; not freshness across identity reuse, external drain, ordering or liveness",
                method="reset base + proved request ledger + common-current-state normal/reset induction + unconditional combinational observation",
                configurations=reports,detected_mutations=list(mutations),
                yosys=subprocess.check_output(["yosys","-V"],text=True).strip(),
                sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    (out/"summary.json").write_text(json.dumps(result,indent=2)+"\n")

if __name__=="__main__":
    main()
