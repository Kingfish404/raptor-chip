`include "rapt.svh"

// One-operation-at-a-time IEEE-754 divider/square-root unit, multi-cycle
// iterative implementation. One quotient/root bit is retired per clock using
// a restoring shift-and-subtract recurrence (long division for divide, the
// classic digit-by-digit method for square root), so a double-precision
// operation completes in ~56 cycles. The per-cycle critical path is a single
// 64-bit add plus compare -- short enough to close 50 MHz timing with very
// wide margin (this module was the -458 ns WNS critical path when it was a
// combinational unrolled algorithm; it is now fully sequential).
//
// The datapath produces a p+3-bit quotient/root (guard/round/sticky), so the
// final packer implements all architectural RISC-V rounding modes. Special
// cases (NaN / Inf / zero / divide-by-zero / sqrt of negative) are decoded
// combinationally at launch and complete in a single cycle.
//
// Timing contract: valid && ready launches an operation. result_valid rises
// for exactly one clock when the result is ready, with result / flags valid
// in the same cycle. flush aborts any in-flight operation.

module rapt_fpu_divsqrt #(
    parameter int XLEN = `RAPT_XLEN
) (
    input  logic        clock,
    input  logic        reset,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [2:0]  rounding_mode,
    input  logic        src_is_double,
    input  logic        dst_is_double,
    input  logic        divide,
    input  logic        sqrt,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);

  localparam int CNT_W = 7;

  typedef enum logic [0:0] {ST_IDLE = 1'b0, ST_RUN = 1'b1} state_e;

  state_e           state_q;
  logic [CNT_W-1:0] cnt_q;          // iterations remaining
  logic             do_divide_q;    // 1 = divide, 0 = sqrt
  logic             is_double_q;
  logic [2:0]       rm_q;
  logic             sign_q;         // result sign
  logic signed [13:0] exp_q;        // result exponent (unbiased)

  // Iterative datapath.
  //   divide: rem_q = partial remainder, quo_q = quotient (MSB-first),
  //           d_q = divisor.
  //   sqrt:   rem_q = residual operand (wide), quo_q = root being built,
  //           d_q = "one" trial bit (highest power of four, walks right by
  //           two each cycle).
  logic [191:0]     rem_q;
  logic [55:0]      quo_q;
  logic [191:0]     d_q;
  logic [55:0]      sroot_q;        // sqrt partial root (MSB-first)

  logic [63:0]      result_q;
  logic [4:0]       flags_q;
  logic             done_q;

  // ------------------------------------------------------------------------
  // Input decode / special cases (combinational at launch)
  // ------------------------------------------------------------------------
  logic [10:0] exp_a, exp_b;
  logic [51:0] frac_a, frac_b;
  logic sign_a, sign_b;
    logic a_boxed, b_boxed;
  logic a_nan, b_nan, a_snan, b_snan, a_inf, b_inf, a_zero, b_zero;

    assign a_boxed = src_is_double || operand_a[63:32] == '1;
    assign b_boxed = src_is_double || operand_b[63:32] == '1;
  assign sign_a = src_is_double ? operand_a[63]    : operand_a[31];
  assign sign_b = src_is_double ? operand_b[63]    : operand_b[31];
    assign exp_a  = src_is_double ? operand_a[62:52]
      : a_boxed ? {3'b0, operand_a[30:23]} : 11'h0ff;
    assign exp_b  = src_is_double ? operand_b[62:52]
      : b_boxed ? {3'b0, operand_b[30:23]} : 11'h0ff;
    assign frac_a = src_is_double ? operand_a[51:0]
      : a_boxed ? {29'b0, operand_a[22:0]} : {29'b0, 23'h40_0000};
    assign frac_b = src_is_double ? operand_b[51:0]
      : b_boxed ? {29'b0, operand_b[22:0]} : {29'b0, 23'h40_0000};

  localparam logic [10:0] EXP_ALL1_DP = 11'h7ff;
  localparam logic [10:0] EXP_ALL1_SP = 11'h0ff;

  assign a_nan  = (exp_a == (src_is_double ? EXP_ALL1_DP : EXP_ALL1_SP)) && (frac_a != '0);
  assign b_nan  = (exp_b == (src_is_double ? EXP_ALL1_DP : EXP_ALL1_SP)) && (frac_b != '0);
  assign a_snan = a_nan && !(src_is_double ? frac_a[51] : frac_a[22]);
  assign b_snan = b_nan && !(src_is_double ? frac_b[51] : frac_b[22]);
  assign a_inf  = (exp_a == (src_is_double ? EXP_ALL1_DP : EXP_ALL1_SP)) && (frac_a == '0);
  assign b_inf  = (exp_b == (src_is_double ? EXP_ALL1_DP : EXP_ALL1_SP)) && (frac_b == '0);
  assign a_zero = (exp_a == '0) && (frac_a == '0);
  assign b_zero = (exp_b == '0) && (frac_b == '0);

  logic        special;
  logic [63:0] special_result;
  logic [4:0]  special_flags;

  always_comb begin
    logic        sign_r;
    logic [63:0] inf_a, qnan_a;
    logic        inv, dz;

    sign_r = divide ? (sign_a ^ sign_b) : sign_a;
    qnan_a = src_is_double ? 64'h7ff8_0000_0000_0000 : 64'hffff_ffff_7fc0_0000;
    inf_a  = src_is_double ? {sign_r, 11'h7ff, 52'b0}
                           : {32'hffff_ffff, sign_r, 8'hff, 23'b0};
    inv = 1'b0;
    dz  = 1'b0;
    special_result = qnan_a;

    if (a_nan || (divide && b_nan)) begin
      inv = a_snan || (divide && b_snan);       // quiet NaN: flag only if sNaN
    end else if (!divide && sign_a && !a_zero) begin
      inv = 1'b1;                               // sqrt(negative)
    end else if (divide && ((a_zero && b_zero) || (a_inf && b_inf))) begin
      inv = 1'b1;                               // 0/0, inf/inf
    end else if (divide && b_zero && a_inf) begin
      special_result = inf_a;                   // inf/0 = inf, NO DZ flag
    end else if (divide && b_zero) begin
      dz = 1'b1;                                // finite-nonzero / 0 = inf, DZ
      special_result = inf_a;
    end else if (divide && b_inf) begin
      special_result = src_is_double ? {sign_r, 63'b0}
                                     : {32'hffff_ffff, sign_r, 31'b0};
    end else if (a_inf) begin
      special_result = inf_a;                   // inf/x = inf ; sqrt(inf)=inf
    end else begin                              // a_zero (b finite nonzero)
      special_result = src_is_double ? {sign_r, 63'b0}
                                     : {32'hffff_ffff, sign_r, 31'b0};
    end

    special = a_nan || (divide && b_nan) || (!divide && sign_a && !a_zero)
        || (divide && (b_zero || b_inf || ((a_zero && b_zero) || (a_inf && b_inf))))
        || a_inf || a_zero;
    special_flags = {inv, dz, 3'b000};
  end

  // ------------------------------------------------------------------------
  // Launch-time operand preparation
  // ------------------------------------------------------------------------
  // Normalise a mantissa to have its leading 1 at bit 52 (1.f at bit 52).
  function automatic logic [52:0] norm_mant(input logic [51:0] frac,
                                            input logic [10:0] exp,
                                            input logic        dbl,
                                            output int adj);
    logic [52:0] m;
    int          i;
    begin
      // Unified 1.f format with the leading 1 at bit 52 for both precisions.
      // Single precision left-aligns its 23-bit fraction just below bit 52.
      if (dbl) m = {1'b1, frac};
      else     m = {1'b1, frac[22:0], 29'b0};
      adj = 0;
      if (exp == '0) begin
        // subnormal: strip the implicit hidden bit, then normalise upward
        if (dbl) m = {1'b0, frac};
        else     m = {1'b0, frac[22:0], 29'b0};
        for (i = 0; i < 52; i = i + 1) begin
          if (!m[52]) begin
            m   = m << 1;
            adj = adj - 1;
          end
        end
      end
      return m;
    end
  endfunction

  logic [52:0] ma_n, mb_n;
  int          adj_a, adj_b;
  logic signed [13:0] exp_launch;
  logic [191:0] d_launch;
  logic [191:0] rem_launch;
  logic [CNT_W-1:0] cnt_launch;

  // Unbiased exponent of an input field (subnormal handled via adj).
  function automatic int unbias(input logic [10:0] e, input logic dbl, input int adj);
    int e_val;
    begin
      if (e == '0) e_val = dbl ? -1022 : -126;
      else         e_val = int'(e) - (dbl ? 1023 : 127);
      return e_val + adj;
    end
  endfunction

  // sqrt launch-time helpers, declared at block scope with defaults so no
  // latches are inferred on the divide path.
  logic        exp_parity;
  logic [53:0] ma_sqrt;

  always_comb begin
    ma_n = norm_mant(frac_a, exp_a, src_is_double, adj_a);
    mb_n = norm_mant(frac_b, exp_b, src_is_double, adj_b);
    exp_launch = 14'(unbias(exp_a, src_is_double, adj_a));
    d_launch   = '0;
    rem_launch = '0;
    exp_parity = 1'b0;
    ma_sqrt    = '0;
    cnt_launch = '0;
    if (divide) begin
      exp_launch = exp_launch - 14'(unbias(exp_b, src_is_double, adj_b));
      if (ma_n < mb_n) begin
        ma_n = ma_n << 1;
        exp_launch = exp_launch - 14'sd1;
      end
      // Restoring long division, one bit/cycle. The recurrence requires
      // R < D at every step (R doubles each cycle then conditionally
      // subtracts D). Since ma >= d is guaranteed by pre-normalisation, the
      // integer quotient bit is 1; we fold it in at launch by setting
      // R_0 = ma - d (which lies in [0,d)) and pre-loading quotient = 1.
      // Each of the following N cycles retires one fraction bit, leaving the
      // quotient's leading 1 at bit N. We need p+3 total bits: double p=53
      // -> 56 bits -> 55 fraction iterations; single p=24 -> 27 bits -> 26.
      d_launch   = 192'({11'b0, mb_n});
      rem_launch = 192'({11'b0, ma_n - mb_n});   // ma - d, in [0, d)
      cnt_launch = CNT_W'(src_is_double ? 55 : 26);
    end else begin
      // sqrt: exponent must be even. When odd, the radicand is ma*2 in [2,4).
      // That shift needs a 54-bit container (the implicit 1 moves to bit 53),
      // so do NOT clobber the 53-bit ma_n; build a separate 54-bit radicand.
      // Capture the parity BEFORE halving the exponent.
      begin
        exp_parity = exp_launch[0];
        exp_launch = exp_launch >>> 1;
        // Restoring square root, one root bit per cycle. The radicand is held
        // in the wide supply register and consumed two bits per cycle from the
        // top, while the residual stays bounded (pencil-and-paper method):
        //   rem' = (rem << 2) | top-2-bits-of-radicand
        //   trial = (root << 2) | 1
        //   if trial <= rem: rem -= trial; root = (root<<1)|1 else root <<= 1
        // The radicand uses a FIXED binary point (value = raw/2^110 for dp):
        // 1.0 sits one bit below 2.0, so their top two-bit groups differ and
        // the recurrence distinguishes them. ma_sqrt is the mantissa scaled
        // into [1,4): even exponent -> leading 1 at bit 52, odd -> bit 53.
        // Shifting left by 138 places bit 52/53 onto supply bits 190/191 so
        // the top-aligned feed consumes the value with its point preserved.
        ma_sqrt  = exp_parity ? {ma_n, 1'b0} : {1'b0, ma_n};
        d_launch   = 192'(ma_sqrt) << 138;      // fixed-point radicand supply
        rem_launch = '0;                        // residual starts at 0
      end
      cnt_launch = CNT_W'(src_is_double ? 56 : 27);
    end
  end

  // ------------------------------------------------------------------------
  // One restoring divide step (1 quotient bit per cycle)
  // ------------------------------------------------------------------------
  logic [191:0] div_rem_n;
  logic [55:0]  div_quo_n;

  always_comb begin
    logic [63:0] rem2;
    rem2 = {rem_q[62:0], 1'b0};                 // 2 * R
    if (rem2 >= d_q[63:0]) begin
      div_rem_n = 192'({64'b0, rem2 - d_q[63:0]});
      div_quo_n = {quo_q[54:0], 1'b1};
    end else begin
      div_rem_n = 192'({64'b0, rem2});
      div_quo_n = {quo_q[54:0], 1'b0};
    end
  end

  // rem_q holds the bounded residual in its low bits; d_q holds the
  // not-yet-consumed radicand, shifted left by two each cycle so its top two
  // bits feed the residual. root accumulates MSB-first in sroot_q.
  logic [191:0] sqrt_rem_n;
  logic [191:0] sqrt_rad_n;
  logic [55:0]  sqrt_root_n;

  always_comb begin
    logic [59:0] rem2;
    logic [59:0] trial;
    // pull the next two radicand bits (top of d_q) into the residual:
    rem2  = {rem_q[57:0], d_q[191:190]};     // (rem << 2) | next-2-bits
    trial = {2'b0, sroot_q, 2'b01};          // (root << 2) | 1, widened to 60b
    if (rem2 >= trial) begin
      sqrt_rem_n  = {132'b0, rem2 - trial};
      sqrt_root_n = {sroot_q[54:0], 1'b1};
    end else begin
      sqrt_rem_n  = {132'b0, rem2};
      sqrt_root_n = {sroot_q[54:0], 1'b0};
    end
    sqrt_rad_n = {d_q[189:0], 2'b00};        // consume two radicand bits
  end

  // ------------------------------------------------------------------------
  // Final rounding / packing (combinational at completion)
  // ------------------------------------------------------------------------
  logic [63:0] final_result;
  logic [4:0]  final_flags;
  logic signed [13:0] final_emin;

  always_comb begin
    logic signed [13:0] e;
    logic [55:0]        q;
    logic               rem_nz;
    logic [57:0]        sig_ext;
    logic               g, r, s, inexact, round_up;
    logic [57:0]        sig_round;
    logic signed [13:0] e_round;
    logic               sub_norm, overflow, uf;
    int                 sh;
    logic [57:0]        sticky_mask;
    logic               sign_r;
    logic [63:0]        inf_a, max_a, qnan_a;
    logic [10:0]        pe;
    int                 int_bit;

    sign_r = sign_q;
    qnan_a = is_double_q ? 64'h7ff8_0000_0000_0000 : 64'hffff_ffff_7fc0_0000;
    inf_a  = is_double_q ? {sign_r, 11'h7ff, 52'b0}
                         : {32'hffff_ffff, sign_r, 8'hff, 23'b0};
    max_a  = is_double_q ? {sign_r, 11'h7fe, 52'hf_ffff_ffff_ffff}
                         : {32'hffff_ffff, sign_r, 8'hfe, 23'h7f_ffff};

    // Default assignments for every local variable so no latches are inferred
    // regardless of which branch executes (some are only used on one path).
    q          = '0;
    rem_nz     = 1'b0;
    e          = '0;
    sig_ext    = '0;
    g          = 1'b0;
    r          = 1'b0;
    s          = 1'b0;
    inexact    = 1'b0;
    round_up   = 1'b0;
    sig_round  = '0;
    e_round    = '0;
    sub_norm   = 1'b0;
    overflow   = 1'b0;
    uf         = 1'b0;
    sh         = 0;
    sticky_mask = '0;
    pe         = '0;
    int_bit    = 0;
    final_result = qnan_a;
    final_flags  = '0;

    q      = do_divide_q ? quo_q : sroot_q;
    rem_nz = (rem_q != '0);
    e      = exp_q;

    // The quotient/root leading 1 sits at bit int_bit. Divide pre-loads the
    // integer 1 then retires cnt fraction bits; the final iteration and the
    // done strobe happen on the same clock edge, so the quotient register
    // sampled by the packer has its leading 1 at bit (cnt-1) = dp 54, sp 25.
    // Sqrt builds its root MSB-first with the leading 1 at the same bit.
    // Normalise the leading 1 to bit 55 of sig_ext so g/r/s land at 2/1/0.
    int_bit = do_divide_q ? (is_double_q ? 54 : 25)
                          : (is_double_q ? 54 : 25);
    if (int_bit >= 55) sig_ext = {2'b0, q} >> (int_bit - 55);
    else               sig_ext = {2'b0, q} << (55 - int_bit);
    sig_ext[0] = sig_ext[0] | rem_nz;

    // subnormal: shift right until exponent reaches emin
    sub_norm = 1'b0;
    final_emin = is_double_q ? -14'sd1022 : -14'sd126;
    if (e < final_emin) begin
        sh = final_emin - e;
        if (sh > 57) sh = 58;
        sticky_mask = (58'd1 << sh) - 58'd1;
        if ((sig_ext & sticky_mask) != '0) begin
          sig_ext = (sig_ext >> sh);
          sig_ext[0] = 1'b1;
        end else begin
          sig_ext = sig_ext >> sh;
        end
        e        = final_emin;
        sub_norm = 1'b1;
    end

    // rounding at target precision
    if (is_double_q) begin
      g = sig_ext[2]; r = sig_ext[1]; s = sig_ext[0];
      inexact = g | r | s;
      unique case (rm_q)
        3'b000:  round_up = g && (r || s || sig_ext[3]);
        3'b001:  round_up = 1'b0;
        3'b010:  round_up = inexact && sign_r;
        3'b011:  round_up = inexact && !sign_r;
        3'b100:  round_up = g;
        default: round_up = 1'b0;
      endcase
      sig_round = {5'b0, sig_ext[55:3]} + 58'(round_up);
    end else begin
      g = sig_ext[31]; r = sig_ext[30]; s = |sig_ext[29:0];
      inexact = g | r | s;
      unique case (rm_q)
        3'b000:  round_up = g && (r || s || sig_ext[32]);
        3'b001:  round_up = 1'b0;
        3'b010:  round_up = inexact && sign_r;
        3'b011:  round_up = inexact && !sign_r;
        3'b100:  round_up = g;
        default: round_up = 1'b0;
      endcase
      sig_round = {26'b0, sig_ext[55:32]} + 58'(round_up);
    end
    e_round = e;
    if (is_double_q) begin
      if (sig_round[53]) begin
        sig_round = sig_round >> 1;
        e_round   = e_round + 14'sd1;
        sub_norm  = 1'b0;
      end
    end else begin
      if (sig_round[24]) begin
        sig_round = sig_round >> 1;
        e_round   = e_round + 14'sd1;
        sub_norm  = 1'b0;
      end
    end

    // pack
    overflow = e_round > 14'(is_double_q ? 1023 : 127);
    if (overflow) begin
      if (rm_q == 3'b001 || (rm_q == 3'b010 && !sign_r)
          || (rm_q == 3'b011 && sign_r)) begin
        final_result = max_a;
      end else begin
        final_result = inf_a;
      end
      final_flags = {2'b00, 1'b1, 1'b0, 1'b1};           // OF | NX
    end else begin
      pe = 11'(e_round + (is_double_q ? 1023 : 127));
      uf = 1'b0;
      if (is_double_q) begin
        if (sub_norm && !sig_round[52]) pe = '0;
        uf = (pe == '0) && inexact;
        final_result = {sign_r, pe, sig_round[51:0]};
      end else begin
        if (sub_norm && !sig_round[23]) pe = '0;
        uf = (pe == '0) && inexact;
        final_result = {32'hffff_ffff, sign_r, pe[7:0], sig_round[22:0]};
      end
      final_flags = {3'b000, uf, inexact};
    end
  end

  // ------------------------------------------------------------------------
  // Sequential control
  // ------------------------------------------------------------------------
  assign ready        = (state_q == ST_IDLE);
  assign result       = result_q;
  assign flags        = flags_q;
  assign result_valid = done_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      state_q <= ST_IDLE;
      done_q  <= 1'b0;
    end else begin
      done_q <= 1'b0;
      unique case (state_q)
        ST_IDLE: begin
          if (valid && (divide || sqrt)) begin
            sign_q      <= divide ? (sign_a ^ sign_b) : sign_a;
            rm_q        <= rounding_mode;
            is_double_q <= src_is_double;
            do_divide_q <= divide;
            if (special) begin
              result_q <= special_result;
              flags_q  <= special_flags;
              done_q   <= 1'b1;
            end else begin
              exp_q <= exp_launch;
              cnt_q <= cnt_launch;
              d_q   <= d_launch;
              rem_q <= rem_launch;
              quo_q <= (divide && !sqrt) ? 56'd1 : 56'd0;  // divide integer bit
              sroot_q <= '0;
              state_q <= ST_RUN;
            end
          end
        end
        ST_RUN: begin
          if (do_divide_q) begin
            rem_q <= div_rem_n;
            quo_q <= div_quo_n;
          end else begin
            rem_q   <= sqrt_rem_n;
            d_q     <= sqrt_rad_n;
            sroot_q <= sqrt_root_n;
          end
          if (cnt_q == CNT_W'(1)) begin
            state_q  <= ST_IDLE;
            result_q <= final_result;
            flags_q  <= final_flags;
            done_q   <= 1'b1;
          end else begin
            cnt_q <= cnt_q - CNT_W'(1);
          end
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

endmodule
