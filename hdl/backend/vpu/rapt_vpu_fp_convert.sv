`include "rapt_sva.svh"
// Raw FP32/FP64 format conversions. rm=0..4 are IEEE rounding modes;
// rm=6 means round-to-odd for narrowing only, not an architectural FRM value.
// Scalar NaN boxing and instruction/FRM legality belong to the caller.
module rapt_vpu_fp_convert (
    input logic clock,
    reset,
    req_valid,
    output logic req_ready,
    input logic req_widen,
    input logic [63:0] operand,
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
  logic lower_ready, lower_valid, bad_request, odd_q;
  // Scalar converter returns an NaN-boxed FP32 value; vectors store raw bits.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] lower_result;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [63:0] expanded;
  logic [4:0] lower_flags;
  logic source_nan;
  rapt_vpu_fp_widen u_expand (
      .value(operand[31:0]),
      .result(expanded)
  );
  assign source_nan = (&operand[30:23]) && operand[22:0] != 0;
  assign bad_request = rm > 4 && (rm != 6 || req_widen);
  assign req_ready = !reset && state == IDLE && lower_ready;
  assign rsp_valid = !reset && state == DONE;
  rapt_fpu_convert_narrow u_narrow (
      .clock(clock),
      .reset(reset),
      .flush(1'b0),
      .valid(req_valid && req_ready && !req_widen && !bad_request),
      .ready(lower_ready),
      .operand(operand),
      .rounding_mode(rm == 6 ? 3'd1 : rm),
      .result(lower_result),
      .flags(lower_flags),
      .result_valid(lower_valid)
  );
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      result <= 0;
      flags <= 0;
      illegal <= 0;
      odd_q <= 0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          illegal <= bad_request;
          odd_q <= rm == 6;
          if (bad_request) begin
            result <= 0;
            flags <= 0;
            state <= DONE;
          end else if (req_widen) begin
            result <= source_nan ? 64'h7ff8000000000000 : expanded;
            flags <= {source_nan && !operand[22],4'b0};
            state <= DONE;
          end else state <= RUN;
        end
        RUN:
        if (lower_valid) begin
          result <= {32'b0,lower_result[31:1],lower_result[0] || (odd_q && lower_flags[0])};
          flags <= lower_flags;
          state <= DONE;
        end
        DONE: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_FP_CONVERT_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 ({result, flags, illegal}))
endmodule
