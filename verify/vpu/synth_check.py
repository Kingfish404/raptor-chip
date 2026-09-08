#!/usr/bin/env python3
"""Check elaborated VPU leaves and SRAM inference; no technology/PPA claim."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VPU = ROOT / "hdl/backend/vpu"
LEAVES = ("core_adapter", "vtype", "csr", "vrf", "owner", "divsqrt", "fp_misc", "fp_estimate", "fp_transfer", "fp_reduce", "fp_reduce_control", "fp_reduce_decode", "fp_reduce_engine", "fp_reduce_engine_baseline", "fp_widen", "fp_wide_arith", "fp_convert", "int_fp16", "int_fp32", "int_fp64", "int_fp_decode", "fp_decode", "fp_arith", "fma", "slide", "mask_scan", "move", "reduce", "fixed", "geometry", "mask_write", "muldiv", "muldiv_baseline", "top", "top_baseline", "top_core")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "verify/build/vpu/synth")
    parser.add_argument("--leaf", action="append", choices=LEAVES, help="Limit to named leaves; repeat to select multiple")
    args = parser.parse_args()
    args.build_dir = args.build_dir.resolve()
    args.build_dir.mkdir(parents=True, exist_ok=True)
    reports = []
    seen = set()
    configs = [(64, 128, 64, 64, 2), (32, 256, 64, 32, 4),
               (32, 128, 32, 64, 1), (64, 512, 64, 128, 4)]
    for xlen, vlen, elen, bank_bits, banks in configs:
        for leaf in LEAVES:
            if args.leaf and leaf not in args.leaf:
                continue
            top = "rapt_vpu_core" if leaf == "top_core" else "rapt_vpu" if leaf.startswith("top") else "rapt_vpu_muldiv" if leaf.startswith("muldiv") else f"rapt_vpu_{leaf}"
            if leaf == "fp_reduce_engine_baseline":
                top = "rapt_vpu_fp_reduce_engine"
            if leaf in ("int_fp16", "int_fp32", "int_fp64"):
                top = "rapt_vpu_int_fp"
            sources = [VPU / f"{top}.sv"]
            if leaf in ("int_fp16", "int_fp32", "int_fp64"):
                sources = [ROOT / "hdl/backend/feu/fpu/rapt_fpu_int_to_fp.sv", ROOT / "hdl/backend/feu/fpu/rapt_fpu_single_to_int_w.sv"] + sources
            if leaf in ("fp_reduce_engine", "fp_reduce_engine_baseline"):
                sources = [VPU / f"rapt_vpu_{name}.sv" for name in ("vtype", "fp_widen", "fp_reduce_decode", "fp_reduce_control")] + sources
            if leaf == "fp_reduce":
                sources = [VPU / "rapt_vpu_fp_reduce_control.sv", ROOT / "hdl/backend/feu/fpu/rapt_fpu_fma.sv", VPU / "rapt_vpu_fma.sv", VPU / "rapt_vpu_fp_arith.sv", VPU / "rapt_vpu_fp_misc.sv", VPU / "rapt_vpu_fp_widen.sv"] + sources
            if leaf == "fp_reduce_control":
                sources.insert(0, VPU / "rapt_vpu_fp_widen.sv")
            if leaf == "fp_transfer":
                sources.insert(0, VPU / "rapt_vpu_slide.sv")
            if leaf == "fp_wide_arith":
                sources = [ROOT / "hdl/backend/feu/fpu/rapt_fpu_fma.sv", VPU / "rapt_vpu_fma.sv", VPU / "rapt_vpu_fp_arith.sv", VPU / "rapt_vpu_fp_widen.sv"] + sources
            if leaf == "fp_convert":
                sources = [ROOT / "hdl/backend/feu/fpu/rapt_fpu_convert_narrow.sv", VPU / "rapt_vpu_fp_widen.sv"] + sources
            if leaf == "divsqrt":
                sources.insert(0, ROOT / "hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv")
            if leaf == "fp_arith":
                sources = [ROOT / "hdl/backend/feu/fpu/rapt_fpu_fma.sv", VPU / "rapt_vpu_fma.sv"] + sources
            if leaf == "fma":
                sources.insert(0, ROOT / "hdl/backend/feu/fpu/rapt_fpu_fma.sv")
            if leaf == "reduce":
                sources.insert(0, VPU / "rapt_vpu_alu.sv")
            if leaf == "csr":
                sources.insert(0, VPU / "rapt_vpu_vtype.sv")
            if leaf.startswith("top"):
                sources = [ROOT / "hdl/memory/rapt_sram_1rw.sv", ROOT / "hdl/backend/feu/fpu/rapt_fpu_fma.sv", ROOT / "hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv", ROOT / "hdl/backend/feu/fpu/rapt_fpu_convert_narrow.sv", ROOT / "hdl/backend/feu/fpu/rapt_fpu_int_to_fp.sv", ROOT / "hdl/backend/feu/fpu/rapt_fpu_single_to_int_w.sv"] + sorted(VPU.glob("*.sv"))
                params = dict(XLEN=xlen, VLEN=vlen, ELEN=elen, BankBits=max(64, bank_bits), Banks=banks,
                              OptimizeOperandReads=int(leaf in ("top", "top_core")))
            elif leaf in ("fp_reduce_engine", "fp_reduce_engine_baseline"):
                params = dict(XLEN=xlen, VLEN=vlen, ELEN=elen, CacheMask=int(leaf == "fp_reduce_engine"))
            elif leaf in ("int_fp16", "int_fp32", "int_fp64"):
                params = dict(FloatDouble=int(xlen == 64), IntBits=int(leaf[6:]))
            elif leaf in ("fma", "fp_arith", "fp_misc", "fp_estimate"):
                params = dict(Double=int(xlen == 64))
            elif leaf in ("fp_reduce", "fp_reduce_control"):
                params = dict(ELEN=elen, CountBits=10)
            elif leaf == "fp_transfer":
                params = dict(ELEN=elen, VLEN=vlen)
            elif leaf in ("mask_scan", "slide"):
                params = dict(XLEN=xlen, VLEN=vlen)
            elif leaf == "move":
                params = dict(VLEN=vlen)
            elif leaf == "vrf":
                sources.insert(0, ROOT / "hdl/memory/rapt_sram_1rw.sv")
                params = dict(VLEN=vlen, BankBits=bank_bits, Banks=banks)
            elif leaf.startswith("muldiv"):
                params = dict(EarlyOut=int(leaf=="muldiv"))
            elif leaf in ("fixed", "fp_widen", "fp_wide_arith", "fp_convert"):
                params = {}
            elif leaf in ("geometry", "fp_decode", "divsqrt", "int_fp_decode", "fp_reduce_decode"):
                params = dict(ELEN=elen)
            elif leaf == "mask_write":
                params = dict(AddrBits=(32*vlen//8-1).bit_length())
            elif leaf == "core_adapter":
                params = dict(RobBits=3 if xlen == 32 else 6, GenerationBits=1 if xlen == 32 else 4,
                              CommandBits=2*xlen+32, ResultBits=3*xlen+20, MetadataBits=xlen+12)
            elif leaf == "owner":
                params = dict(TagBits=10 if xlen == 64 else 3, CommandBits=32+2*xlen, ResultBits=3*xlen+7)
            else:
                params = dict(XLEN=xlen, VLEN=vlen, ELEN=elen)
            name = top + "-" + "-".join(map(str, params.values()))
            if name in seen:
                continue
            seen.add(name)
            out = args.build_dir / name
            out.mkdir(exist_ok=True)
            netlist = out / "netlist.json"
            script = "\n".join([
                "read_slang --top " + top + " -Ihdl/include"
                + " " + " ".join(f"-G{k}={v}" for k, v in params.items())
                + " " + " ".join(str(p.relative_to(ROOT)) for p in sources),
                f"hierarchy -check -top {top}",
                "proc", "opt", "memory_dff", "memory_share", "memory_collect", "opt_clean",
                "check -assert",
                "select -assert-none t:$dlatch t:$adlatch t:$dlatchsr t:$check t:$assert t:$assume t:$cover",
                "stat", "write_json " + json.dumps(str(netlist)),
            ])
            script_path = out / "run.ys"
            script_path.write_text(script + "\n")
            with (out / "run.log").open("w") as log:
                result = subprocess.run([args.yosys, "-Q", "-T", "-m", "slang", "-s", str(script_path)],
                                        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f"Synthesis failed: {(out / 'run.log').read_text()[-6000:]}")
            design = json.loads(netlist.read_text())
            # read_slang flattens by default. Traverse hierarchy nonetheless
            # so SRAM bit counts stay meaningful if that frontend changes.
            counts = {}
            memories = []

            def visit(module_name):
                mod = design["modules"][module_name]
                if int(mod.get("attributes", {}).get("blackbox", "0"), 2):
                    raise AssertionError(f"Unexpected blackbox: {module_name}")
                for cell in mod["cells"].values():
                    kind = cell["type"]
                    if kind in design["modules"]:
                        visit(kind)
                    else:
                        counts[kind] = counts.get(kind, 0) + 1
                        if kind == "$mem_v2":
                            p = cell["parameters"]
                            if int(p["WR_PORTS"], 2) == 0:
                                assert set(p["INIT"]) <= {"0", "1"}, "Uninitialized ROM"
                            memories.append({key: int(p[key], 2) for key in
                                             ("WIDTH", "SIZE", "RD_PORTS", "WR_PORTS", "RD_CLK_ENABLE")})

            visit(top)
            roms = [m for m in memories if m["WR_PORTS"] == 0]
            srams = [m for m in memories if m["WR_PORTS"] != 0]
            if leaf == "fp_estimate" or leaf.startswith("top"):
                expected_rom_reads = 4 if leaf.startswith("top") and elen >= 64 else 2
                assert sum(m["RD_PORTS"] for m in roms) == expected_rom_reads, roms
                assert all(m["WIDTH"] == 7 and m["SIZE"] == 128 and
                           m["RD_CLK_ENABLE"] == 0 for m in roms), roms
            if leaf == "vrf" or leaf.startswith("top"):
                if leaf == "vrf": assert not roms, roms
                assert len(srams) == banks, srams
                assert sum(m["WIDTH"] * m["SIZE"] for m in srams) == 32*vlen, srams
                assert all(m["RD_PORTS"] == 1 and m["WR_PORTS"] == 1 and
                           m["RD_CLK_ENABLE"] == 1 for m in srams), srams
            elif leaf.startswith("muldiv"):
                assert not any(k in counts for k in ("$mul", "$div", "$mod", "$divfloor", "$modfloor")), counts
            elif leaf in ("geometry", "fixed", "fp_misc", "fp_widen", "int_fp_decode", "fp_estimate", "fp_transfer", "fp_reduce_decode"):
                assert not any("dff" in k or "latch" in k for k in counts), counts
            elif leaf == "vtype":
                assert not any("dff" in k or "latch" in k for k in counts), counts
                assert not any(k in counts for k in ("$mul", "$div", "$mod")), counts
            hash_sources = sources + [ROOT / "hdl/include/rapt_sva.svh", ROOT / "hdl/include/rapt_fp_ops.svh", Path(__file__)]
            reports.append(dict(top=top, parameters=params, cells=counts, memories=memories,
                                sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                         for p in hash_sources}))
            print(f"PASS synth {name} cells={sum(counts.values())} memories={len(memories)}")
    result = dict(selected_leaves=args.leaf or list(LEAVES), yosys=subprocess.check_output([args.yosys, "-V"], text=True).strip(),
                  scope="word-level synthesis and synchronous SRAM inference; no technology mapping or STA",
                  configurations=reports)
    (args.build_dir / "summary.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
