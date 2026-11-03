// Raw FP32/FP64 element arithmetic with one shared fused datapath. Operation
// 0 is FMA with independent sign controls; 1/2/3 are add/subtract/multiply and
// ignore c and the sign controls. No intermediate product rounding is added.
module rapt_vpu_fp_arith #(
    parameter bit Double = 1
) (
    input logic clock,
    reset,
    input logic req_valid,
    output logic req_ready,
    input logic [1:0] operation,
    input logic [63:0] a,
    b,
    c,
    input logic negate_product,
    negate_addend,
    input logic [2:0] rm,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  logic [63:0] factor, addend;
  logic product_negative, addend_negative;
  always_comb begin
    factor = b;
    addend = c;
    product_negative = negate_product;
    addend_negative = negate_addend;
    if (operation != 0) begin
      product_negative = 0;
      addend_negative = 0;
      if (operation == 3) begin
        // Use a zero with the exact product sign. Adding +0 unconditionally
        // would turn a negative zero product into +0 under several modes.
        addend = Double ? {a[63] ^ b[63], 63'b0} : {32'b0, a[31] ^ b[31], 31'b0};
      end else begin
        factor = Double ? 64'h3ff0000000000000 : 64'h000000003f800000;
        addend = b;
        addend_negative = operation == 2;
      end
    end
  end
  rapt_vpu_fma #(
      .Double(Double)
  ) u_fma (
      .clock(clock),
      .reset(reset),
      .req_valid(req_valid),
      .req_ready(req_ready),
      .a(a),
      .b(factor),
      .c(addend),
      .negate_product(product_negative),
      .negate_addend(addend_negative),
      .rm(rm),
      .rsp_valid(rsp_valid),
      .rsp_ready(rsp_ready),
      .result(result),
      .flags(flags),
      .illegal(illegal)
  );
endmodule
