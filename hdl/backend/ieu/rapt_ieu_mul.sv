`include "rapt.svh"

module rapt_ieu_mul #(
    parameter int XLEN = `RAPT_XLEN,
    parameter unsigned TAG_W = 1,
    parameter bit UseDsp = `RAPT_FPGA_DSP
) (
    input clock,
    input reset,
    input flush,
    // A tag may be reused on the next edge: cancellation clears all valid
    // owners here and suppresses a same-cycle output for that tag.
    input logic [(1 << TAG_W)-1:0] cancel_tags,
    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_word,  // RV64 W-variant: operate on lower 32 bits, sign-extend result
    input [TAG_W-1:0] in_tag,
    input in_valid,
    output logic in_ready,
    output logic [XLEN-1:0] out_r,
    output logic [TAG_W-1:0] out_tag,
    output logic out_valid
);

`ifdef RAPT_M_FAST
  // Hybrid fast MUL + iterative DIV/REM:
  //   MUL/MULH/MULHSU/MULHU: fully pipelined (2-cycle latency, 1/cycle throughput)
  //   DIV/DIVU/REM/REMU: iterative restoring divider. One normalization cycle
  //   skips the dividend's leading zero bits (their quotient bits are zero),
  //   then two restoring steps retire per cycle: about
  //   2 + ceil(significant dividend bits / 2) cycles, serial.
  //
  // MUL and DIV datapaths are split: MUL has its own 2-stage pipe (m1_*, m2_*)
  // with tag pass-through; DIV runs serial in (div_*) state and blocks new
  // accepts via `in_ready`. Output mux gives DIV priority (rare emission) to
  // avoid collisions -- MUL stage-B emission cannot coincide with DIV done
  // because `in_ready=0` during div_active drains the MUL pipeline first.

  // ---------------- DIV path (serial) ----------------
  logic [XLEN-1:0] div_s1, div_s2;
  logic [               4:0] div_op;
  logic                      div_word;
  logic [         TAG_W-1:0] div_tag;

  logic [          XLEN-1:0] div_quotient;
  logic [            XLEN:0] div_remainder;
  logic [          XLEN-1:0] div_divisor;
  logic [          XLEN-1:0] div_dividend_shifted;
  logic [$clog2(XLEN+1)-1:0] div_counter;
  logic [               1:0] div_sign;
  logic                      div_active;
  logic                      div_norm;

  // Leading zeros of the aligned dividend magnitude (XLEN for zero).
  function automatic logic [$clog2(XLEN+1)-1:0] div_clz(input logic [XLEN-1:0] value);
    div_clz = $clog2(XLEN + 1)'(XLEN);
    for (int i = 0; i < XLEN; i++) if (value[i]) div_clz = $clog2(XLEN + 1)'(XLEN - 1 - i);
  endfunction
  logic [$clog2(XLEN+1)-1:0] div_lz;
  logic [$clog2(XLEN+1):0] div_start;
  logic [XLEN-1:0] div_normalized;
  assign div_lz = div_clz(div_dividend_shifted);
  assign div_start = {1'b0, div_counter} + {1'b0, div_lz};
  assign div_normalized = div_dividend_shifted << div_lz;

  // Two cascaded restoring steps. The second is skipped on an odd final bit.
  logic div_q1, div_q2, div_two;
  logic [XLEN:0] div_r1, div_r2;
  assign div_two = int'(div_counter) + 1 < XLEN;
  assign div_q1 = div_remainder >= {1'b0, div_divisor};
  assign div_r1 = ((div_q1 ? div_remainder - {1'b0, div_divisor} : div_remainder) << 1)
      + {{XLEN{1'b0}}, div_dividend_shifted[XLEN-1]};
  assign div_q2 = div_r1 >= {1'b0, div_divisor};
  assign div_r2 = ((div_q2 ? div_r1 - {1'b0, div_divisor} : div_r1) << 1)
      + {{XLEN{1'b0}}, div_dividend_shifted[XLEN-2]};

  logic [XLEN-1:0] div_q_signed, div_r_signed;
  assign div_q_signed = (div_sign == 2'b00 || div_sign == 2'b11) ? div_quotient : -div_quotient;
  assign div_r_signed = (div_sign[1] == 1'b0) ? div_remainder[XLEN:1] : -div_remainder[XLEN:1];

  logic signed_div;
  assign signed_div = (in_op == `RAPT_ALU_DIV___ || in_op == `RAPT_ALU_REM___);
  logic [XLEN-1:0] div_input_a, div_input_b;
  always_comb begin
    div_input_a = in_a;
    div_input_b = in_b;
    if (in_word && XLEN > 32) begin
      if (signed_div) begin
        div_input_a = {{XLEN - 32{in_a[31]}}, in_a[31:0]};
        div_input_b = {{XLEN - 32{in_b[31]}}, in_b[31:0]};
      end else begin
        div_input_a = {{XLEN - 32{1'b0}}, in_a[31:0]};
        div_input_b = {{XLEN - 32{1'b0}}, in_b[31:0]};
      end
    end
  end
  logic [XLEN-1:0] abs_a, abs_b;
  assign abs_a = (signed_div && div_input_a[XLEN-1]) ? -div_input_a : div_input_a;
  assign abs_b = (signed_div && div_input_b[XLEN-1]) ? -div_input_b : div_input_b;
  // W operands have only 32 magnitude bits. Align them with the existing
  // serial input and skip the known-zero upper iterations; quotient bit
  // numbering and the restoring datapath remain unchanged.
  logic [XLEN-1:0] div_aligned_a;
  assign div_aligned_a = (XLEN > 32 && in_word) ? abs_a << (XLEN - 32) : abs_a;

  logic in_is_div;
  assign in_is_div = (in_op == `RAPT_ALU_DIV___ || in_op ==
      `RAPT_ALU_DIVU__
      || in_op == `RAPT_ALU_REM___ || in_op == `RAPT_ALU_REMU__);

  // DIV result register (held one cycle for output emission)
  logic [ XLEN-1:0] div_out_r;
  logic [TAG_W-1:0] div_out_tag;
  logic             div_out_valid;

  // ---------------- MUL path (pipelined) ----------------
  // Stage 1: operand latch
  logic [XLEN-1:0] m1_s1, m1_s2;
  logic [       4:0] m1_op;
  logic              m1_word;
  logic [ TAG_W-1:0] m1_tag;
  logic              m1_v;

  // Stage 2: registered combinational result
  logic [  XLEN-1:0] m2_r;
  logic [ TAG_W-1:0] m2_tag;
  logic              m2_v;

  // Single shared (XLEN+1)x(XLEN+1) signed multiplier. Operand sign-extension
  // bit is op-dependent so MUL/MULH/MULHSU/MULHU all reuse the same datapath:
  //   * MUL  : low XLEN bits -- sign-extension irrelevant
  //   * MULH : signed   x signed   -- both extended with sign bit
  //   * MULHSU: signed  x unsigned -- only s1 extended
  //   * MULHU: unsigned x unsigned -- neither extended
  // Replaces three independent 2*XLEN-wide multipliers (only one was ever
  // used per cycle) with one 2*(XLEN+1)-wide signed multiplier.
  logic              m1_sext_a;
  logic              m1_sext_b;
  always_comb begin
    unique case (m1_op)
      `RAPT_ALU_MULH__: begin
        m1_sext_a = 1'b1;
        m1_sext_b = 1'b1;
      end
      `RAPT_ALU_MULHSU: begin
        m1_sext_a = 1'b1;
        m1_sext_b = 1'b0;
      end
      `RAPT_ALU_MULHU_: begin
        m1_sext_a = 1'b0;
        m1_sext_b = 1'b0;
      end
      // MUL (and any default) -- low product is sign-agnostic.
      default: begin
        m1_sext_a = 1'b0;
        m1_sext_b = 1'b0;
      end
    endcase
  end

  logic signed [XLEN:0]     mul_ext_a;
  logic signed [XLEN:0]     mul_ext_b;
  // Select FPGA mapping independently of the arithmetic and valid/tag stages.
  // Both implementations retain the same two-edge acceptance-to-result path.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [2*XLEN+1:0] mul_full;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mul_ext_a = $signed({m1_sext_a & m1_s1[XLEN-1], m1_s1});
  assign mul_ext_b = $signed({m1_sext_b & m1_s2[XLEN-1], m1_s2});
  if (UseDsp) begin : g_dsp
    (* use_dsp = "yes" *) wire signed [2*XLEN+1:0] product;
    assign product = mul_ext_a * mul_ext_b;
    assign mul_full = product;
  end else begin : g_fabric
    (* use_dsp = "no" *) wire signed [2*XLEN+1:0] product;
    assign product = mul_ext_a * mul_ext_b;
    assign mul_full = product;
  end

  logic [XLEN-1:0] mul_r_comb;
  always_comb begin
    unique case (m1_op)
      // verilog_format: off
      `RAPT_ALU_MUL___: begin
          if (m1_word && XLEN > 32) begin
            // RV64 MULW: 32-bit low product, sign-extended to XLEN.
            mul_r_comb = {{XLEN-32{mul_full[31]}}, mul_full[31:0]};
          end else begin
            mul_r_comb = mul_full[XLEN-1:0];
          end
        end
      `RAPT_ALU_MULH__,
      `RAPT_ALU_MULHSU,
      `RAPT_ALU_MULHU_: begin mul_r_comb = mul_full[2*XLEN-1:XLEN]; end
               default: begin mul_r_comb = '0; end
      // verilog_format: on
    endcase
  end

  // Accept logic: MUL stream accepts every cycle unless DIV is iterating.
  assign in_ready = !div_active;

  logic accept_mul, accept_div;
  assign accept_mul = in_valid && in_ready && !in_is_div && !cancel_tags[in_tag];
  assign accept_div = in_valid && in_ready && in_is_div && !cancel_tags[in_tag];

  // ---- Output mux (DIV has priority; see note above) ----
  always_comb begin
    if (div_out_valid && !cancel_tags[div_out_tag]) begin
      out_r     = div_out_r;
      out_tag   = div_out_tag;
      out_valid = 1'b1;
    end else if (m2_v && !cancel_tags[m2_tag]) begin
      out_r     = m2_r;
      out_tag   = m2_tag;
      out_valid = 1'b1;
    end else begin
      out_r     = '0;
      out_tag   = '0;
      out_valid = 1'b0;
    end
  end

  // ---- Sequential logic ----
  // Only control/valid state is reset.  Datapath registers (m1_s1/s2, m2_r,
  // div_* operands) are gated by their valid companions (m1_v/m2_v,
  // div_active, div_out_valid) and need no reset: an inactive lane's stale
  // data never reaches out_valid (same principle as rapt_prf).  This keeps
  // ~2*XLEN*6 reset endpoints off the reset/flush network.  div_counter is
  // reset because accept_div keys off div_active alone; the counter is only
  // read while div_active, but keeping it defined avoids a sim-only X check
  // on the first post-reset division.
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      m1_v          <= 1'b0;
      m2_v          <= 1'b0;
      div_active    <= 1'b0;
      div_norm      <= 1'b0;
      div_out_valid <= 1'b0;
      div_counter   <= '0;
    end else begin
      // ===== MUL stage-1 load =====
      if (accept_mul) begin
        m1_s1   <= in_a;
        m1_s2   <= in_b;
        m1_op   <= in_op;
        m1_word <= in_word;
        m1_tag  <= in_tag;
        m1_v    <= 1'b1;
      end else begin
        m1_v <= 1'b0;
      end

      // ===== MUL stage-1 -> stage-2 =====
      if (m1_v && !cancel_tags[m1_tag]) begin
        m2_r   <= mul_r_comb;
        m2_tag <= m1_tag;
        m2_v   <= 1'b1;
      end else begin
        m2_v <= 1'b0;
      end

      // ===== DIV start =====
      if (accept_div) begin
        div_op               <= in_op;
        div_s1               <= div_input_a;
        div_s2               <= div_input_b;
        div_word             <= in_word;
        div_tag              <= in_tag;

        div_quotient         <= 0;
        div_remainder        <= '0;
        div_divisor          <= abs_b;
        div_dividend_shifted <= div_aligned_a;
        div_counter          <= (XLEN > 32 && in_word) ? $clog2(XLEN+1)'(XLEN - 32) : '0;
        div_sign             <= {div_input_a[XLEN-1], div_input_b[XLEN-1]};
        div_active           <= 1'b1;
        div_norm             <= 1'b1;
        div_out_valid        <= 1'b0;
      end else if (div_active && cancel_tags[div_tag]) begin
        // Abort only this divider owner; older pipelined MULs remain live.
        div_active <= 1'b0;
        div_norm <= 1'b0;
        div_out_valid <= 1'b0;
      end else if (div_active && div_norm) begin
        // Leading dividend zeros keep a zero partial remainder and produce
        // zero quotient bits (a zero divisor's result is overridden below).
        // Start at the first significant bit, exactly where the bit-serial
        // loop would first leave a zero remainder.
        div_norm <= 1'b0;
        if (div_start >= ($clog2(XLEN + 1) + 1)'(XLEN)) begin
          div_counter <= $clog2(XLEN + 1)'(XLEN);
        end else begin
          div_counter          <= div_start[$clog2(XLEN+1)-1:0];
          div_remainder        <= {{XLEN{1'b0}}, div_normalized[XLEN-1]};
          div_dividend_shifted <= div_normalized << 1;
        end
      end else if (div_active) begin
        if (div_counter == XLEN[$clog2(XLEN+1)-1:0]) begin
          // Division complete: apply sign correction and emit
          div_active    <= 1'b0;
          div_out_valid <= 1'b1;
          div_out_tag   <= div_tag;
          unique case (div_op)
            `RAPT_ALU_DIV___: begin
              if (div_s2 == 0) div_out_r <= ~'h0;
              else if (!div_word && div_s1 == ('b1 << (XLEN - 1)) && div_s2 == ~'h0)
                div_out_r <= 'b1 << (XLEN - 1);
              else if (div_word && div_s1[31:0] == 32'h8000_0000 && div_s2[31:0] == 32'hffff_ffff)
                div_out_r <= {{XLEN - 32{1'b1}}, 32'h8000_0000};
              else if (div_word) div_out_r <= {{XLEN - 32{div_q_signed[31]}}, div_q_signed[31:0]};
              else div_out_r <= div_q_signed;
            end
            `RAPT_ALU_DIVU__: begin
              if (div_s2 == 0) div_out_r <= ~'h0;
              else if (div_word) div_out_r <= {{XLEN - 32{div_quotient[31]}}, div_quotient[31:0]};
              else div_out_r <= div_quotient;
            end
            `RAPT_ALU_REM___: begin
              if (div_s2 == 0) div_out_r <= div_s1;
              else if (div_word) div_out_r <= {{XLEN - 32{div_r_signed[31]}}, div_r_signed[31:0]};
              else div_out_r <= div_r_signed;
            end
            `RAPT_ALU_REMU__: begin
              // REMUW by zero returns the low 32-bit dividend and, like
              // every W-form result, sign-extends it to XLEN.
              if (div_s2 == 0 && div_word) div_out_r <= {{XLEN - 32{div_s1[31]}}, div_s1[31:0]};
              else if (div_s2 == 0) div_out_r <= div_s1;
              else if (div_word) div_out_r <= {{XLEN - 32{div_remainder[32]}}, div_remainder[32:1]};
              else div_out_r <= div_remainder[XLEN:1];
            end
            default: div_out_r <= 0;
          endcase
        end else begin
          // Two restoring iterations (one on the final odd bit).
          div_quotient <= div_quotient
              | (XLEN'(div_q1) << (XLEN[$clog2(XLEN+1)-1:0] - 1 - div_counter))
              | (XLEN'(div_two && div_q2) << (XLEN[$clog2(XLEN+1)-1:0] - 2 - div_counter));
          div_remainder <= div_two ? div_r2 : div_r1;
          div_dividend_shifted <= div_two ? div_dividend_shifted << 2 : div_dividend_shifted << 1;
          div_counter <= div_counter + (div_two ? 2 : 1);
        end
      end else begin
        // No DIV pending: clear any held DIV emission after one cycle.
        div_out_valid <= 1'b0;
      end
    end
  end

`else
  // Non-fast (fully iterative) fallback: serial MUL *and* DIV.
  // Pipelining not supported in this variant; in_ready deasserts while busy.

  logic [XLEN-1:0] s1, s2;
  logic [4:0] op;
  logic word_r;
  logic valid;
  logic [TAG_W-1:0] tag_r;

  assign out_valid = valid && !cancel_tags[tag_r];
  assign out_tag   = tag_r;
  assign in_ready  = (op == 0 && !valid);

  logic [XLEN-1:0] p, s, quotient;
  logic [$clog2(2*XLEN+2)-1:0] counter;
  logic [1:0] bb;

  logic [2*XLEN-1:0] ss1, ss2;
  logic [2*XLEN-1:0] pp, ss;
  logic signed_op;
  assign signed_op = in_op == `RAPT_ALU_REM___ || in_op == `RAPT_ALU_DIV___;
  logic [XLEN-1:0] s1_signed;
  assign s1_signed = ((signed_op) && in_a[XLEN-1]) ? -in_a : in_a;

  logic [XLEN-1:0] div_bit;
  logic [XLEN:0] reh;
  logic [1:0] sign;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      op      <= 0;
      valid   <= 0;
      counter <= 0;
    end else if ((op != 0 || valid) && cancel_tags[tag_r]) begin
      op <= 0;
      valid <= 0;
      counter <= 0;
    end else if (in_valid && in_ready && !cancel_tags[in_tag]) begin
      op <= in_op;
      word_r <= in_word;
      tag_r <= in_tag;
      s1 <= s1_signed;
      s2 <= (signed_op && in_b[XLEN-1]) ? -in_b : in_b;
      ss1 <= (in_op != `RAPT_ALU_MULHU_) ? {{XLEN{in_a[XLEN-1]}}, in_a} : {{XLEN{1'b0}}, in_a};
      ss2 <= (in_op != `RAPT_ALU_MULH__) ? {{XLEN{1'b0}}, in_b} : {{XLEN{in_b[XLEN-1]}}, in_b};
      s <= 0;
      ss <= 0;
      p <= 0;
      pp <= 0;

      div_bit <= 'b1 << (XLEN - 1);
      reh <= {{XLEN{1'b0}}, s1_signed[XLEN-1]};
      sign <= {in_a[XLEN-1], in_b[XLEN-1]};
      quotient <= 0;

      bb <= 0;
      counter <= 0;
      valid <= 0;
    end else begin
      unique case (op)
        `RAPT_ALU_MUL___: begin
          if (counter == XLEN + 1) begin
            out_r <= p;
            valid <= 1;
            op    <= 0;
          end else begin
            valid <= 0;
          end
        end
        `RAPT_ALU_MULH__, `RAPT_ALU_MULHSU, `RAPT_ALU_MULHU_: begin
          if (counter == 2 * XLEN + 1) begin
            out_r <= pp[2*XLEN-1:XLEN];
            valid <= 1;
            op    <= 0;
          end else begin
            valid <= 0;
          end
        end
        `RAPT_ALU_DIV___, `RAPT_ALU_DIVU__: begin
          if (s2 == 0 && counter == 0) begin
            out_r <= -1;
            valid <= 1;
            op    <= 0;
          end else if (op == `RAPT_ALU_DIV___ && counter == XLEN) begin
            out_r <= (sign == 'b00 || sign == 'b11) ? quotient : ~quotient + 1;
            op <= 0;
            valid <= 1;
          end else if (op == `RAPT_ALU_DIVU__ && counter == XLEN) begin
            out_r <= quotient;
            valid <= 1;
            op    <= 0;
          end else begin
            valid <= 0;
          end
        end
        `RAPT_ALU_REM___: begin
          if (counter == XLEN) begin
            out_r <= (sign == 'b00 || sign == 'b01) ? reh[XLEN:1] : ~reh[XLEN:1] + 1;
            valid <= 1;
            op    <= 0;
          end else begin
            valid <= 0;
          end
        end
        `RAPT_ALU_REMU__: begin
          if (counter == XLEN) begin
            out_r <= reh[XLEN:1];
            valid <= 1;
            op    <= 0;
          end else begin
            valid <= 0;
          end
        end
        default: begin
          valid <= 0;
        end
      endcase

      unique case (op)
        `RAPT_ALU_MUL___: begin
          s  <= {s1[0], s[XLEN-1:1]};
          s1 <= s1 >> 1;
          s2 <= s2 << 1;
          bb <= {s2[XLEN-1], s2[XLEN-2]};
          if (bb == 'b01) begin
            p <= p + s;
          end else if (bb == 'b10) begin
            p <= p - s;
          end
          counter <= counter + 1;
        end
        `RAPT_ALU_MULH__, `RAPT_ALU_MULHSU, `RAPT_ALU_MULHU_: begin
          ss  <= {ss1[0], ss[2*XLEN-1:1]};
          ss1 <= ss1 >> 1;
          ss2 <= ss2 << 1;
          bb  <= {ss2[2*XLEN-1], ss2[2*XLEN-2]};
          if (bb == 'b01) begin
            pp <= pp + ss;
          end else if (bb == 'b10) begin
            pp <= pp - ss;
          end
          counter <= counter + 1;
        end
        `RAPT_ALU_DIV___, `RAPT_ALU_DIVU__, `RAPT_ALU_REM___, `RAPT_ALU_REMU__: begin
          div_bit <= div_bit >> 1;
          quotient <= (reh >= {{1'b0}, s2}) ? quotient + div_bit : quotient;
          reh <= (reh >= {{1'b0}, s2}) ?
            ((reh - {{1'b0}, s2}) << 1) + {{XLEN{1'b0}}, s1[XLEN-2]} :
            ((reh) << 1) + {{XLEN{1'b0}}, s1[XLEN-2]};
          s1 <= s1 << 1;
          counter <= counter + 1;
        end
        default: begin
        end
      endcase
    end
  end
`endif

endmodule
