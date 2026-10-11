`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"

module tb_l1d_ptw_permission_stage;
`ifdef RAPT_TEST_PTW_L2TLB
  rapt_pkg::l2tlb_req_t l2_req [2];
  rapt_pkg::l2tlb_rsp_t l2_rsp [2];
  logic [1:0] l2_ready;
  assign l2_req[0] = '0;
  rapt_l2tlb #(
      .Entries(`RAPT_L2TLB_ENTRIES)
  ) l2_tlb (
      .clock,
      .reset,
      .flush(cmu_bcast.fence_time),
      .req_i(l2_req),
      .ready_o(l2_ready),
      .rsp_o(l2_rsp)
  );
`endif
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] VA = 'h40000120;
  localparam logic [XLEN-1:0] RootPte = XLEN'('h80001000) + XLEN'(XLEN == 64 ? 8 : 1024);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d #(
      .LineRefill(0)
`ifdef RAPT_TEST_PTW_L2TLB
      ,
      .L2Tlb(1)
`endif
  ) dut (
`ifdef RAPT_TEST_PTW_L2TLB
      .l2tlb_req_o(l2_req[1]),
      .l2tlb_ready_i(l2_ready[1]),
      .l2tlb_rsp_i(l2_rsp[1]),
`else
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
`endif
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
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  int issued = 0, fresh_checks = 0, denied_checks = 0;
  int cancelled_before = 0, cancelled_after = 0, retries = 0;
  always @(posedge clock) begin
    if (!reset && l1d_bus.arvalid && l1d_bus.rready) begin
      check(l1d_bus.ar_ptw && l1d_bus.araddr == RootPte, "unexpected request reached the bus");
      issued++;
    end
  end

  task automatic permissions(input bit allow_read);
    pmp_update.addr_we = 1;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we[0] = 1;
    pmp_update.mode_off[0] = 0;
    pmp_update.mode_napot[0] = 1;
    pmp_update.cfg_r[0] = allow_read;
    pmp_update.cfg_w[0] = 1;
    pmp_update.cfg_x[0] = 1;
    tick(1);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we = 0;
  endtask

  task automatic boot(input bit allow_read);
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    l1d_bus.rready = 0;
    tick(3);
    reset = 0;
    tick(1);
    permissions(allow_read);
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.satp_ppn = 'h80001;
  endtask

  task automatic request(input int kind, input bit enable);
    lsu_l1d.raddr = VA;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = enable && kind == 0;
    exu_l1d.vaddr = VA;
    exu_l1d.mmu_en = kind != 0;
    exu_l1d.cmo_mgmt = kind == 2;
    exu_l1d.walu = kind == 2 ? `RAPT_CBO_MGMT_WALU : `RAPT_SW_WSTRB;
    exu_l1d.valid = enable && kind != 0;
  endtask

  task automatic first_permission_cycle;
    for (int n = 0; n < 50 && !dut.ptw_arvalid; n++) tick(1);
    check(dut.ptw_arvalid && dut.ptw_araddr == RootPte,
          "new walk did not present its own root PTE address");
    check(!dut.ptw_permission_valid_q && !l1d_bus.arvalid,
          "new walk reused stale approval or bypassed the permission boundary");
    check(!lsu_l1d.trap && !exu_l1d.trap, "orphan fault before permission capture");
    fresh_checks++;
  endtask

  task automatic expect_fault(input int kind, input int cause);
    for (int n = 0; n < 20 && !(kind == 0 ? lsu_l1d.trap : exu_l1d.trap); n++) tick(1);
    if (kind == 0) begin
      check(lsu_l1d.rready && lsu_l1d.trap && lsu_l1d.cause == XLEN'(cause),
            "load fault class or completion was lost");
      check(!exu_l1d.trap, "load fault escaped to store port");
    end else begin
      check(exu_l1d.ready && exu_l1d.trap && exu_l1d.cause == XLEN'(cause),
            "store/CMO fault class or completion was lost");
      check(!lsu_l1d.trap, "store/CMO fault escaped to load port");
    end
    check(dut.rec_addr == VA, "fault lost the original virtual address");
  endtask

  task automatic cancel_walk(input int kind, input bit fence);
    request(kind, 0);
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.fence_time = fence;
    l1d_bus.rready = 1;
    #1;
    check(!l1d_bus.arvalid, "cancelled permission issued a PTE read");
    tick(1);
    cmu_bcast.flush_pipe = 0;
    cmu_bcast.fence_time = 0;
    l1d_bus.rready = 0;
    tick(4);
    check(!dut.ptw_busy && !dut.ptw_permission_valid_q && !l1d_bus.arvalid,
          "cancelled walk retained bus or permission ownership");
    check(!lsu_l1d.trap && !exu_l1d.trap, "cancelled walk leaked a fault");
  endtask

  task automatic retry_and_complete(input int kind);
    int before_issued;
    before_issued = issued;
    request(kind, 1);
    first_permission_cycle();
    tick(1);
    check(dut.ptw_permission_valid_q && !dut.ptw_permission_fault_q,
          "retry did not capture a fresh allowed permission");
    // The granted request must retain its address under several cycles of
    // backpressure, then be consumed exactly once.
    repeat (5) begin
      check(l1d_bus.arvalid && l1d_bus.ar_ptw && l1d_bus.araddr == RootPte,
            "approved PTE request changed while backpressured");
      check(!lsu_l1d.trap && !exu_l1d.trap, "stale denial faulted an allowed retry");
      tick(1);
    end
    check(issued == before_issued, "backpressured PTE request was accepted early");
    l1d_bus.rready = 1;
    tick(1);
    l1d_bus.rready = 0;
    check(issued == before_issued + 1 && !dut.ptw_permission_valid_q,
          "PTE acceptance did not consume exactly one permission");
    // An invalid response must fault the accepted operation as a page
    // fault, proving that the surviving owner reaches the real walker.
    l1d_bus.rdata = '0;
    l1d_bus.ptw_rvalid = 1;
    tick(1);
    l1d_bus.ptw_rvalid = 0;
    expect_fault(kind, kind == 0 ? 13 : 15);
    request(kind, 0);
    tick(3);
    check(!dut.ptw_busy && !dut.ptw_permission_valid_q,
          "completed retry retained permission ownership");
    retries++;
  endtask

  initial begin
    for (int kind = 0; kind < 3; kind++) begin
      for (int after_capture = 0; after_capture < 2; after_capture++) begin
        for (int fence = 0; fence < 2; fence++) begin
          int before_issued;
          boot(1);
          before_issued = issued;
          request(kind, 1);
          first_permission_cycle();
          if (after_capture != 0) begin
            tick(1);
            repeat (4) begin
              check(dut.ptw_permission_valid_q && l1d_bus.arvalid,
                    "allowed permission did not survive backpressure");
              tick(1);
            end
            cancelled_after++;
          end else cancelled_before++;
          cancel_walk(kind, 1'(fence));
          check(issued == before_issued, "cancelled PTE request reached the bus");
          retry_and_complete(kind);
        end
      end
      begin
        int before_issued;
        boot(0);
        before_issued = issued;
        // A ready receiver must not advance an unapproved or denied walk.
        l1d_bus.rready = 1;
        request(kind, 1);
        first_permission_cycle();
        tick(1);
        check(dut.ptw_permission_valid_q && dut.ptw_permission_fault_q && !l1d_bus.arvalid,
              "PMP denial failed to block the implicit read");
        expect_fault(kind, kind == 0 ? 5 : 7);
        check(issued == before_issued, "denied PTE request reached the bus");
        denied_checks++;
        cancel_walk(kind, 0);
        permissions(1);
        retry_and_complete(kind);
      end
    end
    check(
        fresh_checks == 30 && cancelled_before == 6 && cancelled_after == 6
              && denied_checks == 3 && retries == 15 && issued == 15,
        "permission boundary coverage incomplete");
    $display(
        "PASS: PTW permission boundary XLEN=%0d fresh=%0d cancel_before=%0d cancel_after=%0d denied=%0d retries=%0d issued=%0d",
        XLEN, fresh_checks, cancelled_before, cancelled_after, denied_checks, retries, issued);
    $finish;
  end
endmodule
