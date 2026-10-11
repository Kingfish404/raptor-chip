`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"
module tb_cbo_tlb #(
    parameter bit L2Tlb = 0
);
  localparam int LineBytes = `RAPT_CACHE_LINE_BYTES;
  localparam int WayBytes = LineBytes * (1 << `RAPT_L1D_LEN);
  localparam int Capacity = WayBytes * `RAPT_L1D_N_WAYS;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_pkg::l2tlb_req_t l2_req [2];
  rapt_pkg::l2tlb_rsp_t l2_rsp [2];
  logic [1:0] l2_ready;
  rapt_l2tlb shared_tlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .req_i(l2_req),
      .ready_o(l2_ready),
      .rsp_o(l2_rsp)
  );
  rapt_l1d #(
      .WriteBack(L2Tlb ? 1'b1 : `RAPT_L1D_WRITEBACK),
      .L2Tlb(L2Tlb),
      .LineRefill(0)
  ) dut (
      .l2tlb_req_o(l2_req[0]),
      .l2tlb_ready_i(l2_ready[0]),
      .l2tlb_rsp_i(l2_rsp[0]),
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
  `include "tb_l1d_defaults.svh"
  task automatic translate(input bit hot);
    bit responded;
    responded = 0;
    @(negedge clock);
    exu_l1d.valid = 1;
    for (int cycle = 0; cycle < 100; cycle++) begin
      #1;
      if (hot && L2Tlb && (l1d_bus.awvalid || l1d_bus.wvalid))
        $fatal(1, "L2 TLB hit unexpectedly drained dirty data");
      if (exu_l1d.trap) $fatal(1, "CMO translation trapped cause=%h", exu_l1d.cause);
      if (exu_l1d.ready) begin
        if (exu_l1d.paddr != XLEN'('h8000003f)) $fatal(1, "CMO translated PA wrong");
        @(posedge clock);
        @(negedge clock);
        exu_l1d.valid = 0;
        repeat (3) @(negedge clock);
        return;
      end
      if (l1d_bus.arvalid) begin
        if (hot || responded || !l1d_bus.ar_ptw) $fatal(1, "unexpected PTW after CBO");
        if (l1d_bus.araddr != XLEN'('h80001000) + XLEN'(XLEN == 64 ? 8 : 1024))
          $fatal(1, "unexpected root PTE address %h", l1d_bus.araddr);
        responded = 1;
        @(posedge clock);
        @(negedge clock);
        // Leaf at the root: aligned 1 GiB (Sv39) / 4 MiB (Sv32), R/W/A/D.
        l1d_bus.rdata = XLEN'('h200000c7);
        l1d_bus.ptw_rvalid = 1;
        @(posedge clock);
        @(negedge clock);
        l1d_bus.ptw_rvalid = 0;
      end else @(negedge clock);
    end
    $fatal(1, "CMO translation timeout");
  endtask
  initial begin
    l2_req[1] = '0;
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    l1d_bus.rready = 1;
    repeat (4) @(negedge clock);
    reset = 0;
    csr_bcast.dmmu_en = 1;
    csr_bcast.satp_ppn = ('h80001);
    exu_l1d.mmu_en = 1;
    exu_l1d.vaddr = XLEN'('h4000003f);
    exu_l1d.cmo_mgmt = 1;
    exu_l1d.walu = `RAPT_CBO_MGMT_WALU;
    lsu_l1d.raddr = XLEN'('h4000003f);
    translate(0);
    if (!dut.tlb_hit || !dut.stlb_hit) $fatal(1, "PTW did not cross-fill DTLB/DSTLB");
    cmu_bcast.cbo_inval = 1;
    cmu_bcast.cbo_block = 0;
    cmu_bcast.flush_pipe = 1;
    @(negedge clock);
    cmu_bcast.cbo_inval = 0;
    cmu_bcast.flush_pipe = 0;
    repeat (3) @(negedge clock);
    if (!dut.tlb_hit || !dut.stlb_hit) $fatal(1, "CBO invalidated DTLB/DSTLB");
    translate(1);
    cmu_bcast.fence_time = 1;
    @(negedge clock);
    cmu_bcast.fence_time = 0;
    repeat (3) @(negedge clock);
    if (dut.tlb_hit || dut.stlb_hit) $fatal(1, "global fence failed to clear TLBs");
    if (L2Tlb) begin
      // Model a translation filled by the instruction walker. A cold data
      // L1 must consume it without issuing any PTE read, then warm both views.
      l2_req[1].valid = 1;
      l2_req[1].fill = 1;
      l2_req[1].vtag = exu_l1d.vaddr[XLEN-1:12];
      l2_req[1].asid = exu_l1d.mem_context.asid;
      l2_req[1].root = csr_bcast.satp_ppn;
      l2_req[1].pbmte = exu_l1d.mem_context.pbmte;
      l2_req[1].sbe = csr_bcast.sbe;
      l2_req[1].ptag = (XLEN-10)'('h80000);
      l2_req[1].pte = 7'h63;
      #1;
      if (!l2_ready[1]) $fatal(1, "other walker fill was not accepted");
      @(posedge clock);
      @(negedge clock);
      l2_req[1] = '0;
      // Keep an unrelated dirty word resident while the L1 TLB is cold.
      // No B response is supplied: draining before the L2 lookup deadlocks.
      lsu_l1d.waddr = XLEN'('h80005000);
      lsu_l1d.wdata = XLEN'('h12345678);
      lsu_l1d.walu = 8'({XLEN / 8{1'b1}});
      lsu_l1d.wvalid = 1;
      for (int n = 0; n < 30 && !lsu_l1d.wready; n++) @(negedge clock);
      if (!lsu_l1d.wready) $fatal(1, "dirty word store stalled");
      @(posedge clock);
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      repeat (4) @(negedge clock);
      if (!dut.dirty_any) $fatal(1, "test requires a dirty cache line");
      translate(1);
      if (!dut.dirty_any) $fatal(1, "L2 TLB hit drained dirty cache line");
      if (!dut.tlb_hit || !dut.stlb_hit) $fatal(1, "L2 hit did not cross-fill DTLB/DSTLB");
    end
    $display("PASS: CBO RV%0d real PTW, translated PA, preserves DTLB/DSTLB, global flush retained",
             XLEN);
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "TLB test timeout");
  end
endmodule
