`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

module rapt_memory #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int MemoryReadCredits = 8,
    parameter bit L1dWriteBack = `RAPT_L1D_WRITEBACK,
`ifdef RAPT_L2_EN
    parameter int PostedWrites = 0
`else
    parameter int PostedWrites = L1dWriteBack ? 0 : `RAPT_POSTED_WRITES
`endif
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
    // Drain completion is held for the requesting serializing ROB owner.
    output logic writeback_done_o,
    input logic stores_empty_i = 1'b1,
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
  axi4_if l2_outer_axi ();
  logic cache_coherent_ready, cache_coherent_request, cache_coherent_write;
  logic l2_probe_valid, l2_probe_ready;
  logic [XLEN-1:0] l2_probe_addr;
  logic l2_probe_release_valid, l2_probe_release_ready;
  logic [XLEN-1:0] l2_probe_release_addr, l2_probe_release_data;
  logic l2_release_valid, l2_release_ready, l2_release_ack;
  logic l2_release_has_data, l2_release_mask, l2_release_last;
  logic [XLEN-1:0] l2_release_addr, l2_release_data;
  logic l2_probe_window, l1d_writeback_bus_pending;
  logic data_idle_q;
  logic cache_writeback_drain;

  rapt_memory_drain drain_control (
      .clock(clock),
      .reset(reset),
      .request_i(writeback_drain_i),
      .stores_empty_i(stores_empty_i),
      .memory_idle_i(lsu_l1d.idle && l1d_bus.idle),
      .writeback_idle_i(writeback_idle_o),
      .drain_o(cache_writeback_drain),
      .done_o(writeback_done_o)
  );

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

  rapt_pkg::l2tlb_req_t l2tlb_req [2];
  rapt_pkg::l2tlb_rsp_t l2tlb_rsp [2];
  logic [1:0] l2tlb_ready;
  if (`RAPT_L2TLB_ENTRIES > 0) begin : g_l2tlb
    rapt_l2tlb #(
        .Entries(`RAPT_L2TLB_ENTRIES),
        .XLEN(XLEN)
    ) u_l2tlb (
        .clock(clock),
        .reset(reset),
        .flush(cmu_bcast.fence_time),
        .req_i(l2tlb_req),
        .ready_o(l2tlb_ready),
        .rsp_o(l2tlb_rsp)
    );
  end else begin : g_no_l2tlb
    assign l2tlb_ready = '0;
    assign l2tlb_rsp[0] = '0;
    assign l2tlb_rsp[1] = '0;
  end

  rapt_l1i #(
      .L2Tlb(`RAPT_L2TLB_ENTRIES > 0)
  ) l1i_cache (
      .l2tlb_req_o(l2tlb_req[0]),
      .l2tlb_ready_i(l2tlb_ready[0]),
      .l2tlb_rsp_i(l2tlb_rsp[0]),
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
      .WriteBack(L1dWriteBack),
      .L2Tlb(`RAPT_L2TLB_ENTRIES > 0)
  ) l1d_cache (
      .l2tlb_req_o(l2tlb_req[1]),
      .l2tlb_ready_i(l2tlb_ready[1]),
      .l2tlb_rsp_i(l2tlb_rsp[1]),
      .clock(clock),
      .reset(reset),
      .coherent_ready(cache_coherent_ready),
      .coherent_request(cache_coherent_request),
      .coherent_write(cache_coherent_write),
      .probe_valid_i(l2_probe_valid),
      .probe_addr_i(l2_probe_addr),
      .probe_ready_o(l2_probe_ready),
      .probe_release_valid_o(l2_probe_release_valid),
      .probe_release_addr_o(l2_probe_release_addr),
      .probe_release_data_o(l2_probe_release_data),
      .probe_release_ready_i(l2_probe_release_ready),
      .release_valid_o(l2_release_valid),
      .release_addr_o(l2_release_addr),
      .release_data_o(l2_release_data),
      .release_has_data_o(l2_release_has_data),
      .release_mask_o(l2_release_mask),
      .release_last_o(l2_release_last),
      .release_ready_i(l2_release_ready),
      .release_ack_i(l2_release_ack),
      .probe_window_i(l2_probe_window),
      .writeback_bus_pending_o(l1d_writeback_bus_pending),
      .writeback_error(writeback_error_o),
      .writeback_idle(writeback_idle_o),
      .writeback_drain(cache_writeback_drain),
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

  rapt_bus #(
      .XLEN(XLEN),
      .PostedWrites(PostedWrites)
  ) bus (
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
      .MAX_READ_OUTSTANDING(MemoryReadCredits),
      .MAX_WRITE_OUTSTANDING(PostedWrites > 0 ? PostedWrites : 1)
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
      .probe_valid_o(l2_probe_valid),
      .probe_addr_o(l2_probe_addr),
      .probe_ready_i(l2_probe_ready),
      .probe_release_valid_i(l2_probe_release_valid),
      .probe_release_addr_i(l2_probe_release_addr),
      .probe_release_data_i(l2_probe_release_data),
      .probe_release_ready_o(l2_probe_release_ready),
      .release_valid_i(l2_release_valid),
      .release_addr_i(l2_release_addr),
      .release_data_i(l2_release_data),
      .release_has_data_i(l2_release_has_data),
      .release_mask_i(l2_release_mask),
      .release_last_i(l2_release_last),
      .release_ready_o(l2_release_ready),
      .release_ack_o(l2_release_ack),
      .l1d_writeback_pending_i(l1d_writeback_bus_pending),
      .probe_window_o(l2_probe_window),
      .axi_s(l2_axi),
      .axi_m(l2_outer_axi)
  );

  rapt_axi_r_buffer #(
      .XLEN(XLEN),
`ifdef RAPT_L2_STORE_WRITEBACK
      .Enable(1'b1)
`else
      .Enable(1'b0)
`endif
  ) outer_r_buffer (
      .clock,
      .reset,
      .upstream(l2_outer_axi),
      .downstream(io_master)
  );
endmodule
