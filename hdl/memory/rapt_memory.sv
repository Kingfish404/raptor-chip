`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

module rapt_memory #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int MemoryReadCredits = 8,
    parameter bit L1dWriteBack = 1'b0
) (
    input logic clock,
    input logic reset,
    ifu_l1i_if.slave ifu_l1i,
    lsu_l1d_if.slave lsu_l1d,
    lsu_l1d_mmu_if.slave exu_l1d,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    pmp_update_if.in pmp_update,
    axi4_if.master io_master,
    input logic ifetch_io_authorized_i,
    output logic ifetch_io_start_o,
    output logic [XLEN-1:0] ifetch_io_owner_pc_o,
    output logic data_idle_o,
    output logic writeback_idle_o,
    input logic writeback_drain_i = 1'b0,
    output logic writeback_error_o,
    input logic external_write_valid_i = 1'b0,
    input logic external_write_pending_i = 1'b0,
    input logic [XLEN-1:0] external_write_first_i = '0,
    input logic [XLEN-1:0] external_write_last_i = '0
);
  pmp_state_if pmp_fetch_state ();
  l1i_bus_if l1i_bus ();
  l1d_bus_if l1d_bus ();
  mem_link_if memory_link ();
  axi4_if l2_axi ();
  logic cache_coherent_ready, cache_coherent_request, cache_coherent_write;
  logic data_idle_q;

  // IO instruction fetches need a quiescent data side, but the live bus-idle
  // expression includes DTLB/PMP request generation.  Sampling quiescence
  // here keeps that cross-cache path out of the L1I request decision.  Reset
  // is conservative; an IO fetch waits for one observed idle cycle.
  always_ff @(posedge clock) begin
    if (reset) data_idle_q <= 1'b0;
    else data_idle_q <= lsu_l1d.idle && l1d_bus.idle;
  end
  assign data_idle_o = data_idle_q;

  rapt_pmp_state pmp_fetch_state_regs (
      .clock(clock),
      .reset(reset),
      .update(pmp_update),
      .state(pmp_fetch_state)
  );

  rapt_l1i l1i_cache (
      .clock(clock),
      .reset(reset),
      .io_authorized(ifetch_io_authorized_i),
      .io_start(ifetch_io_start_o),
      .io_owner_pc(ifetch_io_owner_pc_o),
      .cmu_bcast(cmu_bcast),
      .ifu_l1i(ifu_l1i),
      .l1i_bus(l1i_bus),
      .csr_bcast(csr_bcast),
      .pmp_state(pmp_fetch_state)
  );

  rapt_l1d #(
      .WriteBack(L1dWriteBack)
  ) l1d_cache (
      .clock(clock),
      .reset(reset),
      .coherent_ready(cache_coherent_ready),
      .coherent_request(cache_coherent_request),
      .coherent_write(cache_coherent_write),
      .writeback_error(writeback_error_o),
      .writeback_idle(writeback_idle_o),
      .writeback_drain(writeback_drain_i),
      .external_write_valid_i(external_write_valid_i),
      .external_write_pending_i(external_write_pending_i),
      .external_write_first_i(external_write_first_i),
      .external_write_last_i(external_write_last_i),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d)
  );

  rapt_bus bus (
      .clock(clock),
      .reset(reset),
      .coherent_ready(cache_coherent_ready),
      .coherent_request(cache_coherent_request),
      .coherent_write(cache_coherent_write),
      .mem(memory_link),
      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast)
  );

  rapt_axi_master #(
      .XLEN(XLEN),
      .MAX_READ_OUTSTANDING(MemoryReadCredits)
  ) axi_master (
      .clock(clock),
      .reset(reset),
      .mem(memory_link),
      .axi(l2_axi)
  );

  rapt_l2 l2 (
      .clock(clock),
      .reset(reset),
      .cbo_inval_i(cmu_bcast.cbo_inval),
      .cbo_block_i(cmu_bcast.cbo_block),
      .axi_s(l2_axi),
      .axi_m(io_master)
  );
endmodule
