`include "rapt.svh"
`include "rapt_if.svh"

// ALU pipe: simple arithmetic + JAL/JALR link write.
//
// Pure combinational function unit + writeback drive for the ALU CDB
// port. Dispatch routing guarantees this pipe never sees CSR / system /
// trap / conditional-branch / MUL-DIV uops, so the only taken-redirect
// source is an unconditional jump (jen).
/* verilator lint_off UNUSEDSIGNAL */
module rapt_exu_pipe_alu #(
    parameter unsigned XLEN = `RAPT_XLEN
) (
    // Issue slot from the ALU issue port
    exu_iq_iss_if.fu iss,

    // Writeback (CDB port [1])
    exu_wb_if.out wb_alu
);
  /* verilator lint_on UNUSEDSIGNAL */

  logic [XLEN-1:0] alu_result;
  rapt_exu_alu gen_alu (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.alu),
      .word(iss.word),
      .out_r(alu_result)
  );

  logic [XLEN-1:0] jump_target;
  assign jump_target = ((iss.jren ? iss.op1 : iss.pc) + iss.imm) & ~'b1;

  // === Writeback ===
  assign wb_alu.valid = iss.valid;
  assign wb_alu.dest = iss.dest;
  assign wb_alu.result = iss.jen
      ? iss.pc + (iss.c ? 2 : 4)
      : alu_result;
  assign wb_alu.prd = iss.prd;
  assign wb_alu.rd = iss.rd;
  assign wb_alu.pc = iss.pc;
  assign wb_alu.npc    = iss.jen
      ? jump_target
      : iss.pc + (iss.c ? 2 : 4);
  assign wb_alu.btaken = 1'b0;
  assign wb_alu.mispredict = (wb_alu.npc != iss.pnpc);
  assign wb_alu.difftest_skip = 1'b0;
  // ALU never produces CSR / trap / MEM sideband (unified exu_wb_if tie-offs).
  assign wb_alu.csr_wen = 1'b0;
  assign wb_alu.csr_wdata = '0;
  assign wb_alu.fp_flags_valid = 1'b0;
  assign wb_alu.fp_flags = '0;
  assign wb_alu.trap = 1'b0;
  assign wb_alu.tval = '0;
  assign wb_alu.cause = '0;
  assign wb_alu.wen = 1'b0;
  assign wb_alu.alu = '0;
  assign wb_alu.sq_waddr = '0;
  assign wb_alu.sq_wdata = '0;
  assign wb_alu.sq_wdata64 = '0;
  assign wb_alu.sq_fp64 = 1'b0;

endmodule
