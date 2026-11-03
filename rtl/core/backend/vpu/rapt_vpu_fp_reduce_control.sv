`include "rapt_sva.svh"
// Sequential floating-point reduction stream, independent of VRF and XLEN.
// op: 0=sum, 1=min, 2=max. Ordered summation is also a permitted unordered
// implementation. Caller streams exactly count elements in increasing order,
// with active=0 for masked entries; seed is vs1[0] at destination precision.
// Zero count completes without a destination write; all inactive, nonempty
// streams copy the seed without arithmetic or exception flags.
module rapt_vpu_fp_reduce_control #(
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
    write_result,
    output logic service_req_valid,
    input logic service_req_ready,
    output logic [1:0] service_op,
    output logic service_double,
    output logic [2:0] service_rm,
    output logic [63:0] service_a,
    service_b,
    input logic service_rsp_valid,
    output logic service_rsp_ready,
    input logic [63:0] service_result,
    input logic [4:0] service_flags,
    input logic service_illegal
);
  typedef enum logic [2:0] {
    IDLE,
    FEED,
    ISSUE,
    RUN,
    DONE
  } state_t;
  state_t state;
  logic [1:0] op_q;
  logic double_q, widen_q, bad_request;
  logic [2:0] rm_q;
  logic [CountBits-1:0] remaining_q;
  logic [63:0] operand_q, expanded;
  assign bad_request = op == 3 || rm > 4 || (widen && (source_double || op != 0))
      || (ELEN < 64 && (source_double || widen)) || ELEN < 32;
  assign req_ready = !reset && state == IDLE;
  assign element_ready = !reset && state == FEED;
  assign rsp_valid = !reset && state == DONE;
  if (ELEN >= 64) begin : gen_expand
    rapt_vpu_fp_widen u_expand (
        .value(element[31:0]),
        .result(expanded)
    );
  end else begin : gen_no_expand
    assign expanded = 0;
  end
  // One outstanding numeric request. The service must reset/drain with this
  // controller; responses carry no identity and must belong to that request.
  // A combinational service may return on the request-acceptance cycle.
  assign service_req_valid = !reset && state == ISSUE;
  assign service_rsp_ready = !reset && (state == RUN || (state == ISSUE && service_req_ready));
  assign service_op = op_q;
  assign service_double = double_q;
  assign service_rm = rm_q;
  assign service_a = result;
  assign service_b = operand_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      op_q <= 0;
      double_q <= 0;
      widen_q <= 0;
      rm_q <= 0;
      remaining_q <= 0;
      operand_q <= 0;
      result <= 0;
      flags <= 0;
      illegal <= 0;
      write_result <= 0;
    end else begin
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          op_q <= op;
          double_q <= source_double || widen;
          widen_q <= widen;
          rm_q <= rm;
          remaining_q <= count;
          flags <= 0;
          illegal <= bad_request;
          write_result <= !bad_request && count != 0;
          result <= bad_request ? 64'd0 : source_double || widen ? seed : {32'd0,seed[31:0]};
          state <= bad_request || count == 0 ? DONE : FEED;
        end
        FEED:
        if (element_valid && element_ready) begin
          remaining_q <= remaining_q - 1'b1;
          if (!element_active) begin
            if (remaining_q == 1) state <= DONE;
          end else begin
            operand_q <= widen_q ? expanded : double_q ? element : {32'd0,element[31:0]};
            state <= ISSUE;
          end
        end
        ISSUE: if (service_req_ready) state <= RUN;
        RUN: ;
        DONE: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
      if (service_rsp_valid && service_rsp_ready) begin
        result <= service_result;
        flags <= flags | service_flags;
        illegal <= service_illegal;
        if (service_illegal) begin
          write_result <= 0;
          state <= DONE;
        end else state <= remaining_q == 0 ? DONE : FEED;
      end
    end
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_FP_REDUCE_SERVICE_HOLD, service_req_valid && !service_req_ready,
                 service_req_valid && $stable
                 ({service_op, service_double, service_rm, service_a, service_b}))
  `RAPT_SVA_NEXT(clock, reset, VPU_FP_REDUCE_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 ({result, flags, illegal, write_result}))
  `RAPT_SVA_IMPLY(clock, reset, VPU_FP_REDUCE_FEED_COUNT, element_ready,
                  remaining_q != 0 && !req_ready && !rsp_valid)
endmodule
