module formal_exu_mul #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_valid,
    output reg [XLEN-1:0] out_r,
    output reg out_valid,

    input reset
);
  ysyx_exu_mul mul (
      .clock(clock),
      .in_a(in_a),
      .in_b(in_b),
      .in_op(in_op),
      .in_word(1'b0),
      .in_valid(in_valid),
      .out_r(out_r),
      .out_valid(out_valid)
  );

  reg start = 0;
  reg [XLEN-1:0] ref_s1 = 0, ref_s2 = 0, r = 0;
  reg [4:0] op = 0;

  wire [2*XLEN-1:0] mulh = {{XLEN{in_a[XLEN-1]}}, in_a} * {{XLEN{in_b[XLEN-1]}}, in_b};
  wire [2*XLEN-1:0] muls = {{XLEN{in_a[XLEN-1]}}, in_a} * {{XLEN{1'b0}}, in_b};
  wire [2*XLEN-1:0] mulu = {{XLEN{1'b0}}, in_a} * {{XLEN{1'b0}}, in_b};

  always @(posedge clock) begin
    if (in_valid) begin
      op <= in_op;
      start <= 1;
      ref_s1 <= in_a;
      ref_s2 <= in_b;
      unique case (in_op)
        // RV32M
        // verilog_format: off
      `YSYX_ALU_MUL___: begin r <= in_a * in_b;      end
      `YSYX_ALU_MULH__: begin r <= mulh[2*XLEN-1:XLEN];  end
      `YSYX_ALU_MULHSU: begin r <= muls[2*XLEN-1:XLEN];  end
      `YSYX_ALU_MULHU_: begin r <= mulu[2*XLEN-1:XLEN];  end
      `YSYX_ALU_DIV___: begin r <= in_b != 0 ? $signed($signed(in_a) / $signed(in_b)): -1; end
      `YSYX_ALU_DIVU__: begin r <= in_b != 0 ? (in_a) / (in_b) : -1; end
      `YSYX_ALU_REM___: begin r <= in_b != 0 ? $signed($signed(in_a) % $signed(in_b)): in_a; end
      `YSYX_ALU_REMU__: begin r <= in_b != 0 ? (in_a) % (in_b) : in_a; end
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
endmodule
