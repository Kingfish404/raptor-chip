// RVV 1.0 FP reduction admission. No arithmetic or architectural effects.
// enabled combines VS and FS. Caller checks VTYPE/LMUL/source-group geometry,
// VL and nonzero vstart before reading VRF or issuing a numeric request.
// Seed/destination are scalars independent of LMUL and may overlap any source.
module rapt_vpu_fp_reduce_decode #(
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
    output logic [1:0] operation,
    output logic source_double,
    widen,
    ordered_sum
);
  logic selected_widen, selected_ordered;
  logic [1:0] selected_operation;
  always_comb begin
    recognized = 0;
    selected_widen = 0;
    selected_ordered = 0;
    selected_operation = 0;
    if (insn[6:0] == 7'h57 && insn[14:12] == 1) begin
      case (insn[31:26])
        6'h01: recognized = 1; // vfredusum
        6'h03: begin recognized = 1; selected_ordered = 1; end
        6'h05: begin recognized = 1; selected_operation = 1; end
        6'h07: begin recognized = 1; selected_operation = 2; end
        6'h31: begin recognized = 1; selected_widen = 1; end
        6'h33: begin recognized = 1; selected_widen = 1; selected_ordered = 1; end
        default: ;
      endcase
    end
    legal = recognized && enabled && !vill && frm <= 4 && ELEN >= 32
        && (sew == 2 || (sew == 3 && ELEN >= 64))
        && (!selected_widen || (sew == 2 && ELEN >= 64));
    operation = legal ? selected_operation : 2'd0;
    source_double = legal && sew == 3;
    widen = legal && selected_widen;
    ordered_sum = legal && selected_ordered;
  end
endmodule
