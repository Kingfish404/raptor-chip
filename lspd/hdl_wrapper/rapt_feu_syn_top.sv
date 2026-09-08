`include "rapt.svh"
`include "rapt_if.svh"

// Transparent functional boundary, including load-fast confirmation and
// writeback backpressure. XLEN and payload types follow the selected preset.
module rapt_feu_syn_top #(
    parameter int unsigned NumSlots = rapt_pkg::DispatchWidth,
    parameter int unsigned NumCompletions = rapt_pkg::CoreConfig.completion_ports,
    parameter int unsigned FPQ_SIZE = 4
) (
    input logic clock,
    reset,
    cancel_valid,
    input logic [$clog2(rapt_pkg::CoreConfig.rob_entries)-1:0] cancel_head,
    cancel_owner,
    input rapt_pkg::dispatch_slot_t dispatch[NumSlots],
    input rapt_pkg::completion_t completion[NumCompletions],
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    load_fast_if.sink load_fast,
    fpr_if.alu fpr,
    input logic fpq_accept[NumSlots],
    input logic [rapt_pkg::index_bits(FPQ_SIZE)-1:0] fpq_index[NumSlots],
    output logic fpq_free[NumSlots],
    output logic [rapt_pkg::index_bits(FPQ_SIZE)-1:0] fpq_free_index[NumSlots],
    output rapt_pkg::completion_t wb_fpu,
    input logic wb_accept,
    output logic issue_enable
);
  dpu_iq_if #(
      .RS_SIZE(FPQ_SIZE),
      .Width(NumSlots)
  ) disp_fpq ();
  for (genvar s = 0; s < NumSlots; s++) begin : g_slot
    assign disp_fpq.accept[s] = fpq_accept[s];
    assign disp_fpq.rs_idx[s] = fpq_index[s];
    assign fpq_free[s] = disp_fpq.free_found[s];
    assign fpq_free_index[s] = disp_fpq.free_idx[s];
  end
  rapt_feu #(
      .NumSlots(NumSlots),
      .NumCompletions(NumCompletions),
      .FPQ_SIZE(FPQ_SIZE)
  ) dut (
      .clock,
      .reset,
      .cancel_valid,
      .cancel_head,
      .cancel_owner,
      .dispatch,
      .completion,
      .cmu_bcast,
      .csr_bcast,
      .load_fast,
      .fpr,
      .disp_fpq,
      .wb_fpu,
      .wb_accept,
      .issue_enable
  );
endmodule
