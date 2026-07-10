`include "rapt.svh"
`include "rapt_if.svh"

// ALU-A pipe: full execution path (ALU + CSR / system / trap writeback).
//
// Pure combinational function unit + writeback drive for the exu_rou CDB
// port; all scheduling state lives in the upstream rapt_exu_iq instance.
// Dispatch routing guarantees this pipe never sees conditional branches
// (BRU pipe) nor MUL/DIV arithmetic (MULDIV pipe); it is the only pipe
// that handles CSR / ecall / ebreak / mret / sret / trap semantics.
module rapt_exu_pipe_a #(
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    // Issue slot from the ALU-A issue queue
    exu_iq_iss_if.fu iss,

    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,

    // CSR read access (this pipe is the only CSR reader)
    exu_csr_if.master exu_csr,

    // Writeback (CDB port [0])
    exu_wb_if.out exu_rou,

    // Dispatch-only uop payload snapshot (sys / ecall / mret / csr_* bits)
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);
  // Payload view of the issuing entry. Only the system / ecall / ebreak /
  // mret / sret / csr_csw sub-fields are consumed.
  /* verilator lint_off UNUSEDSIGNAL */
  rapt_pkg::uop_payload_t pl_a;
  /* verilator lint_on UNUSEDSIGNAL */
  assign pl_a = uop_pl[iss.dest];

  logic [XLEN-1:0] alu_result_a;
  rapt_exu_alu gen_alu_a (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.alu),
      .word(iss.word),
      .out_r(alu_result_a)
  );

  // Jump target: base = op1 for JALR (jen + register base), else PC.
  logic [XLEN-1:0] addr_exu_a;
  assign addr_exu_a = ((iss.jen ? iss.op1 : iss.pc) + iss.imm) & ~'b1;

  // CSR read + write-strobe data
  logic [XLEN-1:0] csr_wdata_a;
  assign exu_csr.raddr = iss.imm[11:0];
  assign csr_wdata_a = (
      ({XLEN{pl_a.csr_csw[0]}} & iss.op1) |
      ({XLEN{pl_a.csr_csw[1]}} & (exu_csr.rdata | iss.op1)) |
      ({XLEN{pl_a.csr_csw[2]}} & (exu_csr.rdata & ~iss.op1)) |
      (0)
  );

  // instret correction: account for in-flight ROB entries before this CSR read.
  logic [$clog2(ROB_SIZE)-1:0] instret_correction_a;
  logic                        is_instret_read_a;
  assign instret_correction_a = (iss.dest - cmu_bcast.rob_head + 1'b1);
  assign is_instret_read_a = (iss.imm[11:0] ==
      `RAPT_CSR_INSTRET_
      || iss.imm[11:0] == `RAPT_CSR_MINSTRET);
  logic [XLEN-1:0] csr_rdata_corrected_a;
  assign csr_rdata_corrected_a = is_instret_read_a
      ? (exu_csr.rdata + XLEN'(instret_correction_a))
      : exu_csr.rdata;

  // === Writeback ===
  assign exu_rou.dest = iss.dest;
  assign exu_rou.result  = (pl_a.sys
      ? csr_rdata_corrected_a
      : iss.jen
          ? iss.pc + (iss.c ? 2 : 4)
          : alu_result_a);
  assign exu_rou.npc = (
      (pl_a.ecall || pl_a.ebreak)
      ? csr_bcast.mtvec
      : iss.trap
          ? csr_bcast.tvec
          : pl_a.mret
              ? exu_csr.mepc
              : pl_a.sret
                  ? exu_csr.sepc
                  : iss.jen
                      ? addr_exu_a
                      : (iss.pc + (iss.c ? 2 : 4)));
  // Conditional branches never issue here (BRU pipe owns them).
  assign exu_rou.btaken = 1'b0;
  assign exu_rou.mispredict = (exu_rou.npc != iss.pnpc);
  assign exu_rou.prd = iss.prd;
  assign exu_rou.rd = iss.rd;
  assign exu_rou.pc = iss.pc;
  assign exu_rou.csr_wen = |pl_a.csr_csw;
  assign exu_rou.csr_wdata = csr_wdata_a;
  assign exu_rou.trap = iss.trap;
  assign exu_rou.tval = iss.tval;
  assign exu_rou.cause = iss.cause;
  assign exu_rou.difftest_skip = |pl_a.csr_csw && (iss.imm[11:0] ==
      `RAPT_CSR_TIME___
      || iss.imm[11:0] ==
      `RAPT_CSR_TIMEH__
      || iss.imm[11:0] ==
      `RAPT_CSR_CYCLE__
      || iss.imm[11:0] ==
      `RAPT_CSR_MCYCLE_
      || iss.imm[11:0] == `RAPT_CSR_MCYCLEH);
  assign exu_rou.valid = iss.valid;
  // ALU-A never produces the MEM sideband (unified exu_wb_if tie-offs).
  assign exu_rou.wen = 1'b0;
  assign exu_rou.alu = '0;
  assign exu_rou.sq_waddr = '0;
  assign exu_rou.sq_wdata = '0;

endmodule
