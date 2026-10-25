`include "rapt.svh"
`include "rapt_if.svh"

// Integer ALU, CSR, system and trap execution pipe. Scalar floating-point
// arithmetic is owned by rapt_feu.
module rapt_ieu_pipe_alu_csr #(
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter bit UseDispatchCsrAddress = 1'b0,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    cmu_bcast_if.in cmu_bcast,
    input IssueT iss,
    input logic [11:0] csr_read_addr = '0,
    csr_bcast_if.in csr_bcast,
    exu_csr_if.master exu_csr,
    output CompletionT wb_alu_csr
);

  logic [XLEN-1:0] alu_result;
  localparam int SfenceVpnBits = XLEN == 64 ? 27 : 20;
  logic sfence_operands, sfence_noncanonical;
  logic [XLEN-1:0] sfence_result;
  assign sfence_operands = `RAPT_SFENCE_SELECTIVE != 0
      && iss.uop.execute.sys.kind == rapt_pkg::SYS_TRANSLATION;
  if (XLEN == 64) begin : g_sfence_sv39
    assign sfence_noncanonical = iss.op1[63:39] != {25{iss.op1[38]}};
  end else begin : g_sfence_sv32
    assign sfence_noncanonical = 1'b0;
  end
  // Both operands are resolved at issue. The unused integer result transports
  // a compact fence descriptor; rd remains x0 and cannot update the PRF.
  assign sfence_result = XLEN'({sfence_noncanonical, iss.op2[8:0], iss.op1[SfenceVpnBits+11:12]});
  rapt_ieu_alu #(
      .XLEN(XLEN)
  ) gen_alu (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.uop.execute.int_op.alu),
      .word(iss.uop.execute.int_op.word),
      .out_r(alu_result)
  );

  localparam int PcW = `RAPT_PC_BITS_OF(XLEN);
  wire [XLEN-1:0] pc_value = `RAPT_PC_SEXT(XLEN, iss.uop.pc);
  logic [XLEN-1:0] jump_target, next_pc_value;
  logic [XLEN-1:0] csr_wdata;
  logic csr_write_enable;
  assign jump_target = ((iss.uop.execute.branch.indirect ? iss.op1 : pc_value)
      + XLEN'($signed(iss.uop.imm))) & ~'b1;
  assign exu_csr.raddr = UseDispatchCsrAddress ? csr_read_addr : iss.uop.imm[11:0];
  // Write suppression depends on the encoded rs1/uimm field, not its value.
  // A non-x0 register containing zero still writes CSRRS/CSRRC (for example,
  // an explicit minstret write must override that instruction's increment).
  assign csr_write_enable = iss.uop.execute.sys.csr_csw[0]
    || ((iss.uop.execute.sys.csr_csw[1] || iss.uop.execute.sys.csr_csw[2])
        && (iss.uop.imm[16:12] != 5'b0));
  assign csr_wdata = ({XLEN{iss.uop.execute.sys.csr_csw[0]}} & iss.op1)
    | ({XLEN{iss.uop.execute.sys.csr_csw[1]}} & (exu_csr.rmw_data | iss.op1))
    | ({XLEN{iss.uop.execute.sys.csr_csw[2]}} & (exu_csr.rmw_data & ~iss.op1));

  always_comb begin
    wb_alu_csr = '0;
    wb_alu_csr.dest = iss.dest;
    wb_alu_csr.generation = iss.generation;
    // CSR instructions are serializing, so by the time one executes all older
    // instructions have already updated minstret. The CSR instruction itself
    // must not be included in the value it reads; the former ROB-distance + 1
    // correction therefore made every rdinstret result at least one too large.
    wb_alu_csr.result = sfence_operands ? sfence_result
    : iss.uop.execute.sys.valid ? exu_csr.rdata
    : iss.uop.execute.branch.jump ? pc_value + XLEN'(iss.uop.c ? 2 : 4) : alu_result;
    next_pc_value = (iss.uop.execute.sys.ecall || iss.uop.execute.sys.ebreak)
      ? csr_bcast.mtvec
    : iss.uop.trap ? csr_bcast.tvec
    : iss.uop.execute.sys.mret ? exu_csr.mepc
    : iss.uop.execute.sys.sret ? exu_csr.sepc
    : iss.uop.execute.branch.jump ? jump_target : pc_value + XLEN'(iss.uop.c ? 2 : 4);
    wb_alu_csr.npc = `RAPT_PC_LEGALIZE(XLEN, PcW, next_pc_value);
    // Control-flow target checking is centralized in the ROB. System returns
    // serialize at commit and redirect through the CSR/CMU path.
    wb_alu_csr.prd = iss.prd;
    wb_alu_csr.rd = iss.uop.rd;
    wb_alu_csr.pc = iss.uop.pc;
    wb_alu_csr.csr_wen = csr_write_enable;
    wb_alu_csr.csr_wdata = csr_wdata;
    wb_alu_csr.trap = iss.uop.trap;
    wb_alu_csr.tval = `RAPT_UOP_TVAL(XLEN, iss.uop);
    wb_alu_csr.cause = iss.uop.cause;
    wb_alu_csr.difftest_skip = |iss.uop.execute.sys.csr_csw && (iss.uop.imm[11:0] ==
      `RAPT_CSR_TIME___
      || iss.uop.imm[11:0] == `RAPT_CSR_TIMEH__ || iss.uop.imm[11:0] ==
      `RAPT_CSR_CYCLE__
      || iss.uop.imm[11:0] ==
      `RAPT_CSR_CYCLEH_
      || iss.uop.imm[11:0] == `RAPT_CSR_MCYCLE_ || iss.uop.imm[11:0] == `RAPT_CSR_MCYCLEH);
    wb_alu_csr.valid = iss.valid;
    wb_alu_csr.updates = '{
          control_flow: 1'b1,
          memory: 1'b0,
          system_state: 1'b1,
          exception: 1'b1
      };
  end
endmodule
