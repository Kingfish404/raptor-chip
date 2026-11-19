`include "rapt_sva.svh"
// Raw adjacent-width format conversions. rm=0..4 are IEEE rounding modes.
// rm=6 selects round-to-odd for FP64-to-FP32 narrowing.
// Scalar NaN boxing and instruction/FRM legality belong to the caller.
module rapt_vpu_fp_convert #(
    parameter bit Zvfhmin = 0
) (
    input logic clock,
    reset,
    req_valid,
    output logic req_ready,
    input logic req_widen,
    input logic req_half,
    input logic [63:0] operand,
    input logic [2:0] rm,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  typedef enum logic [2:0] {
    IDLE,
    RUN,
    HALF_WIDEN,
    HALF_NARROW,
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
  logic half_widen_ready, half_widen_valid, half_narrow_ready, half_narrow_valid;
  // Each shared converter also returns the scalar NaN box above the element.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] half_expanded, half_narrowed;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [4:0] half_widen_flags, half_narrow_flags;
  rapt_vpu_fp_widen u_expand (
      .value(operand[31:0]),
      .result(expanded)
  );
  assign source_nan = (&operand[30:23]) && operand[22:0] != 0;
  assign bad_request = (req_half && !Zvfhmin) || (rm > 4 && (rm != 6 || req_widen || req_half));
  assign req_ready = !reset && state == IDLE && (Zvfhmin && req_half
      ? (req_widen ? half_widen_ready : half_narrow_ready) : lower_ready);
  assign rsp_valid = !reset && state == DONE;
  rapt_fpu_convert_narrow u_narrow (
      .clock(clock),
      .reset(reset),
      .flush(1'b0),
      .valid(req_valid && req_ready && !req_half && !req_widen && !bad_request),
      .ready(lower_ready),
      .operand(operand),
      .rounding_mode(rm == 6 ? 3'd1 : rm),
      .result(lower_result),
      .flags(lower_flags),
      .result_valid(lower_valid)
  );
  if (Zvfhmin) begin : g_half
    // The shared scalar converters check NaN boxes. Vector memory and the
    // VRF carry raw element bits, so supply and remove the boxes here.
    rapt_fpu_half_to_fp u_widen (
        .clock,
        .reset,
        .flush(1'b0),
        .valid(req_valid && req_ready && req_half && req_widen && !bad_request),
        .ready(half_widen_ready),
        .operand({48'hffff_ffff_ffff, operand[15:0]}),
        .target_double(1'b0),
        .result(half_expanded),
        .flags(half_widen_flags),
        .result_valid(half_widen_valid)
    );
    rapt_fpu_fp_to_half u_narrow (
        .clock,
        .reset,
        .flush(1'b0),
        .valid(req_valid && req_ready && req_half && !req_widen && !bad_request),
        .ready(half_narrow_ready),
        .operand({32'hffff_ffff, operand[31:0]}),
        .source_double(1'b0),
        .rounding_mode(rm),
        .result(half_narrowed),
        .flags(half_narrow_flags),
        .result_valid(half_narrow_valid)
    );
  end else begin : g_no_half
    assign half_widen_ready = 1'b0;
    assign half_widen_valid = 1'b0;
    assign half_narrow_ready = 1'b0;
    assign half_narrow_valid = 1'b0;
    assign half_expanded = '0;
    assign half_narrowed = '0;
    assign half_widen_flags = '0;
    assign half_narrow_flags = '0;
  end
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
          end else if (req_half) begin
            state <= req_widen ? HALF_WIDEN : HALF_NARROW;
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
        HALF_WIDEN:
        if (half_widen_valid) begin
          result <= 64'(half_expanded[31:0]);
          flags <= half_widen_flags;
          state <= DONE;
        end
        HALF_NARROW:
        if (half_narrow_valid) begin
          result <= 64'(half_narrowed[15:0]);
          flags <= half_narrow_flags;
          state <= DONE;
        end
        DONE: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_FP_CONVERT_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 ({result, flags, illegal}))
endmodule
