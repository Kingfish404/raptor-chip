// Unary integer/FP conversion admission, independent of scalar XLEN.
module rapt_vpu_int_fp_decode #(
    parameter int ELEN = 64
) (
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [31:0] insn,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [2:0] sew,
    frm,
    input logic enabled,
    vill,
    output logic recognized,
    legal,
    to_float,
    unsigned_integer,
    output logic widen,
    narrow,
    float_double,
    output logic [1:0] integer_size,
    output logic [2:0] rounding_mode
);
  logic selected, direction, up, down;
  int unsigned source_size, destination_size, fp_size, int_size;
  always_comb begin
    selected = 0;
    case (insn[19:15])
      0, 1, 2, 3, 6, 7, 8, 9, 10, 11, 14, 15,
      16, 17, 18, 19, 22, 23: selected = 1;
      default: ;
    endcase
    recognized = insn[6:0] == 7'h57 && insn[31:26] == 6'h12 && insn[14:12] == 1 && selected;
    direction = insn[16] && !insn[17];
    up = insn[18] && !insn[19];
    down = insn[19];
    source_size = int'(sew) + int'(down);
    destination_size = int'(sew) + int'(up);
    fp_size = direction ? destination_size : source_size;
    int_size = direction ? source_size : destination_size;
    legal = recognized && enabled && !vill && frm <= 4
        && fp_size >= 2 && fp_size <= 3 && int_size >= 1 && int_size <= 3
        && (8 << source_size) <= ELEN && (8 << destination_size) <= ELEN;
    to_float = 0;
    unsigned_integer = 0;
    widen = 0;
    narrow = 0;
    float_double = 0;
    integer_size = 0;
    rounding_mode = 0;
    if (legal) begin
      to_float = direction;
      unsigned_integer = !insn[15];
      widen = up;
      narrow = down;
      float_double = fp_size == 3;
      integer_size = 2'(int_size);
      rounding_mode = insn[17] ? 3'd1 : frm;
    end
  end
endmodule
