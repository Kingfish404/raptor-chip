`include "rapt.svh"
`include "rapt_if.svh"
module tb_registered_store_path;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam int Bytes = XLEN / 8;
  localparam int SetStride = 64 * (1 << `RAPT_L1D_LEN);
  localparam int MemBytes = SetStride * (`RAPT_L1D_N_WAYS + 4);
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  localparam logic [XLEN-1:0] ErrorAddr = Base + 512;
  `define TB_LSU_CACHE_EXTERNAL_BUS
  `include "tb_lsu_cache_harness.svh"

  logic hold_store = 0, hold_read = 0, inject_error = 0;
  logic probe_valid = 0;
  logic [XLEN-1:0] probe_addr = Base;
  logic [7:0] memory_bytes[MemBytes];
  logic read_pending = 0;
  logic [XLEN-1:0] read_addr;
  integer read_wait = 0;
  integer accepted = 0, errors = 0, bus_writes = 0, victim_cycles = 0;
  integer cases = 0;

  assign l1d_bus.idle = !read_pending;
  assign l1d_bus.rready = !reset && !read_pending;
  assign l1d_bus.wready = !reset && (!hold_store || cache_dut.wb_valid) && l1d_bus.wvalid;
  assign l1d_bus.werr = inject_error && l1d_bus.awaddr == ErrorAddr && l1d_bus.wready;
  assign l1d_bus.rerr = 0;
  assign l1d_bus.rlast = 1;
  assign l1d_bus.r_mshr = 0;
  assign l1d_bus.r_mshr_id = 0;
  assign l1d_bus.ptw_rvalid = 0;
  assign l1d_bus.ptw_rerr = 0;
  assign l1d_bus.difftest_skip = 0;
  assign l1d_bus.posted_busy = 0;
  assign l1d_bus.posted_error = 0;
  assign l1d_bus.posted_error_addr = 0;

  always @(posedge clock) begin
    if (reset) begin
      read_pending <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.rdata <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      if (lsu_l1d.wvalid && lsu_l1d.wready) begin
        accepted <= accepted + 1;
        if (lsu_l1d.werr) errors <= errors + 1;
      end
      if (cache_dut.wb_state != 0) victim_cycles <= victim_cycles + 1;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        check(!l1d_bus.ar_ptw && !l1d_bus.ar_mshr && l1d_bus.arlen == 0,
              "unexpected walk or line transaction");
        read_addr <= l1d_bus.araddr & ~XLEN'(Bytes - 1);
        read_wait <= 5;
        read_pending <= 1;
      end else if (read_pending && !hold_read) begin
        if (read_wait != 0) read_wait <= read_wait - 1;
        else begin
          for (int b = 0; b < Bytes; b++)
          l1d_bus.rdata[b*8+:8] <= memory_bytes[int'(read_addr-Base)+b];
          l1d_bus.rvalid <= 1;
          read_pending <= 0;
        end
      end
      if (l1d_bus.wvalid && l1d_bus.wready) begin
        bus_writes <= bus_writes + 1;
        if (!l1d_bus.werr) begin
          if (l1d_bus.wzero) begin
            for (int b = 0; b < 64; b++) memory_bytes[int'(l1d_bus.awaddr-Base)+b] <= 0;
          end else begin
            for (int b = 0; b < Bytes; b++)
            if (l1d_bus.wstrb[b])
              memory_bytes[int'(l1d_bus.awaddr-Base)+b] <= l1d_bus.wdata[b*8+:8];
          end
        end
      end
      if (cache_dut.probe_release_valid_o) begin
        for (int b = 0; b < Bytes; b++)
        memory_bytes[int'(cache_dut.probe_release_addr_o - Base) + b]
              <= cache_dut.probe_release_data_o[b*8+:8];
      end
    end
  end

  task automatic allocate(input logic [XLEN-1:0] addr, input logic [63:0] data,
                          input logic [4:0] alu, input bit fp64 = 0, input logic [1:0] pbmt = 0);
    check(exu_lsu.stq_ready, "test exhausted SQ");
    exu_ioq_bcast = '0;
    exu_ioq_bcast.valid = 1;
    exu_ioq_bcast.wen = 1;
    exu_ioq_bcast.tval = addr;
    rou_lsu.sq_vaddr = addr;
    exu_ioq_bcast.sq_waddr = addr;
    exu_ioq_bcast.sq_wdata = XLEN'(data);
    exu_ioq_bcast.sq_wdata64 = data;
    exu_ioq_bcast.sq_fp64 = fp64;
    exu_ioq_bcast.alu = {1'b0, alu};
    sq_waddr_hi = (addr & ~XLEN'(Bytes - 1)) + XLEN'(Bytes);
    sq_waddr_third = sq_waddr_hi + XLEN'(Bytes);
    sq_wpbmt = {pbmt, pbmt, pbmt};
    tick(1);
    exu_ioq_bcast = '0;
  endtask

  task automatic commit_store;
    rou_lsu.valid = 1;
    rou_lsu.store = 1;
    tick(1);
    rou_lsu.valid = 0;
    rou_lsu.store = 0;
  endtask

  task automatic drain;
    for (int c = 0; c < 4096; c++) begin
      if (dut.sq_all_empty && !cache_dut.l1d_update) return;
      tick(1);
    end
    fail("pending store failed to drain");
  endtask

  task automatic read_check(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] expected,
                            input logic [4:0] alu = `RAPT_ALU_LW__);
    exu_lsu.raddr = addr;
    exu_lsu.ralu = alu;
    exu_lsu.rvalid = 1;
    for (int c = 0; c < 4096; c++) begin
      #1;
      if (exu_lsu.rready) begin
        check(!exu_lsu.trap && exu_lsu.rdata == expected, $sformatf(
              "read %h got %h expected %h", addr, exu_lsu.rdata, expected));
        tick(1);
        exu_lsu.rvalid = 0;
        tick(2);
        return;
      end
      tick(1);
    end
    fail("dependent load failed to complete");
  endtask

  initial begin
    init_inputs();
    force cache_dut.coherent_request = hold_store;
    force cache_dut.probe_valid_i = probe_valid;
    force cache_dut.probe_addr_i = probe_addr;
    force cache_dut.probe_release_ready_i = 1'b1;
    for (int b = 0; b < MemBytes; b++) memory_bytes[b] = 0;
    tick(3);
    reset = 0;
    tick(2);
    // A committed descriptor remains visible to forwarding and ordering while
    // its output register is stalled. A different tag in the same set cannot
    // receive its forwarded bytes.
    hold_store = 1;
    allocate(Base, 64'h12345678, `RAPT_SW_WSTRB);
    commit_store();
    check(lsu_l1d.wvalid && !rou_lsu.sq_empty, "commit missed registered drain view");
    read_check(Base, XLEN'('h12345678));
    exu_lsu.rvalid = 1;
    exu_lsu.raddr = Base + XLEN'(SetStride);
    #1;
    check(!exu_lsu.rready, "aliasing set incorrectly forwarded store data");
    exu_lsu.rvalid = 0;
    cmu_bcast.flush_pipe = 1;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    check(lsu_l1d.wvalid && !rou_lsu.sq_empty, "flush lost committed descriptor");
    hold_store = 0;
    drain();
    read_check(Base, XLEN'('h12345678));
    read_check(Base + XLEN'(SetStride), 0);
    cases++;

    // Hold a real refill response while a store commits, then flush the load.
    hold_read = 1;
    exu_lsu.raddr = Base + 128;
    exu_lsu.rvalid = 1;
    for (int c = 0; c < 64 && !read_pending; c++) tick(1);
    check(read_pending, "refill did not start");
    hold_store = 1;
    allocate(Base + 192, 64'h23456789, `RAPT_SW_WSTRB);
    commit_store();
    cmu_bcast.flush_pipe = 1;
    exu_lsu.rvalid = 0;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    check(lsu_l1d.wvalid && !rou_lsu.sq_empty, "refill/flush discarded pending store");
    hold_read = 0;
    hold_store = 0;
    drain();
    read_check(Base + 192, XLEN'('h23456789));
    cases++;

    // Dirty stores competing for one set force the victim capture path.
    for (int n = 0; n <= `RAPT_L1D_N_WAYS; n++) begin
      allocate(Base + XLEN'(n * SetStride), 64'(n + 17),
               XLEN == 64 ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB);
      commit_store();
      drain();
    end
    check(victim_cycles != 0, "dirty victim path was not exercised");
    read_check(Base, 17);
    cases++;

    hold_store = 1;
    allocate(Base + 256, 64'h3456789a, `RAPT_SW_WSTRB);
    commit_store();
    probe_addr = Base;
    probe_valid = 1;
    for (int c = 0; c < 4096; c++) begin
      #1;
      if (cache_dut.probe_ready_o) break;
      tick(1);
    end
    check(cache_dut.probe_ready_o, "probe did not finish around pending store");
    tick(1);
    probe_valid = 0;
    cmu_bcast.fence_time = 1;
    tick(1);
    cmu_bcast.fence_time = 0;
    check(lsu_l1d.wvalid && !rou_lsu.sq_empty, "probe/fence lost pending descriptor");
    hold_store = 0;
    drain();
    read_check(Base + 256, XLEN'('h3456789a));
    cases++;

    // An unaligned FSD is two beats in RV64 and three in RV32. Verify bytes
    // through ordinary loads after the resident owner has finally drained.
    allocate(Base + 321, 64'h0123456789abcdef, `RAPT_SD_WSTRB, 1);
    commit_store();
    drain();
    for (int b = 0; b < 8; b++)
    read_check(Base + XLEN'(321 + b), XLEN'(8'(64'h0123456789abcdef >> (8 * b))), `RAPT_ALU_LBU_);
    cases++;

    allocate(Base + 383, 0, `RAPT_CBO_ZERO_WALU);
    commit_store();
    drain();
    for (int b = 0; b < 64; b += 4) read_check(Base + XLEN'(320 + b), 0);
    cases++;

    inject_error = 1;
    allocate(ErrorAddr, 64'h456789ab, `RAPT_SW_WSTRB, 0, 1);
    commit_store();
    drain();
    check(errors == 1, "uncached bus error did not release its store owner");
    inject_error = 0;
    read_check(ErrorAddr, 0);
    cases++;

    // Supply a warm translation and consume the actual P1c response register
    // before allocating its PA into the SQ. Existing PTW tests cover walking.
    force cache_dut.stlb_hit = 1'b1;
    force cache_dut.dstlb_ptag = (`RAPT_PADDR_BITS - 12)'((Base + 768) >> 12);
    force cache_dut.dstlb_pbmt = 2'b00;
    force cache_dut.pf_store_tlb = 1'b0;
    exu_l1d.mmu_en = 1;
    exu_l1d.valid = 1;
    exu_l1d.vaddr = Base + 768;
    exu_l1d.walu = `RAPT_SW_WSTRB;
    #1;
    check(!exu_l1d.ready, "translation bypassed its response register");
    tick(1);
    check(exu_l1d.ready && !exu_l1d.trap && exu_l1d.paddr == Base + 768,
          "translated store response corrupted");
    allocate(exu_l1d.paddr, 64'h56789abc, `RAPT_SW_WSTRB);
    exu_l1d.valid = 0;
    exu_l1d.mmu_en = 0;
    release cache_dut.stlb_hit;
    release cache_dut.dstlb_ptag;
    release cache_dut.dstlb_pbmt;
    release cache_dut.pf_store_tlb;
    commit_store();
    drain();
    read_check(Base + 768, XLEN'('h56789abc));
    cases++;
    $display("PASS: registered store path XLEN=%0d cases=%0d beats=%0d errors=%0d victims=%0d",
             XLEN, cases, accepted, errors, victim_cycles);
    $finish;
  end
endmodule
