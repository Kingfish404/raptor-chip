`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"

module tb_translated_load_pipeline;
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
        pending_data <= l1d_bus.ar_ptw ? XLEN'('h200000cf) : Value;
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
    tick(1);
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

  initial begin
    boot();
    warm();
    translate();
    request();
    check(!lsu_l1d.trap, "TLB hit faulted");
    // The PA and original VA are independent of the following live request.
    lsu_l1d.raddr = XLEN'('hdead0000);
    #1;
    check(dut.perm_base_addr == PA, "live VA leaked into registered permission address");
    lsu_l1d.raddr = VA;
    finish_load();
    check(data_reads == 1, "translated cache hit missed");
    cases++;

    boot();
    translate();
    pmp_read(0);
    request();
    finish_load(5);
    check(data_reads == 0, "PMP denial issued a data read");
    cases++;

    boot();
    // U-page access from S without SUM must remain a page fault, ahead of PMP.
    pmp_read(0);
    translate(7'b1101011);
    request();
    finish_load(13);
    check(data_reads == 0, "TLB page fault issued a data read");
    cases++;

    boot();
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    lsu_l1d.raddr = VA;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = 1;
    finish_load();
    check(walks == 1 && data_reads == 1, "PTW-completed load did not use its translation");
    cases++;

    boot();
    warm();
    translate();
    request();
    cmu_bcast.flush_pipe = 1;
    lsu_l1d.rvalid = 0;
    #1;
    check(!lsu_l1d.rready && !l1d_bus.arvalid, "flush leaked a translated completion");
    tick(1);
    cmu_bcast.flush_pipe = 0;
    tick(3);
    check(dut.l1d_state == 0 && data_reads == 1, "flush failed to discard the captured load");
    cases++;

    boot();
    warm();
    translate();
    force dut.ptw_arvalid = 1;
    force dut.ptw_araddr = '0;
    request();
    repeat (3) begin
      check(!lsu_l1d.rready && !lsu_l1d.trap, "load consumed the walker's permission");
      tick(1);
    end
    release dut.ptw_arvalid;
    release dut.ptw_araddr;
    finish_load();
    cases++;

    boot();
    warm();
    translate();
    lsu_l1d.atomic_lock = 1;
    request();
    finish_load();
    check(exu_l1d.reservation_valid && exu_l1d.reservation == PA,
          "translated LR did not reserve the physical address");
    exu_l1d.reservation_clear = 1;
    tick(1);
    check(!exu_l1d.reservation_valid, "SC reservation clear failed");
    cases++;

    boot();
    translate();
    lsu_l1d.rcheck_valid = 1;
    lsu_l1d.rcheck_offset = 1;
    lsu_l1d.rcheck_size_m1 = 2;
    lsu_l1d.rorig_size_m1 = 3;
    lsu_l1d.rmisaligned = 1;
    request();
    check(dut.perm_load_addr == PA + 1 && dut.perm_load_size_m1 == 2,
          "split fragment lost registered extent");
    finish_load();
    cases++;

    for (int pbmt = 1; pbmt <= 2; pbmt++) begin
      boot();
      warm();
      translate(7'b1100011, 2'(pbmt));
      request();
      finish_load();
      check(data_reads == 2, "NC/IO translated load incorrectly used a cache hit");
      cases++;
    end
    boot();
    translate(7'b1100011, 2'b10);
    lsu_l1d.rmisaligned = 1;
    request();
    finish_load(5);
    check(data_reads == 0, "misaligned translated IO load issued a bus read");
    cases++;
    // A captured translated A request retains its context while a bare B
    // request selects another SRAM set and a store races the A hit.
    boot();
    warm();
    translate();
    request();
    csr_bcast.dmmu_en = 0;
    lsu_l1d.rvalid_b = 1;
    lsu_l1d.raddr_b = PA + 64;
    lsu_l1d.ralu_b = `RAPT_ALU_LW__;
    lsu_l1d.waddr = PA;
    lsu_l1d.wdata = XLEN'('h12345678);
    lsu_l1d.walu = `RAPT_SW_WSTRB;
    lsu_l1d.wvalid = 1;
    begin
      bit stored = 0, loaded = 0, armed = 0;
      for (int n = 0; n < 100 && !(stored && loaded && armed); n++) begin
        bit take_store, take_load;
        #1;
        take_store = lsu_l1d.wvalid && lsu_l1d.wready;
        take_load = lsu_l1d.rvalid && lsu_l1d.rready;
        armed |= dut.b_arm_ok;
        check(!lsu_l1d.rready_b, "B consumed A's data from another SRAM set");
        if (take_load) begin
          check(!lsu_l1d.trap && lsu_l1d.rdata == (stored ? XLEN'('h12345678) : Value),
                "store/A race consumed stale or wrong-set data");
        end
        tick(1);
        if (take_store) begin
          stored = 1;
          lsu_l1d.wvalid = 0;
        end
        if (take_load) begin
          loaded = 1;
          lsu_l1d.rvalid = 0;
        end
      end
      check(stored && loaded && armed, "store/load/B race failed to exercise all owners");
    end
    lsu_l1d.rvalid_b = 0;
    tick(3);
    cases++;
    $display("PASS: translated load pipeline XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule
