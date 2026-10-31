`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// rapt_l2_subsystem: the memory side of the cluster, outside every core.
//
//   core (L1I/L1D/PTW -> rapt_bus) --l2_client_if--> rapt_l2_subsystem --AXI4--> router
//
// It always exists. Without an L2 cache it is the management-only L2: AXI4
// protocol conversion, AXI IDs and the outstanding read/write budgets. With
// RAPT_L2_EN it also holds the inclusive L2 cache, which probes the client's
// L1D and accepts its victim releases.
//
// One client today. A multi-hart cluster adds a client arbiter here that
// extends request IDs with the client index and routes D/B traffic back;
// cores and the router stay unchanged.
module rapt_l2_subsystem #(
    parameter int XLEN = `RAPT_XLEN,
    parameter rapt_pkg::l2_link_config_t L2Link = rapt_pkg::L2LinkConfig,
    // Reads the AXI master may have in flight.
    parameter int MemoryReadCredits = 8
) (
    input logic clock,
    input logic reset,
    l2_client_if.manager client,
    axi4_if.master io_master
);
  // Simulator observation paths (sim/include/npc_verilog.h) address this
  // block as part of `rapt` for every preset, whatever its size.
  /* verilator inline_module */
`ifdef RAPT_L2_EN
  localparam bit CacheBuilt = 1'b1;
`else
  localparam bit CacheBuilt = 1'b0;
`endif
  // rapt_l2 selects its cache body with RAPT_L2_EN; the contract handed to
  // the clients must describe the same build.
  if (L2Link.cache != CacheBuilt) begin : g_invalid_link
    $error("rapt_l2_subsystem: L2Link.cache does not match RAPT_L2_EN");
  end

  mem_link_if memory_link ();
  axi4_if l2_axi ();
  axi4_if l2_outer_axi ();

  assign memory_link.rd_req_valid = client.rd_req_valid;
  assign memory_link.rd_req_id = client.rd_req_id;
  assign memory_link.rd_req_addr = client.rd_req_addr;
  assign memory_link.rd_req_size = client.rd_req_size;
  assign memory_link.rd_req_len = client.rd_req_len;
  assign memory_link.rd_req_burst = client.rd_req_burst;
  assign memory_link.rd_req_pbmt = client.rd_req_pbmt;
  assign memory_link.rd_req_noallocate = client.rd_req_noallocate;
  assign client.rd_req_ready = memory_link.rd_req_ready;
  assign client.rd_rsp_valid = memory_link.rd_rsp_valid;
  assign client.rd_rsp_id = memory_link.rd_rsp_id;
  assign client.rd_rsp_data = memory_link.rd_rsp_data;
  assign client.rd_rsp_last = memory_link.rd_rsp_last;
  assign client.rd_rsp_error = memory_link.rd_rsp_error;
  assign memory_link.rd_rsp_ready = client.rd_rsp_ready;
  assign memory_link.wr_req_valid = client.wr_req_valid;
  assign memory_link.wr_req_zero = client.wr_req_zero;
  assign memory_link.wr_req_id = client.wr_req_id;
  assign memory_link.wr_req_addr = client.wr_req_addr;
  assign memory_link.wr_req_size = client.wr_req_size;
  assign memory_link.wr_req_pbmt = client.wr_req_pbmt;
  assign memory_link.wr_req_data = client.wr_req_data;
  assign memory_link.wr_req_strb = client.wr_req_strb;
  assign client.wr_req_ready = memory_link.wr_req_ready;
  assign client.wr_rsp_valid = memory_link.wr_rsp_valid;
  assign client.wr_rsp_id = memory_link.wr_rsp_id;
  assign client.wr_rsp_error = memory_link.wr_rsp_error;
  assign memory_link.wr_rsp_ready = client.wr_rsp_ready;

  rapt_axi_master #(
      .XLEN(XLEN),
      .MAX_READ_OUTSTANDING(MemoryReadCredits),
      .USE_CARRIED_READ_CACHEABLE(1'b1),
      .MAX_WRITE_OUTSTANDING(L2Link.posted_writes > 0 ? L2Link.posted_writes : 1)
  ) axi_master (
      .clock(clock),
      .reset(reset),
      .mem(memory_link),
      .rd_req_cacheable(client.rd_req_cacheable),
      .axi(l2_axi)
  );

  rapt_l2 l2 (
      .clock(clock),
      .reset(reset),
      .cbo_inval_i(client.cbo_inval),
      .cbo_block_i(client.cbo_block),
      .probe_valid_o(client.probe_valid),
      .probe_addr_o(client.probe_addr),
      .probe_ready_i(client.probe_ready),
      .probe_release_valid_i(client.probe_release_valid),
      .probe_release_addr_i(client.probe_release_addr),
      .probe_release_data_i(client.probe_release_data),
      .probe_release_ready_o(client.probe_release_ready),
      .release_valid_i(client.release_valid),
      .release_addr_i(client.release_addr),
      .release_data_i(client.release_data),
      .release_has_data_i(client.release_has_data),
      .release_mask_i(client.release_mask),
      .release_last_i(client.release_last),
      .release_ready_o(client.release_ready),
      .release_ack_o(client.release_ack),
      .l1d_writeback_pending_i(client.writeback_pending),
      .probe_window_o(client.probe_window),
      .axi_s(l2_axi),
      .axi_m(l2_outer_axi)
  );

  rapt_axi_r_buffer #(
      .XLEN(XLEN),
      .Enable(L2Link.store_writeback)
  ) outer_r_buffer (
      .clock,
      .reset,
      .upstream(l2_outer_axi),
      .downstream(io_master)
  );
endmodule
