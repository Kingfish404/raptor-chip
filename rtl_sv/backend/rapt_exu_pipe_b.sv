`include "rapt.svh"
`include "rapt_if.svh"

// ALU-B pipe: simple arithmetic + JAL/JALR link write.
//
// Pure combinational function unit + writeback drive for the exu_rou_b CDB
// port. Dispatch routing guarantees this pipe never sees CSR / system /
// trap / conditional-branch / MUL-DIV uops, so the only taken-redirect
// source is an unconditional jump (jen).
/* verilator lint_off UNUSEDSIGNAL */
module rapt_exu_pipe_b #(
    parameter unsigned XLEN = `RAPT_XLEN
) (
    // Issue slot from the ALU-B issue queue
    exu_iq_iss_if.fu iss,

    // Writeback (CDB port [1])
    exu_wb_if.out exu_rou_b
);
  /* verilator lint_on UNUSEDSIGNAL */

  logic [XLEN-1:0] alu_result_b;
  rapt_exu_alu gen_alu_b (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.alu),
      .word(iss.word),
      .out_r(alu_result_b)
  );

  logic [XLEN-1:0] addr_exu_b;
  assign addr_exu_b = ((iss.jen ? iss.op1 : iss.pc) + iss.imm) & ~'b1;

  // === Writeback ===
  assign exu_rou_b.valid = iss.valid;
  assign exu_rou_b.dest = iss.dest;
  assign exu_rou_b.result = iss.jen
      ? iss.pc + (iss.c ? 2 : 4)
      : alu_result_b;
  assign exu_rou_b.prd = iss.prd;
  assign exu_rou_b.rd = iss.rd;
  assign exu_rou_b.pc = iss.pc;
  assign exu_rou_b.npc    = iss.jen
      ? addr_exu_b
      : iss.pc + (iss.c ? 2 : 4);
  assign exu_rou_b.btaken = 1'b0;
  assign exu_rou_b.mispredict = (exu_rou_b.npc != iss.pnpc);
  assign exu_rou_b.difftest_skip = 1'b0;
  // ALU-B never produces CSR / trap / MEM sideband (unified exu_wb_if tie-offs).
  assign exu_rou_b.csr_wen = 1'b0;
  assign exu_rou_b.csr_wdata = '0;
  assign exu_rou_b.trap = 1'b0;
  assign exu_rou_b.tval = '0;
  assign exu_rou_b.cause = '0;
  assign exu_rou_b.wen = 1'b0;
  assign exu_rou_b.alu = '0;
  assign exu_rou_b.sq_waddr = '0;
  assign exu_rou_b.sq_wdata = '0;

endmodule
