`include "ysyx.svh"

module formal_exu_mul (
    input clock,

    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_valid,
    output reg [XLEN-1:0] out_r,
    output reg out_valid,

    input reset
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;

  wire [XLEN-1:0] s1 = in_a;
  wire [XLEN-1:0] s2 = in_b;

  ysyx_exu_mul mul (
      .clock(clock),
      .in_a(s1),
      .in_b(s2),
      .in_op(in_op),
      .in_valid(in_valid),
      .out_r(out_r),
      .out_valid(out_valid)
  );

  reg start = 0;
  reg [XLEN-1:0] s1 = 0, s2 = 0, r = 0;
  reg [4:0] op = 0;

  assign mulh = {{32{s1[31]}}, s1} * {{32{s2[31]}}, s2};
  assign muls = {{32{s1[31]}}, s1} * {{32'b0}, s2};
  assign mulu = {({{32'b0}, s1}) * ({{32'b0}, s2})};

  always @(posedge clock) begin
    if (in_valid) begin
      op <= in_op;
      start <= 1;
      unique case (in_op)
        // RV32M
        // verilog_format: off
      `YSYX_ALU_MUL___: begin r <= s1 * s2;      end
      `YSYX_ALU_MULH__: begin r <= mulh[63:32];  end
      `YSYX_ALU_MULHSU: begin r <= muls[63:32];  end
      `YSYX_ALU_MULHU_: begin r <= mulu[63:32];  end
      `YSYX_ALU_DIV___: begin r <= s2 != 0 ? $signed($signed(s1) / $signed(s2)): -1; end
      `YSYX_ALU_DIVU__: begin r <= s2 != 0 ? (s1) / (s2) : -1; end
      `YSYX_ALU_REM___: begin r <= s2 != 0 ? $signed($signed(s1) % $signed(s2)): s1; end
      `YSYX_ALU_REMU__: begin r <= s2 != 0 ? (s1) % (s2) : s1; end
               default: begin r = 0; end
        // verilog_format: on
      endcase
    end
  end

`ifdef FORMAL
  always @(*) begin
    if (start && out_valid) begin
      unique case (op)
        // RV32M
        // verilog_format: off
      `YSYX_ALU_MUL___: begin  mul_assert: assert(out_r == r); end
      `YSYX_ALU_MULH__: begin mulh_assert: assert(out_r == r); end
      `YSYX_ALU_MULHSU: begin muls_assert: assert(out_r == r); end
      `YSYX_ALU_MULHU_: begin mulu_assert: assert(out_r == r); end
      `YSYX_ALU_DIV___: begin  div_assert: assert(out_r == r); end
      `YSYX_ALU_DIVU__: begin divu_assert: assert(out_r == r); end
      `YSYX_ALU_REM___: begin  rem_assert: assert(out_r == r); end
      `YSYX_ALU_REMU__: begin remu_assert: assert(out_r == r); end
               default: begin  def_assert: assert(out_r == r); end
        // verilog_format: on
      endcase
    end
  end
`endif  // FORMAL
endmodule  // formal_exu_mul
