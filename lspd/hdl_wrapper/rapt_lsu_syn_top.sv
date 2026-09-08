`include "rapt.svh"
`include "rapt_if.svh"

// Transparent synthesis boundary. Keep committed-store control, MMU/PMP,
// completion acceptance and load-fast identity visible as independent ports.
// XLEN and payload/ROB types follow the selected preset.
module rapt_lsu_syn_top #(
    parameter int unsigned NumSlots = rapt_pkg::DispatchWidth,
    parameter int unsigned NumCompletions = rapt_pkg::CoreConfig.completion_ports,
    parameter int unsigned SQ_SIZE = rapt_pkg::CoreConfig.sq_entries,
    parameter int unsigned IOQ_SIZE = rapt_pkg::CoreConfig.ioq_entries
) (
    input logic clock,
    reset,
    input rapt_pkg::dispatch_slot_t dispatch[NumSlots],
    input rapt_pkg::completion_t completion[NumCompletions],
    input logic ioq_accept[NumSlots],
    output logic ioq_ready[NumSlots],
    cmu_bcast_if.in cmu_bcast,
    lsu_l1d_if.master lsu_l1d,
    lsu_l1d_mmu_if.master exu_l1d,
    rou_lsu_if.in rou_lsu,
    csr_bcast_if.in csr_bcast,
    pmp_update_if.in pmp_update,
    fpr_if.ioq fpr,
    load_fast_if.source load_fast,
    output rapt_pkg::completion_t exu_ioq_bcast,
    input logic wb_accept,
    output logic pmu_sq_full
);
  dpu_ioq_if #(
      .IOQ_SIZE(IOQ_SIZE),
      .Width(NumSlots)
  ) disp_ioq ();
  for (genvar s = 0; s < NumSlots; s++) begin : g_slot
    assign disp_ioq.accept[s] = ioq_accept[s];
    assign ioq_ready[s] = disp_ioq.ready[s];
  end
  rapt_lsu #(
      .NumSlots(NumSlots),
      .NumCompletions(NumCompletions),
      .SQ_SIZE(SQ_SIZE),
      .IOQ_SIZE(IOQ_SIZE)
  ) dut (
      .clock,
      .reset,
      .dispatch,
      .completion,
      .disp_ioq,
      .cmu_bcast,
      .lsu_l1d,
      .exu_l1d,
      .rou_lsu,
      .csr_bcast,
      .pmp_update,
      .fpr,
      .load_fast,
      .exu_ioq_bcast,
      .wb_accept,
      .pmu_sq_full
  );
endmodule
