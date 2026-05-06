`include "rapt.svh"

module rapt_exu_mul #(
    parameter int XLEN = `RAPT_XLEN,
    parameter unsigned TAG_W = 1
) (
    input clock,
    input reset,
    input flush,
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
  //   DIV/DIVU/REM/REMU: iterative restoring divider, XLEN+1 cycles (serial)
  //
  // MUL and DIV datapaths are split: MUL has its own 2-stage pipe (m1_*, m2_*)
  // with tag pass-through; DIV runs serial in (div_*) state and blocks new
  // accepts via `in_ready`. Output mux gives DIV priority (rare emission) to
  // avoid collisions — MUL stage-B emission cannot coincide with DIV done
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

  logic [XLEN-1:0] div_q_signed, div_r_signed;
  assign div_q_signed = (div_sign == 2'b00 || div_sign == 2'b11) ? div_quotient : -div_quotient;
  assign div_r_signed = (div_sign[1] == 1'b0) ? div_remainder[XLEN:1] : -div_remainder[XLEN:1];

  logic signed_div;
  assign signed_div = (in_op == `RAPT_ALU_DIV___ || in_op == `RAPT_ALU_REM___);
  logic [XLEN-1:0] abs_a, abs_b;
  assign abs_a = (signed_div && in_a[XLEN-1]) ? -in_a : in_a;
  assign abs_b = (signed_div && in_b[XLEN-1]) ? -in_b : in_b;

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
  //   * MUL  : low XLEN bits — sign-extension irrelevant
  //   * MULH : signed   x signed   — both extended with sign bit
  //   * MULHSU: signed  x unsigned — only s1 extended
  //   * MULHU: unsigned x unsigned — neither extended
  // Replaces three independent 2*XLEN-wide multipliers (only one was ever
  // used per cycle) with one 2*(XLEN+1)-wide signed multiplier.
  logic              m1_sext_a;
  logic              m1_sext_b;
  always_comb begin
    unique case (m1_op)
      `RAPT_ALU_MULH__: begin m1_sext_a = 1'b1; m1_sext_b = 1'b1; end
      `RAPT_ALU_MULHSU: begin m1_sext_a = 1'b1; m1_sext_b = 1'b0; end
      `RAPT_ALU_MULHU_: begin m1_sext_a = 1'b0; m1_sext_b = 1'b0; end
      // MUL (and any default) — low product is sign-agnostic.
      default:          begin m1_sext_a = 1'b0; m1_sext_b = 1'b0; end
    endcase
  end

  logic signed [XLEN:0]     mul_ext_a;
  logic signed [XLEN:0]     mul_ext_b;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [2*XLEN+1:0] mul_full;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mul_ext_a = $signed({m1_sext_a & m1_s1[XLEN-1], m1_s1});
  assign mul_ext_b = $signed({m1_sext_b & m1_s2[XLEN-1], m1_s2});
  assign mul_full  = mul_ext_a * mul_ext_b;

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
  assign accept_mul = in_valid && in_ready && !in_is_div;
  assign accept_div = in_valid && in_ready && in_is_div;

  // ---- Output mux (DIV has priority; see note above) ----
  always_comb begin
    if (div_out_valid) begin
      out_r     = div_out_r;
      out_tag   = div_out_tag;
      out_valid = 1'b1;
    end else if (m2_v) begin
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
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      m1_v          <= 1'b0;
      m2_v          <= 1'b0;
      div_active    <= 1'b0;
      div_out_valid <= 1'b0;
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
      if (m1_v) begin
        m2_r   <= mul_r_comb;
        m2_tag <= m1_tag;
        m2_v   <= 1'b1;
      end else begin
        m2_v <= 1'b0;
      end

      // ===== DIV start =====
      if (accept_div) begin
        div_op               <= in_op;
        div_s1               <= in_a;
        div_s2               <= in_b;
        div_word             <= in_word;
        div_tag              <= in_tag;

        div_quotient         <= 0;
        div_remainder        <= {{XLEN{1'b0}}, abs_a[XLEN-1]};
        div_divisor          <= abs_b;
        div_dividend_shifted <= abs_a << 1;
        div_counter          <= 0;
        div_sign             <= {in_a[XLEN-1], in_b[XLEN-1]};
        div_active           <= 1'b1;
        div_out_valid        <= 1'b0;
      end else if (div_active) begin
        if (div_counter == XLEN[$clog2(XLEN+1)-1:0]) begin
          // Division complete: apply sign correction and emit
          div_active    <= 1'b0;
          div_out_valid <= 1'b1;
          div_out_tag   <= div_tag;
          unique case (div_op)
            `RAPT_ALU_DIV___: begin
              if (div_s2 == 0) div_out_r <= ~'h0;
              else if (div_s1 == ('b1 << (XLEN - 1)) && div_s2 == ~'h0)
                div_out_r <= 'b1 << (XLEN - 1);
              else if (div_word) div_out_r <= {{XLEN - 32{div_q_signed[31]}}, div_q_signed[31:0]};
              else div_out_r <= div_q_signed;
            end
            `RAPT_ALU_DIVU__: begin
              if (div_s2 == 0) div_out_r <= ~'h0;
              else if (div_word) div_out_r <= {{XLEN - 32{1'b0}}, div_quotient[31:0]};
              else div_out_r <= div_quotient;
            end
            `RAPT_ALU_REM___: begin
              if (div_s2 == 0) div_out_r <= div_s1;
              else if (div_word) div_out_r <= {{XLEN - 32{div_r_signed[31]}}, div_r_signed[31:0]};
              else div_out_r <= div_r_signed;
            end
            `RAPT_ALU_REMU__: begin
              if (div_s2 == 0) div_out_r <= div_s1;
              else if (div_word) div_out_r <= {{XLEN - 31{1'b0}}, div_remainder[31:1]};
              else div_out_r <= div_remainder[XLEN:1];
            end
            default: div_out_r <= 0;
          endcase
        end else begin
          // One iteration of restoring division
          if (div_remainder >= {{1'b0}, div_divisor}) begin
            div_quotient <= div_quotient | ('b1 << (XLEN[$clog2(XLEN+1)-1:0] - 1 - div_counter));
            div_remainder <= ((div_remainder - {{1'b0}, div_divisor}) << 1)
                           + {{XLEN{1'b0}}, div_dividend_shifted[XLEN-1]};
          end else begin
            div_remainder <= (div_remainder << 1) + {{XLEN{1'b0}}, div_dividend_shifted[XLEN-1]};
          end
          div_dividend_shifted <= div_dividend_shifted << 1;
          div_counter          <= div_counter + 1;
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

  assign out_valid = valid;
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
    end else if (in_valid && in_ready) begin
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
