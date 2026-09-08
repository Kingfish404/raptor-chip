`include "rapt.svh"
`include "rapt_if.svh"

// Integer ALU, CSR, system and trap execution pipe. Scalar floating-point
// arithmetic is owned by rapt_feu.
module rapt_ieu_pipe_alu_csr #(
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    cmu_bcast_if.in cmu_bcast,
    input IssueT iss,
    csr_bcast_if.in csr_bcast,
    exu_csr_if.master exu_csr,
    output CompletionT wb_alu_csr
);

  logic [XLEN-1:0] alu_result;
  rapt_ieu_alu gen_alu (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.uop.execute.int_op.alu),
      .word(iss.uop.execute.int_op.word),
      .out_r(alu_result)
  );

  logic [XLEN-1:0] jump_target;
  logic [XLEN-1:0] csr_wdata;
  logic csr_write_enable;
  assign jump_target = ((iss.uop.execute.branch.indirect ? iss.op1 : iss.uop.pc) + iss.uop.imm) & ~'b1;
  assign exu_csr.raddr = iss.uop.imm[11:0];
  // Write suppression depends on the encoded rs1/uimm field, not its value.
  // A non-x0 register containing zero still writes CSRRS/CSRRC (for example,
  // an explicit minstret write must override that instruction's increment).
  assign csr_write_enable = iss.uop.execute.sys.csr_csw[0]
    || ((iss.uop.execute.sys.csr_csw[1] || iss.uop.execute.sys.csr_csw[2])
        && (iss.uop.inst[19:15] != 5'b0));
  assign csr_wdata = ({XLEN{iss.uop.execute.sys.csr_csw[0]}} & iss.op1)
    | ({XLEN{iss.uop.execute.sys.csr_csw[1]}} & (exu_csr.rmw_data | iss.op1))
    | ({XLEN{iss.uop.execute.sys.csr_csw[2]}} & (exu_csr.rmw_data & ~iss.op1));

  assign wb_alu_csr.dest = iss.dest;
  assign wb_alu_csr.generation = iss.generation;
  // CSR instructions are serializing, so by the time one executes all older
  // instructions have already updated minstret. The CSR instruction itself
  // must not be included in the value it reads; the former ROB-distance + 1
  // correction therefore made every rdinstret result at least one too large.
  assign wb_alu_csr.result = iss.uop.execute.sys.valid ? exu_csr.rdata
    : iss.uop.execute.branch.jump ? iss.uop.pc + (iss.uop.c ? 2 : 4) : alu_result;
  assign wb_alu_csr.npc = (iss.uop.execute.sys.ecall || iss.uop.execute.sys.ebreak) ? csr_bcast.mtvec
    : iss.uop.trap ? csr_bcast.tvec
    : iss.uop.execute.sys.mret ? exu_csr.mepc
    : iss.uop.execute.sys.sret ? exu_csr.sepc
    : iss.uop.execute.branch.jump ? jump_target : iss.uop.pc + (iss.uop.c ? 2 : 4);
  assign wb_alu_csr.mispredict = wb_alu_csr.npc != iss.uop.pnpc;
  assign wb_alu_csr.prd = iss.prd;
  assign wb_alu_csr.rd = iss.uop.rd;
  assign wb_alu_csr.pc = iss.uop.pc;
  assign wb_alu_csr.csr_wen = csr_write_enable;
  assign wb_alu_csr.csr_wdata = csr_wdata;
  assign wb_alu_csr.fp_flags_valid = 1'b0;
  assign wb_alu_csr.fp_flags = '0;
  assign wb_alu_csr.trap = iss.uop.trap;
  assign wb_alu_csr.tval = iss.uop.tval;
  assign wb_alu_csr.cause = iss.uop.cause;
  assign wb_alu_csr.difftest_skip = |iss.uop.execute.sys.csr_csw && (iss.uop.imm[11:0] ==
      `RAPT_CSR_TIME___
      || iss.uop.imm[11:0] == `RAPT_CSR_TIMEH__ || iss.uop.imm[11:0] ==
      `RAPT_CSR_CYCLE__
      || iss.uop.imm[11:0] == `RAPT_CSR_MCYCLE_ || iss.uop.imm[11:0] == `RAPT_CSR_MCYCLEH);
  assign wb_alu_csr.valid = iss.valid;
  assign wb_alu_csr.btaken = 1'b0;
  assign wb_alu_csr.wen = 1'b0;
  assign wb_alu_csr.alu = '0;
  assign wb_alu_csr.sq_waddr = '0;
  assign wb_alu_csr.sq_wdata = '0;
  assign wb_alu_csr.sq_wdata64 = '0;
  assign wb_alu_csr.sq_fp64 = 1'b0;
  assign wb_alu_csr.updates = '{control_flow:1'b1, memory:1'b0, system_state:1'b1, exception:1'b1};
endmodule
