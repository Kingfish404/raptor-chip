`include "rapt.svh"
`include "rapt_if.svh"
module tb_half_store_visibility;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  `define TB_LSU_CACHE_NO_HANDOFF
  `define TB_LSU_CACHE_BACKPRESSURE
  `include "tb_lsu_cache_harness.svh"
  localparam int Bytes = XLEN / 8;
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  // A write-back L1D absorbs a store hit into the dirty line; the backing
  // write is deferred to eviction. Misses and write-through hits write once.
  localparam bit WriteBack = `RAPT_L1D_WRITEBACK;
  logic [7:0] memory_bytes[64];
  logic [XLEN-1:0] old_word, new_word, store_address;
  logic [XLEN-1:0] response_data;
  integer write_delay = 0, write_wait, read_wait;
  integer writes, total_writes = 0, total_reads = 0;
  logic read_pending;
  assign l1d_bus.rready = !reset && !read_pending;
  assign l1d_bus.wready = !reset && write_wait == 0;
  always @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 64; i++) memory_bytes[i] <= 8'(i + 'h40);
      write_wait <= write_delay;
      writes <= 0;
      read_wait <= 0;
      read_pending <= 0;
      l1d_bus.rvalid <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      if (l1d_bus.wvalid && write_wait > 0) write_wait <= write_wait - 1;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        check(!l1d_bus.ar_ptw, "unexpected PTW traffic in Bare test");
        read_pending <= 1;
        read_wait <= 3;
        for (int i = 0; i < Bytes; i++)
        response_data[i*8+:8] <= memory_bytes[int'(l1d_bus.araddr-Base)+i];
      end else if (read_pending) begin
        if (read_wait != 0) read_wait <= read_wait - 1;
        else begin
          l1d_bus.rdata <= response_data;
          l1d_bus.rvalid <= 1;
          read_pending <= 0;
        end
      end
      if (l1d_bus.wvalid && l1d_bus.wready) begin
        check(l1d_bus.awaddr == store_address && l1d_bus.wstrb == 3,
              "aligned half store changed address or split its byte mask");
        l1d_bus.wzero = 0;
        check(l1d_bus.wdata[15:0] == 16'h55aa, "half store payload corrupted");
        writes <= writes+1;
        total_writes <= total_writes+1;
        // The modeled slave applies the accepted byte mask in one clock edge.
        // This is an environment contract, not a proof of a physical AXI slave.
        for (int i = 0; i < Bytes; i++)
        if (l1d_bus.wstrb[i]) memory_bytes[int'(l1d_bus.awaddr-Base)+i] <= l1d_bus.wdata[i*8+:8];
      end
      if (exu_lsu.rvalid && exu_lsu.rready) begin
        check(!exu_lsu.trap, "ordinary observer read trapped");
        check(exu_lsu.rdata == old_word || exu_lsu.rdata == new_word,
              "observer saw a torn half store or corrupted neighbor bytes");
        total_reads <= total_reads + 1;
      end
    end
  end

  task automatic observe_word(input bit require_new);
    exu_lsu.raddr = Base;
`ifdef RAPT_RV64
    exu_lsu.ralu = `RAPT_ALU_LD__;
`else
    exu_lsu.ralu = `RAPT_ALU_LW__;
`endif
    exu_lsu.rvalid = 1;
    for (int c = 0; c < 512; c++) begin
      #1;
      if (exu_lsu.rready) begin
        if (require_new) check(exu_lsu.rdata == new_word, "post-drain read retained old data");
        tick(1);
        exu_lsu.rvalid = 0;
        tick(2);
        return;
      end
      tick(1);
    end
    fail("observer read timed out");
  endtask

  initial begin
    automatic int expected_total_writes = 0;
    for (int hot = 0; hot < 2; hot++)
    for (int offset = 0; offset < Bytes; offset += 2)
    for (int delay_case = 0; delay_case < 3; delay_case++) begin
      automatic int expected_writes = hot && WriteBack ? 0 : 1;
      expected_total_writes += expected_writes;
      reset = 1;
      init_inputs();
      exu_lsu.ordered=0;
      write_delay = delay_case==0 ? 0 : delay_case==1 ? 7 : 63;
      store_address=Base+XLEN'(offset);
      for (int i = 0; i < Bytes; i++) old_word[i*8+:8] = 8'(i + 'h40);
      new_word=old_word;
      new_word[offset*8+:16]=16'h55aa;
      tick(4);
      reset = 0;
      tick(2);
      if (hot) observe_word(0);
      exu_ioq_bcast.valid=1;
      exu_ioq_bcast.wen=1;
      exu_ioq_bcast.alu=`RAPT_SH_WSTRB;
      exu_ioq_bcast.dest=3;
      exu_ioq_bcast.tval=store_address;
      exu_ioq_bcast.sq_waddr=store_address;
      exu_ioq_bcast.sq_wdata=XLEN'('h55aa);
      tick(1);
      exu_ioq_bcast.valid=0;
      exu_ioq_bcast.wen=0;
      tick(1);
      rou_lsu.store=1;
      rou_lsu.dest=3;
      rou_lsu.sq_vaddr=store_address;
      rou_lsu.valid=1;
      tick(1);
      rou_lsu.valid=0;
      rou_lsu.store=0;
      observe_word(0);
      for (int c = 0; c < 512 && !dut.sq_all_empty; c++) tick(1);
      check(dut.sq_all_empty && writes == expected_writes, "store did not drain exactly once");
      observe_word(1);
      tick(8);
      check(writes == expected_writes, "late duplicate store acceptance");
      for (int i = 0; i < 64; i++) begin
        if (expected_writes != 0 && i >= offset && i < offset + 2)
          check(memory_bytes[i] == (i == offset ? 8'haa : 8'h55), "backing half data mismatch");
        else check(memory_bytes[i] == 8'(i + 'h40), "store changed backing guard byte");
      end
    end
    check(total_writes == expected_total_writes && total_reads == Bytes * 3 * 5 / 2,
          "missing store or observer coverage");
    $display("PASS: half store SQ/L1D visibility XLEN=%0d cases=%0d writes=%0d reads=%0d", XLEN,
             Bytes * 3, total_writes, total_reads);
    $finish;
  end
endmodule
