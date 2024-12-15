`include "ysyx.svh"

module ysyx_exu_mul (
    input clock,
    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_valid,
    output reg [XLEN-1:0] out_r,
    output reg out_valid
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;
  reg [XLEN-1:0] s1, s2;
  reg [4:0] op;
  reg valid;

  assign out_valid = valid;

`ifdef YSYX_M_FAST
  reg [XLEN-1:0] r;
  wire [63:0] mulh;
  wire [64:0] muls;
  wire [63:0] mulu;

  always_ff @(posedge clock) begin
    if (in_valid) begin
      op <= in_op;
      s1 <= in_a;
      s2 <= in_b;
      valid <= 0;
    end
    if (op[4]) begin
      out_r <= r;
      valid <= 1;
      op <= 0;
    end else begin
      valid <= 0;
    end
  end

  assign mulh = {{32{s1[31]}}, s1} * {{32{s2[31]}}, s2};
  assign muls = {{32{s1[31]}}, s1} * {{32'b0}, s2};
  assign mulu = {({{32'b0}, s1}) * ({{32'b0}, s2})};

  always_comb begin
    unique case (op)
      // RV32M
      // verilog_format: off
      `YSYX_ALU_MUL___: begin r = s1 * s2;      end
      `YSYX_ALU_MULH__: begin r = mulh[63:32];  end
      `YSYX_ALU_MULHSU: begin r = muls[63:32];  end
      `YSYX_ALU_MULHU_: begin r = mulu[63:32];  end
      `YSYX_ALU_DIV___: begin r = s2 != 0 ? $signed($signed(s1) / $signed(s2)): -1; end
      `YSYX_ALU_DIVU__: begin r = s2 != 0 ? (s1) / (s2) : -1; end
      `YSYX_ALU_REM___: begin r = s2 != 0 ? $signed($signed(s1) % $signed(s2)): s1; end
      `YSYX_ALU_REMU__: begin r = s2 != 0 ? (s1) % (s2) : s1; end
               default: begin r = 0; end
      // verilog_format: on
    endcase
  end

`else

  reg [XLEN-1:0] p, s, quotient;
  reg [6:0] counter;
  reg [1:0] bb;

  reg [63:0] ss1, ss2;
  reg [63:0] pp, ss;
  wire signed_op = in_op == `YSYX_ALU_REM___ || in_op == `YSYX_ALU_DIV___;
  wire [XLEN-1:0] s1_signed = ((signed_op) && in_a[31]) ? -in_a : in_a;

  reg [XLEN-1:0] div_bit;
  reg [32:0] reh;
  reg [1:0] sign;

  always_ff @(posedge clock) begin
    if (in_valid) begin
      op <= in_op;
      s1 <= s1_signed;
      s2 <= (signed_op && in_b[31]) ? -in_b : in_b;
      ss1 <= (in_op != `YSYX_ALU_MULHU_) ? {{32{in_a[31]}}, in_a} : {{32'b0}, in_a};
      ss2 <= (in_op != `YSYX_ALU_MULH__) ? {{32'b0}, in_b} : {{32{in_b[31]}}, in_b};
      s <= 0;
      ss <= 0;
      p <= 0;
      pp <= 0;

      div_bit <= 'h80000000;
      reh <= {{XLEN{1'b0}}, s1_signed[XLEN-1]};
      sign <= {in_a[XLEN-1], in_b[XLEN-1]};
      quotient <= 0;

      bb <= 0;
      counter <= 0;
      valid <= 0;
    end else begin
      unique case (op)
        `YSYX_ALU_MUL___: begin
          if (counter == 33) begin
            out_r <= p;
            valid <= 1;
          end
        end
        `YSYX_ALU_MULH__, `YSYX_ALU_MULHSU, `YSYX_ALU_MULHU_: begin
          if (counter == 65) begin
            out_r <= pp[63:32];
            valid <= 1;
          end
        end
        `YSYX_ALU_DIV___, `YSYX_ALU_DIVU__: begin
          if (s2 == 0 && counter == 0) begin
            out_r <= -1;
            valid <= 1;
          end else if (op == `YSYX_ALU_DIV___ && counter == 32) begin
            out_r <= (sign == 'b00 || sign == 'b11) ? quotient : ~quotient + 1;
            valid <= 1;
            op <= 0;
          end else if (op == `YSYX_ALU_DIVU__ && counter == 32) begin
            out_r <= quotient;
            valid <= 1;
          end
        end
        `YSYX_ALU_REM___: begin
          if (counter == 32) begin
            out_r <= (sign == 'b00 || sign == 'b01) ? reh[32:1] : ~reh[32:1] + 1;
            valid <= 1;
          end
        end
        `YSYX_ALU_REMU__: begin
          if (counter == 32) begin
            out_r <= reh[32:1];
            valid <= 1;
          end
        end
        default: begin
          valid <= 0;
        end
      endcase

      unique case (op)
        `YSYX_ALU_MUL___: begin
          // Booth's algorithm for 32-bit multiplication
          //  P(i+1)=2^-1(P(i)+(b_{i-1}-b_i)A*2^8)
          //  P(0)=0, S=A*2^8={A,XLEN′b0}
          //  P(i+1) = P(i) + S if bb=01 else -S if bb=10 else 0
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
          // Booth's algorithm for 64-bit multiplication
          ss  <= {ss1[0], ss[63:1]};
          ss1 <= ss1 >> 1;
          ss2 <= ss2 << 1;
          bb  <= {ss2[63], ss2[62]};
          if (bb == 'b01) begin
            pp <= pp + ss;
          end else if (bb == 'b10) begin
            pp <= pp - ss;
          end
          counter <= counter + 1;
        end
        `YSYX_ALU_DIV___, `YSYX_ALU_DIVU__, `YSYX_ALU_REM___, `YSYX_ALU_REMU__: begin
          // iterative restoring division algorithm
          div_bit <= div_bit >> 1;
          quotient <= (reh >= {{1'b0}, s2}) ? quotient + div_bit : quotient;
          reh <= (reh >= {{1'b0}, s2}) ?
            ((reh - {{1'b0}, s2}) << 1) + {{32'b0}, s1[30]} :
            ((reh) << 1) + {{32'b0}, s1[30]};
          s1 <= s1 << 1;
          counter <= counter + 1;
        end
        default: begin
        end
      endcase
    end
  end
`endif

endmodule  // ysyx_alu_mul
