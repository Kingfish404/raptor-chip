// Legacy L1D tests do not drive the cache-coherence release interface.
`ifndef TB_L1D_UNUSED_RELEASE_PORTS
`define TB_L1D_UNUSED_RELEASE_PORTS \
  .probe_valid_i(1'b0), \
  .probe_addr_i('0), \
  .probe_ready_o(), \
  .probe_release_valid_o(), \
  .probe_release_addr_o(), \
  .probe_release_data_o(), \
  .probe_release_ready_i(1'b0), \
  .release_valid_o(), \
  .release_addr_o(), \
  .release_data_o(), \
  .release_has_data_o(), \
  .release_mask_o(), \
  .release_last_o(), \
  .release_ready_i(1'b0), \
  .release_ack_i(1'b0), \
  .probe_window_i(1'b0), \
  .writeback_bus_pending_o()
`endif
