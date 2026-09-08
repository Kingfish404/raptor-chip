`include "rapt.svh"
`include "rapt_if.svh"

// Transparent boundary: no correlated stimulus slices or output reduction.
// Instantiate queue interfaces here so distinct queue depths are preserved.
module rapt_ieu_syn_top #(
    parameter int unsigned NumSlots = rapt_pkg::DispatchWidth,
    parameter int unsigned NumIntegerPorts = rapt_pkg::CoreConfig.integer_issue_ports,
    parameter int unsigned IntegerSystemPort = rapt_pkg::CoreConfig.integer_system_port,
    parameter int unsigned NumCompletions = rapt_pkg::CoreConfig.completion_ports,
    parameter int unsigned ALQ_SIZE = rapt_pkg::CoreConfig.iq_entries,
    parameter int unsigned BRQ_SIZE = 4,
    parameter int unsigned MDQ_SIZE = 4
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
    exu_csr_if.master exu_csr,
    input logic integer_system_issue_enable,
    input logic alq_accept[NumSlots],
    brq_accept[NumSlots],
    mdq_accept[NumSlots],
    input logic [rapt_pkg::index_bits(ALQ_SIZE)-1:0] alq_index[NumSlots],
    input logic [rapt_pkg::index_bits(BRQ_SIZE)-1:0] brq_index[NumSlots],
    input logic [rapt_pkg::index_bits(MDQ_SIZE)-1:0] mdq_index[NumSlots],
    output logic alq_free[NumSlots],
    brq_free[NumSlots],
    mdq_free[NumSlots],
    output logic [rapt_pkg::index_bits(ALQ_SIZE)-1:0] alq_free_index[NumSlots],
    output logic [rapt_pkg::index_bits(BRQ_SIZE)-1:0] brq_free_index[NumSlots],
    output logic [rapt_pkg::index_bits(MDQ_SIZE)-1:0] mdq_free_index[NumSlots],
    output rapt_pkg::completion_t wb_integer_raw[NumIntegerPorts],
    output rapt_pkg::completion_t wb_branch,
    exu_wb_mul,
    output logic pmu_ooo_valid,
    pmu_ooo_valid_found,
    pmu_ooo_full
);
  dpu_iq_if #(
      .RS_SIZE(ALQ_SIZE),
      .Width(NumSlots)
  ) disp_alq ();
  dpu_iq_if #(
      .RS_SIZE(BRQ_SIZE),
      .Width(NumSlots)
  ) disp_brq ();
  dpu_iq_if #(
      .RS_SIZE(MDQ_SIZE),
      .Width(NumSlots)
  ) disp_mdq ();
  for (genvar s = 0; s < NumSlots; s++) begin : g_slot
    assign disp_alq.accept[s] = alq_accept[s];
    assign disp_alq.rs_idx[s] = alq_index[s];
    assign alq_free[s] = disp_alq.free_found[s];
    assign alq_free_index[s] = disp_alq.free_idx[s];
    assign disp_brq.accept[s] = brq_accept[s];
    assign disp_brq.rs_idx[s] = brq_index[s];
    assign brq_free[s] = disp_brq.free_found[s];
    assign brq_free_index[s] = disp_brq.free_idx[s];
    assign disp_mdq.accept[s] = mdq_accept[s];
    assign disp_mdq.rs_idx[s] = mdq_index[s];
    assign mdq_free[s] = disp_mdq.free_found[s];
    assign mdq_free_index[s] = disp_mdq.free_idx[s];
  end
  rapt_ieu #(
      .NumSlots(NumSlots),
      .NumIntegerPorts(NumIntegerPorts),
      .IntegerSystemPort(IntegerSystemPort),
      .NumCompletions(NumCompletions),
      .ALQ_SIZE(ALQ_SIZE),
      .BRQ_SIZE(BRQ_SIZE),
      .MDQ_SIZE(MDQ_SIZE)
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
      .exu_csr,
      .integer_system_issue_enable,
      .disp_alq,
      .disp_brq,
      .disp_mdq,
      .wb_integer_raw,
      .wb_branch,
      .exu_wb_mul,
      .pmu_ooo_valid,
      .pmu_ooo_valid_found,
      .pmu_ooo_full
  );
endmodule
