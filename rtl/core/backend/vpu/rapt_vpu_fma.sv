`include "rapt_fp_ops.svh"
`include "rapt_sva.svh"

// Independently testable fused element engine. Inputs are raw vector bits;
// FP32 values do not carry scalar NaN boxing. Caller resolves dynamic FRM,
// selects operand order, and accumulates flags only for active written elements.
// No command cancellation after acceptance; reset aborts all local work.
/* verilator lint_off DECLFILENAME */
module rapt_vpu_fma_multi (
    input logic clock,
    input logic reset,
    input logic req_valid,
    output logic req_ready,
    input logic req_double,
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [63:0] c,
    input logic negate_product,
    input logic negate_addend,
    input logic [2:0] rm,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  typedef enum logic [1:0] {
    IDLE,
    RUN,
    DONE
  } state_t;
  state_t state;
  logic ready, valid, double_q;
  logic [5:0] op;
  logic [63:0] value;
  logic [4:0] exceptions;
  logic [52:0] product_a, product_b;
  logic [105:0] product;
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_product_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  assign product = product_a * product_b;

  always_comb begin
    unique case ({
      negate_product, negate_addend
    })
      2'd0: op = req_double ? `RAPT_FP_OP_FMADD_D : `RAPT_FP_OP_FMADD_S;
      2'd1: op = req_double ? `RAPT_FP_OP_FMSUB_D : `RAPT_FP_OP_FMSUB_S;
      2'd2: op = req_double ? `RAPT_FP_OP_FNMSUB_D : `RAPT_FP_OP_FNMSUB_S;
      default: op = req_double ? `RAPT_FP_OP_FNMADD_D : `RAPT_FP_OP_FNMADD_S;
    endcase
  end

  rapt_fpu_fma_pipeline #(
      .TARGET_DOUBLE(1'b1),
      .MultiFormat(1'b1)
  ) u_fma (
      .clock(clock),
      .reset(reset),
      .flush(1'b0),
      .valid(req_valid && req_ready && rm <= 3'd4),
      .target_double(req_double),
      .ready(ready),
      .op(op),
      .operand_a(req_double ? a : {32'hffff_ffff, a[31:0]}),
      .operand_b(req_double ? b : {32'hffff_ffff, b[31:0]}),
      .operand_c(req_double ? c : {32'hffff_ffff, c[31:0]}),
      .rounding_mode(rm),
      .result(value),
      .flags(exceptions),
      .result_valid(valid),
      .product_a(product_a),
      .product_b(product_b),
      .product_valid(unused_product_valid),
      .product(product)
  );

  assign req_ready = !reset && state == IDLE && ready;
  assign rsp_valid = !reset && state == DONE;

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      double_q <= 1'b0;
      result <= 64'd0;
      flags <= 5'd0;
      illegal <= 1'b0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          double_q <= req_double;
          illegal <= rm > 3'd4;
          if (rm > 3'd4) begin
            result <= 64'd0;
            flags <= 5'd0;
            state <= DONE;
          end else state <= RUN;
        end
        RUN:
        if (valid) begin
          result <= double_q ? value : {32'b0, value[31:0]};
          flags <= exceptions;
          state <= DONE;
        end
        DONE: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_FMA_MULTI_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 ({result, flags, illegal}))
endmodule
/* verilator lint_on DECLFILENAME */

module rapt_vpu_fma #(
    parameter bit Double = 1
) (
    input logic clock,
    input logic reset,
    input logic req_valid,
    output logic req_ready,
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [63:0] c,
    input logic negate_product,
    input logic negate_addend,
    input logic [2:0] rm,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  typedef enum logic [1:0] {
    IDLE,
    RUN,
    DONE
  } state_t;
  state_t state;
  logic ready, valid;
  logic [5:0] op;
  logic [63:0] value;
  logic [4:0] exceptions;
  always_comb begin
    unique case ({
      negate_product, negate_addend
    })
      2'd0: op = Double ? `RAPT_FP_OP_FMADD_D : `RAPT_FP_OP_FMADD_S;
      2'd1: op = Double ? `RAPT_FP_OP_FMSUB_D : `RAPT_FP_OP_FMSUB_S;
      2'd2: op = Double ? `RAPT_FP_OP_FNMSUB_D : `RAPT_FP_OP_FNMSUB_S;
      default: op = Double ? `RAPT_FP_OP_FNMADD_D : `RAPT_FP_OP_FNMADD_S;
    endcase
  end
  rapt_fpu_fma #(
      .TARGET_DOUBLE(Double)
  ) u_fma (
      .clock(clock),
      .reset(reset),
      .flush(1'b0),
      .valid(req_valid && req_ready && rm <= 3'd4),
      .ready(ready),
      .op(op),
      .operand_a(Double ? a : {32'hffffffff, a[31:0]}),
      .operand_b(Double ? b : {32'hffffffff, b[31:0]}),
      .operand_c(Double ? c : {32'hffffffff, c[31:0]}),
      .rounding_mode(rm),
      .result(value),
      .flags(exceptions),
      .result_valid(valid)
  );
  assign req_ready = !reset && state == IDLE && ready;
  assign rsp_valid = !reset && state == DONE;
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      result <= 64'd0;
      flags <= 5'd0;
      illegal <= 1'b0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          illegal <= rm > 3'd4;
          if (rm > 3'd4) begin
            result <= 64'd0;
            flags <= 5'd0;
            state <= DONE;
          end else state <= RUN;
        end
        RUN:
        if (valid) begin
          result <= Double ? value : {32'b0, value[31:0]};
          flags <= exceptions;
          state <= DONE;
        end
        DONE: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_FMA_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 ({result, flags, illegal}))
endmodule
