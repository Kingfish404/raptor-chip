`include "rapt.svh"
`include "rapt_if.svh"

// Branch pipe: dedicated conditional-branch resolution (ben).
//
// Only the 6 conditional-branch compare opcodes (BEQ/BNE/BLT/BGE/BLTU/BGEU
// -> ALU_EQ_/XOR_/SLT_/SGE_/SLTU/SGEU) are ever routed here, so a single
// taken/not-taken bit replaces a full XLEN-wide ALU (no shifter / Zbb /
// Zbs / CLMUL cones behind this pipe). Conditional branches never write
// rd and never produce values consumed downstream, so the writeback
// carries only ROB-state + branch-resolution fields (result/prd/rd tied 0
// -> no PRF write port, no bypass network entry).
/* verilator lint_off UNUSEDSIGNAL */
module rapt_ieu_pipe_branch #(
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter unsigned XLEN = `RAPT_XLEN
) (
    // Issue slot from the branch issue queue
    input IssueT iss,

    // Writeback (CDB port [2])
    output CompletionT wb_branch
);
  /* verilator lint_on UNUSEDSIGNAL */

  logic branch_taken;
  always_comb begin
    unique case (iss.uop.execute.int_op.alu)
      `RAPT_ALU_EQ__: branch_taken = (iss.op1 == iss.op2);  // BEQ
      `RAPT_ALU_XOR_: branch_taken = (iss.op1 != iss.op2);  // BNE: |s1^s2
      `RAPT_ALU_SLT_: branch_taken = ($signed(iss.op1) < $signed(iss.op2));  // BLT
      `RAPT_ALU_SGE_: branch_taken = ($signed(iss.op1) >= $signed(iss.op2));  // BGE
      `RAPT_ALU_SLTU: branch_taken = (iss.op1 < iss.op2);  // BLTU
      `RAPT_ALU_SGEU: branch_taken = (iss.op1 >= iss.op2);  // BGEU
      default:        branch_taken = 1'b0;
    endcase
  end

  logic [XLEN-1:0] branch_target;
  assign branch_target = (iss.uop.pc + iss.uop.imm) & ~'b1;

  // === Writeback ===
  assign wb_branch.valid = iss.valid;
  assign wb_branch.dest = iss.dest;
  assign wb_branch.generation = iss.generation;
  assign wb_branch.pc = iss.uop.pc;
  assign wb_branch.npc    = branch_taken
      ? branch_target
      : iss.uop.pc + (iss.uop.c ? 2 : 4);
  assign wb_branch.btaken = branch_taken;
  // Direction is independent metadata: a branch targeting its fall-through can
  // have the right next PC but the wrong speculative history bit.
  // If direction differs, recovery is unconditional. Otherwise the predicted
  // direction selects the same address as branch_taken. Compare addresses
  // independently of the operand-dependent branch decision, avoiding an
  // actual-next-PC mux followed by an XLEN-wide comparison on that path.
  logic predicted_target_mismatch;
  assign predicted_target_mismatch = iss.uop.execute.branch.predicted_taken
      ? (branch_target != iss.uop.pnpc)
      : ((iss.uop.pc + (iss.uop.c ? 2 : 4)) != iss.uop.pnpc);
  assign wb_branch.mispredict = predicted_target_mismatch
      || branch_taken != iss.uop.execute.branch.predicted_taken;
  assign wb_branch.difftest_skip = 1'b0;
  // Branch pipe never writes rd nor produces CSR / trap / MEM sideband (unified
  // completion sideband tie-offs; keeps the no-PRF-write-port / no-bypass-entry
  // property: consumers never see a valid prd from this port).
  assign wb_branch.result = '0;
  assign wb_branch.prd = '0;
  assign wb_branch.rd = '0;
  assign wb_branch.csr_wen = 1'b0;
  assign wb_branch.csr_wdata = '0;
  assign wb_branch.fp_flags_valid = 1'b0;
  assign wb_branch.fp_flags = '0;
  assign wb_branch.trap = 1'b0;
  assign wb_branch.tval = '0;
  assign wb_branch.cause = '0;
  assign wb_branch.wen = 1'b0;
  assign wb_branch.alu = '0;
  assign wb_branch.sq_waddr = '0;
  assign wb_branch.sq_wdata = '0;
  assign wb_branch.sq_wdata64 = '0;
  assign wb_branch.sq_fp64 = 1'b0;

  assign wb_branch.updates = '{control_flow:1'b1, default:'0};
endmodule
