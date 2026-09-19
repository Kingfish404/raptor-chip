`include "rapt.svh"
`include "rapt_if.svh"
module tb_mshr_cache;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Words = `RAPT_CACHE_LINE_BYTES / (XLEN/8);
  bit clock = 0;
  always #5 clock = ~clock;
  logic reset = 1;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (.external_write_valid_i(1'b0), .external_write_pending_i(1'b0),
      .external_write_first_i('0), .external_write_last_i('0), .*);
  `include "tb_l1d_defaults.svh"
  int requests = 0;
  logic [XLEN-1:0] issued_addr[4];
  logic [3:0] outstanding = 0;
  always @(posedge clock) if (!reset && l1d_bus.arvalid && l1d_bus.rready) begin
    if (!l1d_bus.ar_mshr || l1d_bus.ar_ptw || l1d_bus.arlen != 8'(Words-1))
      $fatal(1, "expected tagged line request: mshr=%b ptw=%b len=%d eligible=%b safe=%b allowed=%b atomic=%b misaligned=%b",l1d_bus.ar_mshr,l1d_bus.ar_ptw,l1d_bus.arlen,dut.mshr_eligible,dut.refill_safe,lsu_l1d.replay_allowed,dut.l1d_atomic_lock,dut.l1d_orig_misaligned);
    if (outstanding[l1d_bus.ar_mshr_id]) $fatal(1, "MSHR ID reused before RLAST");
    issued_addr[l1d_bus.ar_mshr_id] = l1d_bus.araddr;
    outstanding[l1d_bus.ar_mshr_id] = 1;
    requests++;
  end
  function automatic logic [XLEN-1:0] value(input logic [XLEN-1:0] a);
    return a ^ XLEN'('h12345678);
  endfunction
  task automatic lookup(input logic [XLEN-1:0] a, input bit miss, input bit fault=0);
    @(negedge clock);
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = a;
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    for (int n=0; n<100; n++) begin
      @(posedge clock);
      if (lsu_l1d.rmiss || lsu_l1d.rready) begin
        if (lsu_l1d.rmiss != miss || (lsu_l1d.rready && lsu_l1d.trap != fault))
          $fatal(1, "unexpected lookup disposition addr=%h",a);
        if (!miss && !fault && lsu_l1d.rdata != value(a))
          $fatal(1, "wrong replay data addr=%h got=%h",a,lsu_l1d.rdata);
        @(negedge clock); lsu_l1d.rvalid = 0;
        repeat (3) @(negedge clock);
        return;
      end
    end
    $fatal(1, "lookup did not release or complete %h",a);
  endtask
  task automatic refill(input int id, input int bad_word=-1, input int first_word=0);
    if (!outstanding[id]) $fatal(1,"no outstanding ID %0d",id);
    for (int w=first_word; w<Words; w++) begin
      @(negedge clock);
      l1d_bus.rvalid = 1;
      l1d_bus.r_mshr = 1;
      l1d_bus.r_mshr_id = 2'(id);
      l1d_bus.rdata = value(issued_addr[id] + (XLEN'(w) << $clog2(XLEN/8)));
      l1d_bus.rerr = w == bad_word;
      l1d_bus.rlast = w == Words-1;
      @(negedge clock); l1d_bus.rvalid = 0; l1d_bus.r_mshr = 0;
      l1d_bus.rlast = 0; l1d_bus.rerr = 0;
    end
    outstanding[id] = 0;
  endtask
  initial begin
    init_l1d_inputs();
    lsu_l1d.rvalid_b=0;
    repeat (4) @(negedge clock);
    reset=0;
    lsu_l1d.replay_allowed=1;
    l1d_bus.rready=1;
    lookup(XLEN'('h80000000),1);
    lookup(XLEN'('h80000100),1);
    lookup(XLEN'('h80000008),1); // secondary miss, same line
    lookup(XLEN'('h80000200),1); // full table, wait for progress
    if (requests != 2 || outstanding != 4'b0011) $fatal(1,"miss merge/capacity failed");
    refill(1); // Return distinct IDs out of order.
    lookup(XLEN'('h80000100),0);
    refill(0);
    lookup(XLEN'('h80000000),0);
    lookup(XLEN'('h80000008),0);
    if (requests != 2) $fatal(1,"replay issued duplicate AR");
    // Buffered data cannot bypass permissions on replay. With no PMP entries,
    // U-mode denies RAM even though this physical line was fetched in M-mode.
    csr_bcast.priv=`RAPT_PRIV_U;
    lookup(XLEN'('h80000010),0,1);
    csr_bcast.priv=`RAPT_PRIV_M;
    lookup(XLEN'('h80000010),0);
    if (requests != 2) $fatal(1,"permission replay emitted unexpected AR");
    lookup(XLEN'('h80000200),1);
    repeat (3) @(negedge clock);
    if (requests != 3) $fatal(1,"completed entry not reusable");
    // Kill an issued miss, drain all data, and ensure the killed line is not served.
    cmu_bcast.flush_pipe=1;
    @(negedge clock); cmu_bcast.flush_pipe=0;
    for (int i=0;i<4;i++) if(outstanding[i]) refill(i);
    lookup(XLEN'('h80000200),1);
    for (int i=0;i<4;i++) if(outstanding[i]) refill(i,0);
    lookup(XLEN'('h80000200),0,1);
    // Error is per beat: another word of this buffered line remains usable.
    lookup(XLEN'('h80000208),0);
    // A committed write cannot overtake a pending refill; after it drains,
    // its buffered line is invalidated before the store is accepted.
    lookup(XLEN'('h80000300),1);
    lsu_l1d.wvalid=1; lsu_l1d.waddr=XLEN'('h80000300);
    lsu_l1d.walu=8'((1 << (XLEN/8))-1); lsu_l1d.wdata=XLEN'(77);
    #1;
    if (lsu_l1d.wready || l1d_bus.awvalid || l1d_bus.wvalid)
      $fatal(1,"store overtook pending refill");
    for (int i=0;i<4;i++) if(outstanding[i]) refill(i);
    repeat (3) @(negedge clock);
    if (!lsu_l1d.wready) $fatal(1,"store blocked after refill drain");
    lsu_l1d.wvalid=0;
    // This store was already pending at RLAST and cancelled installation.
    lookup(XLEN'('h80000308),1);
    for (int i=0;i<4;i++) if(outstanding[i]) refill(i);
    // Backpressured, not-yet-accepted requests can be cancelled immediately.
    @(negedge clock); cmu_bcast.flush_pipe=1;
    @(negedge clock); cmu_bcast.flush_pipe=0; l1d_bus.rready=0;
    lookup(XLEN'('h80000400),1);
    repeat (3) @(negedge clock);
    if (!l1d_bus.arvalid || !l1d_bus.ar_mshr) $fatal(1,"lost stalled request");
    cmu_bcast.flush_pipe=1;
    @(negedge clock); cmu_bcast.flush_pipe=0;
    repeat (3) @(negedge clock);
    if (l1d_bus.arvalid || dut.mshr_busy) $fatal(1,"unissued cancellation did not free entry");
    // The first demanded beat must be consumable while the rest is stalled.
    l1d_bus.rready=1;
    lookup(XLEN'('h80000500),1);
    begin
      int id;
      id=outstanding[0] ? 0 : 1;
      @(negedge clock);
      l1d_bus.rvalid=1; l1d_bus.r_mshr=1; l1d_bus.r_mshr_id=2'(id);
      l1d_bus.rdata=value(issued_addr[id]); l1d_bus.rlast=0;
      @(negedge clock); l1d_bus.rvalid=0; l1d_bus.r_mshr=0;
      lookup(XLEN'('h80000500),0);
      if (!dut.mshr_busy) $fatal(1,"early return released burst ownership");
      lookup(XLEN'('h80000500)+XLEN'(XLEN/8),1);
      refill(id,-1,1);
      lookup(XLEN'('h80000500)+XLEN'(XLEN/8),0);
      // Once a line is installed, an unrelated store must preserve it and
      // a same-line word store must preserve the other installed words.
      lsu_l1d.wvalid=1; lsu_l1d.waddr=XLEN'('h80000500);
      lsu_l1d.walu=8'((1 << (XLEN/8))-1); lsu_l1d.wdata=XLEN'(77);
      repeat (3) @(negedge clock);
      lsu_l1d.wvalid=0;
      lookup(XLEN'('h80000500)+XLEN'(XLEN/8),0);
    end
    // Hold an unrelated store through RLAST so the completed buffer cannot
    // install yet. Selective invalidation must retain this buffered line.
    lookup(XLEN'('h80000600),1);
    lsu_l1d.wvalid=1; lsu_l1d.waddr=XLEN'('h80000700);
    lsu_l1d.walu=8'((1 << (XLEN/8))-1); lsu_l1d.wdata=XLEN'(77);
    for (int i=0;i<4;i++) if(outstanding[i]) refill(i);
    repeat (3) @(negedge clock);
    lsu_l1d.wvalid=0;
    lookup(XLEN'('h80000600),0);
    // Cache-installed lines must release capacity even when their original
    // consumers never replay through the buffer (cache/B hits can do that).
    @(negedge clock); cmu_bcast.flush_pipe=1;
    @(negedge clock); cmu_bcast.flush_pipe=0;
    for (int line=0;line<3;line++) begin
      int before_requests;
      before_requests=requests;
      lookup(XLEN'('h80000800)+XLEN'(line*256),1);
      if (requests != before_requests+1)
        $fatal(1,"installed unconsumed lines blocked MSHR replacement");
      for (int i=0;i<4;i++) if(outstanding[i]) refill(i);
      repeat (4) @(negedge clock);
    end
    $display("PASS: MSHR cache RV%0d two in-flight lines, merge, full-table replay, reverse responses, flush drain, beat errors",XLEN);
    $finish;
  end
  initial begin #200000; $fatal(1,"MSHR cache timeout"); end
endmodule
