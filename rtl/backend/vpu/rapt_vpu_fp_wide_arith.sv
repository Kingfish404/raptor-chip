// FP32 -> FP64 widening arithmetic. operation uses the fp_arith encoding:
// 0=FMA, 1=add, 2=subtract, 3=multiply. FMA's c is always raw FP64.
// a_is_wide selects the FP64 source of vfwadd.w/vfwsub.w only; b is FP32.
// Scalar boxing and ISA register geometry are the caller's responsibility.
module rapt_vpu_fp_wide_arith (
    input logic clock,
    reset,
    req_valid,
    output logic req_ready,
    input logic [1:0] operation,
    input logic a_is_wide,
    input logic [63:0] a,
    input logic [31:0] b,
    input logic [63:0] c,
    input logic negate_product,
    negate_addend,
    input logic [2:0] rm,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  logic [63:0] expanded_a, expanded_b;
  logic bad_shape;
  rapt_vpu_fp_widen u_a (
      .value(a[31:0]),
      .result(expanded_a)
  );
  rapt_vpu_fp_widen u_b (
      .value(b),
      .result(expanded_b)
  );
  assign bad_shape = a_is_wide && operation != 1 && operation != 2;
  // The existing held-response wrapper rejects reserved RM without launching
  // arithmetic; use that same path for invalid widening operand shapes.
  rapt_vpu_fp_arith #(
      .Double(1)
  ) u_arith (
      .clock(clock),
      .reset(reset),
      .req_valid(req_valid),
      .req_ready(req_ready),
      .operation(operation),
      .a(a_is_wide ? a : expanded_a),
      .b(expanded_b),
      .c(c),
      .negate_product(negate_product),
      .negate_addend(negate_addend),
      .rm(bad_shape ? 3'd7 : rm),
      .rsp_valid(rsp_valid),
      .rsp_ready(rsp_ready),
      .result(result),
      .flags(flags),
      .illegal(illegal)
  );
endmodule
