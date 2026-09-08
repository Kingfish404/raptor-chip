`include "rapt_sva.svh"
// Raw element divide/sqrt using one shared, runtime-precision iterative unit.
// Caller resolves FRM and instruction legality; rm=5..7 and unsupported FP64
// requests return illegal without launching the arithmetic unit. Reset aborts.
module rapt_vpu_divsqrt #(
    parameter int ELEN = 64
) (
    input logic clock,
    reset,
    input logic req_valid,
    output logic req_ready,
    input logic req_double,
    req_sqrt,
    input logic [63:0] a,
    b,
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
  logic ready, valid, double_q, selected_double, bad_request;
  logic [63:0] value;
  logic [4:0] exceptions;
  assign selected_double = ELEN >= 64 && req_double;
  assign bad_request = rm > 4 || (req_double && ELEN < 64);
  rapt_fpu_divsqrt #(
      .XLEN(64)
  ) u_divsqrt (
      .clock(clock),
      .reset(reset),
      .operand_a(selected_double ? a : {32'hffffffff,a[31:0]}),
      .operand_b(selected_double ? b : {32'hffffffff,b[31:0]}),
      .rounding_mode(rm),
      .src_is_double(selected_double),
      .dst_is_double(selected_double),
      .divide(!req_sqrt),
      .sqrt(req_sqrt),
      .flush(1'b0),
      .valid(req_valid && req_ready && !bad_request),
      .ready(ready),
      .result(value),
      .flags(exceptions),
      .result_valid(valid)
  );
  assign req_ready = !reset && state == IDLE && ready;
  assign rsp_valid = !reset && state == DONE;
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      double_q <= 0;
      result <= 0;
      flags <= 0;
      illegal <= 0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          illegal <= bad_request;
          double_q <= selected_double;
          if (bad_request) begin
            result <= 0;
            flags <= 0;
            state <= DONE;
          end else state <= RUN;
        end
        RUN:
        if (valid) begin
          result <= double_q ? value : {32'b0,value[31:0]};
          flags <= exceptions;
          state <= DONE;
        end
        DONE: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_DIVSQRT_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 ({result, flags, illegal}))
endmodule
