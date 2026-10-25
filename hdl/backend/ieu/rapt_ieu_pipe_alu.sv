`include "rapt.svh"
`include "rapt_if.svh"

// ALU pipe: simple arithmetic + JAL/JALR link write.
//
// Pure combinational function unit + writeback drive for the ALU CDB
// port. Dispatch routing guarantees this pipe never sees CSR / system /
// trap / conditional-branch / MUL-DIV / count / CLMUL uops, so the only
// taken-redirect source is an unconditional jump (jen).
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
  rapt_ieu_alu #(
      .XLEN(XLEN),
      .EnableRareOps(1'b0)
  ) gen_alu (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.uop.execute.int_op.alu),
      .word(iss.uop.execute.int_op.word),
      .out_r(alu_result)
  );

  localparam int PcW = `RAPT_PC_BITS_OF(XLEN);
  wire [XLEN-1:0] pc_value = `RAPT_PC_SEXT(XLEN, iss.uop.pc);
  logic [XLEN-1:0] jump_target;
  assign jump_target = ((iss.uop.execute.branch.indirect ? iss.op1 : pc_value) + XLEN'($signed(
      iss.uop.imm
  ))) & ~'b1;

  // === Writeback ===
  always_comb begin
    wb_alu = '0;
    wb_alu.valid = iss.valid;
    wb_alu.dest = iss.dest;
    wb_alu.generation = iss.generation;
    wb_alu.result = iss.uop.execute.branch.jump
      ? pc_value + XLEN'(iss.uop.c ? 2 : 4)
      : alu_result;
    wb_alu.prd = iss.prd;
    wb_alu.rd = iss.uop.rd;
    wb_alu.pc = iss.uop.pc;
    wb_alu.npc    = iss.uop.execute.branch.jump
      ? `RAPT_PC_LEGALIZE(XLEN, PcW, jump_target)
      : iss.uop.pc + PcW'(iss.uop.c ? 2 : 4);
    // IDU corrects non-control predictions before rename. Jump predictions are
    // checked centrally at completion by the ROB checkpoint target file.

    wb_alu.updates = '{control_flow:1'b1, default:'0};
  end
endmodule
