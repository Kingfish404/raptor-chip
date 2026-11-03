// Target-neutral pad primitives used by rapt_chip_pads. These behavioral bodies
// serve simulation and generic synthesis; an implementation flow may supply
// modules with the same names and ports that wrap real I/O cells.
//
// Pull selects the pad's weak pull: 0 = none, 1 = up, 2 = down.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
module rapt_pad_in #(
    parameter int Pull = 0
) (
    input wire pad,
    output logic c_o
);
  assign c_o = pad;
endmodule

module rapt_pad_out (
    input logic i_i,
    output wire pad
);
  assign pad = i_i;
endmodule

module rapt_pad_bidi #(
    parameter int Pull = 0
) (
    input logic i_i,
    input logic oe_i,
    output logic c_o,
    inout wire pad
);
  assign pad = oe_i ? i_i : 1'bz;
  assign c_o = pad;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on DECLFILENAME */
