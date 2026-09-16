#!/usr/bin/env python3
"""Prove the actual SQ span helper against full-width modular subtraction.

Only the combinational helper is proved, not the whole SQ or its lifecycle.
The function's single SV return is translated to a function-result assignment
for Yosys's built-in SystemVerilog frontend; its arithmetic is unchanged.
"""

import argparse
import hashlib
from pathlib import Path
import re
import subprocess


REFERENCE = """
function automatic logic reference_span(input logic [Xlen-1:0] store_va,
    load_va, input logic [1:0] span, load_span, input logic page_only);
  logic [Xlen-OffsetBits-1:0] forward_word, backward_word;
  logic [11-OffsetBits:0] forward_page, backward_page;
  forward_word = load_va[Xlen-1:OffsetBits] - store_va[Xlen-1:OffsetBits];
  backward_word = store_va[Xlen-1:OffsetBits] - load_va[Xlen-1:OffsetBits];
  forward_page = load_va[11:OffsetBits] - store_va[11:OffsetBits];
  backward_page = store_va[11:OffsetBits] - load_va[11:OffsetBits];
  reference_span = page_only
      ? (forward_page <= (12-OffsetBits)'(span)
         || backward_page <= (12-OffsetBits)'(load_span))
      : (forward_word <= (Xlen-OffsetBits)'(span)
         || backward_word <= (Xlen-OffsetBits)'(load_span));
endfunction
"""


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path,
                        default=repo / "hdl/backend/lsu/rapt_sq_forward.sv")
    parser.add_argument("--build-dir", type=Path,
                        default=repo / "verify/build/sq-span-equivalence")
    parser.add_argument("--yosys", default="yosys")
    args = parser.parse_args()
    rtl = args.rtl.read_text()
    match = re.search(r"function automatic logic word_in_store\b.*?endfunction",
                      rtl, re.DOTALL)
    if match is None:
        parser.error("word_in_store helper not found; update the proof adapter")
    helper = match.group()
    if len(re.findall(r"\breturn\b", helper)) != 1:
        parser.error("expected one return; review the proof adapter for new control flow")
    helper = re.sub(r"\breturn\s+", "word_in_store = ", helper)
    output = args.build_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    print(f"RTL SHA256={hashlib.sha256(rtl.encode()).hexdigest()}", flush=True)
    for xlen in (32, 64):
        source = output / f"span-rv{xlen}.sv"
        source.write_text(f"""module span_equivalence (
input [{xlen - 1}:0] store_va, load_va,
input [1:0] span, load_span,
input page_only,
output equivalent);
localparam Xlen = {xlen};
localparam OffsetBits = $clog2(Xlen/8);
{REFERENCE}
{helper}
assign equivalent = reference_span(store_va, load_va, span, load_span, page_only)
                 == word_in_store(store_va, load_va, span, load_span, page_only);
endmodule
""")
        quoted_source = str(source).replace("\\", "\\\\").replace('"', '\\"')
        commands = (f'read_verilog -sv "{quoted_source}"; '
                    "prep -top span_equivalence; flatten; "
                    "sat -verify -prove equivalent 1 -show-inputs")
        log_path = output / f"proof-rv{xlen}.log"
        with log_path.open("w") as log:
            result = subprocess.run([args.yosys, "-Q", "-T", "-p", commands],
                                    stdout=log, stderr=subprocess.STDOUT, check=False)
        if result.returncode or "SAT proof finished - no model found: SUCCESS!" not in log_path.read_text():
            raise SystemExit(f"FAIL: RV{xlen} span equivalence; see {log_path}")
        print(f"PASS: RV{xlen} SQ span equivalence, unconstrained inputs ({log_path})",
              flush=True)


if __name__ == "__main__":
    main()
