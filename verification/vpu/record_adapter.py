#!/usr/bin/env python3
"""Fingerprint the core adapter/owner composition test before building."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
files = [root/p for p in (
    'rtl/backend/vpu/rapt_vpu_core_adapter.sv',
    'rtl/backend/vpu/rapt_vpu_owner.sv', 'rtl/include/rapt_sva.svh',
    'verification/vpu/tb_vpu_core_adapter.sv', 'verification/vpu/Makefile',
    'verification/vpu/record_adapter.py')]
Path(sys.argv[1]).write_text(json.dumps(dict(
    parameters=dict(RobBits=int(sys.argv[2]), GenerationBits=int(sys.argv[3]),
                    CommandBits=32, ResultBits=32, MetadataBits=64),
    verilator=subprocess.check_output(['verilator', '--version'], text=True).strip(),
    sources={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in files}), indent=2)+'\n')
