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

  localparam int PcW = `RAPT_PC_BITS_OF(XLEN);
  wire [XLEN-1:0] pc_value = `RAPT_PC_SEXT(XLEN, iss.uop.pc);
  logic [PcW-1:0] branch_target;
  assign branch_target = PcW'((pc_value + XLEN'($signed(iss.uop.imm))) & ~'b1);

  // === Writeback ===
  always_comb begin
    wb_branch = '0;
    wb_branch.valid = iss.valid;
    wb_branch.dest = iss.dest;
    wb_branch.generation = iss.generation;
    wb_branch.pc = iss.uop.pc;
    wb_branch.npc    = branch_taken
      ? branch_target
      : iss.uop.pc + PcW'(iss.uop.c ? 2 : 4);
    wb_branch.btaken = branch_taken;
    // Prediction checking belongs to the ROB checkpoint target file. This
    // execution pipe only resolves direction and the actual next PC.

    wb_branch.updates = '{control_flow:1'b1, default:'0};
  end
endmodule
