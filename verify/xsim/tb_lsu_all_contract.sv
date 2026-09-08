// ---- tb_lsu_atomic_contract ----
// ---- tb_lsu_atomic_acquire ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_atomic_acquire;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  `include "tb_lsu_harness.svh"
  task automatic fresh;
    reset = 1;
    init_lsu_inputs(1, 0, 0);
    tick(3);
    reset = 0;
    tick(1);
  endtask
  task automatic allocate(input bit aq, input bit writes);
    exu_ioq_bcast='0;
    exu_ioq_bcast.valid=1;
    exu_ioq_bcast.wen=writes;
    exu_ioq_bcast.dest=3;
    exu_ioq_bcast.tval=XLEN'('h80001000);
    exu_ioq_bcast.sq_waddr=XLEN'('h80001000);
    exu_ioq_bcast.sq_wdata=1;
    exu_ioq_bcast.alu=XLEN==64 ? 6'(`RAPT_SD_WSTRB) : 6'(`RAPT_SW_WSTRB);
    sq_acquire=aq;
    tick(1);
    exu_ioq_bcast.valid=0;
    exu_ioq_bcast.wen=0;
    sq_acquire=0;
  endtask
  task automatic reads(input bit blocked, input bit same_address, input bit distinct_offset = 0);
    exu_lsu.rvalid=1;
    exu_lsu.rvalid_b=1;
    exu_lsu.raddr=XLEN'(same_address?'h80001000:'h80002000);
    if (distinct_offset) exu_lsu.raddr += XLEN'(16);
    exu_lsu.raddr_b=exu_lsu.raddr;
    exu_lsu.ralu=`RAPT_ALU_LW__;
    exu_lsu.ralu_b=5'(`RAPT_ALU_LW__);
    lsu_l1d.rready=1;
    lsu_l1d.rready_b=1;
    #1;
    if (blocked) begin
      check(!lsu_l1d.rvalid && !exu_lsu.rready, "A read escaped resident acquire");
      check(!lsu_l1d.rvalid_b && !exu_lsu.rready_b, "B read/forward escaped resident acquire");
    end else begin
      check(exu_lsu.rready, "A read failed to resume");
      check(exu_lsu.rready_b, "B read failed to resume");
    end
    exu_lsu.rvalid=0;
    exu_lsu.rvalid_b=0;
  endtask
  task automatic scenario(input bit aq, input bit writes, input bit commits);
    fresh();
    allocate(aq, writes);
    reads(aq && writes, 0);
    reads(aq && writes, 1);
    rou_lsu.dest=3;
    rou_lsu.sq_vaddr=XLEN'('h80001000);
    rou_lsu.store=commits && writes;
    rou_lsu.valid=commits && writes;
    cmu_bcast.flush_pipe=1;
    tick(1);
    cmu_bcast.flush_pipe=0;
    rou_lsu.store=0;
    rou_lsu.valid=0;
    tick(2);
    if (commits && writes) begin
      check(lsu_l1d.wvalid && !rou_lsu.sq_empty, "commit plus flush lost store");
      repeat (5) begin
        // Flush invalidates the retained store's VA identity. Same-offset
        // queries must wait even for a relaxed store; a distinct offset
        // bypasses that alias hazard, but must still respect acquire.
        reads(1, 0);
        reads(1, 1);
        reads(aq, 0, 1);
        tick(1);
      end
      lsu_l1d.wready = 1;
      tick(1);
      lsu_l1d.wready = 0;
      tick(2);
    end
    check(rou_lsu.sq_empty, "flushed/drained/failed-SC entry left SQ resident");
    reads(0, 0);
    reads(0, 1);
    // Reuse the flushed/drained slot without reset: stale aq payload must
    // neither survive invalidation nor infect a newly allocated relaxed store.
    allocate(0, 1);
    reads(0, 0);
    reads(0, 1);
    $display("PASS CASE aq=%0d writes=%0d commits=%0d", aq, writes, commits);
  endtask
  task automatic branch_recovery(input int kind, input int context_event);
    fresh();
    allocate(0, 1);
    rou_lsu.dest=3;
    rou_lsu.sq_vaddr=XLEN'('h80001000);
    rou_lsu.store=1;
    rou_lsu.valid=1;
    tick(1);
    rou_lsu.store=0;
    rou_lsu.valid=0;
    cmu_bcast.ben=(kind==0);
    cmu_bcast.jen=(kind==1);
    cmu_bcast.jren=(kind==2);
    cmu_bcast.time_trap=(context_event==1);
    cmu_bcast.fence_time=(context_event==2);
    cmu_bcast.flush_pipe=1;
    tick(1);
    cmu_bcast.flush_pipe=0;
    cmu_bcast.time_trap=0;
    cmu_bcast.fence_time=0;
    cmu_bcast.ben=0;
    cmu_bcast.jen=0;
    cmu_bcast.jren=0;
    tick(2);
    check(lsu_l1d.wvalid && !rou_lsu.sq_empty, "branch recovery lost committed store");
    reads(context_event != 0, 0);
    reads(context_event != 0, 1);
    reads(0, 0, 1);
    lsu_l1d.wready = 1;
    tick(1);
    lsu_l1d.wready = 0;
    tick(2);
    check(rou_lsu.sq_empty, "branch recovery store failed to drain");
    reads(0, 0);
    reads(0, 1);
    $display("PASS BRANCH kind=%0d context_event=%0d", kind, context_event);
  endtask
  initial begin
    scenario(1, 1, 1);
    scenario(1, 1, 0);
    scenario(1, 0, 0);
    scenario(0, 1, 1);
    for (int kind = 0; kind < 3; kind++)
    for (int context_event = 0; context_event < 3; context_event++)
    branch_recovery(kind, context_event);
    $display("PASS: SQ acquire lifetime and both read paths XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_lsu_atomic_release ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_atomic_release;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  `include "tb_lsu_harness.svh"
  task automatic scenario(input bit release_bit);
    reset = 1;
    init_lsu_inputs(1, 0, 0);
    tick(3);
    reset = 0;
    tick(1);
    // Older store has committed but its downstream completion is delayed.
    exu_ioq_bcast='0;
    exu_ioq_bcast.valid=1;
    exu_ioq_bcast.wen=1;
    exu_ioq_bcast.dest=3;
    exu_ioq_bcast.tval=XLEN'('h80001000);
    exu_ioq_bcast.sq_waddr=XLEN'('h80001000);
    exu_ioq_bcast.sq_wdata=1;
    exu_ioq_bcast.alu=6'(`RAPT_SW_WSTRB);
    tick(1);
    exu_ioq_bcast.valid=0;
    exu_ioq_bcast.wen=0;
    rou_lsu.dest=3;
    rou_lsu.sq_vaddr=XLEN'('h80001000);
    rou_lsu.store=1;
    rou_lsu.valid=1;
    tick(1);
    rou_lsu.store=0;
    rou_lsu.valid=0;
    tick(2);
    check(!rou_lsu.sq_empty && lsu_l1d.wvalid, "older store did not reach delayed drain");
    exu_lsu.rvalid=1;
    exu_lsu.raddr=XLEN'('h80002000);
    exu_lsu.ralu=`RAPT_ALU_LW__;
    exu_lsu.atomic_lock=1;
    exu_lsu.atomic_release=release_bit;
    lsu_l1d.rready=1;
    #1;
    $display("OBSERVE release=%0d older_write_pending=1 read_request=%0d read_complete=%0d",
             release_bit, lsu_l1d.rvalid, exu_lsu.rready);
    if (!release_bit) check(lsu_l1d.rvalid && exu_lsu.rready, "relaxed LR unnecessarily blocked");
    else begin
      repeat (5) begin
        check(!lsu_l1d.rvalid && !exu_lsu.rready,
              "release LR read escaped before older write completed");
        tick(1);
      end
      // Acknowledgement, not store allocation or architectural commit, opens
      // the read. All older writes have left SQ and the drain FSM is idle.
      lsu_l1d.wready = 1;
      tick(1);
      lsu_l1d.wready = 0;
      tick(2);
      check(rou_lsu.sq_empty, "older store failed to drain");
      check(lsu_l1d.rvalid && exu_lsu.rready, "release LR failed to resume after write completion");
    end
    exu_lsu.rvalid = 0;
  endtask
  initial begin
    scenario(0);
    scenario(1);
    $display("PASS: atomic release older-store drain XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_lsu_axi_io_order ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
module tb_lsu_axi_io_order;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic pmu_sq_full;
  logic [XLEN-1:0] sq_waddr_hi;
  logic [XLEN-1:0] sq_waddr_third;
  logic [2:0][1:0] sq_wpbmt;

  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  lsu_pipe_if exu_lsu ();
  rapt_pkg::completion_t exu_ioq_bcast;
  rou_lsu_if rou_lsu ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();

  rapt_lsu_sq #(
      .SQ_SIZE(LsuTbSqSize)
  ) dut (
      .clock,
      .cmu_bcast,
      .lsu_l1d,
      .exu_lsu,
      .exu_ioq_bcast,
      .completion_accept(1'b1),
      .sq_waddr_hi,
      .sq_waddr_third,
      .sq_wpbmt,
      .sq_acquire(1'b0),
      .rou_lsu,
      .csr_bcast,
      .pmp_state,
      .pmu_sq_full,
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"

l1d_bus_if l1d_bus ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d cache_dut (
      .clock,
      .reset,
      .cmu_bcast,
      .lsu_l1d,
      .l1d_bus,
      .csr_bcast,
      .pmp_update,
      .exu_l1d,
      .rou_cmu
  );
  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b0);
      init_pmp_state_defaults(1'b0);
      exu_lsu.rvalid = 1'b0;
      exu_lsu.raddr = '0;
      exu_lsu.ralu = `RAPT_ALU_LW__;
      exu_lsu.atomic_lock = 1'b0;
      exu_lsu.atomic_release = 1'b0;
      exu_lsu.ordered = 1;
      exu_lsu.pc = '0;
      exu_lsu.rvalid_b = 1'b0;
      exu_lsu.raddr_b = '0;
      exu_lsu.ralu_b = 0;
      exu_ioq_bcast.pc = '0;
      exu_ioq_bcast.npc = '0;
      exu_ioq_bcast.btaken = 1'b0;
      exu_ioq_bcast.mispredict = 1'b0;
      exu_ioq_bcast.dest = '0;
      exu_ioq_bcast.result = '0;
      exu_ioq_bcast.prd = '0;
      exu_ioq_bcast.rd = '0;
      exu_ioq_bcast.csr_wen = 1'b0;
      exu_ioq_bcast.csr_wdata = '0;
      exu_ioq_bcast.wen = 1'b0;
      exu_ioq_bcast.alu = '0;
      exu_ioq_bcast.sq_waddr = '0;
      exu_ioq_bcast.sq_wdata = '0;
      exu_ioq_bcast.sq_wdata64 = '0;
      exu_ioq_bcast.sq_fp64 = 1'b0;
      exu_ioq_bcast.trap = 1'b0;
      exu_ioq_bcast.tval = '0;
      exu_ioq_bcast.cause = '0;
      exu_ioq_bcast.difftest_skip = 1'b0;
      exu_ioq_bcast.valid = 1'b0;
      rou_lsu.store = 1'b0;
      rou_lsu.dest = '0;
      rou_lsu.sq_vaddr = '0;
      rou_lsu.pc = '0;
      rou_lsu.valid = 1'b0;
      sq_waddr_hi = '0;
      sq_waddr_third = '0;
      sq_wpbmt = '0;



      pmp_update.addr_we = 1'b0;
      pmp_update.addr_idx = '0;
      pmp_update.raw_addr = '0;
      pmp_update.napot_mask = '0;
      pmp_update.cfg_we = '0;
      pmp_update.cfg_r = '0;
      pmp_update.cfg_w = '0;
      pmp_update.cfg_x = '0;
      pmp_update.cfg_l = '0;
      pmp_update.mode_off = '1;
      pmp_update.mode_tor = '0;
      pmp_update.mode_na4 = '0;
      pmp_update.mode_napot = '0;

      exu_l1d.mmu_en = 1'b0;
      exu_l1d.vaddr = '0;
      exu_l1d.walu = '0;
      exu_l1d.misaligned = 0;
      exu_l1d.cmo_mgmt = 1'b0;
      exu_l1d.valid = 1'b0;
      exu_l1d.reservation_clear = 1'b0;


      rou_cmu.slot[0].valid = 1'b0;
      rou_cmu.atomic_sc = 1'b0;
      rou_cmu.fence_time = 1'b0;
      rou_cmu.flush_pipe = 1'b0;
      exu_lsu.fp_rdata64_req = 0;
    end
  endtask

  // Actual SQ -> L1D -> bus -> AXI adapter. ROB commit and the external
  // device are modeled; no direct drive of any internal completion-ready.
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) axi ();
  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) mem ();
  l1i_bus_if l1i_bus ();
  rapt_bus #(
      .XLEN(XLEN)
  ) bus_dut (
      .clock,
      .reset,
      .mem,
      .l1i_bus,
      .l1d_bus,
      .csr_bcast,
      .cmu_bcast
  );
  rapt_axi_master #(
      .XLEN(XLEN),
      .ID_W(4)
  ) adapter (
      .clock,
      .reset,
      .mem,
      .axi
  );
  int aw_count, w_count, b_count, ar_count;
  always @(posedge clock) begin
    if (reset) begin
      aw_count=0;
      w_count=0;
      b_count=0;
      ar_count=0;
    end else begin
      if (axi.awvalid && axi.awready) aw_count++;
      if (axi.wvalid && axi.wready) w_count++;
      if (axi.bvalid && axi.bready) b_count++;
      if (axi.arvalid && axi.arready) ar_count++;
    end
  end
  task automatic init_external;
    axi.arready=0;
    axi.rid=0;
    axi.rlast=0;
    axi.rdata=0;
    axi.rresp=0;
    axi.rvalid=0;
    axi.awready=0;
    axi.wready=0;
    axi.bid=2;
    axi.bresp=0;
    axi.bvalid=0;
    l1i_bus.arvalid=0;
    l1i_bus.araddr=0;
    l1i_bus.arburst=0;
    l1i_bus.ar_ptw=0;
    l1i_bus.rpbmt=0;
    l1i_bus.awvalid=0;
    l1i_bus.awaddr=0;
    l1i_bus.aw_ptw=0;
    l1i_bus.wvalid=0;
    l1i_bus.wdata=0;
    l1i_bus.wstrb=0;
  endtask
  task automatic blocked;
    check(!exu_lsu.rready && !axi.arvalid && ar_count == 0,
          "younger IO read escaped before external write completion");
    check(!rou_lsu.sq_empty, "SQ emptied before external write completion");
  endtask
  task automatic warm_cache;
    bit completed;
    begin
      completed=0;
      exu_lsu.raddr=XLEN'('h80001000);
      exu_lsu.ralu=`RAPT_ALU_LW__;
      exu_lsu.rvalid=1;
      repeat (30) begin
        if (axi.arvalid) break;
        tick(1);
      end
      check(axi.arvalid && axi.arlen == 0, "warmup did not request single-word fill");
      axi.arready = 1;
      tick(1);
      axi.arready=0;
      axi.rid=2;
      axi.rvalid=1;
      axi.rdata=0;
      axi.rlast=1;
      #1;
      check(axi.rready && exu_lsu.rready, "warmup response not accepted");
      tick(1);
      axi.rvalid=0;
      exu_lsu.rvalid=0;
      tick(8);
      // Re-read through the real SQ/L1D path and require completion without AR.
      exu_lsu.rvalid = 1;
      repeat (12) begin
        #1;
        check(!axi.arvalid, "warmup reread missed cache");
        if (exu_lsu.rready) begin
          completed = 1;
          break;
        end
        tick(1);
      end
      check(completed, "warmup hit did not complete");
      tick(1);
      exu_lsu.rvalid = 0;
      tick(4);
      // The following store now exercises cache-hit byte merge, not only the
      // cold write-through path. Count external effects of the measured phase.
      aw_count=0;
      w_count=0;
      b_count=0;
      ar_count=0;
    end
  endtask
  task automatic scenario(input int region, input bit data_first, input bit flush_commit,
                          input logic [1:0] response);
    logic [XLEN-1:0] address;
    logic [3:0] expected_cache;
    begin
      reset = 1;
      init_inputs();
      init_external();
      tick(4);
      reset = 0;
      tick(2);
      if (region == 4) warm_cache();
      address=region==0 ? XLEN'('h10000000) : XLEN'('h80001000);
      expected_cache=region==0 || region==3 ? 0 : region==1 || region==4 ? 15 : 2;
      exu_ioq_bcast='0;
      exu_ioq_bcast.valid=1;
      exu_ioq_bcast.wen=1;
      exu_ioq_bcast.dest=3;
      exu_ioq_bcast.tval=address;
      exu_ioq_bcast.sq_waddr=address;
      exu_ioq_bcast.sq_wdata=XLEN'('h12345678);
      exu_ioq_bcast.alu=6'(`RAPT_SW_WSTRB);
      sq_wpbmt[0]=region<2 || region==4 ? 0 : 2'(region-1);
      tick(1);
      exu_ioq_bcast.valid=0;
      exu_ioq_bcast.wen=0;
      rou_lsu.dest=3;
      rou_lsu.sq_vaddr=address;
      rou_lsu.store=1;
      rou_lsu.valid=1;
      cmu_bcast.flush_pipe=flush_commit;
      tick(1);
      cmu_bcast.flush_pipe=0;
      rou_lsu.store=0;
      rou_lsu.valid=0;
      exu_lsu.raddr=XLEN'('h10000004);
      exu_lsu.ralu=`RAPT_ALU_LW__;
      exu_lsu.rvalid=1;
      repeat (20) begin
        if (axi.awvalid && axi.wvalid) break;
        blocked();
        tick(1);
      end
      check(axi.awvalid && axi.wvalid, "write did not reach AXI");
      repeat (4) begin
        blocked();
        check(axi.awaddr == address && axi.awcache == expected_cache,
              "AXI write lost address or PMA/PBMT");
        check(axi.wdata == XLEN'('h12345678) && axi.wstrb == 4'hf && axi.wlast,
              "AXI write data/byte extent changed");
        tick(1);
      end
      if (data_first) axi.wready = 1;
      else axi.awready = 1;
      tick(1);
      axi.wready=0;
      axi.awready=0;
      repeat (4) begin
        blocked();
        tick(1);
      end
      if (data_first) axi.awready = 1;
      else axi.wready = 1;
      tick(1);
      axi.awready=0;
      axi.wready=0;
      repeat (7) begin
        blocked();
        check(!lsu_l1d.wready && !l1d_bus.wready, "internal write completed before B");
        tick(1);
      end
      check(aw_count == 1 && w_count == 1 && b_count == 0, "AW/W duplicated or B fabricated");
      // The device is allowed to delay making its write visible until B.
      // A status read must not be observed before this modeled visibility point.
      axi.bresp=response;
      axi.bvalid=1;
      #1;
      check(axi.bready, "adapter did not accept B");
      check(lsu_l1d.wready && lsu_l1d.werr == (response != 0), "B error lost before SQ");
      check(mem.wr_rsp_error == (response != 0), "adapter lost B response error");
      tick(1);
      axi.bvalid = 0;
      repeat (30) begin
        if (axi.arvalid) break;
        tick(1);
      end
      check(axi.arvalid && rou_lsu.sq_empty && b_count == 1,
            "IO read did not resume after B/drain");
      check(
          axi.araddr == XLEN'('h10000004) && axi.arlen == 0 && axi.arsize == 2 && axi.arcache == 0,
          "device read address/size/type incorrect");
      axi.arready = 1;
      tick(1);
      axi.arready=0;
      axi.rid=2;
      axi.rlast=1;
      axi.rvalid=1;
      axi.rdata=XLEN'(1) << (XLEN==64 ? 32 : 0);
      #1;
      check(axi.rready, "device response not accepted");
      check(exu_lsu.rready && !exu_lsu.trap && exu_lsu.rdata == 1, "IO read completion/data lost");
      tick(1);
      axi.rvalid=0;
      exu_lsu.rvalid=0;
      tick(4);
      check(aw_count == 1 && w_count == 1 && b_count == 1 && ar_count == 1,
            "external access repeated");
      if (region == 4 && response != 0) begin
        // A failed posted write may modify external bytes. A previously hot
        // line must be invalidated, then refetched rather than serving stale 0
        // or the intended but unconfirmed store value.
        exu_lsu.raddr=XLEN'('h80001000);
        exu_lsu.rvalid=1;
        repeat (30) begin
          #1;
          check(!exu_lsu.rready, "failed hot store left cached data visible");
          if (axi.arvalid) break;
          tick(1);
        end
        check(axi.arvalid && axi.araddr == XLEN'('h80001000), "failed hot store did not refetch");
        axi.arready = 1;
        tick(1);
        axi.arready=0;
        axi.rdata=XLEN'('h55);
        axi.rvalid=1;
        axi.rlast=1;
        #1;
        check(exu_lsu.rready && exu_lsu.rdata == XLEN'('h55),
              "post-error refill lost device value");
        tick(1);
        axi.rvalid=0;
        exu_lsu.rvalid=0;
        tick(4);
        check(ar_count == 2 && aw_count == 1 && w_count == 1 && b_count == 1,
              "post-error transaction duplicated");
      end
      $display("PASS IO AXI response=%0d region=%0d Wfirst=%0d flush=%0d XLEN=%0d", response,
               region, data_first, flush_commit, XLEN);
    end
  endtask
  initial begin
    for (int region = 0; region < 5; region++)
    for (int first = 0; first < 2; first++)
    for (int flush = 0; flush < 2; flush++)
    for (int response = 0; response < 4; response++)
    if (response != 1) scenario(region, 1'(first), 1'(flush), 2'(response));
    $display("PASS: SQ/L1D/AXI external IO ordering XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_lsu_cbo_zero ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_lsu_cbo_zero;
  localparam int XLEN = 64;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam logic [63:0] TestAddr = 64'h0000_0000_8000_103d;
  localparam logic [63:0] BlockBase = 64'h0000_0000_8000_1000;

  `include "tb_lsu_harness.svh"

  initial begin
    init_lsu_inputs(1'b1, '0, '0);
    tick(4);
    reset = 1'b0;
    tick(1);

    // Allocate one unaligned-address CBO.ZERO.  The architectural operation
    // selects the containing cache block, not merely the addressed dword.
    exu_ioq_bcast.valid = 1'b1;
    exu_ioq_bcast.wen = 1'b1;
    exu_ioq_bcast.alu = {1'b0, `RAPT_CBO_ZERO_WALU};
    exu_ioq_bcast.dest = 6'd9;
    exu_ioq_bcast.tval = TestAddr;
    exu_ioq_bcast.sq_waddr = TestAddr;
    exu_ioq_bcast.sq_wdata = 64'hdead_beef_cafe_f00d;
    tick(1);
    exu_ioq_bcast.valid = 1'b0;
    exu_ioq_bcast.wen = 1'b0;

    rou_lsu.valid = 1'b1;
    rou_lsu.store = 1'b1;
    rou_lsu.dest = 6'd9;
    rou_lsu.sq_vaddr = TestAddr;
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;

    lsu_l1d.wready = 1'b1;
    for (int beat = 0; beat < 8; beat++) begin
      #1;
      check(lsu_l1d.wvalid, "CBO.ZERO omitted a cache-block write beat");
      check(lsu_l1d.waddr == BlockBase + 64'(beat * 8),
            "CBO.ZERO emitted an incorrect aligned beat address");
      check(lsu_l1d.walu == 8'hff, "CBO.ZERO beat was not a full dword store");
      check(lsu_l1d.wdata == 64'b0, "CBO.ZERO emitted nonzero data");
      tick(1);
    end

    #1;
    check(!lsu_l1d.wvalid, "CBO.ZERO emitted more than one 64-byte block");
    tick(2);
    check(dut.sq_all_empty, "CBO.ZERO did not release its SQ entry");

    $display("PASS: Zicboz clears exactly one 64-byte cache block");
    $finish;
  end
endmodule


// ---- tb_lsu_hum_pmp ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_hum_pmp;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam logic [XLEN-1:0] Addr = XLEN'(32'h80000080);
  `include "tb_lsu_harness.svh"

  task automatic setup(input bit forwarding);
    reset = 1;
    init_lsu_inputs(1, 32'h12345678, '0);
    tick(3);
    reset = 0;
    tick(2);
    if (forwarding) begin
      exu_ioq_bcast.valid=1;
      exu_ioq_bcast.wen=1;
      exu_ioq_bcast.alu=XLEN==64 ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB;
      exu_ioq_bcast.dest=7;
      exu_ioq_bcast.tval=Addr;
      exu_ioq_bcast.sq_waddr=Addr;
      exu_ioq_bcast.sq_wdata='h12345678;
      tick(1);
      exu_ioq_bcast.valid=0;
      exu_ioq_bcast.wen=0;
      tick(1);
    end
    // A locked NA4 region has priority over a permissive background.
    init_pmp_state_defaults(1);
    pmp_state.pmp_raw_addr[0]=$bits(pmp_state.pmp_raw_addr[0])'(Addr>>2);
    pmp_state.pmp_mode_off[0]=0;
    pmp_state.pmp_mode_na4[0]=1;
    pmp_state.pmp_cfg_l[0]=1;
    pmp_state.pmp_raw_addr[1]='1;
    pmp_state.pmp_napot_mask[1]='1;
    pmp_state.pmp_mode_off[1]=0;
    pmp_state.pmp_mode_napot[1]=1;
    pmp_state.pmp_cfg_r[1]=1;
    pmp_state.pmp_cfg_w[1]=1;
    exu_lsu.rvalid_b=1;
    exu_lsu.raddr_b=Addr;
    exu_lsu.ralu_b=`RAPT_ALU_LBU_;
    lsu_l1d.rdata_b='h12345678;
  endtask

  task automatic expect_b(input bit allowed, input bit forwarding);
    #1;
    lsu_l1d.rready_b = lsu_l1d.rvalid_b;
    #1;
    check(exu_lsu.rready_b == allowed,
          "HUM permission mismatch (forbidden completion or permitted load stalled)");
    check(lsu_l1d.rvalid_b == (allowed && !forwarding), "HUM request escaped permission gate");
    if (allowed) check(exu_lsu.rdata_b == 'h78, "allowed B load data incorrect");
  endtask

  initial begin
    for (int f = 0; f < 2; f++) begin
      setup(1'(f));
      expect_b(0, 1'(f));  // M mode is still subject to locked PMP.
      pmp_state.pmp_cfg_l[0] = 0;
      expect_b(1, 1'(f));
      csr_bcast.priv = `RAPT_PRIV_S;
      expect_b(0, 1'(f));
      csr_bcast.priv=`RAPT_PRIV_M;
      csr_bcast.mprv=1;
      csr_bcast.mpp=`RAPT_PRIV_U;
      expect_b(0, 1'(f));
      pmp_state.pmp_cfg_r[0] = 1;
      expect_b(1, 1'(f));
      pmp_state.pmp_cfg_r[0] = 0;
      // Denied B must stay pending, including while A is otherwise idle.
      repeat (3) begin
        expect_b(0, 1'(f));
        tick(1);
      end
    end
    setup(0);
    pmp_state.pmp_cfg_r[0] = 1;
    if (XLEN == 64) begin
      exu_lsu.ralu_b = `RAPT_ALU_LD__;
      expect_b(0, 0);  // Aligned eight-byte load partly matches a four-byte region.
      exu_lsu.ralu_b = `RAPT_ALU_LBU_;
      expect_b(1, 0);  // The byte at exactly the same address is permitted.
    end
    exu_lsu.raddr_b=Addr+3;
    exu_lsu.ralu_b=`RAPT_ALU_LHU_;
    expect_b(0, 0);  // A two-byte access cannot partly match the NA4 entry.
    exu_lsu.raddr_b='h0f001fff;
    exu_lsu.ralu_b=`RAPT_ALU_LHU_;
    expect_b(0, 0);  // SRAM endpoint: entire access must be mapped.
    $display("PASS: HUM cache and SQ-forward permissions, MPRV, PMP/PMA endpoints");
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "timeout");
  end
endmodule


// ---- tb_lsu_l1d_io_split ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_l1d_io_split;
  localparam int XLEN = 64;
  localparam int LsuTbSqSize = 4;
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic pmu_sq_full;
  logic [XLEN-1:0] sq_waddr_hi;
  logic [XLEN-1:0] sq_waddr_third;
  logic [2:0][1:0] sq_wpbmt;

  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  lsu_pipe_if exu_lsu ();
  rapt_pkg::completion_t exu_ioq_bcast;
  rou_lsu_if rou_lsu ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();

  rapt_lsu_sq #(
      .SQ_SIZE(LsuTbSqSize)
  ) dut (
      .clock,
      .cmu_bcast,
      .lsu_l1d,
      .exu_lsu,
      .exu_ioq_bcast,
      .completion_accept(1'b1),
      .sq_waddr_hi,
      .sq_waddr_third,
      .sq_wpbmt,
      .sq_acquire(1'b0),
      .rou_lsu,
      .csr_bcast,
      .pmp_state,
      .pmu_sq_full,
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"

l1d_bus_if l1d_bus ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d cache_dut (
      .clock,
      .reset,
      .cmu_bcast,
      .lsu_l1d,
      .l1d_bus,
      .csr_bcast,
      .pmp_update,
      .exu_l1d,
      .rou_cmu
  );
  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b0);
      init_pmp_state_defaults(1'b0);
      exu_lsu.rvalid = 1'b0;
      exu_lsu.raddr = '0;
      exu_lsu.ralu = `RAPT_ALU_LW__;
      exu_lsu.atomic_lock = 1'b0;
      exu_lsu.atomic_release = 1'b0;
      exu_lsu.ordered = 1;
      exu_lsu.pc = '0;
      exu_lsu.rvalid_b = 1'b0;
      exu_lsu.raddr_b = '0;
      exu_lsu.ralu_b = 0;
      exu_ioq_bcast.pc = '0;
      exu_ioq_bcast.npc = '0;
      exu_ioq_bcast.btaken = 1'b0;
      exu_ioq_bcast.mispredict = 1'b0;
      exu_ioq_bcast.dest = '0;
      exu_ioq_bcast.result = '0;
      exu_ioq_bcast.prd = '0;
      exu_ioq_bcast.rd = '0;
      exu_ioq_bcast.csr_wen = 1'b0;
      exu_ioq_bcast.csr_wdata = '0;
      exu_ioq_bcast.wen = 1'b0;
      exu_ioq_bcast.alu = '0;
      exu_ioq_bcast.sq_waddr = '0;
      exu_ioq_bcast.sq_wdata = '0;
      exu_ioq_bcast.sq_wdata64 = '0;
      exu_ioq_bcast.sq_fp64 = 1'b0;
      exu_ioq_bcast.trap = 1'b0;
      exu_ioq_bcast.tval = '0;
      exu_ioq_bcast.cause = '0;
      exu_ioq_bcast.difftest_skip = 1'b0;
      exu_ioq_bcast.valid = 1'b0;
      rou_lsu.store = 1'b0;
      rou_lsu.dest = '0;
      rou_lsu.sq_vaddr = '0;
      rou_lsu.pc = '0;
      rou_lsu.valid = 1'b0;
      sq_waddr_hi = '0;
      sq_waddr_third = '0;
      sq_wpbmt = '0;


      l1d_bus.rdata = '0;
      l1d_bus.rvalid = 1'b0;
      l1d_bus.ptw_rvalid = 1'b0;
      l1d_bus.ptw_rerr = 1'b0;
      l1d_bus.rlast = 1'b1;
      l1d_bus.difftest_skip = 1'b0;
      l1d_bus.rerr = 1'b0;
      l1d_bus.wready = 1'b1;
      l1d_bus.werr = 1'b0;
      l1d_bus.ptw_wready = 1'b0;
      l1d_bus.ptw_werr = 1'b0;

      pmp_update.addr_we = 1'b0;
      pmp_update.addr_idx = '0;
      pmp_update.raw_addr = '0;
      pmp_update.napot_mask = '0;
      pmp_update.cfg_we = '0;
      pmp_update.cfg_r = '0;
      pmp_update.cfg_w = '0;
      pmp_update.cfg_x = '0;
      pmp_update.cfg_l = '0;
      pmp_update.mode_off = '1;
      pmp_update.mode_tor = '0;
      pmp_update.mode_na4 = '0;
      pmp_update.mode_napot = '0;

      exu_l1d.mmu_en = 1'b0;
      exu_l1d.vaddr = '0;
      exu_l1d.walu = '0;
      exu_l1d.misaligned = 0;
      exu_l1d.cmo_mgmt = 1'b0;
      exu_l1d.valid = 1'b0;
      exu_l1d.reservation_clear = 1'b0;


      rou_cmu.slot[0].valid = 1'b0;
      rou_cmu.atomic_sc = 1'b0;
      rou_cmu.fence_time = 1'b0;
      rou_cmu.flush_pipe = 1'b0;
      exu_lsu.fp_rdata64_req = 0;
    end
  endtask
  logic [1:0] attr0, attr1;
  int delay_count, data_reads, io_reads, ptw_reads;
  logic pending_ptw;
  logic [63:0] response_data;
  assign l1d_bus.rready = l1d_bus.arvalid && delay_count == 0;
  always_ff @(posedge clock) begin
    if (reset) begin
      delay_count <= 0;
      data_reads <= 0;
      io_reads <= 0;
      ptw_reads <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        pending_ptw <= l1d_bus.ar_ptw;
        delay_count <= 3;
        if (l1d_bus.ar_ptw) begin
          ptw_reads <= ptw_reads + 1;
          case (l1d_bus.araddr[63:12])
            'h80001: response_data <= ('h80002000 >> 2) | 1;
            'h80002: response_data <= ('h80003000 >> 2) | 1;
            'h80003: response_data <= ((l1d_bus.araddr[3] ? 64'h82000000 : 64'h81000000) >> 2)
                        | 64'hcf | (64'(l1d_bus.araddr[3] ? attr1 : attr0) << 61);
            default: response_data <= 0;
          endcase
        end else begin
          response_data <= 64'h5555555555555555;
          data_reads <= data_reads + 1;
          if (l1d_bus.rpbmt == 2) io_reads <= io_reads + 1;
        end
      end else if (delay_count > 0) begin
        delay_count <= delay_count - 1;
        if (delay_count == 1) begin
          l1d_bus.rdata <= response_data;
          l1d_bus.rvalid <= !pending_ptw;
          l1d_bus.ptw_rvalid <= pending_ptw;
        end
      end
    end
  end
  initial begin
    for (int a = 0; a < 3; a++) begin
      for (int b = 0; b < 3; b++) begin
        reset = 1;
        init_inputs();
        attr0 = 2'(a);
        attr1 = 2'(b);
        tick(4);
        reset = 0;
        pmp_update.addr_we = 1;
        pmp_update.raw_addr = '1;
        pmp_update.napot_mask = '1;
        pmp_update.cfg_we = 1;
        pmp_update.cfg_r = 1;
        pmp_update.cfg_w = 1;
        pmp_update.cfg_x = 1;
        pmp_update.mode_off[0] = 0;
        pmp_update.mode_napot = 1;
        tick(1);
        pmp_update.addr_we = 0;
        pmp_update.cfg_we = 0;
        csr_bcast.dmmu_en = 1;
        csr_bcast.menvcfg_pbmte = 1;
        csr_bcast.satp_ppn = 'h80001;
        // SQ pre-split PMP defaults are M-mode permissive; L1D walks use the
        // installed allow-all PMP and the real page tables above.
        csr_bcast.mprv = 0;
        tick(2);
        exu_lsu.raddr = 'h40000fff;
        exu_lsu.ralu = `RAPT_ALU_LD__;
        exu_lsu.rvalid = 1;
        for (int c = 0; c < 200; c++) begin
          #1;
          check(!l1d_bus.arvalid || l1d_bus.ar_ptw || l1d_bus.rpbmt != 2,
                "split load presented an IO data read");
          if (exu_lsu.rready) begin
            check(exu_lsu.trap == (a == 2 || b == 2), "mixed-page split fault missing");
            if (a == 2 || b == 2) begin
              check(exu_lsu.cause == 5, "mixed-page IO fault class wrong");
              check(exu_lsu.tval == (a == 2 ? 64'h40000fff : 64'h40001000),
                    "mixed-page IO fault VA wrong");
            end else check(exu_lsu.rdata == 64'h5555555555555555, "split merge changed");
            check(io_reads == 0, "IO side effect escaped");
            check(data_reads == (a == 2 ? 0 : b == 2 ? 1 : 2), "wrong number of ordinary reads");
            check(ptw_reads == (a == 2 ? 3 : 6), "test did not walk both required pages");
            tick(1);
            exu_lsu.rvalid = 0;
            tick(4);
            break;
          end
          if (c == 199) fail("mixed-page IO split timeout");
          tick(1);
        end
      end
    end
    $display("PASS: real SQ/L1D split over all PMA/NC/IO page pairs, precise tval, zero IO reads");
    $finish;
  end
endmodule


// ---- tb_lsu_load_footprint ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_load_footprint;
  localparam int XLEN = `RAPT_XLEN;
  localparam int WB = XLEN / 8;
  localparam int LsuTbSqSize = 4;
  `include "tb_lsu_harness.svh"
  int cases = 0;
  initial begin
    for (int translated = 0; translated < 2; translated++)
    for (int width = 0; width < 4; width++)
    for (int offset = 0; offset < WB; offset++) begin
      automatic int bytes_count=1<<width;
      automatic int beats=(offset+bytes_count+WB-1)/WB;
      automatic logic [XLEN-1:0] va=XLEN'('h40000ff8)+XLEN'(offset);
      reset = 1;
      init_lsu_inputs(1, 0, 0);
      tick(3);
      reset = 0;
      tick(1);
      // Translated requests must reach L1D even when the VA has no PMP grant.
      if (translated != 0) begin
        csr_bcast.priv=`RAPT_PRIV_S;
        csr_bcast.dmmu_en=1;
      end
      exu_lsu.raddr=va;
      exu_lsu.fp_rdata64_req=XLEN==32 && width==3;
      case (width)
        0:exu_lsu.ralu=`RAPT_ALU_LBU_;
        1:exu_lsu.ralu=`RAPT_ALU_LHU_;
        2:exu_lsu.ralu=`RAPT_ALU_LW__;
        3:exu_lsu.ralu=XLEN==64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
      endcase
      exu_lsu.rvalid = 1;
      for (int beat = 0; beat < beats; beat++) begin
        automatic int first = -1, count = 0;
        for (int b = 0; b < bytes_count; b++)
        if ((offset + b) / WB == beat) begin
          if (first < 0) first = (offset + b) % WB;
          count++;
        end
        #1;
        check(lsu_l1d.rvalid && !exu_lsu.trap,
              "architectural footprint rejected before translation");
        check(int'(lsu_l1d.rorig_size_m1) == bytes_count - 1, "lost original access width");
        if (beats == 1) begin
          check(lsu_l1d.raddr == va && !lsu_l1d.rcheck_valid, "unnecessary split access");
        end else begin
          check(lsu_l1d.raddr == (va & ~XLEN'(WB - 1)) + XLEN'(beat) * XLEN'(WB),
                "split beat address");
          check(
              lsu_l1d.rcheck_valid && int'(lsu_l1d.rcheck_offset)==first
              && int'(lsu_l1d.rcheck_size_m1)==count-1,
              "split permission footprint exceeds actual bytes");
        end
        lsu_l1d.rdata=0;
        lsu_l1d.rready=1;
        #1;
        if (beats == 1) check(exu_lsu.rready, "single beat did not complete");
        tick(1);
        lsu_l1d.rready = 0;
      end
      #1;
      if (beats > 1) check(exu_lsu.rready && !exu_lsu.trap, "split response missing");
      exu_lsu.rvalid = 0;
      tick(2);
      cases++;
    end
    $display("PASS: LSU exact byte footprint and VA/PMP separation XLEN=%0d cases=%0d", XLEN,
             cases);
    $finish;
  end
endmodule


// ---- tb_lsu_lr_contract ----
// ---- tb_lsu_lr_sq_forward ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_lsu_lr_sq_forward;
  localparam int XLEN = 32;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam logic [31:0] TestAddr = 32'h8000_0080;
  localparam logic [31:0] StoreData = 32'h89ab_cdef;

  `include "tb_lsu_harness.svh"

  task automatic allocate_store;
    begin
      exu_ioq_bcast.valid = 1'b1;
      exu_ioq_bcast.wen = 1'b1;
      exu_ioq_bcast.alu = 6'b00_1111;
      exu_ioq_bcast.dest = 6'd7;
      exu_ioq_bcast.tval = TestAddr;
      exu_ioq_bcast.sq_waddr = TestAddr;
      exu_ioq_bcast.sq_wdata = StoreData;
      tick(1);
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.wen = 1'b0;
      tick(1);
    end
  endtask

  task automatic drive_allocate(input logic [31:0] addr, input logic [31:0] data,
                                input logic [5:0] dest);
    begin
      exu_ioq_bcast.valid = 1'b1;
      exu_ioq_bcast.wen = 1'b1;
      exu_ioq_bcast.alu = 6'b00_1111;
      exu_ioq_bcast.dest = dest;
      exu_ioq_bcast.tval = addr;
      exu_ioq_bcast.sq_waddr = addr;
      exu_ioq_bcast.sq_wdata = data;
    end
  endtask

  task automatic drive_commit(input logic [31:0] addr, input logic [31:0] data,
                              input logic [5:0] dest);
    begin
      rou_lsu.store = 1'b1;
      rou_lsu.dest = dest;
      rou_lsu.sq_vaddr = addr;
      rou_lsu.valid = 1'b1;
    end
  endtask

  initial begin
    init_lsu_inputs(1'b1, 32'h1020_3040, '0);
    tick(5);
    reset = 1'b0;
    tick(2);

    allocate_store();

    exu_lsu.rvalid = 1'b1;
    exu_lsu.raddr = TestAddr;
    exu_lsu.ralu = `RAPT_ALU_LW__;
    exu_lsu.atomic_lock = 1'b0;
    #1;
    check(exu_lsu.rready, "ordinary load did not forward from full-width SQ store");
    check(exu_lsu.rdata == StoreData, "ordinary SQ forwarding returned wrong data");
    check(!lsu_l1d.rvalid, "forwarded ordinary load unexpectedly reached L1D");

`ifdef RAPT_LSU_HUM
    exu_lsu.rvalid = 1'b0;
    csr_bcast.dmmu_en = 1'b1;
    exu_lsu.rvalid_b = 1'b1;
    exu_lsu.raddr_b = TestAddr;
    exu_lsu.ralu_b = `RAPT_ALU_LW__;
    #1;
    check(exu_lsu.rready_b, "MMU-enabled HUM load did not forward from SQ");
    check(exu_lsu.rdata_b == StoreData, "MMU-enabled HUM SQ forwarding returned wrong data");
    check(!lsu_l1d.rvalid_b, "MMU-enabled forwarded HUM load unexpectedly reached L1D");
    exu_lsu.rvalid_b = 1'b0;
`endif

    exu_lsu.raddr = TestAddr + 32'h1000;
    #1;
    check(!exu_lsu.rready, "MMU alias load incorrectly forwarded from a different VA");
    check(!lsu_l1d.rvalid, "MMU alias load bypassed a pending SQ store");
    exu_lsu.raddr = TestAddr;
    csr_bcast.dmmu_en = 1'b0;

    exu_lsu.rvalid = 1'b1;
    exu_lsu.atomic_lock = 1'b1;
    #1;
    check(!exu_lsu.rready, "LR incorrectly completed through SQ forwarding");
    check(!lsu_l1d.rvalid, "LR reached L1D before the older store drained");
    tick(2);
    check(!exu_lsu.rready, "blocked LR became ready while SQ store remained pending");

    exu_lsu.rvalid = 1'b0;
    rou_lsu.store = 1'b1;
    rou_lsu.dest = 6'd7;
    rou_lsu.sq_vaddr = TestAddr;
    rou_lsu.valid = 1'b1;
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;
    lsu_l1d.wready = 1'b1;
    tick(3);

    exu_lsu.rvalid = 1'b1;
    exu_lsu.atomic_lock = 1'b1;
    #1;
    check(lsu_l1d.rvalid, "LR did not reach L1D after the older store drained");
    check(lsu_l1d.atomic_lock, "LR request lost atomic_lock at the L1D boundary");
    lsu_l1d.rready = 1'b1;
    #1;
    check(exu_lsu.rready, "LR did not complete from L1D");
    check(exu_lsu.rdata == 32'h1020_3040, "LR returned wrong L1D data");

    exu_lsu.rvalid = 1'b0;
    lsu_l1d.rready = 1'b0;
    lsu_l1d.wready = 1'b0;
    reset = 1'b1;
    tick(2);
    reset = 1'b0;
    tick(1);

    drive_allocate(32'h8000_0100, 32'hc4aa_4680, 6'd10);
    tick(1);
    drive_allocate(32'h8000_0104, 32'hc4bb_4680, 6'd11);
    tick(1);
    exu_ioq_bcast.valid = 1'b0;
    exu_ioq_bcast.wen = 1'b0;
    drive_commit(32'h8000_0100, 32'hc4aa_4680, 6'd10);
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;

    lsu_l1d.wready = 1'b1;
    #1;
    check(lsu_l1d.wvalid, "first committed store was not presented");
    check(lsu_l1d.waddr == 32'h8000_0100, "first store address was corrupted");
    check(lsu_l1d.wdata == 32'hc4aa_4680, "first store lost bit 30");
    tick(1);

    drive_allocate(32'h8000_0108, 32'hc4cc_4680, 6'd12);
    drive_commit(32'h8000_0104, 32'hc4bb_4680, 6'd11);
    tick(1);
    exu_ioq_bcast.valid = 1'b0;
    exu_ioq_bcast.wen = 1'b0;
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;
    #1;
    check(lsu_l1d.wvalid, "second store disappeared after alloc+commit+drain");
    check(lsu_l1d.waddr == 32'h8000_0104, "second store address was corrupted");
    check(lsu_l1d.wdata == 32'hc4bb_4680, "second store lost bit 30");
    tick(1);
    tick(1);

    drive_commit(32'h8000_0108, 32'hc4cc_4680, 6'd12);
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;
    #1;
    check(lsu_l1d.wvalid, "third store disappeared after concurrent allocation");
    check(lsu_l1d.waddr == 32'h8000_0108, "third store address was corrupted");
    check(lsu_l1d.wdata == 32'hc4cc_4680, "third store lost bit 30");
    tick(2);
    check(dut.sq_all_empty, "SQ did not empty after lifecycle stress");

    reset = 1'b1;
    lsu_l1d.rready = 1'b0;
    tick(2);
    reset = 1'b0;
    tick(1);

    exu_lsu.rvalid = 1'b1;
    exu_lsu.atomic_lock = 1'b0; // ordinary split load, not the earlier LR
    exu_lsu.raddr = 32'h8000_0201;
    exu_lsu.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rready = 1'b1;
    lsu_l1d.rdata = 32'h4433_2211;
    #1;
    check(lsu_l1d.raddr == 32'h8000_0200, "misaligned low beat used wrong address");
    check(!exu_lsu.rready, "misaligned load completed before its high beat");
    tick(1);

    lsu_l1d.rdata = 32'h8877_6655;
    #1;
    check(lsu_l1d.raddr == 32'h8000_0204, "misaligned high beat used wrong address");
    check(!exu_lsu.rready, "misaligned load completed on its high-beat cycle");
    tick(1);

    #1;
    check(exu_lsu.rready, "merged misaligned load did not complete");
    check(exu_lsu.rdata == 32'h5544_3322, "misaligned load merged the wrong bytes");
    tick(1);

    exu_lsu.raddr = 32'h8000_0300;
    lsu_l1d.rdata = 32'hdead_beef;
    #1;
    check(exu_lsu.rready, "no-bubble aligned follower did not complete");
    check(exu_lsu.rdata == 32'hdead_beef, "aligned follower consumed stale misaligned merged data");

    $display("PASS: LSU forwarding and concurrent SQ lifecycle preserve store data");
    $finish;
  end
endmodule


// ---- tb_lsu_lr_alignment ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_lr_alignment;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  `include "tb_lsu_harness.svh"
  int cases = 0;
  initial begin
    for (int translated = 0; translated < 2; translated++)
    for (int bytes = 4; bytes <= XLEN / 8; bytes += 4)
    for (int offset = 1; offset < bytes; offset++) begin
      reset = 1;
      init_lsu_inputs(1, 0, 0);
      tick(3);
      reset = 0;
      tick(1);
      csr_bcast.dmmu_en=1'(translated);
      exu_lsu.raddr=XLEN'('h80001000)+XLEN'(offset);
      exu_lsu.ralu=bytes==4 ? `RAPT_ALU_LW__ : `RAPT_ALU_LD__;
      exu_lsu.atomic_lock=1;
      exu_lsu.rvalid=1;
      for (int n = 0; n < 10; n++) begin
        #1;
        check(!lsu_l1d.rvalid, "misaligned LR escaped into cache/split path");
        if (exu_lsu.rready) break;
        tick(1);
      end
      check(exu_lsu.rready && exu_lsu.trap && exu_lsu.cause == 5,
            "misaligned LR did not complete with access fault");
      check(exu_lsu.tval == exu_lsu.raddr, "LR fault lost original VA");
      cases++;
    end
    $display("PASS: LR alignment before split XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule


// ---- tb_lsu_split_fault ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_split_fault;
  localparam int XLEN = `RAPT_XLEN;
  localparam int BeatBytes = XLEN / 8;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  `include "tb_lsu_harness.svh"
  task automatic run_fault(input int offset, input int fault_beat,
                           input logic [XLEN-1:0] fault_cause, input bit half = 0);
    logic [XLEN-1:0] va, expected;
    reset = 1;
    init_lsu_inputs(1, 0, 0);
    csr_bcast.dmmu_en = 1;
    tick(3);
    reset = 0;
    tick(1);
    va = 'h40000000 + XLEN'(offset);
    exu_lsu.raddr = va;
    exu_lsu.ralu = half ? `RAPT_ALU_LH__ : (XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__);
    exu_lsu.fp_rdata64_req = !half && XLEN == 32;
    exu_lsu.rvalid = 1;
    for (int beat = 0; beat <= fault_beat; beat++) begin
      #1;
      expected = (va & ~(XLEN'(BeatBytes) - XLEN'(1))) + XLEN'(beat) * XLEN'(BeatBytes);
      check(lsu_l1d.rvalid && lsu_l1d.raddr == expected, "split request address mismatch");
      if (half) check(lsu_l1d.rorig_size_m1 == 4'd1, "half split lost original two-byte width");
      check(lsu_l1d.rmisaligned == ((offset % (half ? 2 : 8)) != 0),
            "split request lost original alignment");
      lsu_l1d.rready = 0;
      tick(3);
      lsu_l1d.trap = beat == fault_beat;
      lsu_l1d.difftest_skip = 1;
      lsu_l1d.cause = fault_cause;
      lsu_l1d.rready = 1;
      tick(1);
      lsu_l1d.rready = 0;
      lsu_l1d.trap = 0;
    end
    lsu_l1d.cause = '1;
    #1;
    check(exu_lsu.rready && exu_lsu.trap && exu_lsu.cause == fault_cause,
          "split fault/cause did not persist until response");
    check(!exu_lsu.difftest_skip, "split fault incorrectly skipped reference");
    check(exu_lsu.tval == (fault_beat == 0 ? va : expected),
          "split fault VA was replaced or aligned down");
    tick(1);
    exu_lsu.rvalid = 0;
    tick(1);
  endtask
  task automatic run_success(input int skip_beat);
    reset = 1;
    init_lsu_inputs(1, 0, 0);
    tick(3);
    reset = 0;
    tick(1);
    exu_lsu.raddr=XLEN'('h80000001);
    exu_lsu.ralu=XLEN==64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    exu_lsu.fp_rdata64_req=XLEN==32;
    exu_lsu.rvalid=1;
    for (int beat = 0; beat < (XLEN == 32 ? 3 : 2); beat++) begin
      #1;
      check(lsu_l1d.rvalid, "split success request missing");
      lsu_l1d.difftest_skip=beat==skip_beat;
      lsu_l1d.rdata=0;
      lsu_l1d.rready=1;
      tick(1);
      lsu_l1d.rready = 0;
    end
    lsu_l1d.difftest_skip = 0;
    #1;
    check(exu_lsu.rready && !exu_lsu.trap, "split success response missing");
    check(exu_lsu.difftest_skip == (skip_beat >= 0),
          "split skip must reflect actual consumed beats");
    tick(1);
    exu_lsu.rvalid = 0;
    tick(1);
  endtask
  initial begin
    for (int skip_beat = -1; skip_beat < (XLEN == 32 ? 3 : 2); skip_beat++) run_success(skip_beat);
    $display(
        "PASS: successful RAM split loads compare reference; per-beat device skip retained XLEN=%0d",
        XLEN);
    run_fault(4092, 0, `RAPT_CAUSE_LOAD_ACC_FAULT);
    if (XLEN == 32) run_fault(4088, 0, `RAPT_CAUSE_LOAD_ACC_FAULT);
    run_fault(4095, 0, `RAPT_CAUSE_LOAD_PAGE_FAULT);
    run_fault(4095, 1, `RAPT_CAUSE_LOAD_PAGE_FAULT);
    run_fault(4095, 1, `RAPT_CAUSE_LOAD_ACC_FAULT);
    if (XLEN == 32) run_fault(4089, 2, `RAPT_CAUSE_LOAD_PAGE_FAULT);
    for (int beat = 0; beat < 2; beat++) begin
      run_fault(4095, beat, `RAPT_CAUSE_LOAD_ACC_FAULT, 1);
      run_fault(4095, beat, `RAPT_CAUSE_LOAD_PAGE_FAULT, 1);
    end
    $display("PASS: half split first/second beat access/page faults XLEN=%0d SQ=%0d cases=4", XLEN,
             LsuTbSqSize);
    $display("PASS: split load fault address/cause retained for first, second and RV32 third beat");
    $finish;
  end
endmodule


// ---- tb_lsu_sq_random ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_lsu_sq_random;
  localparam int XLEN = 32;
  localparam int SQ_SIZE = 4;
  localparam int LsuTbSqSize = SQ_SIZE;
  localparam int CYCLES = 10000;

  `include "tb_lsu_harness.svh"

  logic model_valid[SQ_SIZE];
  logic model_committed[SQ_SIZE];
  logic [31:0] model_vaddr[SQ_SIZE];
  logic [31:0] model_paddr[SQ_SIZE];
  logic [31:0] model_data[SQ_SIZE];
  logic [4:0] model_alu[SQ_SIZE];
  logic [5:0] model_dest[SQ_SIZE];
  int context_epoch;
  int store_epoch[SQ_SIZE];
  int model_head;
  int model_cmt;
  int model_tail;
  int next_dest;
  bit drain_pending;

  int cover_wrap;
  int cover_full;
  int cover_flush;
  int cover_concurrent;
  int cover_mmu_alias;
  int cover_mmu_bypass;
  int cover_exact_fwd;
  int cover_partial_block;
  int cover_bare_bypass;
  int drain_count;

  function automatic int next_index(input int index);
    return (index + 1) % SQ_SIZE;
  endfunction

  function automatic int valid_count;
    int count = 0;
    for (int index = 0; index < SQ_SIZE; index++) count += model_valid[index];
    return count;
  endfunction

  function automatic int youngest_match(input logic [31:0] addr);
    int result = -1;
    int index = model_head;
    for (int age = 0; age < SQ_SIZE; age++) begin
      if (model_valid[index] && model_vaddr[index][31:2] == addr[31:2]) result = index;
      index = next_index(index);
    end
    return result;
  endfunction

  function automatic bit mmu_pageoff_conflict(input logic [31:0] addr);
    bit result = 1'b0;
    for (int index = 0; index < SQ_SIZE; index++) begin
      result |= model_valid[index] && (model_vaddr[index][11:2] == addr[11:2]);
    end
    result |= exu_ioq_bcast.valid && exu_ioq_bcast.wen && (exu_ioq_bcast.tval[11:2] == addr[11:2]);
    return result;
  endfunction

  task automatic clear_model;
    begin
      for (int index = 0; index < SQ_SIZE; index++) begin
        model_valid[index] = 1'b0;
        model_committed[index] = 1'b0;
        model_vaddr[index] = '0;
        model_paddr[index] = '0;
        model_data[index] = '0;
        model_alu[index] = '0;
        model_dest[index] = '0;
      end
      context_epoch = 0;
      for (int index = 0; index < SQ_SIZE; index++) store_epoch[index] = 0;
      model_head = 0;
      model_cmt = 0;
      model_tail = 0;
      next_dest = 1;
      drain_pending = 1'b0;
    end
  endtask

  task automatic check_store_output;
    begin
      if (drain_pending) begin
        check(!lsu_l1d.wvalid, "SQ presented a second store while retiring an accepted store");
      end else if (model_valid[model_head] && model_committed[model_head]) begin
        check(lsu_l1d.wvalid, "committed SQ head was not presented to L1D");
        check(lsu_l1d.waddr == model_paddr[model_head], "SQ drain address/order mismatch");
        check(lsu_l1d.wdata == model_data[model_head], "SQ drain data mismatch");
        check(lsu_l1d.walu == 8'(model_alu[model_head]), "SQ drain width mismatch");
      end else begin
        check(!lsu_l1d.wvalid, "SQ presented an uncommitted or invalid store");
      end
    end
  endtask

  task automatic drive_load_probe(input int kind);
    int match;
    int candidate;
    bit allocation_conflict;
    logic [31:0] probe_addr;
    begin
      exu_lsu.rvalid = 1'b1;
      exu_lsu.atomic_lock = 1'b0;
      exu_lsu.ralu = `RAPT_ALU_LW__;
      probe_addr = 32'h8100_0000 | (($urandom & 32'h000003ff) << 2);
      match = -1;

      if ((kind == 0 || kind == 1 || kind == 2 || kind == 3) && valid_count() != 0) begin
        candidate = model_head;
        for (int age = 0; age < SQ_SIZE; age++) begin
          if (model_valid[candidate]
              && ((kind == 0 && model_alu[candidate] == `RAPT_SW_WSTRB)
                  || (kind == 1 && model_alu[candidate] != `RAPT_SW_WSTRB)
                  || kind == 2 || kind == 3))
            probe_addr = model_vaddr[candidate] + ((kind == 2) ? 32'h0040_0000 : 32'h0);
          candidate = next_index(candidate);
        end
        match = youngest_match(probe_addr);
      end else begin
        for (int attempt = 0; attempt < SQ_SIZE + 1; attempt++) begin
          if ((kind == 4) ? !mmu_pageoff_conflict(probe_addr) : (youngest_match(probe_addr) < 0))
            break;
          probe_addr += 32'h0000_0004;
        end
      end

      csr_bcast.dmmu_en = (kind == 2 || kind == 4);
      exu_lsu.atomic_lock = (kind == 3);
      exu_lsu.raddr = probe_addr;
      #1;

      // Track address identity by recovery epoch, independently of DUT flags.
      // Search youngest first: an unresolved younger alias masks older data.
      match = -1;
      for (int age = SQ_SIZE - 1; age >= 0; age--) begin
        candidate = (model_head + age) % SQ_SIZE;
        if (model_valid[candidate] &&
            ((csr_bcast.dmmu_en || store_epoch[candidate] != context_epoch)
             ? model_vaddr[candidate][11:2] == probe_addr[11:2]
             : model_vaddr[candidate][31:2] == probe_addr[31:2])) begin
          match = candidate;
          break;
        end
      end
      allocation_conflict = exu_ioq_bcast.valid && exu_ioq_bcast.wen &&
          (csr_bcast.dmmu_en ? exu_ioq_bcast.tval[11:2] == probe_addr[11:2]
                            : exu_ioq_bcast.tval[31:2] == probe_addr[31:2]);
      if (allocation_conflict || (match >= 0 &&
          (store_epoch[match] != context_epoch || model_vaddr[match][31:2] != probe_addr[31:2]))) begin
        check(!exu_lsu.rready && !lsu_l1d.rvalid, "unresolved address identity bypassed SQ");
        cover_mmu_alias++;
      end else if ((kind == 2 || kind == 4) && mmu_pageoff_conflict(probe_addr)) begin
        check(!exu_lsu.rready && !lsu_l1d.rvalid,
              "DMMU load bypassed a possible physical alias in SQ");
        cover_mmu_alias++;
      end else if (kind == 2 || kind == 4) begin
        check(lsu_l1d.rvalid, "DMMU load with a disjoint page offset was unnecessarily blocked");
        cover_mmu_bypass++;
      end else if (kind == 3 && match >= 0) begin
        check(!exu_lsu.rready && !lsu_l1d.rvalid, "LR bypassed a matching pending SQ store");
      end else if (match >= 0 && model_alu[match] == `RAPT_SW_WSTRB) begin
        check(exu_lsu.rready, "youngest full-width SQ match did not forward");
        check(exu_lsu.rdata == model_data[match], "youngest SQ forwarding data mismatch");
        check(!lsu_l1d.rvalid, "forwarded load reached L1D");
        cover_exact_fwd++;
      end else if (match >= 0) begin
        check(!exu_lsu.rready && !lsu_l1d.rvalid, "partial matching store did not block load");
        cover_partial_block++;
      end else begin
        check(lsu_l1d.rvalid, $sformatf(
              {
                "unrelated bare load blocked kind=%0d addr=%08x model=%0d ",
                "dut_valid=%b load_in_sq=%b mmio=%b store_state=%0d"
              },
              kind,
              probe_addr,
              valid_count(),
              dut.sq_valid,
              dut.load_in_sq,
              dut.mmio_load_blocked,
              dut.state_store
              ));
        cover_bare_bypass++;
      end
    end
  endtask

  initial begin
    automatic int seed = 32'h51ab_2026;
    int requested_seed;
    int random_discard;
    bit do_alloc;
    bit do_commit;
    bit do_flush;
    bit accepted_store;
    int old_tail;
    int old_cmt;
    int old_head;
    logic [31:0] alloc_base;
    logic [31:0] alloc_data;
    logic [4:0] alloc_width;

    if ($value$plusargs("SEED=%d", requested_seed)) seed = requested_seed;
    random_discard = $urandom(seed);
    init_lsu_inputs(1'b0, 32'h5a5a_a5a5, `RAPT_ALU_LW__);
    clear_model();
    tick(5);
    reset = 1'b0;
    tick(2);

    // A store leaves the IOQ and allocates its SQ entry on this edge. The
    // younger MMU load must not slip into L1D during the one-cycle ownership
    // handoff before sq_valid reflects the new entry.
    @(negedge clock);
    csr_bcast.dmmu_en = 1'b1;
    exu_ioq_bcast.valid = 1'b1;
    exu_ioq_bcast.wen = 1'b1;
    exu_ioq_bcast.alu = `RAPT_SB_WSTRB;
    exu_ioq_bcast.dest = $bits(exu_ioq_bcast.dest)'(next_dest);
    exu_ioq_bcast.tval = 32'h4000_0008;
    exu_ioq_bcast.sq_waddr = 32'h8000_2008;
    exu_ioq_bcast.sq_wdata = 32'h0000_0082;
    exu_lsu.rvalid = 1'b1;
    exu_lsu.raddr = 32'h4040_0008;
    exu_lsu.ralu = `RAPT_ALU_LBU_;
    #1;
    check(!lsu_l1d.rvalid, "DMMU load entered L1D during same-cycle SQ allocation handoff");
    exu_lsu.raddr = 32'h4040_000c;
    #1;
    check(lsu_l1d.rvalid, "DMMU load with a different page offset did not bypass SQ allocation");
    reset = 1'b1;
    tick(1);
    init_lsu_inputs(1'b0, 32'h5a5a_a5a5, `RAPT_ALU_LW__);
    reset = 1'b0;
    tick(2);

    for (int cycle = 0; cycle < CYCLES; cycle++) begin
      @(negedge clock);
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.wen = 1'b0;
      rou_lsu.valid = 1'b0;
      rou_lsu.store = 1'b0;
      cmu_bcast.flush_pipe = 1'b0;
      csr_bcast.dmmu_en = 1'b0;
      exu_lsu.rvalid = 1'b0;
      exu_lsu.atomic_lock = 1'b0;
      lsu_l1d.wready = ($urandom_range(0, 3) != 0);

      check_store_output();
      accepted_store = lsu_l1d.wvalid && lsu_l1d.wready;

      do_flush = !drain_pending && ($urandom_range(0, 63) == 0);
      do_alloc = !do_flush && !model_valid[model_tail] && ($urandom_range(0, 2) != 0);
      do_commit = !do_flush && model_valid[model_cmt] && !model_committed[model_cmt]
                  && ($urandom_range(0, 2) != 0);

      if (do_alloc) begin
        alloc_base = 32'h8000_0000 | (($urandom & 32'h00000fff) << 2);
        alloc_data = ($urandom | 32'h4000_0000);
        case ($urandom_range(
            0, 3
        ))
          0: alloc_width = `RAPT_SB_WSTRB;
          1: alloc_width = `RAPT_SH_WSTRB;
          default: alloc_width = `RAPT_SW_WSTRB;
        endcase
        exu_ioq_bcast.valid = 1'b1;
        exu_ioq_bcast.wen = 1'b1;
        exu_ioq_bcast.alu = {1'b0, alloc_width};
        exu_ioq_bcast.dest = $bits(exu_ioq_bcast.dest)'(next_dest);
        exu_ioq_bcast.tval = alloc_base;
        exu_ioq_bcast.sq_waddr = alloc_base ^ 32'h0040_0000;
        exu_ioq_bcast.sq_wdata = alloc_data;
      end

      if (do_commit) begin
        rou_lsu.valid = 1'b1;
        rou_lsu.store = 1'b1;
        rou_lsu.dest = model_dest[model_cmt];
        rou_lsu.sq_vaddr = model_vaddr[model_cmt];
      end

      if (do_flush) begin
        cmu_bcast.flush_pipe = 1'b1;
        cover_flush++;
      end

      if ((cycle & 3) == 0) drive_load_probe($urandom_range(0, 4));
      else #1;

      if (do_alloc && do_commit && (drain_pending || accepted_store)) cover_concurrent++;
      if (valid_count() == SQ_SIZE) cover_full++;

      old_tail = model_tail;
      old_cmt = model_cmt;
      old_head = model_head;
      @(posedge clock);
      #1;

      if (do_flush) begin
        context_epoch++;
        for (int index = 0; index < SQ_SIZE; index++) begin
          if (model_valid[index] && !model_committed[index]) model_valid[index] = 1'b0;
        end
        model_tail = model_cmt;
      end else begin
        if (do_alloc) begin
          store_epoch[old_tail] = context_epoch;
          model_valid[old_tail] = 1'b1;
          model_committed[old_tail] = 1'b0;
          model_vaddr[old_tail] = exu_ioq_bcast.tval;
          model_paddr[old_tail] = exu_ioq_bcast.sq_waddr;
          model_data[old_tail] = exu_ioq_bcast.sq_wdata;
          model_alu[old_tail] = exu_ioq_bcast.alu[4:0];
          model_dest[old_tail] = exu_ioq_bcast.dest;
          model_tail = next_index(old_tail);
          next_dest++;
          if (model_tail == 0) cover_wrap++;
        end
        if (do_commit) begin
          model_committed[old_cmt] = 1'b1;
          model_cmt = next_index(old_cmt);
        end
      end

      if (drain_pending) begin
        model_valid[old_head] = 1'b0;
        model_committed[old_head] = 1'b0;
        model_head = next_index(old_head);
        drain_count++;
      end
      drain_pending = accepted_store;
    end

    exu_lsu.rvalid = 1'b0;
    csr_bcast.dmmu_en = 1'b0;
    cmu_bcast.flush_pipe = 1'b0;
    while (valid_count() != 0 || drain_pending) begin
      @(negedge clock);
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.wen = 1'b0;
      rou_lsu.valid = 1'b0;
      rou_lsu.store = 1'b0;
      lsu_l1d.wready = 1'b1;
      check_store_output();
      accepted_store = lsu_l1d.wvalid;
      do_commit = model_valid[model_cmt] && !model_committed[model_cmt];
      old_cmt = model_cmt;
      old_head = model_head;
      if (do_commit) begin
        rou_lsu.valid = 1'b1;
        rou_lsu.store = 1'b1;
        rou_lsu.dest = model_dest[model_cmt];
        rou_lsu.sq_vaddr = model_vaddr[model_cmt];
      end
      @(posedge clock);
      #1;
      if (do_commit) begin
        model_committed[old_cmt] = 1'b1;
        model_cmt = next_index(old_cmt);
      end
      if (drain_pending) begin
        model_valid[old_head] = 1'b0;
        model_committed[old_head] = 1'b0;
        model_head = next_index(old_head);
        drain_count++;
      end
      drain_pending = accepted_store;
    end

    check(cover_wrap > 20, "insufficient SQ wrap coverage");
    check(cover_full > 0, "SQ full state was not covered");
    check(cover_flush > 20, "insufficient flush coverage");
    check(cover_concurrent > 0, "alloc+commit+drain concurrency was not covered");
    check(cover_mmu_alias > 20, "insufficient MMU alias coverage");
    check(cover_mmu_bypass > 20, "insufficient MMU page-offset bypass coverage");
    check(cover_exact_fwd > 20, "insufficient exact forwarding coverage");
    check(cover_partial_block > 10, "insufficient partial-store coverage");
    check(cover_bare_bypass > 20, "insufficient bare bypass coverage");
    check(drain_count > 100, "insufficient store drain coverage");

    $display(
        "PASS: randomized LSU SQ scoreboard seed=%0d wraps=%0d flush=%0d concurrent=%0d alias=%0d mmu_bypass=%0d fwd=%0d partial=%0d drains=%0d",
        seed, cover_wrap, cover_flush, cover_concurrent, cover_mmu_alias, cover_mmu_bypass,
        cover_exact_fwd, cover_partial_block, drain_count);
    $finish;
  end
endmodule


// ---- tb_lsu_store_observation ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_lsu_store_observation;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  localparam logic [XLEN-1:0] Address = XLEN'(64'h1234_5678_8000_0040);
  localparam logic [XLEN-1:0] Data = XLEN'(64'hfedc_ba98_7654_3210);
  localparam logic [63:0] FpData = 64'hd00d_beef_1357_2468;
  `include "tb_lsu_harness.svh"

  task automatic allocate_store(input int owner, input logic [XLEN-1:0] addr,
                                input logic [XLEN-1:0] data, input logic fp64,
                                input logic [4:0] walu);
    begin
      exu_ioq_bcast.dest = rapt_pkg::rob_index_t'(owner);
      exu_ioq_bcast.tval = addr;
      exu_ioq_bcast.sq_waddr = addr;
      sq_waddr_hi = addr + XLEN'(4);
      exu_ioq_bcast.sq_wdata = fp64 ? XLEN'(FpData) : data;
      exu_ioq_bcast.sq_wdata64 = FpData;
      exu_ioq_bcast.sq_fp64 = fp64;
      exu_ioq_bcast.alu = {1'b0, walu};
      exu_ioq_bcast.valid = 1'b1;
      exu_ioq_bcast.wen = 1'b1;
      tick(1);
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.wen = 1'b0;
    end
  endtask

  task automatic check_resident_observation(input logic fp64, input logic [4:0] walu);
    int beats;
    logic [XLEN-1:0] expected_addr, expected_data;
    logic [7:0] expected_mask;
    begin
      reset = 1'b1;
      init_lsu_inputs(1'b0, '0, '0);
      tick(4);
      reset = 1'b0;
      tick(1);
      allocate_store(3, Address, Data, fp64, walu);
      allocate_store(4, Address + XLEN'(32), ~Data, 1'b0, `RAPT_SW_WSTRB);
      // Neither the younger resident nor a subsequent completion may supply
      // the retiring store's observation. Hold the drain back throughout.
      exu_ioq_bcast.dest = '1;
      exu_ioq_bcast.sq_waddr = ~Address;
      exu_ioq_bcast.sq_wdata = ~Data;
      exu_ioq_bcast.sq_wdata64 = ~FpData;
      exu_ioq_bcast.sq_fp64 = !fp64;
      exu_ioq_bcast.alu = '0;
      tick(3);
      expected_addr = (XLEN == 32 && fp64) ? Address + XLEN'(4) : Address;
      expected_data = (XLEN == 32 && fp64) ? XLEN'(FpData[63:32]) : Data;
      expected_mask = (XLEN == 32 && fp64) ? 8'h0f : {3'b0, walu};
      rou_lsu.dest = rapt_pkg::rob_index_t'(3);
      rou_lsu.sq_vaddr = Address;
      rou_lsu.store = 1'b1;
      rou_lsu.valid = 1'b1;
      cmu_bcast.flush_pipe = 1'b1;
      #1;
      check(
          dut.difftest_store_addr == expected_addr
            && dut.difftest_store_data == expected_data
            && dut.difftest_store_wstrb == expected_mask,
          "commit observation did not select the durable SQ owner/final RV32D write");
      tick(1);
      rou_lsu.valid = 1'b0;
      rou_lsu.store = 1'b0;
      cmu_bcast.flush_pipe = 1'b0;
      check(dut.sq_valid[0] && dut.sq_committed[0] && !dut.sq_valid[1],
            "commit+flush did not preserve exactly the retired owner");
      lsu_l1d.wready = 1'b1;
      beats = 0;
      #1;
      for (int cycle = 0; cycle < 24 && !rou_lsu.sq_empty; cycle++) begin
        if (lsu_l1d.wvalid) begin
          check(lsu_l1d.waddr == Address + XLEN'(beats * (XLEN / 8)),
                "drain address was corrupted or a flushed younger store escaped");
          if (XLEN == 32 && fp64)
            check(lsu_l1d.wdata == XLEN'(beats == 0 ? FpData[31:0] : FpData[63:32]),
                  "RV32D drain payload was not persistent");
          else check(lsu_l1d.wdata == Data, "drain payload was not persistent");
          beats++;
        end
        tick(1);
      end
      check(rou_lsu.sq_empty && beats == ((XLEN == 32 && fp64) ? 2 : 1),
            "store drain did not complete exactly once per expected beat");
    end
  endtask

  task automatic check_commit_boundary_not_head;
    int beats;
    begin
      reset = 1'b1;
      init_lsu_inputs(1'b0, '0, '0);
      tick(4);
      reset = 1'b0;
      tick(1);
      allocate_store(1, Address, Data, 1'b0, `RAPT_SW_WSTRB);
      rou_lsu.dest = rapt_pkg::rob_index_t'(1);
      rou_lsu.sq_vaddr = Address;
      rou_lsu.valid = 1'b1;
      rou_lsu.store = 1'b1;
      #1;
      check(dut.difftest_store_addr == Address && dut.difftest_store_data == Data,
            "normal commit did not observe the first resident");
      tick(1);
      rou_lsu.valid = 1'b0;
      rou_lsu.store = 1'b0;
      allocate_store(2, Address + XLEN'(32), ~Data, 1'b0, `RAPT_SW_WSTRB);
      allocate_store(3, Address + XLEN'(64), '0, 1'b0, `RAPT_SW_WSTRB);
      check(dut.sq_head == 0 && dut.sq_cmt == 1, "test did not separate commit and drain pointers");
      rou_lsu.dest = rapt_pkg::rob_index_t'(2);
      rou_lsu.sq_vaddr = Address + XLEN'(32);
      rou_lsu.valid = 1'b1;
      rou_lsu.store = 1'b1;
      cmu_bcast.flush_pipe = 1'b1;
      #1;
      check(dut.difftest_store_addr == Address + XLEN'(32) && dut.difftest_store_data == ~Data,
            "observation selected the old drain head or a younger completion");
      tick(1);
      rou_lsu.valid = 1'b0;
      rou_lsu.store = 1'b0;
      cmu_bcast.flush_pipe = 1'b0;
      check(dut.sq_committed[0] && dut.sq_committed[1] && !dut.sq_valid[2],
            "commit+flush lost older committed state or retained a younger store");
      lsu_l1d.wready = 1'b1;
      beats = 0;
      #1;
      for (int cycle = 0; cycle < 24 && !rou_lsu.sq_empty; cycle++) begin
        if (lsu_l1d.wvalid) begin
          check(
              lsu_l1d.waddr == Address + XLEN'(beats * 32)
                && lsu_l1d.wdata == (beats == 0 ? Data : ~Data),
              "committed stores did not drain in program order after flush");
          beats++;
        end
        tick(1);
      end
      check(rou_lsu.sq_empty && beats == 2, "committed residents did not drain exactly once");
    end
  endtask

  initial begin
    check_resident_observation(1'b0, XLEN == 64 ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB);
    // FSD uses the SD size encoding even on RV32; fp64 selects its payload.
    if (XLEN == 32) check_resident_observation(1'b1, `RAPT_SD_WSTRB);
    check_commit_boundary_not_head();
    $display(
        "PASS: SQ-owned store observation, poisoned completion, commit+flush and drain (XLEN=%0d)",
        XLEN);
    $finish;
  end
endmodule
