`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Per-hart memory block: L1I, L1D, TLBs/PTWs, PMP and the bus interface
// unit (rapt_bus). Every access leaves through the L2 client port; AXI,
// outstanding-transaction management and any L2 cache live in the L2
// subsystem outside the core (rapt_l2_subsystem).
module rapt_memory #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit L1dWriteBack = `RAPT_L1D_WRITEBACK,
    parameter bit TargetedCoherence = `RAPT_L1D_TARGETED_COHERENCE,
    // Capabilities of the L2 subsystem behind this hart.
    parameter rapt_pkg::l2_link_config_t L2Link = rapt_pkg::L2LinkConfig
) (
    input logic clock,
    input logic reset,
    ifu_l1i_if.slave ifu_l1i,
    lsu_l1d_if.slave lsu_l1d,
    lsu_l1d_mmu_if.slave exu_l1d,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    pmp_update_if.in pmp_update,
    l2_client_if.client l2_client,
    input logic ifetch_io_authorized_i,
    output logic ifetch_io_start_o,
    output logic [`RAPT_PC_BITS_OF(XLEN)-1:0] ifetch_io_owner_pc_o,
    output logic data_idle_o,
    output logic writeback_idle_o,
    // Drain completion is held for the requesting serializing ROB owner.
    output logic writeback_done_o,
    input logic stores_empty_i = 1'b1,
    input logic writeback_drain_i = 1'b0,
    input logic writeback_clean_i = 1'b1,
    input logic writeback_cbo_i = 1'b0,
    input logic writeback_cbo_invalidate_i = 1'b0,
    input logic [XLEN-1:6] writeback_block_i = '0,
    output logic writeback_error_o,
    input logic external_write_valid_i = 1'b0,
    input logic external_write_pending_i = 1'b0,
    input logic [XLEN-1:0] external_write_first_i = '0,
    input logic [XLEN-1:0] external_write_last_i = '0
);
  localparam int PostedWrites = L2Link.posted_writes;
  pmp_state_if pmp_fetch_state ();
  l1i_bus_if l1i_bus ();
  l1d_bus_if l1d_bus ();
  mem_link_if memory_link ();
  logic memory_read_cacheable;
  logic cache_coherent_ready, cache_coherent_request, cache_coherent_write;
  logic data_idle_q;
  logic cache_writeback_drain, cache_cbo_done, cache_cbo_active_q;
  logic [XLEN-1:0] cache_coherent_addr;

  // Start block maintenance only after older refills and SQ writes finish.
  // Hold the owner once armed: maintenance itself temporarily deasserts idle.
  always_ff @(posedge clock) begin
    if (reset || !TargetedCoherence || !cache_writeback_drain) cache_cbo_active_q <= 1'b0;
    else if (writeback_cbo_i && stores_empty_i && lsu_l1d.idle && l1d_bus.idle)
      cache_cbo_active_q <= 1'b1;
  end

  `RAPT_SVA_IMPLY(
      clock, reset, CBO_START_OBSERVED_QUIESCENCE, $rose(cache_cbo_active_q),
      $past(
          cache_writeback_drain && writeback_cbo_i && stores_empty_i && lsu_l1d.idle && l1d_bus.idle))

  rapt_memory_drain drain_control (
      .clock(clock),
      .reset(reset),
      .request_i(writeback_drain_i),
      .stores_empty_i(stores_empty_i),
      .memory_idle_i(lsu_l1d.idle && l1d_bus.idle),
      .writeback_idle_i((!TargetedCoherence || writeback_clean_i) ? writeback_idle_o
          : writeback_cbo_i ? cache_cbo_done : 1'b1),
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
        .flush(`RAPT_SFENCE_SELECTIVE == 0 && cmu_bcast.fence_time),
        .cancel(cmu_bcast.fence_time),
        .sfence_valid(cmu_bcast.sfence_valid),
        .sfence_vpn(cmu_bcast.sfence_vpn),
        .sfence_asid(cmu_bcast.sfence_asid),
        .sfence_all_vpn(cmu_bcast.sfence_all_vpn),
        .sfence_all_asid(cmu_bcast.sfence_all_asid),
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
      .L2Tlb(`RAPT_L2TLB_ENTRIES > 0),
      .L2Cache(L2Link.cache),
      .L2LineOffset(L2Link.line_offset)
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
      .TargetedCoherence(TargetedCoherence),
      .L2Tlb(`RAPT_L2TLB_ENTRIES > 0),
      .L2Cache(L2Link.cache),
      .L2Inclusive(L2Link.inclusive),
      .L2Release(L2Link.victim_release),
      .L2LineOffset(L2Link.line_offset)
  ) l1d_cache (
      .l2tlb_req_o(l2tlb_req[1]),
      .l2tlb_ready_i(l2tlb_ready[1]),
      .l2tlb_rsp_i(l2tlb_rsp[1]),
      .clock(clock),
      .reset(reset),
      .coherent_ready(cache_coherent_ready),
      .coherent_request(cache_coherent_request),
      .coherent_write(cache_coherent_write),
      .coherent_addr(cache_coherent_addr),
      .probe_valid_i(l2_client.probe_valid),
      .probe_addr_i(l2_client.probe_addr),
      .probe_ready_o(l2_client.probe_ready),
      .probe_release_valid_o(l2_client.probe_release_valid),
      .probe_release_addr_o(l2_client.probe_release_addr),
      .probe_release_data_o(l2_client.probe_release_data),
      .probe_release_ready_i(l2_client.probe_release_ready),
      .release_valid_o(l2_client.release_valid),
      .release_addr_o(l2_client.release_addr),
      .release_data_o(l2_client.release_data),
      .release_has_data_o(l2_client.release_has_data),
      .release_mask_o(l2_client.release_mask),
      .release_last_o(l2_client.release_last),
      .release_ready_i(l2_client.release_ready),
      .release_ack_i(l2_client.release_ack),
      .probe_window_i(l2_client.probe_window),
      .writeback_bus_pending_o(l2_client.writeback_pending),
      .writeback_error(writeback_error_o),
      .writeback_idle(writeback_idle_o),
      .writeback_drain(cache_writeback_drain && (!TargetedCoherence || writeback_clean_i)),
      .writeback_cbo(TargetedCoherence && cache_writeback_drain
          && writeback_cbo_i && cache_cbo_active_q),
      .writeback_cbo_invalidate(writeback_cbo_invalidate_i),
      .writeback_block(writeback_block_i),
      .writeback_cbo_done(cache_cbo_done),
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
      .TargetedCoherence(TargetedCoherence && L1dWriteBack),
      .PostedWrites(PostedWrites)
  ) bus (
      .clock(clock),
      .reset(reset),
      .coherent_ready(cache_coherent_ready),
      .coherent_request(cache_coherent_request),
      .coherent_write(cache_coherent_write),
      .coherent_addr(cache_coherent_addr),
      .mem(memory_link),
      .rd_req_cacheable(memory_read_cacheable),
      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast)
  );

  // A/D channels of the L2 client port: rapt_bus's transaction link, with
  // the PMA it resolved for each read.
  assign l2_client.rd_req_valid = memory_link.rd_req_valid;
  assign l2_client.rd_req_id = memory_link.rd_req_id;
  assign l2_client.rd_req_addr = memory_link.rd_req_addr;
  assign l2_client.rd_req_size = memory_link.rd_req_size;
  assign l2_client.rd_req_len = memory_link.rd_req_len;
  assign l2_client.rd_req_burst = memory_link.rd_req_burst;
  assign l2_client.rd_req_pbmt = memory_link.rd_req_pbmt;
  assign l2_client.rd_req_noallocate = memory_link.rd_req_noallocate;
  assign l2_client.rd_req_cacheable = memory_read_cacheable;
  assign memory_link.rd_req_ready = l2_client.rd_req_ready;
  assign memory_link.rd_rsp_valid = l2_client.rd_rsp_valid;
  assign memory_link.rd_rsp_id = l2_client.rd_rsp_id;
  assign memory_link.rd_rsp_data = l2_client.rd_rsp_data;
  assign memory_link.rd_rsp_last = l2_client.rd_rsp_last;
  assign memory_link.rd_rsp_error = l2_client.rd_rsp_error;
  assign l2_client.rd_rsp_ready = memory_link.rd_rsp_ready;
  assign l2_client.wr_req_valid = memory_link.wr_req_valid;
  assign l2_client.wr_req_zero = memory_link.wr_req_zero;
  assign l2_client.wr_req_id = memory_link.wr_req_id;
  assign l2_client.wr_req_addr = memory_link.wr_req_addr;
  assign l2_client.wr_req_size = memory_link.wr_req_size;
  assign l2_client.wr_req_pbmt = memory_link.wr_req_pbmt;
  assign l2_client.wr_req_data = memory_link.wr_req_data;
  assign l2_client.wr_req_strb = memory_link.wr_req_strb;
  assign memory_link.wr_req_ready = l2_client.wr_req_ready;
  assign memory_link.wr_rsp_valid = l2_client.wr_rsp_valid;
  assign memory_link.wr_rsp_id = l2_client.wr_rsp_id;
  assign memory_link.wr_rsp_error = l2_client.wr_rsp_error;
  assign l2_client.wr_rsp_ready = memory_link.wr_rsp_ready;
  assign l2_client.cbo_inval = cmu_bcast.cbo_inval;
  assign l2_client.cbo_block = cmu_bcast.cbo_block;
endmodule
