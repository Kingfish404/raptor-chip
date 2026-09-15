`include "rapt.svh"
`include "rapt_if.svh"
module tb_cbo_set;
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
  rapt_l1d #(
      .LineRefill(0)
  ) dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_l1d_defaults.svh"
  int reads = 0;
  function automatic logic [XLEN-1:0] word_at(input logic [XLEN-1:0] addr);
    return (addr * XLEN'('h1020305)) ^ XLEN'('hfedcba9876543210);
  endfunction

  task automatic load(input logic [XLEN-1:0] addr, input bit hot, input bit clear_with_fill = 0);
    bit responded;
    int before_reads;
    @(negedge clock);
    before_reads = reads;
    responded = 0;
    lsu_l1d.raddr = addr;
    lsu_l1d.ralu = XLEN == 64 ? 5'b00011 : 5'b00010;
    lsu_l1d.rvalid = 1;
    for (int cycle = 0; cycle < 100; cycle++) begin
      @(negedge clock);
      if (lsu_l1d.rready) begin
        if (lsu_l1d.trap || lsu_l1d.rdata != word_at(addr))
          $fatal(1, "load addr=%h got=%h expected=%h", addr, lsu_l1d.rdata, word_at(addr));
        if (clear_with_fill) begin
          cmu_bcast.cbo_block = addr[11:6];
          cmu_bcast.cbo_inval = 1;
        end
        @(posedge clock);
        @(negedge clock);
        cmu_bcast.cbo_inval = 0;
        lsu_l1d.rvalid = 0;
        l1d_bus.rvalid = 0;
        repeat (3) @(negedge clock);
        if (hot && reads != before_reads) $fatal(1, "resident D word missed addr=%h", addr);
        return;
      end
      if (l1d_bus.arvalid && !responded) begin
        if (l1d_bus.araddr != addr || l1d_bus.ar_ptw)
          $fatal(1, "unexpected D refill address=%h expected=%h", l1d_bus.araddr, addr);
        reads++;
        responded = 1;
        // Acceptance and response are deliberately separated.
        @(posedge clock);
        repeat (2) @(negedge clock);
        l1d_bus.rdata = word_at(addr);
        l1d_bus.rvalid = 1;
      end
    end
    $fatal(1, "load timeout addr=%h", addr);
  endtask
  task automatic invalidate(input logic [XLEN-1:0] va);
    @(negedge clock);
    cmu_bcast.cbo_block = va[11:6];
    cmu_bcast.cbo_inval = 1;
    cmu_bcast.flush_pipe = 1;
    @(negedge clock);
    cmu_bcast.cbo_inval = 0;
    cmu_bcast.flush_pipe = 0;
    repeat (3) @(negedge clock);
  endtask
  initial begin
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    l1d_bus.rready = 1;
    repeat (4) @(negedge clock);
    reset = 0;
    // Populate every word, set and way. With partial fills, filling all words
    // also avoids imposing a particular replacement policy on this test.
    for (int offset = 0; offset < Capacity; offset += XLEN / 8)
    load(XLEN'(32'h80000000 + offset), 0);
    for (int offset = 0; offset < Capacity; offset += XLEN / 8)
    load(XLEN'(32'h80000000 + offset), 1);
    for (int alias_id = 0; alias_id < 2; alias_id++) begin
      // Different virtual page, same page offset; deliberately unaligned rs1.
      invalidate(XLEN'(32'h4000003f + alias_id * 'h12345000));
      // All other sets retain ALL words and ways, not just one sample line.
      for (int offset = 0; offset < Capacity; offset += XLEN / 8)
      if ((offset % WayBytes) >= 64) load(XLEN'(32'h80000000 + offset), 1);
      for (int way = 0; way < `RAPT_L1D_N_WAYS; way++) begin
        for (int offset = 0; offset < 64; offset += XLEN / 8) begin
          int before_reads;
          before_reads = reads;
          load(XLEN'('h80000000) + XLEN'(way * WayBytes + offset), 0);
          if (reads != before_reads + 1)
            $fatal(1, "CBO left word valid: way=%0d offset=%0d", way, offset);
          load(XLEN'('h80000000) + XLEN'(way * WayBytes + offset), 1);
        end
      end
    end
    // The existing global maintenance path still clears all sets.
    @(negedge clock);
    cmu_bcast.fence_time = 1;
    @(negedge clock);
    cmu_bcast.fence_time = 0;
    repeat (3) @(negedge clock);
    for (int offset = 0; offset < Capacity; offset += LineBytes) begin
      int before_reads;
      before_reads = reads;
      load(XLEN'(32'h80000000 + offset), 0);
      if (reads != before_reads + 1) $fatal(1, "global maintenance left a line valid");
    end
    // Isolate the cache's clear/fill race without relying on pipeline kill:
    // a returned word schedules its tag update as the clear mask registers.
    load(XLEN'('h80000000) + XLEN'(XLEN / 8), 0, 1);
    begin
      int before_reads;
      before_reads = reads;
      load(XLEN'('h80000000) + XLEN'(XLEN / 8), 0);
      if (reads != before_reads + 1) $fatal(1, "pending fill resurrected cleared set");
      load(XLEN'('h80000040), 1);
    end
    $display(
        "PASS: CBO RV%0d line=%0d sets=%0d ways=%0d; set scope, all words/ways, aliases, global maintenance",
        XLEN, LineBytes, 1 << `RAPT_L1D_LEN, `RAPT_L1D_N_WAYS);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "CBO test timeout");
  end
endmodule
