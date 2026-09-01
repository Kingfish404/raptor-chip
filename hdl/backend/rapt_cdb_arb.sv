`include "rapt.svh"
`include "rapt_if.svh"

module rapt_cdb_arb (
    input logic clock,
    input logic reset,

    input logic alu_csr_pipe_enable,
    input logic fpu_issue_enable,

    cdb_if.in  wb_alu_csr_raw,
    cdb_if.in  wb_fpu,
    cdb_if.out wb_alu_csr,

    output logic alu_csr_issue_enable
);
  // FP has priority because a multi-cycle FMA/divsqrt may complete while the
  // FPQ is blocked. Keep CSR reads of FFLAGS behind the same ownership gate.
  assign alu_csr_issue_enable = alu_csr_pipe_enable && !wb_fpu.valid && fpu_issue_enable;

  assign wb_alu_csr.pc = wb_fpu.valid ? wb_fpu.pc : wb_alu_csr_raw.pc;
  assign wb_alu_csr.npc = wb_fpu.valid ? wb_fpu.npc : wb_alu_csr_raw.npc;
  assign wb_alu_csr.btaken = wb_fpu.valid ? wb_fpu.btaken : wb_alu_csr_raw.btaken;
  assign wb_alu_csr.mispredict = wb_fpu.valid ? wb_fpu.mispredict : wb_alu_csr_raw.mispredict;
  assign wb_alu_csr.dest = wb_fpu.valid ? wb_fpu.dest : wb_alu_csr_raw.dest;
  assign wb_alu_csr.result = wb_fpu.valid ? wb_fpu.result : wb_alu_csr_raw.result;
  assign wb_alu_csr.prd = wb_fpu.valid ? wb_fpu.prd : wb_alu_csr_raw.prd;
  assign wb_alu_csr.rd = wb_fpu.valid ? wb_fpu.rd : wb_alu_csr_raw.rd;
  assign wb_alu_csr.csr_wen = wb_fpu.valid ? wb_fpu.csr_wen : wb_alu_csr_raw.csr_wen;
  assign wb_alu_csr.csr_wdata = wb_fpu.valid ? wb_fpu.csr_wdata : wb_alu_csr_raw.csr_wdata;
  assign wb_alu_csr.fp_flags_valid = wb_fpu.valid ? wb_fpu.fp_flags_valid
      : wb_alu_csr_raw.fp_flags_valid;
  assign wb_alu_csr.fp_flags = wb_fpu.valid ? wb_fpu.fp_flags : wb_alu_csr_raw.fp_flags;
  assign wb_alu_csr.wen = wb_fpu.valid ? wb_fpu.wen : wb_alu_csr_raw.wen;
  assign wb_alu_csr.alu = wb_fpu.valid ? wb_fpu.alu : wb_alu_csr_raw.alu;
  assign wb_alu_csr.sq_waddr = wb_fpu.valid ? wb_fpu.sq_waddr : wb_alu_csr_raw.sq_waddr;
  assign wb_alu_csr.sq_wdata = wb_fpu.valid ? wb_fpu.sq_wdata : wb_alu_csr_raw.sq_wdata;
  assign wb_alu_csr.sq_wdata64 = wb_fpu.valid ? wb_fpu.sq_wdata64 : wb_alu_csr_raw.sq_wdata64;
  assign wb_alu_csr.sq_fp64 = wb_fpu.valid ? wb_fpu.sq_fp64 : wb_alu_csr_raw.sq_fp64;
  assign wb_alu_csr.trap = wb_fpu.valid ? wb_fpu.trap : wb_alu_csr_raw.trap;
  assign wb_alu_csr.tval = wb_fpu.valid ? wb_fpu.tval : wb_alu_csr_raw.tval;
  assign wb_alu_csr.cause = wb_fpu.valid ? wb_fpu.cause : wb_alu_csr_raw.cause;
  assign wb_alu_csr.difftest_skip = wb_fpu.valid ? wb_fpu.difftest_skip
      : wb_alu_csr_raw.difftest_skip;
  assign wb_alu_csr.valid = wb_fpu.valid ? 1'b1 : wb_alu_csr_raw.valid;

  // Both producers share CDB0. The issue gate above must keep their valid
  // pulses mutually exclusive; otherwise the fixed FP priority would drop an
  // integer/CSR completion.
  `RAPT_SVA(clock, reset, CDB0_PRODUCERS_EXCLUSIVE, !(wb_fpu.valid && wb_alu_csr_raw.valid))
endmodule
