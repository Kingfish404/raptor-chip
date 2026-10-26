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
files = sorted((root / "rtl/backend/vpu").glob("*.sv")) + [
    root / "rtl/backend/feu/fpu/rapt_fpu_fma.sv", root / "rtl/backend/feu/fpu/rapt_fpu_divsqrt.sv", root / "rtl/backend/feu/fpu/rapt_fpu_convert_narrow.sv", root / "rtl/backend/feu/fpu/rapt_fpu_int_to_fp.sv", root / "rtl/backend/feu/fpu/rapt_fpu_integer_to_fp.sv", root / "rtl/backend/feu/fpu/rapt_fpu_single_to_int_w.sv", root / "rtl/backend/feu/fpu/rapt_fpu_fp_to_int.sv", root / "verification/vpu/fma_legacy.vlt", root / "rtl/include/rapt_fp_ops.svh", root / "rtl/sram/rapt_sram_1rw.sv", root / "rtl/include/rapt_sva.svh",
    root / "verification/vpu/test_vpu.cpp", root / "verification/vpu/spike_reference.h",
    root / "verification/vpu/test_store_completion_top.h", root / "verification/vpu/test_context_top.h", root / "verification/vpu/test_encoding_top.h", root / "verification/vpu/test_geometry_top.h", root / "verification/vpu/test_catalog_top.h", root / "verification/vpu/catalog_entries.h", root / "verification/vpu/generate_catalog.py", root / "verification/vpu/vendor/riscv-opcodes/rv_v", root / "verification/vpu/test_fp_reduce_top.h", root / "verification/vpu/test_transfer_top.h", root / "verification/vpu/test_estimate_top.h", root / "verification/vpu/test_int_fp_top.h", root / "verification/vpu/test_fp_convert_top.h", root / "verification/vpu/test_fp_wide_top.h", root / "verification/vpu/test_fp_misc_top.h", root / "verification/vpu/test_fp_divsqrt_top.h", root / "verification/vpu/test_fp_mixed_top.h", root / "verification/vpu/test_fp_top.h", root / "verification/vpu/test_gather_top.h", root / "verification/vpu/test_slide_top.h", root / "verification/vpu/test_compress_top.h", root / "verification/vpu/test_iota_top.h", root / "verification/vpu/test_prefix_top.h", root / "verification/vpu/test_scan_top.h", root / "verification/vpu/test_index_top.h", root / "verification/vpu/test_scalar_move_top.h", root / "verification/vpu/test_move_top.h", root / "verification/vpu/test_reduce_top.h", root / "verification/vpu/test_fixed_top.h", root / "verification/vpu/fixed_reference.h",
    root / "verification/vpu/test_wide_top.h", root / "verification/vpu/test_mask_top.h", root / "verification/vpu/test_carry_top.h", root / "verification/vpu/muldiv_reference.h", root / "verification/vpu/test_muldiv_top.h",
    root / "verification/vpu/memory_model.h", root / "verification/vpu/test_memory.h",
    root / "verification/vpu/Makefile", Path(__file__), root / "verification/vpu/reference_manifest.py"]
output.write_text(json.dumps(dict(
    configuration=dict(zip(names, map(int, sys.argv[2:-1]))),
    suite=sys.argv[-1],
    verilator=subprocess.check_output(["verilator", "--version"], text=True).strip(),
    sources={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}), indent=2)+"\n")
