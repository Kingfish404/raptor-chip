#!/usr/bin/env python3
"""Record sources and explicit parameters of a standalone VPU leaf simulation."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
output, top = Path(sys.argv[1]), sys.argv[2]
assert top in ('rapt_vpu_mask_write', 'rapt_vpu_muldiv', 'rapt_vpu_fixed', 'rapt_vpu_move', 'rapt_vpu_mask_scan', 'rapt_vpu_slide', 'rapt_vpu_fma', 'rapt_vpu_fp_arith', 'rapt_vpu_fp_decode', 'rapt_vpu_divsqrt', 'rapt_vpu_fp_misc', 'rapt_vpu_fp_widen', 'rapt_vpu_fp_wide_arith', 'rapt_vpu_fp_convert', 'rapt_vpu_int_fp', 'rapt_vpu_int_fp_decode', 'rapt_vpu_fp_estimate', 'rapt_vpu_fp_transfer', 'rapt_vpu_fp_reduce', 'rapt_vpu_fp_reduce_control', 'rapt_vpu_fp_reduce_decode', 'rapt_vpu_fp_reduce_engine')
files = [root/f'hdl/backend/vpu/{top}.sv', root/'hdl/include/rapt_sva.svh',
         root/f'verify/vpu/test_{top.removeprefix("rapt_vpu_")}.cpp',
         root/'verify/vpu/Makefile', Path(__file__)]
if top in ('rapt_vpu_fma', 'rapt_vpu_fp_arith'):
    files += [root/'hdl/backend/feu/fpu/rapt_fpu_fma.sv', root/'hdl/include/rapt_fp_ops.svh', root/'verify/vpu/fma_legacy.vlt']
if top == 'rapt_vpu_fp_reduce_engine':
    files += [root/f'hdl/backend/vpu/rapt_vpu_{name}.sv' for name in ('vtype','fp_widen','fp_reduce_decode','fp_reduce_control')]
if top == 'rapt_vpu_fp_reduce_control':
    files.append(root/'hdl/backend/vpu/rapt_vpu_fp_widen.sv')
if top == 'rapt_vpu_fp_reduce':
    files.append(root/'hdl/backend/vpu/rapt_vpu_fp_reduce_control.sv')
    files += [root/'hdl/backend/vpu/rapt_vpu_fp_arith.sv', root/'hdl/backend/vpu/rapt_vpu_fma.sv', root/'hdl/backend/vpu/rapt_vpu_fp_widen.sv', root/'hdl/backend/vpu/rapt_vpu_fp_misc.sv', root/'hdl/backend/feu/fpu/rapt_fpu_fma.sv', root/'hdl/include/rapt_fp_ops.svh', root/'verify/vpu/fma_legacy.vlt']
if top == 'rapt_vpu_fp_transfer':
    files.append(root/'hdl/backend/vpu/rapt_vpu_slide.sv')
if top == 'rapt_vpu_fp_arith':
    files += [root/'hdl/backend/vpu/rapt_vpu_fma.sv', root/'verify/vpu/test_fma.cpp']
if top == 'rapt_vpu_fp_wide_arith':
    files += [root/'hdl/backend/vpu/rapt_vpu_fp_widen.sv', root/'hdl/backend/vpu/rapt_vpu_fp_arith.sv', root/'hdl/backend/vpu/rapt_vpu_fma.sv', root/'hdl/backend/feu/fpu/rapt_fpu_fma.sv', root/'hdl/include/rapt_fp_ops.svh', root/'verify/vpu/fma_legacy.vlt']
if top == 'rapt_vpu_fp_convert':
    files += [root/'hdl/backend/vpu/rapt_vpu_fp_widen.sv', root/'hdl/backend/feu/fpu/rapt_fpu_convert_narrow.sv']
if top == 'rapt_vpu_int_fp':
    files += [root/'hdl/backend/feu/fpu/rapt_fpu_int_to_fp.sv', root/'hdl/backend/feu/fpu/rapt_fpu_single_to_int_w.sv']
if top == 'rapt_vpu_divsqrt':
    files.append(root/'hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv')
if top == 'rapt_vpu_muldiv':
    files.append(root/'verify/vpu/muldiv_reference.h')
if top == 'rapt_vpu_fixed':
    files.append(root/'verify/vpu/fixed_reference.h')
output.write_text(json.dumps(dict(
    top=top, parameters={k: int(v) for k, v in (p.split('=') for p in sys.argv[3:])},
    verilator=subprocess.check_output(['verilator','--version'],text=True).strip(),
    sources={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}), indent=2)+'\n')
