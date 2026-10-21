`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"

module tb_dtlb_verdict;
  function automatic int tlb_slot(input logic [`RAPT_XLEN-1:0] vpn);
    return `RAPT_DTLB_WAYS == 0 ? 0
        : int'(vpn) % (`RAPT_DTLB_ENTRIES / (`RAPT_DTLB_WAYS == 0 ? 1 : `RAPT_DTLB_WAYS));
  endfunction
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] VA = XLEN'('h40000120);
  localparam logic [XLEN-1:0] PA = XLEN'('h80000120);
  localparam logic [XLEN-1:0] Value = XLEN'('h76543210);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  `include "tb_l1d_harness.svh"
  `include "tb_common.svh"
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS

  int delay_left = 0, data_reads = 0, walks = 0, cases = 0;
  bit pending_ptw;
  bit user_leaf = 0;
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
      data_reads <= 0;
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
        pending_data <= l1d_bus.ar_ptw ? XLEN'(user_leaf ? 'h200000df : 'h200000cf) : Value;
        delay_left <= 3;
        if (l1d_bus.ar_ptw) walks <= walks + 1;
        else begin
          check(l1d_bus.araddr == PA, "load issued the virtual or wrong physical address");
          data_reads <= data_reads + 1;
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

  task automatic translate(input logic [6:0] flags = 7'b1100011, input logic [1:0] pbmt = 0);
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.menvcfg_pbmte = 1;
    dut.u_dtlb.valid[tlb_slot(VA >> 12)] = 1;
    dut.u_dtlb.vtags[tlb_slot(VA >> 12)] = $bits(dut.u_dtlb.vtags[tlb_slot(VA >> 12)])'(VA >> 12);
    dut.u_dtlb.ptags[tlb_slot(VA >> 12)] = $bits(dut.u_dtlb.ptags[tlb_slot(VA >> 12)])'(PA >> 12);
    dut.u_dtlb.asids[tlb_slot(VA >> 12)] = 0;
    dut.u_dtlb.ptes[tlb_slot(VA >> 12)] = flags;
    dut.u_dtlb.pbmts[tlb_slot(VA >> 12)] = pbmt;
    dut.u_dtlb.verdicts[tlb_slot(VA >> 12)] = '0;
  endtask

  task automatic request(input bit translated = 1);
    lsu_l1d.raddr = translated ? VA : PA;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = 1;
    tick(1);
    check(dut.l1d_addr == PA || dut.l1d_state == 3'b100,
          "request failed to register its physical address or start a walk");
  endtask

  task automatic finish_load(input int fault = 0);
    for (int n = 0; n < 100 && !lsu_l1d.rready; n++) tick(1);
    check(lsu_l1d.rready, "translated request timed out");
    check(lsu_l1d.trap == (fault != 0), "unexpected translated load fault policy");
    if (fault != 0) begin
      check(lsu_l1d.cause == XLEN'(fault) && dut.rec_addr == VA,
            "translated fault lost cause or virtual tval owner");
    end else check(lsu_l1d.rdata == Value, "translated load consumed the wrong SRAM word");
    tick(1);
    lsu_l1d.rvalid = 0;
    tick(3);
  endtask

  task automatic warm;
    request(0);
    finish_load();
    check(data_reads == 1, "warm-up did not fill the cache");
  endtask

  task automatic page_permission(input bit allow_read, input bit narrow = 0);
    // Entry 1 allows page-table reads; entry 0 overrides the data page.
    pmp_update.addr_idx = 1;
    pmp_update.addr_we = 1;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we = 2;
    pmp_update.cfg_r = 2;
    pmp_update.cfg_w = 2;
    pmp_update.mode_napot = 2;
    pmp_update.mode_na4 = 0;
    pmp_update.mode_off = ~`RAPT_PMP_NUM'(2);
    tick(1);
    pmp_update.addr_idx = 0;
    pmp_update.raw_addr = narrow ? ((PA + 4) >> 2) : ('h80000000 >> 2) | 511;
    pmp_update.napot_mask = narrow ? 1 : 1023;
    pmp_update.cfg_we = 1;
    pmp_update.cfg_r = `RAPT_PMP_NUM'(allow_read);
    pmp_update.cfg_w = 1;
    pmp_update.mode_napot = narrow ? 0 : 1;
    pmp_update.mode_na4 = narrow ? 1 : 0;
    pmp_update.mode_off = ~`RAPT_PMP_NUM'(1);
    tick(1);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we = 0;
  endtask
  task automatic enable_translation;
    csr_bcast.priv = `RAPT_PRIV_M;
    csr_bcast.mprv = 1;
    csr_bcast.mpp = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
  endtask
  initial begin
    boot();
    page_permission(1);
    enable_translation();
    request();
    finish_load();
    check(walks == 1 && dut.u_dtlb.valid == dut.u_dstlb.valid,
          "walk did not share its data translation");
    request();
    check(dut.l1d_state == 3'b001, "uniform hit did not skip PMP stage");
    finish_load();
    check(walks == 1, "superpage portion failed to hit");
    // PMP write alone must discard the cached allow verdict.
    page_permission(0);
    check(dut.u_dtlb.valid == 0 && dut.u_dstlb.valid == 0, "PMP update did not flush");
    request();
    finish_load(5);
    // The freshly cached denial also takes the short path.
    request();
    check(dut.l1d_state == 3'b101, "uniform denied hit did not trap");
    finish_load(5);
    page_permission(1);
    cmu_bcast.fence_time = 1;
    tick(1);
    cmu_bcast.fence_time = 0;
    request();
    finish_load();
    // A four-byte denied region inside the page must never be cached uniform.
    page_permission(0, 1);
    request();
    finish_load();
    check(!dut.dtlb_verdict[0], "nonuniform page cached an unconditional verdict");
    lsu_l1d.rcheck_valid = 1;
    lsu_l1d.rcheck_offset = 3;
    lsu_l1d.rcheck_size_m1 = 3;
    lsu_l1d.rorig_size_m1 = 3;
    lsu_l1d.rmisaligned = 1;
    request();
    check(dut.l1d_state == 3'b011, "nonuniform split skipped physical checker");
    finish_load(5);
    boot();
    page_permission(1);
    enable_translation();
    csr_bcast.mpp = `RAPT_PRIV_U;
    user_leaf = 1;
    request();
    finish_load();
    request();
    check(dut.l1d_state == 3'b001, "MPRV/MPP=U did not use uniform verdict");
    finish_load();
    $display("PASS: P2c cached verdict, PMP writes, superpage, MPRV and split XLEN=%0d", XLEN);
    $finish;
  end
endmodule
