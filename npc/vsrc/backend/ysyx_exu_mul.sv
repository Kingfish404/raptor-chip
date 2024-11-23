`include "ysyx.svh"

module ysyx_exu_mul (
    input clock,
    input reset,
    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_valid,
    output reg [XLEN-1:0] out_r,
    output reg out_valid
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;
  reg [XLEN-1:0] r, s1, s2;
  reg [4:0] op;
  reg valid;
  wire [63:0] mulh;
  wire [64:0] muls;
  wire [63:0] mulu;

  assign out_valid = valid;
  always_ff @(posedge clock) begin
    if (reset) begin
      valid <= 0;
    end else begin
      if (in_valid) begin
        op <= in_op;
        s1 <= in_a;
        s2 <= in_b;
      end
      if (op[4] && valid == 0) begin
        out_r <= r;
        valid <= 1;
        op <= 0;
      end else begin
        valid <= 0;
      end
    end
  end

  assign mulh = $signed(({{32{s1[31:31]}}, s1}) * ({{32{s2[31:31]}}, s2}));
  assign muls = ({{32{s1[31]}}, s1}) * ({{32'b0}, s2});
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
      // verilog_format: on
      default: begin
        r = 0;
      end
    endcase
  end
endmodule  // ysyx_alu_mul
