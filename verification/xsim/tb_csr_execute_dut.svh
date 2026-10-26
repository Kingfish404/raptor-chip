  // Module-local CSR execution fixture. Each inclusion consumes its overrides.
`ifndef TB_CSR_HART_ID
  `define TB_CSR_HART_ID '0
`endif
`ifndef TB_CSR_TIME
  `define TB_CSR_TIME 64'd0
`endif
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i(`TB_CSR_HART_ID),
      .mtime_i(`TB_CSR_TIME),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
`ifdef TB_CSR_BUS_ERROR
      .store_error_i,
      .store_error_addr_i,
      .store_error_strb_i,
`else
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
`endif
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `undef TB_CSR_HART_ID
  `undef TB_CSR_TIME
  `undef TB_CSR_BUS_ERROR
