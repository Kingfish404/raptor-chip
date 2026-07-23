`include "rapt.svh"
`include "rapt_if.svh"

// ALU-CSR pipe: full execution path (ALU + CSR / system / trap writeback).
//
// Pure combinational function unit + writeback drive for the ALU-CSR CDB
// port; all scheduling state lives in the upstream rapt_exu_iq instance.
// Dispatch routing guarantees this pipe never sees conditional branches
// (Branch pipe) nor MUL/DIV arithmetic (MULDIV pipe); it is the only pipe
// that handles CSR / ecall / ebreak / mret / sret / trap semantics.
module rapt_exu_pipe_alu_csr #(
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    // Issue slot from the ALU-CSR issue port
    exu_iq_iss_if.fu iss,

    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,

    // CSR read access (this pipe is the only CSR reader)
    exu_csr_if.master exu_csr,

    // Writeback (CDB port [0])
    exu_wb_if.out wb_alu_csr,

    // Dispatch-only uop payload snapshot (sys / ecall / mret / csr_* bits)
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);
  // Payload view of the issuing entry. Only the system / ecall / ebreak /
  // mret / sret / csr_csw sub-fields are consumed.
  /* verilator lint_off UNUSEDSIGNAL */
  rapt_pkg::uop_payload_t uop_payload;
  /* verilator lint_on UNUSEDSIGNAL */
  assign uop_payload = uop_pl[iss.dest];

  logic [XLEN-1:0] alu_result;
  rapt_exu_alu gen_alu (
      .s1(iss.op1),
      .s2(iss.op2),
      .op(iss.alu),
      .word(iss.word),
      .out_r(alu_result)
  );

    // Jump target: base = op1 for JALR (jren + register base), else PC.
  logic [XLEN-1:0] jump_target;
    assign jump_target = ((iss.jren ? iss.op1 : iss.pc) + iss.imm) & ~'b1;

  // CSR read + write-strobe data
  logic [XLEN-1:0] csr_wdata;
  assign exu_csr.raddr = iss.imm[11:0];
  assign csr_wdata = (
      ({XLEN{uop_payload.csr_csw[0]}} & iss.op1) |
      ({XLEN{uop_payload.csr_csw[1]}} & (exu_csr.rdata | iss.op1)) |
      ({XLEN{uop_payload.csr_csw[2]}} & (exu_csr.rdata & ~iss.op1)) |
      (0)
  );

  // instret correction: account for in-flight ROB entries before this CSR read.
  logic [$clog2(ROB_SIZE)-1:0] instret_correction;
  logic                        is_instret_read;
  assign instret_correction = (iss.dest - cmu_bcast.rob_head + 1'b1);
  assign is_instret_read = (iss.imm[11:0] ==
      `RAPT_CSR_INSTRET_
      || iss.imm[11:0] == `RAPT_CSR_MINSTRET);
  logic [XLEN-1:0] csr_rdata_corrected;
  assign csr_rdata_corrected = is_instret_read
      ? (exu_csr.rdata + XLEN'(instret_correction))
      : exu_csr.rdata;

  // === Writeback ===
  assign wb_alu_csr.dest = iss.dest;
  assign wb_alu_csr.result  = (uop_payload.sys
      ? csr_rdata_corrected
      : iss.jen
          ? iss.pc + (iss.c ? 2 : 4)
          : alu_result);
  assign wb_alu_csr.npc = (
      (uop_payload.ecall || uop_payload.ebreak)
      ? csr_bcast.mtvec
      : iss.trap
          ? csr_bcast.tvec
          : uop_payload.mret
              ? exu_csr.mepc
              : uop_payload.sret
                  ? exu_csr.sepc
                  : iss.jen
                      ? jump_target
                      : (iss.pc + (iss.c ? 2 : 4)));
    // Conditional branches never issue here (the Branch pipe owns them).
  assign wb_alu_csr.btaken = 1'b0;
  assign wb_alu_csr.mispredict = (wb_alu_csr.npc != iss.pnpc);
  assign wb_alu_csr.prd = iss.prd;
  assign wb_alu_csr.rd = iss.rd;
  assign wb_alu_csr.pc = iss.pc;
  assign wb_alu_csr.csr_wen = |uop_payload.csr_csw;
  assign wb_alu_csr.csr_wdata = csr_wdata;
  assign wb_alu_csr.trap = iss.trap;
  assign wb_alu_csr.tval = iss.tval;
  assign wb_alu_csr.cause = iss.cause;
  assign wb_alu_csr.difftest_skip = |uop_payload.csr_csw && (iss.imm[11:0] ==
      `RAPT_CSR_TIME___
      || iss.imm[11:0] ==
      `RAPT_CSR_TIMEH__
      || iss.imm[11:0] ==
      `RAPT_CSR_CYCLE__
      || iss.imm[11:0] ==
      `RAPT_CSR_MCYCLE_
      || iss.imm[11:0] == `RAPT_CSR_MCYCLEH);
  assign wb_alu_csr.valid = iss.valid;
  // ALU-CSR never produces the MEM sideband (unified exu_wb_if tie-offs).
  assign wb_alu_csr.wen = 1'b0;
  assign wb_alu_csr.alu = '0;
  assign wb_alu_csr.sq_waddr = '0;
  assign wb_alu_csr.sq_wdata = '0;

endmodule
