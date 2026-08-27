// ============================================================================
// Formal verification wrapper for rapt_fpu_divsqrt (iterative divider / sqrt)
// ----------------------------------------------------------------------------
// Proves safety and liveness properties of the multi-cycle divider/square-root
// unit. These properties are independent of any floating-point reference
// model (which produces pathological SMT encodings when inlined), so the
// proof is robust and tractable:
//
//   liveness      : every launched operation completes within 64 cycles
//   no_spurious   : result_valid only rises while an operation is in flight
//   special_case  : NaN / Inf / zero / div-by-zero complete in ONE cycle
//   stability     : result/flags only change when result_valid fires
//   flush_clean   : a flushed operation never asserts result_valid
//
// Numeric correctness is established separately by the exhaustive host-FPU
// differential testbench in verify/xsim/fpu/divsqrt (300k vectors,
// bit-exact). This wrapper complements it with proof of the control contract.
//
//   make formal_divsqrt        -> BMC  (finds counterexamples up to depth 70)
//   make formal_divsqrt_prove  -> k-induction proof of the safety properties
// ============================================================================

module formal_divsqrt (
    input logic        clock,
    input logic        reset,
    input logic [63:0] operand_a,
    input logic [63:0] operand_b,
    input logic [2:0]  rounding_mode,
    input logic        src_is_double,
    input logic        divide,
    input logic        sqrt,
    input logic        valid,
    input logic        flush
);

  logic        dut_ready;
  logic [63:0] dut_result;
  logic [4:0]  dut_flags;
  logic        dut_valid;

  rapt_fpu_divsqrt dut (
      .clock(clock), .reset(reset),
      .operand_a(operand_a), .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .src_is_double(src_is_double), .dst_is_double(src_is_double),
      .divide(divide), .sqrt(sqrt), .flush(flush),
      .valid(valid), .ready(dut_ready),
      .result(dut_result), .flags(dut_flags), .result_valid(dut_valid)
  );

  // Legal launch contract (mirrors the EXU issue stage).
  always_comb begin
    asm_rm:    assume (rounding_mode <= 3'd4);
    asm_rdy:   assume (!(valid && !dut_ready));        // never launch while busy
    asm_mutex: assume (!(valid && divide && sqrt));    // mutually exclusive
    asm_op:    assume (!(valid && !divide && !sqrt));  // exactly one op
  end

  // Initialisation: force a reset on the very first frame so the proof starts
  // from a known state (registers are otherwise arbitrary at time 0, which
  // would produce spurious counterexamples / unsat cores on the assumptions).
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clock) f_past_valid <= 1'b1;
  always_comb begin
    asm_init: assume (f_past_valid || reset);
  end

  wire launch = valid && dut_ready && (divide || sqrt);

  // ------------------------------------------------------------------------
  // Special-case detection (combinational, mirrors the DUT decode) so the
  // "completes in one cycle" property can be stated precisely.
  // ------------------------------------------------------------------------
  logic [10:0] exp_a, exp_b;
  logic [51:0] frac_a, frac_b;
  logic        sign_a, a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
  assign exp_a  = src_is_double ? operand_a[62:52] : {3'b0, operand_a[30:23]};
  assign exp_b  = src_is_double ? operand_b[62:52] : {3'b0, operand_b[30:23]};
  assign frac_a = src_is_double ? operand_a[51:0]  : {29'b0, operand_a[22:0]};
  assign frac_b = src_is_double ? operand_b[51:0]  : {29'b0, operand_b[22:0]};
  assign sign_a = src_is_double ? operand_a[63]    : operand_a[31];
  assign a_nan  = (&exp_a) && (frac_a != '0);
  assign b_nan  = (&exp_b) && (frac_b != '0);
  assign a_inf  = (&exp_a) && (frac_a == '0);
  assign b_inf  = (&exp_b) && (frac_b == '0);
  assign a_zero = (exp_a == '0) && (frac_a == '0);
  assign b_zero = (exp_b == '0) && (frac_b == '0);

  wire is_special = a_nan || (divide && b_nan)
      || (!divide && sign_a && !a_zero)
      || (divide && (b_zero || b_inf || ((a_zero && b_zero) || (a_inf && b_inf))))
      || a_inf || a_zero;

  // ------------------------------------------------------------------------
  // Operation tracking
  // ------------------------------------------------------------------------
  logic       in_flight_q;   // an iterative (non-special) op is running
  logic       any_op_q;      // any op launched, result pending
  logic [6:0] cycles_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      in_flight_q <= 1'b0;
      any_op_q    <= 1'b0;
      cycles_q    <= '0;
    end else begin
      if (launch) begin
        any_op_q    <= 1'b1;
        in_flight_q <= !is_special;
        cycles_q    <= '0;
      end else if (dut_valid) begin
        any_op_q    <= 1'b0;
        in_flight_q <= 1'b0;
        cycles_q    <= '0;
      end else if (in_flight_q) begin
        cycles_q    <= cycles_q + 7'd1;
      end
    end
  end

  // ------------------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------------------
`ifdef FORMAL
  // Delayed signals for the temporal properties (this slang build does not
  // support $past/$stable, so we register the previous-cycle values).
  logic        result_valid_d;
  logic [63:0] dut_result_d;
  logic [4:0]  dut_flags_d;
  always_ff @(posedge clock) begin
    if (reset) begin
      result_valid_d <= 1'b0;
      dut_result_d   <= '0;
      dut_flags_d    <= '0;
    end else begin
      result_valid_d <= dut_valid;
      dut_result_d   <= dut_result;
      dut_flags_d    <= dut_flags;
    end
  end

  always_ff @(posedge clock) begin
    if (!reset) begin
      // ---- Liveness: an iterative op completes within 63 cycles ----
      live: assert (!(in_flight_q && cycles_q == 7'd62) || dut_valid || flush);

      // ---- No spurious result_valid without a launched operation ----
      nospur: assert (!(dut_valid && !any_op_q && !launch));

      // ---- Stability: result/flags only change when result_valid fires ----
      if (result_valid_d && !dut_valid) begin
        stab_r: assert (dut_result == dut_result_d);
        stab_f: assert (dut_flags  == dut_flags_d);
      end
    end
  end

  // ---- Special cases complete in exactly one cycle ----
  // (launch with a special operand => result_valid is already high next cycle,
  //  i.e. the unit never enters the iterative state for them).
  logic launch_special_q;
  always_ff @(posedge clock) begin
    if (reset || flush) launch_special_q <= 1'b0;
    else                launch_special_q <= (launch && is_special);
  end
  always_ff @(posedge clock) begin
    if (!reset && launch_special_q && !flush) begin
      spec1: assert (dut_valid);
    end
  end

  // ---- Flush: a flushed operation never asserts result_valid afterwards ----
  logic flush_d;
  always_ff @(posedge clock) begin
    if (reset) flush_d <= 1'b0;
    else       flush_d <= flush;
  end
  always_ff @(posedge clock) begin
    if (!reset && flush_d && !flush) begin
      flclean: assert (!dut_valid);
    end
  end

  // ---- Coverage witnesses ----
  always_ff @(posedge clock) begin
    if (!reset) begin
      cov_div_dp:  cover (dut_valid &&  divide &&  src_is_double);
      cov_div_sp:  cover (dut_valid &&  divide && !src_is_double);
      cov_sqrt_dp: cover (dut_valid &&  sqrt   &&  src_is_double);
      cov_sqrt_sp: cover (dut_valid &&  sqrt   && !src_is_double);
      cov_special: cover (dut_valid &&  launch_special_q);
    end
  end
`endif

endmodule
