  // Module-local L1D fixture for directed single-word-refill checks.
  // Intentionally no include guard; each bench owns its interfaces and DUT.
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d #(
      .LineRefill(0)
  ) dut (
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .coherent_request(1'b0),
      .coherent_write(1'b0),
      .coherent_ready(),
      .writeback_error(),
      .writeback_idle(),
      .writeback_drain(1'b0),
      `TB_L1D_UNUSED_RELEASE_PORTS,
      .*
  );
