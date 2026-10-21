`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"

module tb_dtlb_l2_conflict;
  localparam int XLEN = `RAPT_XLEN;
  localparam int ConflictPages = `RAPT_DTLB_WAYS + 1;
  localparam int PageStride = 64 << 12;
  localparam logic [XLEN-1:0] VA = XLEN'('h40000120);
  localparam logic [XLEN-1:0] PA = XLEN'('h80000120);
  localparam logic [XLEN-1:0] Value = XLEN'('h76543210);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
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
      .LineRefill(0),
      .L2Tlb(1)
  ) dut (
      .l2tlb_req_o(l2_req[1]),
      .l2tlb_ready_i(l2_ready[1]),
      .l2tlb_rsp_i(l2_rsp[1]),
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
  rapt_pkg::l2tlb_req_t l2_req[2];
  rapt_pkg::l2tlb_rsp_t l2_rsp[2];
  logic [1:0] l2_ready;
  assign l2_req[0] = '0;
  rapt_l2tlb #(
      .Entries(256)
  ) l2_tlb (
      .clock,
      .reset,
      .flush(cmu_bcast.fence_time),
      .req_i(l2_req),
      .ready_o(l2_ready),
      .rsp_o(l2_rsp)
  );

  `include "tb_common.svh"
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS

  int delay_left = 0, walks = 0;
  bit pending_ptw;
  logic [XLEN-1:0] pending_data;
  assign l1d_bus.rready = delay_left == 0;
  assign l1d_bus.idle = delay_left == 0;
  assign l1d_bus.rerr = 0;
  assign l1d_bus.ptw_rerr = 0;
  assign l1d_bus.rlast = 1;
  assign l1d_bus.r_mshr = 0;
  assign l1d_bus.r_mshr_id = 0;
  assign l1d_bus.wready = 1;
  assign l1d_bus.werr = 0;
  assign l1d_bus.difftest_skip = 0;
  assign l1d_bus.posted_busy = 0;
  assign l1d_bus.posted_error = 0;
  assign l1d_bus.posted_error_addr = 0;
  always @(posedge clock) begin
    if (reset) begin
      delay_left <= 0;
      walks <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      l1d_bus.rdata <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        pending_ptw <= l1d_bus.ar_ptw;
        // A root-level leaf maps VA to the aligned RAM superpage on both XLENs.
        pending_data <= l1d_bus.ar_ptw ? XLEN'('h200000cf) : Value;
        delay_left <= 3;
        if (l1d_bus.ar_ptw) walks <= walks + 1;
        else begin
          check(
              l1d_bus.araddr >= PA && l1d_bus.araddr < PA + XLEN'(ConflictPages * PageStride)
                    && (l1d_bus.araddr - PA) % XLEN'(PageStride) == 0,
              "load issued the virtual or wrong physical address");
        end
      end else if (delay_left != 0) begin
        delay_left <= delay_left - 1;
        if (delay_left == 1) begin
          l1d_bus.rdata <= pending_data;
          l1d_bus.rvalid <= !pending_ptw;
          l1d_bus.ptw_rvalid <= pending_ptw;
        end
      end
    end
  end

  task automatic pmp_read(input bit allow_read);
    pmp_update.addr_we = 1;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we = 1;
    pmp_update.cfg_r = `RAPT_PMP_NUM'(allow_read);
    pmp_update.cfg_w = 1;
    pmp_update.mode_off = '1;
    pmp_update.mode_off[0] = 0;
    pmp_update.mode_napot = 1;
    tick(1);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we = 0;
  endtask

  task automatic boot;
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    tick(3);
    reset = 0;
    tick(1);
    pmp_read(1);
    csr_bcast.satp_ppn = 'h80001;
  endtask

  task automatic finish_load;
    for (int n = 0; n < 100 && !lsu_l1d.rready; n++) tick(1);
    check(lsu_l1d.rready, "translated request timed out");
    check(!lsu_l1d.trap, "unexpected translated load fault");
    check(lsu_l1d.rdata == Value, "translated load consumed the wrong SRAM word");
    tick(1);
    lsu_l1d.rvalid = 0;
    tick(3);
  endtask

  task automatic access_page(input int delta, input int expected_walks);
    lsu_l1d.raddr = VA + XLEN'(delta);
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = 1;
    #1;
    check(!dut.tlb_hit, "conflicting page unexpectedly remained in the L1 DTLB");
    finish_load();
    check(walks == expected_walks, "DTLB conflict failed to refill from L2");
  endtask
  initial begin
    boot();
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    for (int page = 0; page < ConflictPages; page++) access_page(page * PageStride, page + 1);
    for (int page = 0; page < ConflictPages; page++) access_page(page * PageStride, ConflictPages);
    check(dut.u_dtlb.valid == dut.u_dstlb.valid, "replica validity diverged");
    // Store consumes the shared load-filled translation with no extra walk.
    exu_l1d.mmu_en = 1;
    exu_l1d.valid = 1;
    exu_l1d.vaddr = VA + XLEN'((ConflictPages - 1) * PageStride);
    exu_l1d.walu = `RAPT_SW_WSTRB;
    tick(1);
    check(exu_l1d.ready && !exu_l1d.trap, "load-filled translation failed for store");
    check(exu_l1d.paddr == PA + XLEN'((ConflictPages - 1) * PageStride),
          "store got wrong shared PPN");
    tick(1);
    exu_l1d.valid = 0;
    tick(2);
    check(walks == ConflictPages, "shared store caused extra walk");
    cmu_bcast.fence_time = 1;
    tick(1);
    cmu_bcast.fence_time = 0;
    access_page(0, ConflictPages + 1);
    $display("PASS: P2c DTLB conflicts/L2 refill/load-store sharing XLEN=%0d", XLEN);
    $finish;
  end
endmodule
