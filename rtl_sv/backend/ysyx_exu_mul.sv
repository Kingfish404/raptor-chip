`include "ysyx.svh"

module ysyx_exu_mul #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_word,  // RV64 W-variant: operate on lower 32 bits, sign-extend result
    input in_valid,
    output logic [XLEN-1:0] out_r,
    output logic out_valid
);
  logic [XLEN-1:0] s1, s2;
  logic [4:0] op;
  logic word_r;
  logic valid;

  assign out_valid = valid;

`ifdef YSYX_M_FAST
  // Hybrid fast MUL + iterative DIV/REM:
  //   MUL/MULH/MULHSU/MULHU: combinational multiply, 2-cycle pipeline
  //   DIV/DIVU/REM/REMU: iterative restoring divider, XLEN+1 cycles
  // This avoids the ~14 ns combinational divider on the critical path.

  logic [XLEN-1:0] mul_r;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2*XLEN-1:0] mulh;
  logic [2*XLEN:0] muls;
  logic [2*XLEN-1:0] mulu;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [XLEN-1:0] r_pipe;
  logic pipe_valid;
  logic is_div;  // 1 = DIV/REM path (iterative), 0 = MUL path (fast)

  // Iterative divider state
  logic [XLEN-1:0] div_quotient;
  logic [XLEN:0] div_remainder;
  logic [XLEN-1:0] div_divisor;
  logic [XLEN-1:0] div_dividend_shifted;
  logic [$clog2(XLEN+1)-1:0] div_counter;
  logic [1:0] div_sign;  // {sign_a, sign_b}
  logic div_active;

  // Pre-computed signed correction for DIV/REM results
  logic [XLEN-1:0] div_q_signed;
  logic [XLEN-1:0] div_r_signed;
  assign div_q_signed = (div_sign == 2'b00 || div_sign == 2'b11) ? div_quotient : -div_quotient;
  assign div_r_signed = (div_sign[1] == 1'b0) ? div_remainder[XLEN:1] : -div_remainder[XLEN:1];

  // Sign/zero extend to 2*XLEN for high-word multiply
  assign mulh = {{XLEN{s1[XLEN-1]}}, s1} * {{XLEN{s2[XLEN-1]}}, s2};
  assign muls = {{XLEN{s1[XLEN-1]}}, s1} * {{XLEN{1'b0}}, s2};
  assign mulu = {({{XLEN{1'b0}}, s1}) * ({{XLEN{1'b0}}, s2})};

  // W-variant: use lower 32-bit operands
  logic [XLEN-1:0] ws1, ws2;
  assign ws1 = {{XLEN - 32{s1[31]}}, s1[31:0]};
  assign ws2 = {{XLEN - 32{s2[31]}}, s2[31:0]};

  // Combinational MUL result (no division logic — removes critical path)
  always_comb begin
    unique case (op)
      // verilog_format: off
      `YSYX_ALU_MUL___: begin
          if (word_r) begin
            logic [31:0] mul32; mul32 = ws1[31:0] * ws2[31:0];
            mul_r = {{XLEN-32{mul32[31]}}, mul32};
          end else
            mul_r = s1 * s2;
        end
      `YSYX_ALU_MULH__: begin mul_r = mulh[2*XLEN-1:XLEN];  end
      `YSYX_ALU_MULHSU: begin mul_r = muls[2*XLEN-1:XLEN];  end
      `YSYX_ALU_MULHU_: begin mul_r = mulu[2*XLEN-1:XLEN];  end
               default: begin mul_r = 0; end
      // verilog_format: on
    endcase
  end

  // Detect signed DIV/REM for operand negation
  logic signed_div;
  assign signed_div = (in_op == `YSYX_ALU_DIV___ || in_op == `YSYX_ALU_REM___);
  logic [XLEN-1:0] abs_a, abs_b;
  assign abs_a = (signed_div && in_a[XLEN-1]) ? -in_a : in_a;
  assign abs_b = (signed_div && in_b[XLEN-1]) ? -in_b : in_b;

  // Detect if incoming op is DIV/REM
  logic in_is_div;
  assign in_is_div = (in_op == `YSYX_ALU_DIV___ || in_op ==
      `YSYX_ALU_DIVU__
      || in_op == `YSYX_ALU_REM___ || in_op == `YSYX_ALU_REMU__);

  always_ff @(posedge clock) begin
    if (in_valid) begin
      op <= in_op;
      s1 <= in_a;
      s2 <= in_b;
      word_r <= in_word;
      valid <= 0;
      pipe_valid <= 0;
      is_div <= in_is_div;

      if (in_is_div) begin
        // Initialize iterative divider with absolute values
        div_quotient <= 0;
        div_remainder <= {{XLEN{1'b0}}, abs_a[XLEN-1]};
        div_divisor <= abs_b;
        div_dividend_shifted <= abs_a << 1;
        div_counter <= 0;
        div_sign <= {in_a[XLEN-1], in_b[XLEN-1]};
        div_active <= 1;
      end else begin
        div_active <= 0;
      end
    end else if (div_active) begin
      // Iterative restoring division: XLEN cycles
      if (div_counter == XLEN[$clog2(XLEN+1)-1:0]) begin
        // Division complete — apply sign correction and output
        div_active <= 0;
        unique case (op)
          `YSYX_ALU_DIV___: begin
            if (s2 == 0) out_r <= ~'h0;
            else if (s1 == ('b1 << (XLEN - 1)) && s2 == ~'h0) out_r <= 'b1 << (XLEN - 1);
            else if (word_r) out_r <= {{XLEN - 32{div_q_signed[31]}}, div_q_signed[31:0]};
            else out_r <= div_q_signed;
          end
          `YSYX_ALU_DIVU__: begin
            if (s2 == 0) out_r <= ~'h0;
            else if (word_r) out_r <= {{XLEN - 32{1'b0}}, div_quotient[31:0]};
            else out_r <= div_quotient;
          end
          `YSYX_ALU_REM___: begin
            if (s2 == 0) out_r <= s1;
            else if (word_r) out_r <= {{XLEN - 32{div_r_signed[31]}}, div_r_signed[31:0]};
            else out_r <= div_r_signed;
          end
          `YSYX_ALU_REMU__: begin
            if (s2 == 0) out_r <= s1;
            else if (word_r) out_r <= {{XLEN - 32{1'b0}}, div_remainder[31:1]};
            else out_r <= div_remainder[XLEN:1];
          end
          default: out_r <= 0;
        endcase
        valid <= 1;
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
        div_counter <= div_counter + 1;
      end
    end else if (op[4] && !pipe_valid && !is_div) begin
      // MUL path: register combinational result (stage 1)
      r_pipe <= mul_r;
      pipe_valid <= 1;
      op <= 0;
    end else if (pipe_valid) begin
      // MUL path: present registered result (stage 2)
      out_r <= r_pipe;
      valid <= 1;
      pipe_valid <= 0;
    end else begin
      valid <= 0;
    end
  end

`else

  logic [XLEN-1:0] p, s, quotient;
  logic [$clog2(2*XLEN+2)-1:0] counter;
  logic [1:0] bb;

  logic [2*XLEN-1:0] ss1, ss2;
  logic [2*XLEN-1:0] pp, ss;
  logic signed_op;
  assign signed_op = in_op == `YSYX_ALU_REM___ || in_op == `YSYX_ALU_DIV___;
  logic [XLEN-1:0] s1_signed;
  assign s1_signed = ((signed_op) && in_a[XLEN-1]) ? -in_a : in_a;

  logic [XLEN-1:0] div_bit;
  logic [XLEN:0] reh;
  logic [1:0] sign;

  always_ff @(posedge clock) begin
    if (in_valid) begin
      op <= in_op;
      word_r <= in_word;
      s1 <= s1_signed;
      s2 <= (signed_op && in_b[XLEN-1]) ? -in_b : in_b;
      ss1 <= (in_op != `YSYX_ALU_MULHU_) ? {{XLEN{in_a[XLEN-1]}}, in_a} : {{XLEN{1'b0}}, in_a};
      ss2 <= (in_op != `YSYX_ALU_MULH__) ? {{XLEN{1'b0}}, in_b} : {{XLEN{in_b[XLEN-1]}}, in_b};
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
        `YSYX_ALU_MUL___: begin
          if (counter == XLEN + 1) begin
            out_r <= p;
            valid <= 1;
          end else begin
            valid <= 0;
          end
        end
        `YSYX_ALU_MULH__, `YSYX_ALU_MULHSU, `YSYX_ALU_MULHU_: begin
          if (counter == 2 * XLEN + 1) begin
            out_r <= pp[2*XLEN-1:XLEN];
            valid <= 1;
          end else begin
            valid <= 0;
          end
        end
        `YSYX_ALU_DIV___, `YSYX_ALU_DIVU__: begin
          if (s2 == 0 && counter == 0) begin
            out_r <= -1;
            valid <= 1;
          end else if (op == `YSYX_ALU_DIV___ && counter == XLEN) begin
            out_r <= (sign == 'b00 || sign == 'b11) ? quotient : ~quotient + 1;
            op <= 0;
            valid <= 1;
          end else if (op == `YSYX_ALU_DIVU__ && counter == XLEN) begin
            out_r <= quotient;
            valid <= 1;
          end else begin
            valid <= 0;
          end
        end
        `YSYX_ALU_REM___: begin
          if (counter == XLEN) begin
            out_r <= (sign == 'b00 || sign == 'b01) ? reh[XLEN:1] : ~reh[XLEN:1] + 1;
            valid <= 1;
          end else begin
            valid <= 0;
          end
        end
        `YSYX_ALU_REMU__: begin
          if (counter == XLEN) begin
            out_r <= reh[XLEN:1];
            valid <= 1;
          end else begin
            valid <= 0;
          end
        end
        default: begin
          valid <= 0;
        end
      endcase

      unique case (op)
        `YSYX_ALU_MUL___: begin
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
        `YSYX_ALU_MULH__, `YSYX_ALU_MULHSU, `YSYX_ALU_MULHU_: begin
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
        `YSYX_ALU_DIV___, `YSYX_ALU_DIVU__, `YSYX_ALU_REM___, `YSYX_ALU_REMU__: begin
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
