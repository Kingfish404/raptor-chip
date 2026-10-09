// Shared module-local tasks. Intentionally no include guard.
task automatic init_inputs;
  begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_S, '0, 1'b0);
    init_pmp_state_defaults(1'b0);

    ifu_l1i.pc = OldSupervisorPc;
    ifu_l1i.consumed = 0;
    ifu_l1i.cancel = 0;
    ifu_l1i.invalid = 1'b0;
    ifu_l1i.prefetch_pc = '0;
    ifu_l1i.prefetch_valid = 1'b0;

    l1i_bus.rready = 1'b0;
    l1i_bus.rdata = '0;
    l1i_bus.rvalid = 1'b0;
    l1i_bus.ptw_rerr = 0;
    l1i_bus.ptw_rvalid = 1'b0;
    l1i_bus.rerr = 1'b0;
    l1i_bus.ptw_wready = 1'b0;
    l1i_bus.ptw_werr = 1'b0;

    csr_bcast.immu_en = 1'b1;
    csr_bcast.satp_ppn = `RAPT_CSR_SATP_PPN_W'(32'h8000_0);
    pmp_state.pmp_cfg_r[0] = 1'b1;
    pmp_state.pmp_cfg_w[0] = 1'b1;
    pmp_state.pmp_cfg_x[0] = 1'b1;
    pmp_state.pmp_mode_off[0] = 1'b0;
    pmp_state.pmp_mode_napot[0] = 1'b1;
    pmp_state.pmp_raw_addr[0] = '1;
    pmp_state.pmp_napot_mask[0] = '1;
  end
endtask

task automatic wait_for_ptw_request(input string message);
  bit found;
  begin
    found = 1'b0;
    for (int cycle = 0; cycle < 32; cycle++) begin
      #1;
      if (l1i_bus.arvalid && l1i_bus.ar_ptw) begin
        found = 1'b1;
        cycle = 32;
      end else begin
        tick(1);
      end
    end
    if (!found) fail(message);
  end
endtask

task automatic accept_ptw_request;
  begin
    l1i_bus.rready = 1'b1;
    tick(1);
    l1i_bus.rready = 1'b0;
  end
endtask

task automatic return_ptw_pte(input logic [XLEN-1:0] pte);
  begin
    l1i_bus.rdata = pte;
    l1i_bus.ptw_rvalid = 1'b1;
    tick(1);
    l1i_bus.ptw_rvalid = 1'b0;
  end
endtask
