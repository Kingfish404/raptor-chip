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
//   result_owner  : every result belongs to a previously launched operation
//   flush_clean   : a flushed operation never asserts result_valid
//
// Numeric correctness is checked separately by the host-FPU differential
// testbench in verification/xsim/fpu/divsqrt (300k vectors,
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
      .clock(clock),
      .reset(reset),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .src_is_double(src_is_double),
      .dst_is_double(src_is_double),
      .divide(divide),
      .sqrt(sqrt),
      .flush(flush),
      .valid(valid),
      .ready(dut_ready),
      .result(dut_result),
      .flags(dut_flags),
      .result_valid(dut_valid)
  );

  // Legal launch contract (mirrors the EXU issue stage).
  always_comb begin
    asm_rm : assume (rounding_mode <= 3'd4);
    asm_rdy : assume (!(valid && !dut_ready));  // never launch while busy
    asm_mutex : assume (!(valid && divide && sqrt));  // mutually exclusive
    asm_op : assume (!(valid && !divide && !sqrt));  // exactly one op
  end

  // Initialisation: force a reset on the very first frame so the proof starts
  // from a known state (registers are otherwise arbitrary at time 0, which
  // would produce spurious counterexamples / unsat cores on the assumptions).
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clock) f_past_valid <= 1'b1;
  always_comb begin
    asm_init : assume (f_past_valid || reset);
  end

  wire launch = valid && dut_ready && (divide || sqrt);

  // ------------------------------------------------------------------------
  // Special-case detection (combinational, mirrors the DUT decode) so the
  // "completes in one cycle" property can be stated precisely.
  // ------------------------------------------------------------------------
  logic [10:0] exp_a, exp_b;
  logic [51:0] frac_a, frac_b;
  logic sign_a, a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
  logic a_boxed, b_boxed, exp_a_all_ones, exp_b_all_ones;
  assign exp_a  = src_is_double ? operand_a[62:52] : {3'b0, operand_a[30:23]};
  assign exp_b  = src_is_double ? operand_b[62:52] : {3'b0, operand_b[30:23]};
  assign frac_a = src_is_double ? operand_a[51:0]  : {29'b0, operand_a[22:0]};
  assign frac_b = src_is_double ? operand_b[51:0]  : {29'b0, operand_b[22:0]};
  assign sign_a = src_is_double ? operand_a[63]    : operand_a[31];
  assign a_boxed = src_is_double || operand_a[63:32] == '1;
  assign b_boxed = src_is_double || operand_b[63:32] == '1;
  assign exp_a_all_ones = src_is_double ? &exp_a : &exp_a[7:0];
  assign exp_b_all_ones = src_is_double ? &exp_b : &exp_b[7:0];
  assign a_nan  = !a_boxed || (exp_a_all_ones && frac_a != '0);
  assign b_nan  = !b_boxed || (exp_b_all_ones && frac_b != '0);
  assign a_inf  = a_boxed && exp_a_all_ones && frac_a == '0;
  assign b_inf  = b_boxed && exp_b_all_ones && frac_b == '0;
  assign a_zero = a_boxed && exp_a == '0 && frac_a == '0;
  assign b_zero = b_boxed && exp_b == '0 && frac_b == '0;

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
        cycles_q <= cycles_q + 7'd1;
      end
    end
  end

  // ------------------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------------------
`ifdef FORMAL
  // Payload is owned only while dut_valid is asserted. Idle preloading may
  // change result/flags at any other time, including immediately after a result.
  logic launched_double_q, launched_divide_q;
  logic [6:0] expected_iterations;
  assign expected_iterations = launched_double_q ? (launched_divide_q ? 7'd55 : 7'd56)
      : (launched_divide_q ? 7'd26 : 7'd27);
  always_ff @(posedge clock) begin
    if (reset) begin
      launched_double_q <= 1'b0;
      launched_divide_q <= 1'b0;
    end else if (launch && !flush) begin
      launched_double_q <= src_is_double;
      launched_divide_q <= divide;
    end
  end

  always_ff @(posedge clock) begin
    if (!reset) begin
      // Prove the relation between the independent age monitor and the DUT
      // countdown. These are assertions, not assumptions about internal progress.
      if (!dut_ready) begin
        busy_owner : assert (in_flight_q && any_op_q && !dut_valid);
      end
      if (in_flight_q && !dut_valid) begin
        iter_busy : assert (!dut_ready);
        iter_age : assert (cycles_q < expected_iterations);
        iter_count : assert ({1'b0, cycles_q} + {1'b0, dut.cnt_q} == {1'b0, expected_iterations});
      end
      if (in_flight_q && dut_valid) begin
        iter_done : assert (cycles_q == expected_iterations);
      end
      // ---- Liveness: an iterative op completes within 63 cycles ----
      live : assert (!(in_flight_q && cycles_q == 7'd62) || dut_valid || flush);

      // ---- No spurious result_valid without a launched operation ----
      nospur : assert (!dut_valid || any_op_q);
    end
  end

  // ---- Special cases complete in exactly one cycle ----
  // (launch with a special operand => result_valid is already high next cycle,
  //  i.e. the unit never enters the iterative state for them).
  logic launch_special_q;
  always_ff @(posedge clock) begin
    if (reset || flush) launch_special_q <= 1'b0;
    else launch_special_q <= (launch && is_special);
  end
  always_ff @(posedge clock) begin
    if (!reset && launch_special_q && !flush) begin
      spec1 : assert (dut_valid);
    end
  end

  // ---- Flush: a flushed operation never asserts result_valid afterwards ----
  logic flush_d;
  always_ff @(posedge clock) begin
    if (reset) flush_d <= 1'b0;
    else flush_d <= flush;
  end
  always_ff @(posedge clock) begin
    if (!reset && flush_d && !flush) begin
      flclean : assert (!dut_valid);
    end
  end

  // ---- Coverage witnesses ----
  always_ff @(posedge clock) begin
    if (!reset) begin
      cov_div_dp : cover (dut_valid && launched_divide_q && launched_double_q);
      cov_div_sp : cover (dut_valid && launched_divide_q && !launched_double_q);
      cov_sqrt_dp : cover (dut_valid && !launched_divide_q && launched_double_q);
      cov_sqrt_sp : cover (dut_valid && !launched_divide_q && !launched_double_q);
      cov_special : cover (dut_valid && launch_special_q);
      cov_iter_div_dp : cover (dut_valid && in_flight_q && launched_divide_q && launched_double_q);
      cov_iter_div_sp : cover (dut_valid && in_flight_q && launched_divide_q && !launched_double_q);
      cov_iter_sqrt_dp :
      cover (dut_valid && in_flight_q && !launched_divide_q && launched_double_q);
      cov_iter_sqrt_sp :
      cover (dut_valid && in_flight_q && !launched_divide_q && !launched_double_q);
      cov_flush_busy : cover (flush && in_flight_q);
    end
  end
`endif

endmodule
