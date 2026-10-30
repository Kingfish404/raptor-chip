`include "rapt.svh"
`include "rapt_if.svh"

// Transparent functional boundary, including load-fast confirmation and
// writeback backpressure. XLEN and payload types follow the selected preset.
module rapt_feu_syn_top #(
    parameter int unsigned NumSlots = rapt_pkg::DispatchWidth,
    parameter int unsigned NumCompletions = rapt_pkg::CoreConfig.completion_ports,
    parameter int unsigned FPQ_SIZE = rapt_pkg::CoreConfig.iq_entries
) (
    input logic [1:0][rapt_pkg::PLENPkg-1:0] int_source_regs[NumSlots],
    input logic [2:0][rapt_pkg::index_bits(rapt_pkg::CoreConfig.rob_entries):0]
        fp_dispatch_tag[NumSlots],
    input logic [2:0][rapt_pkg::CoreConfig.rob_generation_bits-1:0]
        fp_dispatch_generation[NumSlots],
    input logic fp_retire_valid[rapt_pkg::CommitWidth],
    input logic [63:0] fp_retire_value[rapt_pkg::CommitWidth],
    input logic [rapt_pkg::index_bits(rapt_pkg::CoreConfig.rob_entries)-1:0]
        fp_retire_owner[rapt_pkg::CommitWidth],
    input logic [rapt_pkg::CoreConfig.rob_generation_bits-1:0]
        fp_retire_generation[rapt_pkg::CommitWidth],
    output rapt_pkg::uop_t fp_queue_read_uop,
    output logic [2:0][rapt_pkg::index_bits(rapt_pkg::CoreConfig.rob_entries):0] fp_queue_read_tag,
    input logic [2:0][63:0] operand_read_value,
    input logic [2:0][rapt_pkg::index_bits(rapt_pkg::CoreConfig.rob_entries):0] fp_queue_ready_tag,
    input logic [2:0][rapt_pkg::CoreConfig.rob_generation_bits-1:0] fp_queue_read_generation,
    output logic [rapt_pkg::PLENPkg-1:0] int_operand_address,
    input logic [`RAPT_XLEN-1:0] int_operand_value,
    input logic int_operand_valid,
    input logic clock,
    reset,
    cancel_valid,
    input logic [$clog2(rapt_pkg::CoreConfig.rob_entries)-1:0] cancel_head,
    cancel_owner,
    input rapt_pkg::dispatch_slot_t dispatch[NumSlots],
    input rapt_pkg::completion_t completion[NumCompletions],
    input rapt_pkg::completion_t early_completion[NumCompletions],
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
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
      .early_completion,
      .int_source_regs,
      .fp_dispatch_tag,
      .fp_dispatch_generation,
      .fp_retire_valid,
      .fp_retire_value,
      .fp_retire_owner,
      .fp_retire_generation,
      .fp_queue_read_uop,
      .fp_queue_read_tag,
      .operand_read_value,
      .fp_queue_ready_tag,
      .fp_queue_read_generation,
      .int_operand_address,
      .int_operand_value,
      .int_operand_valid,
      .clock,
      .reset,
      .cancel_valid,
      .cancel_head,
      .cancel_owner,
      .dispatch,
      .completion,
      .cmu_bcast,
      .csr_bcast,
      .disp_fpq,
      .wb_fpu,
      .wb_accept,
      .issue_enable
  );
endmodule
