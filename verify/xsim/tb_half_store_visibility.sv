`include "rapt.svh"
`include "rapt_if.svh"
module tb_half_store_visibility;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
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
  localparam int Bytes = XLEN / 8;
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
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
    for (int hot = 0; hot < 2; hot++)
    for (int offset = 0; offset < Bytes; offset += 2)
    for (int delay_case = 0; delay_case < 3; delay_case++) begin
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
      check(dut.sq_all_empty && writes == 1, "store did not drain exactly once");
      observe_word(1);
      tick(8);
      check(writes == 1, "late duplicate store acceptance");
      for (int i = 0; i < 64; i++) begin
        if (i >= offset && i < offset + 2)
          check(memory_bytes[i] == (i == offset ? 8'haa : 8'h55), "backing half data mismatch");
        else check(memory_bytes[i] == 8'(i + 'h40), "store changed backing guard byte");
      end
    end
    check(total_writes == Bytes * 3 && total_reads == Bytes * 3 * 5 / 2,
          "missing store or observer coverage");
    $display("PASS: half store SQ/L1D visibility XLEN=%0d cases=%0d writes=%0d reads=%0d", XLEN,
             Bytes * 3, total_writes, total_reads);
    $finish;
  end
endmodule
