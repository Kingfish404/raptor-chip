`include "rapt_sva.svh"
// Sequential floating-point reduction stream, independent of VRF and XLEN.
// op: 0=sum, 1=min, 2=max. Ordered summation is also a permitted unordered
// implementation. Caller streams exactly count elements in increasing order,
// with active=0 for masked entries; seed is vs1[0] at destination precision.
// Zero count completes without a destination write; all inactive, nonempty
// streams copy the seed without arithmetic or exception flags.
module rapt_vpu_fp_reduce #(
    parameter int ELEN = 64,
    parameter int CountBits = 10
) (
    input logic clock,
    reset,
    req_valid,
    output logic req_ready,
    input logic [1:0] op,
    input logic source_double,
    widen,
    input logic [2:0] rm,
    input logic [CountBits-1:0] count,
    input logic [63:0] seed,
    input logic element_valid,
    element_active,
    output logic element_ready,
    input logic [63:0] element,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal,
    write_result
);
  logic service_req_valid, service_req_ready, service_rsp_valid, service_rsp_ready;
  logic service_double, service_illegal;
  logic [1:0] service_op;
  logic [2:0] service_rm;
  logic [63:0] service_a, service_b, service_result;
  logic [4:0] service_flags;
  logic [1:0] sum_ready, sum_valid, sum_illegal, misc_illegal;
  logic [1:0][63:0] sum_result, misc_result;
  logic [1:0][4:0] sum_flags, misc_flags;
  // Standalone numerical wrapper; integrated users can share their numeric
  // resources by instantiating the control module directly.
  rapt_vpu_fp_reduce_control #(
      .ELEN(ELEN),
      .CountBits(CountBits)
  ) u_control (
      .clock(clock),
      .reset(reset),
      .req_valid(req_valid),
      .req_ready(req_ready),
      .op(op),
      .source_double(source_double),
      .widen(widen),
      .rm(rm),
      .count(count),
      .seed(seed),
      .element_valid(element_valid),
      .element_active(element_active),
      .element_ready(element_ready),
      .element(element),
      .rsp_valid(rsp_valid),
      .rsp_ready(rsp_ready),
      .result(result),
      .flags(flags),
      .illegal(illegal),
      .write_result(write_result),
      .service_req_valid(service_req_valid),
      .service_req_ready(service_req_ready),
      .service_op(service_op),
      .service_double(service_double),
      .service_rm(service_rm),
      .service_a(service_a),
      .service_b(service_b),
      .service_rsp_valid(service_rsp_valid),
      .service_rsp_ready(service_rsp_ready),
      .service_result(service_result),
      .service_flags(service_flags),
      .service_illegal(service_illegal)
  );
  assign service_req_ready = service_op == 0 ? sum_ready[service_double] : 1'b1;
  assign service_rsp_valid = service_op == 0 ? sum_valid[service_double] : service_req_valid;
  assign service_result = service_op == 0 ? sum_result[service_double] : misc_result[service_double];
  assign service_flags = service_op == 0 ? sum_flags[service_double] : misc_flags[service_double];
  assign service_illegal = service_op == 0 ? sum_illegal[service_double] : misc_illegal[service_double];
  for (genvar precision = 0; precision < 2; precision++) begin : gen_precision
    if (precision == 0 || ELEN >= 64) begin : gen_supported
      rapt_vpu_fp_arith #(
          .Double(precision == 1)
      ) u_sum (
          .clock(clock),
          .reset(reset),
          .req_valid(service_req_valid && service_op == 0 && service_double == 1'(precision)),
          .req_ready(sum_ready[precision]),
          .operation(2'd1),
          .a(service_a),
          .b(service_b),
          .c(64'd0),
          .negate_product(1'b0),
          .negate_addend(1'b0),
          .rm(service_rm),
          .rsp_valid(sum_valid[precision]),
          .rsp_ready(service_rsp_ready && service_op == 0 && service_double == 1'(precision)),
          .result(sum_result[precision]),
          .flags(sum_flags[precision]),
          .illegal(sum_illegal[precision])
      );
      rapt_vpu_fp_misc #(
          .Double(precision == 1)
      ) u_minmax (
          .a(service_a),
          .b(service_b),
          .operation(service_op == 2 ? 4'd1 : 4'd0),
          .result(misc_result[precision]),
          .flags(misc_flags[precision]),
          .illegal(misc_illegal[precision])
      );
    end else begin : gen_absent
      assign sum_ready[precision] = 0;
      assign sum_valid[precision] = 0;
      assign sum_illegal[precision] = 0;
      assign sum_result[precision] = 0;
      assign sum_flags[precision] = 0;
      assign misc_result[precision] = 0;
      assign misc_flags[precision] = 0;
      assign misc_illegal[precision] = 0;
    end
  end
endmodule
