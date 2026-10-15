`include "rapt.svh"

// Exhaustive equivalence on every opcode supported by a simple issue port.
module formal_ieu_alu_slim #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic [XLEN-1:0] s1,
    input logic [XLEN-1:0] s2,
    input logic [5:0] op,
    input logic word
);
  logic [XLEN-1:0] full_result, simple_result;
  logic rare_op;
  rapt_ieu_alu #(
      .XLEN(XLEN)
  ) full_alu (
      .*,
      .out_r(full_result)
  );
  rapt_ieu_alu #(
      .XLEN(XLEN),
      .EnableRareOps(1'b0)
  ) simple_alu (
      .*,
      .out_r(simple_result)
  );
  assign rare_op = (op == `RAPT_ALU_CLZ_) || (op == `RAPT_ALU_CTZ_) || (op == `RAPT_ALU_CPOP)
      || (op == `RAPT_ALU_CLMUL) || (op == `RAPT_ALU_CLMULH) || (op == `RAPT_ALU_CLMULR);
  always_comb begin
    if (rare_op) begin
      assert (simple_result == '0);
    end else begin
      assert (simple_result == full_result);
    end
  end
endmodule
