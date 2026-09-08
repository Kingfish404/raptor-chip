#!/usr/bin/env python3
"""Fingerprint the current DUT/test sources and the selected run configuration."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1])
names = ("XLEN", "VLEN", "ELEN", "BankBits", "Banks", "OptimizeOperandReads", "Spike", "CoreAdapter")
assert len(sys.argv[2:]) == len(names)+1
assert sys.argv[-1] in ("full", "fp-mixed", "fp-divsqrt", "fp-misc", "fp-wide", "fp-convert", "int-fp", "estimate", "transfer", "fp-reduce", "encoding", "config-encoding", "memory-encoding", "geometry", "catalog", "context", "store-completion")
files = sorted((root / "hdl/backend/vpu").glob("*.sv")) + [
    root / "hdl/backend/feu/fpu/rapt_fpu_fma.sv", root / "hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv", root / "hdl/backend/feu/fpu/rapt_fpu_convert_narrow.sv", root / "hdl/backend/feu/fpu/rapt_fpu_int_to_fp.sv", root / "hdl/backend/feu/fpu/rapt_fpu_single_to_int_w.sv", root / "verify/vpu/fma_legacy.vlt", root / "hdl/include/rapt_fp_ops.svh", root / "hdl/memory/rapt_sram_1rw.sv", root / "hdl/include/rapt_sva.svh",
    root / "verify/vpu/test_vpu.cpp", root / "verify/vpu/spike_reference.h",
    root / "verify/vpu/test_store_completion_top.h", root / "verify/vpu/test_context_top.h", root / "verify/vpu/test_encoding_top.h", root / "verify/vpu/test_geometry_top.h", root / "verify/vpu/test_catalog_top.h", root / "verify/vpu/catalog_entries.h", root / "verify/vpu/generate_catalog.py", root / "verify/vpu/vendor/riscv-opcodes/rv_v", root / "verify/vpu/test_fp_reduce_top.h", root / "verify/vpu/test_transfer_top.h", root / "verify/vpu/test_estimate_top.h", root / "verify/vpu/test_int_fp_top.h", root / "verify/vpu/test_fp_convert_top.h", root / "verify/vpu/test_fp_wide_top.h", root / "verify/vpu/test_fp_misc_top.h", root / "verify/vpu/test_fp_divsqrt_top.h", root / "verify/vpu/test_fp_mixed_top.h", root / "verify/vpu/test_fp_top.h", root / "verify/vpu/test_gather_top.h", root / "verify/vpu/test_slide_top.h", root / "verify/vpu/test_compress_top.h", root / "verify/vpu/test_iota_top.h", root / "verify/vpu/test_prefix_top.h", root / "verify/vpu/test_scan_top.h", root / "verify/vpu/test_index_top.h", root / "verify/vpu/test_scalar_move_top.h", root / "verify/vpu/test_move_top.h", root / "verify/vpu/test_reduce_top.h", root / "verify/vpu/test_fixed_top.h", root / "verify/vpu/fixed_reference.h",
    root / "verify/vpu/test_wide_top.h", root / "verify/vpu/test_mask_top.h", root / "verify/vpu/test_carry_top.h", root / "verify/vpu/muldiv_reference.h", root / "verify/vpu/test_muldiv_top.h",
    root / "verify/vpu/memory_model.h", root / "verify/vpu/test_memory.h",
    root / "verify/vpu/Makefile", Path(__file__), root / "verify/vpu/reference_manifest.py"]
output.write_text(json.dumps(dict(
    configuration=dict(zip(names, map(int, sys.argv[2:-1]))),
    suite=sys.argv[-1],
    verilator=subprocess.check_output(["verilator", "--version"], text=True).strip(),
    sources={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}), indent=2)+"\n")
