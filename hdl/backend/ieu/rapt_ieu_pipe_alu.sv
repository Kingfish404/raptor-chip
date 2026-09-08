`include "rapt.svh"
`include "rapt_if.svh"

// ALU pipe: simple arithmetic + JAL/JALR link write.
//
// Pure combinational function unit + writeback drive for the ALU CDB
// port. Dispatch routing guarantees this pipe never sees CSR / system /
// trap / conditional-branch / MUL-DIV uops, so the only taken-redirect
// source is an unconditional jump (jen).
/* verilator lint_off UNUSEDSIGNAL */
module rapt_ieu_pipe_alu #(
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter unsigned XLEN = `RAPT_XLEN
) (
    // Issue slot from the ALU issue port
    input IssueT iss,

    // Writeback (CDB port [1])
    output CompletionT wb_alu
);
  /* verilator lint_on UNUSEDSIGNAL */

  logic [XLEN-1:0] alu_result;
  rapt_ieu_alu gen_alu (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.uop.execute.int_op.alu),
      .word(iss.uop.execute.int_op.word),
      .out_r(alu_result)
  );

  logic [XLEN-1:0] jump_target;
  assign jump_target = ((iss.uop.execute.branch.indirect ? iss.op1 : iss.uop.pc) + iss.uop.imm) & ~'b1;

  // === Writeback ===
  assign wb_alu.valid = iss.valid;
  assign wb_alu.dest = iss.dest;
  assign wb_alu.generation = iss.generation;
  assign wb_alu.result = iss.uop.execute.branch.jump
      ? iss.uop.pc + (iss.uop.c ? 2 : 4)
      : alu_result;
  assign wb_alu.prd = iss.prd;
  assign wb_alu.rd = iss.uop.rd;
  assign wb_alu.pc = iss.uop.pc;
  assign wb_alu.npc    = iss.uop.execute.branch.jump
      ? jump_target
      : iss.uop.pc + (iss.uop.c ? 2 : 4);
  assign wb_alu.btaken = 1'b0;
  assign wb_alu.mispredict = (wb_alu.npc != iss.uop.pnpc);
  assign wb_alu.difftest_skip = 1'b0;
  // ALU never produces CSR / trap / MEM sideband (unified completion sideband tie-offs).
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

  assign wb_alu.updates = '{control_flow:1'b1, default:'0};
endmodule
