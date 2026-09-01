`include "rapt.svh"
`include "rapt_if.svh"

module rapt_lsu #(
    parameter unsigned SQ_SIZE  = `RAPT_SQ_SIZE,
    parameter unsigned IOQ_SIZE = `RAPT_IOQ_SIZE,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,
    cmu_bcast_if.in cmu_bcast,
    lsu_l1d_if.master lsu_l1d,
    lsu_l1d_mmu_if.master exu_l1d,
    rou_exu_if.monitor rou_exu,
    dpu_ioq_if.ioq disp_ioq,
    cdb_if.in wb_alu_csr,
    cdb_if.in wb_alu,
    cdb_if.in exu_wb_mul,
    cdb_if exu_ioq_bcast,
    rou_lsu_if.in rou_lsu,
    csr_bcast_if.in csr_bcast,
    pmp_update_if.in pmp_update,
    fpr_if.ioq fpr,
    load_fast_if.source load_fast,
    output logic pmu_sq_full
);
  lsu_pipe_if #(.XLEN(XLEN)) exu_lsu ();
  pmp_state_if #(.XLEN(XLEN)) pmp_state ();
  logic pmu_ioq_full_unused;

  rapt_pmp_state pmp_state_regs (
      .clock,
      .reset,
      .update(pmp_update),
      .state (pmp_state)
  );

  rapt_lsu_ioq #(
      .IOQ_SIZE(IOQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_ioq (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .csr_bcast    (csr_bcast),
      .pmp_state    (pmp_state),
      .rou_exu      (rou_exu),
      .disp         (disp_ioq),
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_wb_mul   (exu_wb_mul),
      .exu_lsu      (exu_lsu),
      .exu_l1d      (exu_l1d),
      .fpr          (fpr),
      .exu_ioq_bcast(exu_ioq_bcast),
      .load_fast    (load_fast),
      .pmu_ioq_full (pmu_ioq_full_unused)
  );

  rapt_lsu_sq #(
      .SQ_SIZE(SQ_SIZE),
      .XLEN   (XLEN)
  ) u_sq (
      .clock        (clock),
      .cmu_bcast    (cmu_bcast),
      .lsu_l1d      (lsu_l1d),
      .exu_lsu      (exu_lsu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .rou_lsu      (rou_lsu),
      .csr_bcast    (csr_bcast),
      .pmp_state    (pmp_state),
      .pmu_sq_full  (pmu_sq_full),
      .reset        (reset)
  );
endmodule
