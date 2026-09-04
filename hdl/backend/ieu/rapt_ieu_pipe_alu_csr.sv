`include "rapt.svh"
`include "rapt_if.svh"

// Integer ALU, CSR, system and trap execution pipe. Scalar floating-point
// arithmetic is owned by rapt_feu.
module rapt_ieu_pipe_alu_csr #(
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    cmu_bcast_if.in cmu_bcast,
    iq_iss_if.fu iss,
    csr_bcast_if.in csr_bcast,
    exu_csr_if.master exu_csr,
    cdb_if.out wb_alu_csr,
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);
  rapt_pkg::uop_payload_t uop_payload;
  assign uop_payload = uop_pl[iss.dest];

  logic [XLEN-1:0] alu_result;
  rapt_ieu_alu gen_alu (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.alu),
      .word(iss.word),
      .out_r(alu_result)
  );

  logic [XLEN-1:0] jump_target;
  logic [XLEN-1:0] csr_wdata;
  logic csr_write_enable;
  assign jump_target = ((iss.jren ? iss.op1 : iss.pc) + iss.imm) & ~'b1;
  assign exu_csr.raddr = iss.imm[11:0];
  assign csr_write_enable = uop_payload.csr_csw[0]
    || ((uop_payload.csr_csw[1] || uop_payload.csr_csw[2]) && |iss.op1);
  assign csr_wdata = ({XLEN{uop_payload.csr_csw[0]}} & iss.op1)
    | ({XLEN{uop_payload.csr_csw[1]}} & (exu_csr.rdata | iss.op1))
    | ({XLEN{uop_payload.csr_csw[2]}} & (exu_csr.rdata & ~iss.op1));

  assign wb_alu_csr.dest = iss.dest;
  // CSR instructions are serializing, so by the time one executes all older
  // instructions have already updated minstret. The CSR instruction itself
  // must not be included in the value it reads; the former ROB-distance + 1
  // correction therefore made every rdinstret result at least one too large.
  assign wb_alu_csr.result = uop_payload.sys ? exu_csr.rdata
    : iss.jen ? iss.pc + (iss.c ? 2 : 4) : alu_result;
  assign wb_alu_csr.npc = (uop_payload.ecall || uop_payload.ebreak) ? csr_bcast.mtvec
    : iss.trap ? csr_bcast.tvec
    : uop_payload.mret ? exu_csr.mepc
    : uop_payload.sret ? exu_csr.sepc
    : iss.jen ? jump_target : iss.pc + (iss.c ? 2 : 4);
  assign wb_alu_csr.mispredict = wb_alu_csr.npc != iss.pnpc;
  assign wb_alu_csr.prd = iss.prd;
  assign wb_alu_csr.rd = iss.rd;
  assign wb_alu_csr.pc = iss.pc;
  assign wb_alu_csr.csr_wen = csr_write_enable;
  assign wb_alu_csr.csr_wdata = csr_wdata;
  assign wb_alu_csr.fp_flags_valid = 1'b0;
  assign wb_alu_csr.fp_flags = '0;
  assign wb_alu_csr.trap = iss.trap;
  assign wb_alu_csr.tval = iss.tval;
  assign wb_alu_csr.cause = iss.cause;
  assign wb_alu_csr.difftest_skip = |uop_payload.csr_csw && (iss.imm[11:0] ==
      `RAPT_CSR_TIME___
      || iss.imm[11:0] == `RAPT_CSR_TIMEH__ || iss.imm[11:0] ==
      `RAPT_CSR_CYCLE__
      || iss.imm[11:0] == `RAPT_CSR_MCYCLE_ || iss.imm[11:0] == `RAPT_CSR_MCYCLEH);
  assign wb_alu_csr.valid = iss.valid;
  assign wb_alu_csr.btaken = 1'b0;
  assign wb_alu_csr.wen = 1'b0;
  assign wb_alu_csr.alu = '0;
  assign wb_alu_csr.sq_waddr = '0;
  assign wb_alu_csr.sq_wdata = '0;
  assign wb_alu_csr.sq_wdata64 = '0;
  assign wb_alu_csr.sq_fp64 = 1'b0;
endmodule
