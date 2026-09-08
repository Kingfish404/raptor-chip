`include "rapt.svh"
`include "rapt_if.svh"

module rapt_lsu #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type SlotT = rapt_pkg::dispatch_slot_t,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned SQ_SIZE  = Cfg.sq_entries,
    parameter unsigned IOQ_SIZE = Cfg.ioq_entries,
    parameter unsigned ROB_SIZE = Cfg.rob_entries,
    parameter unsigned PLEN     = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned RLEN     = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned XLEN     = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input clock,
    input reset,
    cmu_bcast_if.in cmu_bcast,
    lsu_l1d_if.master lsu_l1d,
    lsu_l1d_mmu_if.master exu_l1d,
    input SlotT dispatch[NumSlots],
    dpu_ioq_if.ioq disp_ioq,

    output CompletionT exu_ioq_bcast,
    input logic wb_accept,
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
  logic [XLEN-1:0] sq_waddr_hi;
  logic [XLEN-1:0] sq_waddr_third;
  logic [2:0][1:0] sq_wpbmt;
  logic sq_acquire;

  rapt_pmp_state pmp_state_regs (
      .clock(clock),
      .reset(reset),
      .update(pmp_update),
      .state (pmp_state)
  );

  rapt_lsu_ioq #(
      .SlotT(SlotT),
      .NumSlots(NumSlots),
      .Cfg(Cfg),
      .NumCompletions(NumCompletions),
      .CompletionT(CompletionT),
      .IOQ_SIZE(IOQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_ioq (
      .completion(completion),
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .csr_bcast    (csr_bcast),
      .pmp_state    (pmp_state),
      .dispatch(dispatch),
      .disp         (disp_ioq),

      .exu_lsu      (exu_lsu),
      .exu_l1d      (exu_l1d),
      .fpr          (fpr),
      .exu_ioq_bcast(exu_ioq_bcast),
      .wb_accept   (wb_accept),
      .sq_waddr_hi  (sq_waddr_hi),
      .sq_waddr_third(sq_waddr_third),
      .sq_wpbmt(sq_wpbmt),
      .sq_acquire(sq_acquire),
      .load_fast    (load_fast),
      .pmu_ioq_full (pmu_ioq_full_unused)
  );

  rapt_lsu_sq #(
      .CompletionT(CompletionT),
      .SQ_SIZE(SQ_SIZE),
      .XLEN   (XLEN)
  ) u_sq (
      .clock        (clock),
      .cmu_bcast    (cmu_bcast),
      .lsu_l1d      (lsu_l1d),
      .exu_lsu      (exu_lsu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .completion_accept(wb_accept),
      .sq_waddr_hi  (sq_waddr_hi),
      .sq_waddr_third(sq_waddr_third),
      .sq_wpbmt(sq_wpbmt),
      .sq_acquire(sq_acquire),
      .rou_lsu      (rou_lsu),
      .csr_bcast    (csr_bcast),
      .pmp_state    (pmp_state),
      .pmu_sq_full  (pmu_sq_full),
      .reset        (reset)
  );
endmodule
