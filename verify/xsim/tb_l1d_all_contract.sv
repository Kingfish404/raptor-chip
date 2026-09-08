// ---- tb_l1d_byte_rom ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_byte_rom;
  localparam int XLEN = 32;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_rd_pending;
  logic [31:0] bus_rd_addr;

  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();

  rapt_l1d dut (
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d),
      .rou_cmu(rou_cmu),
      .reset(reset)
  );

  always #5 clock = ~clock;

  function automatic logic [31:0] rom_word(input logic [31:0] addr);
    logic [31:0] aligned;
    begin
      aligned = {addr[31:2], 2'b00};
      unique case (aligned)
        32'h2000_336c: rom_word = 32'h6d31_5b1b; // ESC [ 1 m
        32'h2000_3370: rom_word = 32'h2020_2020;
        32'h2000_3374: rom_word = 32'h2020_2020;
        32'h2000_3378: rom_word = 32'h2020_5f5f;
        32'h2000_337c: rom_word = 32'h5f205f20;
        32'h2000_3380: rom_word = 32'h20205f5f;
        32'h2000_3384: rom_word = 32'h5f202020;
        32'h2000_3388: rom_word = 32'h1b5f5f20;
        default:       rom_word = 32'hbad0_0000 ^ aligned;
      endcase
    end
  endfunction

  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic read_byte_addr(input logic [31:0] addr);
    logic [31:0] expected;
    begin
      expected = rom_word(addr);
      lsu_l1d.raddr = addr;
      lsu_l1d.ralu = `RAPT_ALU_LBU_;
      lsu_l1d.rvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 32; wait_cycle++) begin
        @(posedge clock);
        #1;
        if (lsu_l1d.rready) begin
          check(!lsu_l1d.trap, "L1D trapped on cacheable ROM byte read");
          check(lsu_l1d.rdata == expected, $sformatf(
                "ROM word mismatch addr=%08x got=%08x expected=%08x", addr, lsu_l1d.rdata, expected
                ));
          lsu_l1d.rvalid = 1'b0;
          tick(1);
          return;
        end
      end
      fail($sformatf("timed out waiting for L1D read addr=%08x", addr));
    end
  endtask

  assign l1d_bus.rready = !reset && l1d_bus.arvalid && !bus_rd_pending;

  always_ff @(posedge clock) begin : fake_rom_bus
    if (reset) begin
      bus_rd_pending <= 1'b0;
      bus_rd_addr <= '0;
      l1d_bus.rdata <= '0;
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
    end else begin
      l1d_bus.rvalid <= bus_rd_pending;
      l1d_bus.rdata <= rom_word(bus_rd_addr);
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
      if (bus_rd_pending) begin
        bus_rd_pending <= 1'b0;
      end
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        bus_rd_addr <= l1d_bus.araddr;
        bus_rd_pending <= 1'b1;
      end
    end
  end

  initial begin
    init_l1d_inputs();
    lsu_l1d.ralu = `RAPT_ALU_LBU_;
    tick(5);
    reset = 1'b0;
    tick(2);

    for (int i = 0; i < 30; i++) begin
      read_byte_addr(32'h2000_336c + 32'(i));
    end

    cmu_bcast.fence_time = 1'b1;
    tick(1);
    cmu_bcast.fence_time = 1'b0;
    tick(2);

    for (int i = 0; i < 30; i++) begin
      read_byte_addr(32'h2000_336c + 32'(i));
    end

    $display("PASS: L1D byte-ROM xsim checks passed");
    $finish;
  end
endmodule


// ---- tb_l1d_cmo_permissions ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_cmo_permissions;
  localparam int XLEN = 64;
  localparam logic [63:0] Vaddr = 64'h0000_0000_4000_0123;
  logic [63:0] Paddr = 64'h0000_0000_8000_0123;

  logic clock = 1'b0;
  logic reset = 1'b1;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();

  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic install_store_tlb(input logic [6:0] pte);
    begin
      dut.u_dstlb.valid[0] = 1'b1;
      dut.u_dstlb.vtags[0] = Vaddr[63:12];
      dut.u_dstlb.ptags[0] = 64'(Paddr >> 12);
      dut.u_dstlb.asids[0] = '0;
      dut.u_dstlb.ptes[0] = pte;
    end
  endtask

  task automatic expect_cmo_success(input string name);
    begin
      exu_l1d.vaddr = Vaddr;
      exu_l1d.walu = `RAPT_CBO_MGMT_WALU;
      exu_l1d.cmo_mgmt = 1'b1;
      exu_l1d.mmu_en = 1'b1;
      exu_l1d.valid = 1'b1;
      #1;
      check(!lsu_l1d.idle, "incoming CMO translation advertised L1D idle");
      check(exu_l1d.ready && !exu_l1d.trap, {name, " did not authorize"});
      tick(1);
      exu_l1d.valid = 1'b0;
      exu_l1d.mmu_en = 1'b0;
      exu_l1d.cmo_mgmt = 1'b0;
      tick(1);
    end
  endtask

  task automatic expect_store_page_fault(
      input logic cmo, input string name,
      input logic [63:0] expected_cause = `RAPT_CAUSE_STORE_PAGE_FAULT);
    begin
      exu_l1d.vaddr = Vaddr;
      exu_l1d.walu = cmo ? `RAPT_CBO_MGMT_WALU : `RAPT_SW_WSTRB;
      exu_l1d.cmo_mgmt = cmo;
      exu_l1d.mmu_en = 1'b1;
      exu_l1d.valid = 1'b1;
      tick(1);
      #1;
      check(exu_l1d.ready && exu_l1d.trap, {name, " did not trap"});
      check(exu_l1d.cause == expected_cause, {name, " reported wrong fault cause"});
      check(!l1d_bus.arvalid && !l1d_bus.awvalid, {
            name, " rejected translated store emitted a bus request"});
      exu_l1d.valid = 1'b0;
      exu_l1d.mmu_en = 1'b0;
      exu_l1d.cmo_mgmt = 1'b0;
      tick(2);
    end
  endtask

  initial begin
    init_l1d_inputs();
    tick(4);
    reset = 1'b0;
    tick(1);
    csr_bcast.dmmu_en = 1'b1;

    // {D,A,G,U,X,W,R}: read-only, A=1, D=0.  CMO management must
    // succeed via load permission while an ordinary store faults.
    install_store_tlb(7'b010_0001);
    expect_cmo_success("read-only A=1,D=0 CMO");
    expect_store_page_fault(1'b0, "ordinary store on read-only D=0 PTE");

    // A=0 is always a CMO page fault, even when R permission is present.
    install_store_tlb(7'b000_0001);
    expect_store_page_fault(1'b1, "CMO with A=0");

    // Execute-only becomes load-permitted under MXR and therefore also
    // authorizes a cache-block management operation.
    install_store_tlb(7'b010_0100);
    expect_store_page_fault(1'b1, "execute-only CMO with MXR=0");
    csr_bcast.mxr = 1'b1;
    expect_cmo_success("execute-only CMO with MXR=1");

    // A/D/R/W in a hot TLB do not override physical ROM/flash write PMA.
    // Cache maintenance still succeeds through ordinary read permission.
    for (int region = 0; region < 2; region++) begin
      Paddr = region == 0 ? 64'h20000123 : 64'h30000123;
      install_store_tlb(7'b110_0011);
      expect_store_page_fault(0, "writable PTE mapped to physical ROM", 7);
      expect_cmo_success("physical ROM CMO via read permission");
    end

    $display("PASS: Zicbom R-or-W, A-only PTE permission and store-fault semantics");
    $finish;
  end
endmodule


// ---- tb_l1d_data ----
module tb_l1d_data;
  logic clock = 1'b0;
  logic [11:0] done = '0;
  always #5 clock = ~clock;

  // RV32/RV64, direct/2/4-way, and narrow/multi-bank lines.
  for (genvar width_idx = 0; width_idx < 2; width_idx++) begin : g_width
    for (genvar way_idx = 0; way_idx < 3; way_idx++) begin : g_ways
      for (genvar line_idx = 0; line_idx < 2; line_idx++) begin : g_line
        localparam int Xlen = 32 << width_idx;
        localparam int Ways = 1 << way_idx;
        localparam int WayBits = Ways > 1 ? $clog2(Ways) : 1;
        localparam int WordBits = line_idx == 0 ? 1 : 3;
        localparam int Words = 1 << WordBits;
        localparam int CaseId = width_idx * 6 + way_idx * 2 + line_idx;
        logic reset = 1'b1, write_valid = 1'b0;
        logic [1:0] read_addr = '0, write_addr = '0;
        logic [WordBits-1:0] write_word = '0;
        logic [WayBits-1:0] write_way = '0;
        logic [Xlen-1:0] write_data = '0;
        wire read_valid;
        wire [1:0] read_index;
        wire [Xlen-1:0] read_data[Ways][Words];
        logic [Xlen-1:0] model[Ways][4][Words];
        logic [63:0] rng = 64'h123456789abcdef0 ^ 64'(CaseId);

        rapt_l1d_data #(
            .Xlen(Xlen),
            .SetBits(2),
            .WordBits(WordBits),
            .Ways(Ways)
        ) dut (
            .*
        );

        task automatic step(input bit wr, input int set_idx, input int way, input int word_idx,
                            input logic [63:0] data, input bit rst = 1'b0);
          @(negedge clock);
          reset = rst;
          write_valid = wr;
          read_addr = 2'(set_idx);
          write_addr = 2'(set_idx);
          write_way = WayBits'(way);
          write_word = WordBits'(word_idx);
          write_data = Xlen'(data);
          @(posedge clock);
          if (wr) model[way][set_idx][word_idx] = Xlen'(data);
          #1;
          if (read_valid !== (!rst && !wr)) $fatal(1, "case %0d: read-valid contract", CaseId);
          if (!rst && !wr) begin
            if (read_index !== 2'(set_idx)) $fatal(1, "case %0d: read index", CaseId);
            for (int w = 0; w < Ways; w++)
            for (int word_offset = 0; word_offset < Words; word_offset++)
            if (read_data[w][word_offset] !== model[w][set_idx][word_offset])
              $fatal(
                  1,
                  "case %0d: SRAM mismatch set=%0d way=%0d word=%0d",
                  CaseId,
                  set_idx,
                  w,
                  word_offset
              );
          end
        endtask

        initial begin
          @(posedge clock);
          #1;
          if (read_valid !== 1'b0) $fatal(1, "reset must invalidate read");
          // Initialize via real writes; SRAM contents have no reset value.
          for (int set_idx = 0; set_idx < 4; set_idx++)
          for (int way = 0; way < Ways; way++)
          for (int word_idx = 0; word_idx < Words; word_idx++)
          step(1, set_idx, way, word_idx,
               64'hfedcba9876543210 ^ 64'(set_idx * 256 + way * 16 + word_idx));
          for (int cycle_idx = 0; cycle_idx < 2000; cycle_idx++) begin
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            step(rng[0], int'(rng[2:1]), int'(rng[4:3]) % Ways, int'(rng[7:5]) % Words, rng,
                 cycle_idx % 97 == 0);
          end
          // Reset must not erase SRAM, and the next read must recover validity.
          step(0, 0, 0, 0, '0, 1);
          for (int set_idx = 0; set_idx < 4; set_idx++) step(0, set_idx, 0, 0, '0);
          done[CaseId] = 1'b1;
        end
      end
    end
  end

  initial begin
    wait (&done);
    $display("PASS: L1D data array: 12 geometries, 2000 random cycles each");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "L1D data-array timeout");
  end
endmodule


// ---- tb_l1d_flush_ordered ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_flush_ordered;
  localparam int XLEN = 32;
  localparam logic [31:0] CacheAddr = 32'h8000_0000;
  localparam logic [31:0] MmioAddr = 32'h1000_0000;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_accept;

  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();

  rapt_l1d dut (
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d),
      .rou_cmu(rou_cmu),
      .reset(reset)
  );

  always #5 clock = ~clock;
  assign l1d_bus.rready = bus_accept && l1d_bus.arvalid;

  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic begin_load(input logic [31:0] addr, input logic ordered);
    begin
      lsu_l1d.raddr = addr;
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.ordered = ordered;
      lsu_l1d.rvalid = 1'b1;
      tick(1);
      if (addr != MmioAddr || ordered)
        for (int c = 0; c < 20 && !l1d_bus.arvalid && !lsu_l1d.rready; c++) tick(1);
    end
  endtask

  initial begin
    init_l1d_inputs();
    bus_accept = 1'b0;
    tick(5);
    reset = 1'b0;
    tick(2);

    begin_load(MmioAddr, 1'b0);
    check(!l1d_bus.arvalid, "unordered MMIO load issued a bus request");
    tick(3);
    check(!l1d_bus.arvalid, "unordered MMIO load did not remain blocked");
    lsu_l1d.ordered = 1'b1;
    #1;
    check(l1d_bus.arvalid, "ordered MMIO load did not become issuable");

    lsu_l1d.rvalid = 1'b0;
    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    check(!l1d_bus.arvalid, "flush did not cancel an unaccepted MMIO load");

    begin_load(CacheAddr, 1'b0);
    check(l1d_bus.arvalid, "cacheable load was incorrectly blocked by ordered permit");
    lsu_l1d.rvalid = 1'b0;
    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    check(!l1d_bus.arvalid, "flush did not cancel an unaccepted cacheable load");

    bus_accept = 1'b1;
    begin_load(CacheAddr, 1'b0);
    check(l1d_bus.arvalid && l1d_bus.rready, "cacheable load was not offered for acceptance");
    tick(1);
    bus_accept = 1'b0;
    lsu_l1d.rvalid = 1'b0;
    check(!l1d_bus.arvalid, "accepted load request was reissued");

    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    tick(2);
    check(!l1d_bus.arvalid, "killed accepted load escaped its drain state");

    l1d_bus.rdata = 32'hdead_beef;
    l1d_bus.rvalid = 1'b1;
    tick(1);
    check(!lsu_l1d.rready, "killed load produced architectural completion");
    l1d_bus.rvalid = 1'b0;
    tick(1);

    begin_load(CacheAddr, 1'b0);
    check(l1d_bus.arvalid, "killed refill populated the cache");
    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    lsu_l1d.rvalid = 1'b0;

    lsu_l1d.atomic_lock = 1'b1;
    begin_load(CacheAddr + 32'h40, 1'b0);
    check(l1d_bus.arvalid, "LR miss did not issue a bus request");
    check(!exu_l1d.reservation_valid, "LR established reservation before AR acceptance");
    bus_accept = 1'b1;
    tick(1);
    bus_accept = 1'b0;
    check(!exu_l1d.reservation_valid, "LR established reservation before its response");

    lsu_l1d.atomic_lock = 1'b0;
    l1d_bus.rdata = 32'h1234_5678;
    l1d_bus.rvalid = 1'b1;
    tick(1);
    l1d_bus.rvalid = 1'b0;
    lsu_l1d.rvalid = 1'b0;
    check(exu_l1d.reservation_valid, "LR ownership was lost while awaiting its response");
    check(exu_l1d.reservation == CacheAddr + 32'h40, "LR reserved the wrong address");
    tick(1);

    exu_l1d.reservation_clear = 1'b1;
    tick(1);
    exu_l1d.reservation_clear = 1'b0;
    check(!exu_l1d.reservation_valid, "reservation clear did not take effect");

    lsu_l1d.atomic_lock = 1'b1;
    begin_load(CacheAddr + 32'h40, 1'b0);
    lsu_l1d.atomic_lock = 1'b0;
    tick(1);
    check(exu_l1d.reservation_valid, "LR cache-hit ownership was not latched");
    check(exu_l1d.reservation == CacheAddr + 32'h40, "LR cache hit reserved the wrong address");
    lsu_l1d.rvalid = 1'b0;

    exu_l1d.reservation_clear = 1'b1;
    tick(1);
    exu_l1d.reservation_clear = 1'b0;
    lsu_l1d.atomic_lock = 1'b1;
    bus_accept = 1'b1;
    begin_load(CacheAddr + 32'h80, 1'b0);
    tick(1);
    bus_accept = 1'b0;
    lsu_l1d.atomic_lock = 1'b0;
    lsu_l1d.rvalid = 1'b0;
    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    l1d_bus.rvalid = 1'b1;
    tick(1);
    l1d_bus.rvalid = 1'b0;
    check(!exu_l1d.reservation_valid, "killed LR established a reservation");

    $display("PASS: L1D flush and ordered-access xsim checks passed");
    $finish;
  end
endmodule


// ---- tb_l1d_io_size ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_io_size;
  localparam int XLEN = 64;
  logic [63:0] physical_page;
  localparam logic [63:0] VA = 64'h40000000;
  logic clock = 0, reset = 1;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  logic [1:0] pte_pbmt;
  logic allow_data;
  logic pending_ptw;
  logic [63:0] response_data, data_value;
  int delay_count, data_reads, ptw_reads;
  assign l1d_bus.rready = l1d_bus.arvalid && delay_count == 0 && (l1d_bus.ar_ptw || allow_data);
  always_ff @(posedge clock) begin
    if (reset) begin
      delay_count <= 0;
      data_reads <= 0;
      ptw_reads <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      l1d_bus.rdata <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        pending_ptw <= l1d_bus.ar_ptw;
        response_data <= l1d_bus.ar_ptw
            ? ((physical_page >> 2) | 64'hcf | (64'(pte_pbmt) << 61)) : data_value;
        if (l1d_bus.ar_ptw) ptw_reads <= ptw_reads + 1;
        else data_reads <= data_reads + 1;
        delay_count <= 4;
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
  task automatic run_case(input int attr, input bit store, input bit misaligned, input bit device);
    int before_data, before_ptw;
    reset = 1;
    init_l1d_inputs();
    allow_data = 1;
    pte_pbmt = 2'(attr);
    physical_page = device ? 64'hc0000000 : 64'h80000000;
    data_value = 64'h1122334455667788;
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
    tick(2);
    csr_bcast.mprv = 1;
    csr_bcast.mpp = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.menvcfg_pbmte = 1;
    csr_bcast.satp_ppn = 'h80001;
    for (int hit = 0; hit < 2; hit++) begin
      before_data = data_reads;
      before_ptw = ptw_reads;
      // Aligned address represents a split beat of an unaligned instruction.
      lsu_l1d.raddr = VA;
      lsu_l1d.ralu = `RAPT_ALU_LD__;
      lsu_l1d.rmisaligned = misaligned;
      lsu_l1d.ordered = 1;
      lsu_l1d.rvalid = !store;
      exu_l1d.vaddr = VA;
      exu_l1d.walu = `RAPT_SD_WSTRB;
      exu_l1d.misaligned = misaligned;
      exu_l1d.mmu_en = store;
      exu_l1d.valid = store;
      for (int c = 0; c < 100; c++) begin
        #1;
        if ((store && exu_l1d.ready) || (!store && lsu_l1d.rready)) begin
          check((store ? exu_l1d.trap : lsu_l1d.trap) == ((attr == 2 || device) && misaligned),
                "wrong IO size fault decision");
          if ((attr == 2 || device) && misaligned) begin
            check((store ? exu_l1d.cause : lsu_l1d.cause) == (store ? 7 : 5),
                  "IO misalignment must raise access fault");
            check(data_reads == before_data, "faulting IO issued a data read");
          end
          check(!l1d_bus.wvalid, "translation issued a write");
          check(ptw_reads == before_ptw + (hit == 0 ? 1 : 0), "missing PTW/TLB coverage");
          tick(1);
          lsu_l1d.rvalid = 0;
          exu_l1d.valid = 0;
          exu_l1d.mmu_en = 0;
          tick(4);
          break;
        end
        if ((attr == 2 || device) && misaligned)
          check(!l1d_bus.arvalid || l1d_bus.ar_ptw, "IO over-read request presented");
        if (c == 99) fail("IO size check timeout");
        tick(1);
      end
    end
  endtask
  initial begin
    for (int device = 0; device < 2; device++)
    for (int attr = 0; attr <= 2; attr++)
    for (int store = 0; store < 2; store++)
    for (int misaligned = 0; misaligned < 2; misaligned++)
    run_case(attr, 1'(store), 1'(misaligned), 1'(device));
    $display("PASS: RAM/device PMA/NC/IO load/store original alignment, PTW/TLB, no IO over-read");
    $finish;
  end
endmodule


// ---- tb_l1d_load_contract ----
// ---- tb_l1d_load_pbmt ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_load_pbmt;
  localparam int XLEN = 64;
  localparam logic [63:0] PA = 64'h80000000;
  localparam logic [63:0] VA = 64'h40000000;
  logic clock = 0, reset = 1;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  logic [1:0] pte_pbmt;
  logic allow_data;
  logic pending_ptw;
  logic [63:0] response_data, data_value;
  int delay_count, data_reads, ptw_reads;
  assign l1d_bus.rready = l1d_bus.arvalid && delay_count == 0 && (l1d_bus.ar_ptw || allow_data);
  always_ff @(posedge clock) begin
    if (reset) begin
      delay_count <= 0;
      data_reads <= 0;
      ptw_reads <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      l1d_bus.rdata <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        pending_ptw <= l1d_bus.ar_ptw;
        response_data <= l1d_bus.ar_ptw
            ? ((PA >> 2) | 64'hcf | (64'(pte_pbmt) << 61)) : data_value;
        if (l1d_bus.ar_ptw) ptw_reads <= ptw_reads + 1;
        else data_reads <= data_reads + 1;
        delay_count <= 4;
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
  task automatic finish_read(input logic [63:0] expected);
    for (int c = 0; c < 100; c++) begin
      #1;
      if (lsu_l1d.rready) begin
        check(!lsu_l1d.trap && lsu_l1d.rdata == expected, "read returned cache data or fault");
        tick(1);
        lsu_l1d.rvalid = 0;
        tick(4);
        return;
      end
      tick(1);
    end
    fail("load response timeout");
  endtask
  task automatic run_case(input int attr, input bit hot, input bit byte_load, input bit cancel);
    int before_data, before_ptw;
    reset = 1;
    init_l1d_inputs();
    allow_data = 1;
    pte_pbmt = 2'(attr);
    data_value = 64'h1122334455667788;
    tick(4);
    reset = 0;
    // Permit data and PTW access in S effective privilege.
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
    tick(2);
    if (hot) begin
      lsu_l1d.raddr = PA;
      lsu_l1d.ralu = `RAPT_ALU_LD__;
      lsu_l1d.rvalid = 1;
      finish_read(data_value);
    end
    before_data = data_reads;
    before_ptw = ptw_reads;
    csr_bcast.mprv = 1;
    csr_bcast.mpp = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.menvcfg_pbmte = 1;
    csr_bcast.satp_ppn = 'h80001;
    lsu_l1d.raddr = VA;
    lsu_l1d.ralu = byte_load ? `RAPT_ALU_LBU_ : `RAPT_ALU_LD__;
    lsu_l1d.ordered = 0;
    lsu_l1d.rvalid = 1;
    allow_data = 0;
    tick(30);
    check(ptw_reads == before_ptw + 1, "test did not perform one real page walk");
    check(data_reads == before_data && !l1d_bus.arvalid && !lsu_l1d.rready,
          "unretired typed request accessed memory or hit a cached alias");
    // Change live inputs after the completed translation; accepted request
    // and TLB payload must retain the original type.
    pte_pbmt = 2'(3-attr);
    csr_bcast.menvcfg_pbmte = 0;
    if (cancel) begin
      cmu_bcast.flush_pipe = 1;
      tick(1);
      lsu_l1d.rvalid = 0;
      cmu_bcast.flush_pipe = 0;
      tick(5);
      check(data_reads == before_data, "cancelled IO request caused a data read");
      return;
    end
    lsu_l1d.ordered = 1;
    for (int c = 0; c < 5; c++) begin
      #1;
      check(
          l1d_bus.arvalid && !l1d_bus.ar_ptw && l1d_bus.rpbmt == 2'(attr)
            && l1d_bus.araddr == PA && l1d_bus.rstrb == (byte_load ? 8'h01 : 8'hff),
          "held request lost PBMT, PA or access size");
      tick(1);
    end
    data_value = 64'h99;
    allow_data = 1;
    finish_read(data_value);
    check(data_reads == before_data + 1, "typed read was duplicated or skipped");
    // A second request hits the TLB, but still must miss the data cache.
    lsu_l1d.rvalid = 1;
    data_value = 64'h77;
    finish_read(data_value);
    check(ptw_reads == before_ptw + 1 && data_reads == before_data + 2,
          "TLB hit lost type or NC/IO response allocated cache data");
  endtask
  initial begin
    for (int attr = 1; attr <= 2; attr++)
    for (int hot = 0; hot < 2; hot++)
    for (int bytes = 0; bytes < 2; bytes++) run_case(attr, 1'(hot), 1'(bytes), 0);
    run_case(2, 1, 1, 1);
    $display(
        "PASS: PTW/TLB typed loads bypass cold/hot cache, retain attrs, await order and cancel safely");
    $finish;
  end
endmodule


// ---- tb_l1d_load_footprint ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_load_footprint;
  localparam int XLEN = `RAPT_XLEN;
  localparam int WORD_BYTES = XLEN / 8;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  initial begin
    for (int translated = 0; translated < 2; translated++)
    for (int half = 0; half < 2; half++)
    for (int kind = 0; kind < 3; kind++) begin
      automatic logic [XLEN-1:0] grant_pa=XLEN'('h80001000)+XLEN'(half)*XLEN'(4);
      automatic logic [XLEN-1:0] beat_pa=grant_pa & ~XLEN'(WORD_BYTES-1);
      automatic logic [XLEN-1:0] va=translated!=0 ? XLEN'('h40001000)+(beat_pa & XLEN'(4095)) : beat_pa;
      if (kind == 2 && XLEN == 32) continue;
      reset = 1;
      init_l1d_inputs();
      tick(3);
      reset = 0;
      tick(1);
      csr_bcast.priv=`RAPT_PRIV_S;
      csr_bcast.dmmu_en=translated!=0;
      pmp_update.addr_we=1;
      pmp_update.addr_idx=0;
      pmp_update.raw_addr=$bits(pmp_update.raw_addr)'(grant_pa>>2);
      pmp_update.cfg_we[0]=1;
      pmp_update.mode_off[0]=0;
      pmp_update.mode_na4[0]=1;
      pmp_update.cfg_r[0]=kind!=1;
      tick(1);
      pmp_update.addr_we=0;
      pmp_update.cfg_we=0;
      if (translated != 0) begin
        dut.u_dtlb.valid[0]=1;
        dut.u_dtlb.vtags[0]=va[XLEN-1:12];
        dut.u_dtlb.ptags[0]=$bits(dut.u_dtlb.ptags[0])'(beat_pa>>12);
        dut.u_dtlb.asids[0]=0;
        dut.u_dtlb.ptes[0]=7'b1100011;
      end
      lsu_l1d.raddr=va;
      lsu_l1d.ralu=XLEN==64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
      lsu_l1d.rcheck_valid=1;
      lsu_l1d.rorig_size_m1=7;
      lsu_l1d.rcheck_offset=kind==2 ? 3'd0 : 3'(grant_pa-beat_pa);
      lsu_l1d.rcheck_size_m1=kind==2 ? 4'd7 : 4'd3;
      lsu_l1d.rvalid=1;
      lsu_l1d.ordered=1;
      tick(1);
      // Live metadata changes must not replace the captured owner's policy.
      lsu_l1d.rcheck_offset=7;
      lsu_l1d.rcheck_size_m1=7;
      lsu_l1d.rcheck_valid=0;
      for (int c = 0; c < 20; c++) begin
        #1;
        if (kind != 0) check(!l1d_bus.arvalid, "denied fragment emitted RAM read");
        if (kind == 0 ? l1d_bus.arvalid : lsu_l1d.trap) break;
        tick(1);
      end
      if (kind == 0)
        check(l1d_bus.arvalid && l1d_bus.araddr == beat_pa && !lsu_l1d.trap,
              "valid partial-word footprint rejected by wider data beat");
      else check(lsu_l1d.trap && lsu_l1d.cause == 5, "fragment PMP denial lost");
    end
    $display("PASS: L1D captured physical fragment PMP footprint XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_l1d_page_permissions ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_page_permissions;
  localparam int XLEN = `RAPT_XLEN;
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  logic tlb_hit, stlb_hit;
  logic [6:0] dtlb_pte, dstlb_pte, ptw_result_pte;
  logic pf_load_tlb, pf_store_tlb, pf_load_ptw, pf_store_ptw;
  rapt_l1d_access #(
      .XLEN(XLEN)
  ) dut (
      .csr_bcast(csr_bcast),
      .pmp_state(pmp_state),
      .load_addr(XLEN'('h80000000)),
      .store_addr(XLEN'('h80000000)),
      .ptw_addr(XLEN'('h80001000)),
      .load_size_m1(4'd1),
      .store_walu(8'(`RAPT_SH_WSTRB)),
      .cmo_mgmt(1'b0),
      .tlb_hit(tlb_hit),
      .stlb_hit(stlb_hit),
      .dtlb_pte(dtlb_pte),
      .dstlb_pte(dstlb_pte),
      .ptw_result_pte(ptw_result_pte),
      .pmp_load_fault(),
      .load_unmapped_fault(),
      .pmp_store_fault_mmu(),
      .store_unmapped_fault_mmu(),
      .pmp_ptw_fault(),
      .pf_load_tlb(pf_load_tlb),
      .pf_store_tlb(pf_store_tlb),
      .pf_load_ptw(pf_load_ptw),
      .pf_store_ptw(pf_store_ptw)
  );
  function automatic bit allowed(input logic [6:0] flags, input bit store, input int effective,
                                 input bit sum, mxr);
    bit domain;
    domain = effective == 0 ? flags[3] : (effective == 1 ? (!flags[3] || sum) : 1'b1);
    return domain && flags[5] && (store ? (flags[1] && flags[6]) : (flags[0] || (mxr && flags[2])));
  endfunction
  int cases = 0;
  initial begin
    int effective;
    pmp_state.pmp_raw_addr = '{default:'0};
    pmp_state.pmp_napot_mask = '{default:1};
    pmp_state.pmp_cfg_r='0;
    pmp_state.pmp_cfg_w='0;
    pmp_state.pmp_cfg_x='0;
    pmp_state.pmp_cfg_l='0;
    pmp_state.pmp_mode_off='1;
    pmp_state.pmp_mode_tor='0;
    pmp_state.pmp_mode_na4='0;
    pmp_state.pmp_mode_napot='0;
    for (int current_priv = 0; current_priv < 3; current_priv++)
    for (int previous_priv = 0; previous_priv < 3; previous_priv++)
    for (int mprv = 0; mprv < 2; mprv++)
    for (int sum = 0; sum < 2; sum++)
    for (int mxr = 0; mxr < 2; mxr++)
    for (int hits = 0; hits < 4; hits++)
    for (int flags = 0; flags < 128; flags++) begin
      csr_bcast.priv = current_priv == 2 ? 2'd3 : 2'(current_priv);
      csr_bcast.mpp = previous_priv == 2 ? 2'd3 : 2'(previous_priv);
      csr_bcast.mprv = 1'(mprv);
      csr_bcast.sum = 1'(sum);
      csr_bcast.mxr = 1'(mxr);
      effective = current_priv == 2 && mprv != 0 ? int'(csr_bcast.mpp) : int'(csr_bcast.priv);
      tlb_hit=hits[0];
      stlb_hit=hits[1];
      // Different patterns expose accidental wiring between ports.
      dtlb_pte=7'(flags);
      dstlb_pte=7'(flags)^7'h55;
      ptw_result_pte=7'(flags)^7'h2a;
      #1;
      if (pf_load_tlb !== (tlb_hit && !allowed(
              dtlb_pte, 0, effective, 1'(sum), 1'(mxr)
          )) || pf_store_tlb !== (stlb_hit && !allowed(
              dstlb_pte, 1, effective, 1'(sum), 1'(mxr)
          )) || pf_load_ptw !== !allowed(
              ptw_result_pte, 0, effective, 1'(sum), 1'(mxr)
          ) || pf_store_ptw !== !allowed(
              ptw_result_pte, 1, effective, 1'(sum), 1'(mxr)
          ))
        $fatal(
            1,
            "page permissions priv=%0d mpp=%0d mprv=%0d SUM=%0d MXR=%0d hits=%0d flags=%h",
            csr_bcast.priv,
            csr_bcast.mpp,
            mprv,
            sum,
            mxr,
            hits,
            flags
        );
      cases++;
    end
    if (cases != 36864) $fatal(1, "permission coverage count");
    $display("PASS: L1D half page permissions XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule


// ---- tb_l1d_permission_stage ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_permission_stage;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_write_valid_i = 0, external_write_pending_i = 0;
  logic [XLEN-1:0] external_write_first_i = '0, external_write_last_i = '0;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (.*);
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  localparam logic [XLEN-1:0] PA = XLEN'('h80001000);
  int cases = 0;
  task automatic boot;
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b=0;
    l1d_bus.rready=0;
    external_write_valid_i=0;
    external_write_pending_i=0;
    tick(3);
    reset = 0;
    tick(1);
  endtask
  task automatic event_at(input logic [XLEN-1:0] first, last);
    external_write_first_i=first;
    external_write_last_i=last;
    external_write_valid_i=1;
    #1;
    check(exu_l1d.reservation_blocked, "valid event must block SC admission");
  endtask
  task automatic start_lr(input logic [XLEN-1:0] addr, input int bytes);
    lsu_l1d.raddr=addr;
    lsu_l1d.ralu=bytes==8 ? 5'b00011 : 5'b00010;
    lsu_l1d.atomic_lock=1;
    lsu_l1d.rvalid=1;
    tick(1);
    for (int n = 0; n < 20 && !l1d_bus.arvalid; n++) tick(1);
    check(l1d_bus.arvalid, "cold LR did not request memory");
    l1d_bus.rready = 1;
    tick(1);
    l1d_bus.rready = 0;
  endtask
  task automatic finish_lr;
    l1d_bus.rdata=XLEN'('h12345678);
    l1d_bus.rvalid=1;
    tick(1);
    l1d_bus.rvalid=0;
    lsu_l1d.rvalid=0;
    lsu_l1d.atomic_lock=0;
  endtask
  initial begin
    for (int bytes = 4; bytes <= XLEN / 8; bytes += 4) begin
      for (int scenario = 0; scenario < 3; scenario++) begin
        boot();
        lsu_l1d.raddr=PA;
        lsu_l1d.ralu=bytes==8 ? 5'b00011 : 5'b00010;
        lsu_l1d.atomic_lock=1;
        lsu_l1d.rvalid=1;
        tick(1);
        check(dut.l1d_state == dut.LD_CHECK, "request did not reach permission stage");
        check(!l1d_bus.arvalid && !lsu_l1d.rready,
              "permission stage exposed a request or completion");
        if (scenario == 2) begin
          cmu_bcast.flush_pipe=1;
          lsu_l1d.rvalid=0;
          tick(1);
          cmu_bcast.flush_pipe=0;
          lsu_l1d.atomic_lock=0;
          repeat (3) begin
            check(!l1d_bus.arvalid && !exu_l1d.reservation_valid,
                  "canceled permission-stage LR issued or reserved");
            tick(1);
          end
        end else begin
          // A one-cycle event must be remembered after it is withdrawn,
          // even though no memory request has yet left the permission stage.
          event_at(scenario == 0 ? PA : PA + 64, scenario == 0 ? PA : PA + 64);
          tick(1);
          external_write_valid_i = 0;
          for (int n = 0; n < 20 && !l1d_bus.arvalid; n++) tick(1);
          check(l1d_bus.arvalid, "checked LR did not progress to memory");
          l1d_bus.rready = 1;
          tick(1);
          l1d_bus.rready = 0;
          finish_lr();
          #1;
          check(exu_l1d.reservation_valid == (scenario == 1),
                "permission-stage interference was lost or overmatched");
        end
        tick(3);
        // No reset: stale cancellation/interference must not poison a new LR.
        start_lr(PA + 128, bytes);
        finish_lr();
        #1;
        check(exu_l1d.reservation_valid && exu_l1d.reservation == PA + 128,
              "fresh LR failed after permission-stage event/cancellation");
        cases++;
      end
    end
    $display("PASS: L1D permission-stage event/cancel/retry XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule


// ---- tb_l1d_plic_width ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_plic_width;
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
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  initial begin
    for (int translated = 0; translated < 2; translated++)
    for (int kind = 0; kind < 5; kind++) begin
      automatic logic [XLEN-1:0] pa=XLEN'('h0c200000);
      automatic logic [XLEN-1:0] va=translated!=0 ? XLEN'('h40000000) : pa;
      reset = 1;
      init_l1d_inputs();
      tick(3);
      reset = 0;
      tick(1);
      if (translated != 0) begin
        csr_bcast.priv=`RAPT_PRIV_S;
        csr_bcast.dmmu_en=1;
        pmp_update.addr_we=1;
        pmp_update.raw_addr='1;
        pmp_update.napot_mask='1;
        pmp_update.cfg_we=1;
        pmp_update.cfg_r=1;
        pmp_update.cfg_w=1;
        pmp_update.mode_off[0]=0;
        pmp_update.mode_napot=1;
        tick(1);
        pmp_update.addr_we=0;
        pmp_update.cfg_we=0;
        dut.u_dtlb.valid[0]=1;
        dut.u_dtlb.vtags[0]=va[XLEN-1:12];
        dut.u_dtlb.ptags[0]=$bits(dut.u_dtlb.ptags[0])'(pa>>12);
        dut.u_dtlb.asids[0]=0;
        dut.u_dtlb.ptes[0]=7'b1100011;
      end
      lsu_l1d.raddr = va;
      case (kind)
        0:lsu_l1d.ralu=`RAPT_ALU_LBU_;
        1:lsu_l1d.ralu=`RAPT_ALU_LHU_;
        2,4:lsu_l1d.ralu=`RAPT_ALU_LW__;
        3:lsu_l1d.ralu=`RAPT_ALU_LD__;
      endcase
      // A word-sized physical fragment must not authorize an eight-byte FLD.
      lsu_l1d.rcheck_valid=kind==4;
      lsu_l1d.rcheck_size_m1=3;
      lsu_l1d.rorig_size_m1=7;
      lsu_l1d.rvalid=1;
      lsu_l1d.ordered=1;
      tick(1);
      lsu_l1d.rorig_size_m1=3;
      lsu_l1d.rcheck_valid=0;
      for (int c = 0; c < 30; c++) begin
        #1;
        if (kind != 2) check(!l1d_bus.arvalid, "unsupported width emitted device AR");
        if (kind == 2 ? l1d_bus.arvalid : lsu_l1d.trap) break;
        tick(1);
      end
      if (kind == 2)
        check(l1d_bus.arvalid && l1d_bus.araddr == pa && !lsu_l1d.trap,
              "supported PLIC word read rejected");
      else
        check(lsu_l1d.trap && lsu_l1d.cause == 5,
              "unsupported PLIC width did not fault before device read");
    end
    $display("PASS: L1D PLIC original width, Bare/translated, no denied AR XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_l1d_pma ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_pma;
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
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  logic [XLEN-1:0] pa, va;
  bit sram_path;
  initial begin
    sram_path = $test$plusargs("SRAM");
    for (int translated = 0; translated < 2; translated++)
    for (int region = 0; region < (sram_path ? 2 : 3); region++)
    for (int kind = 0; kind < (sram_path ? 3 : 1); kind++) begin
      if (sram_path && kind == 2 && !translated) continue;
      reset = 1;
      init_l1d_inputs();
      lsu_l1d.rvalid_b=0;
      l1d_bus.rready=1;
      tick(3);
      reset = 0;
      tick(1);
      pmp_update.addr_we=1;
      pmp_update.addr_idx=0;
      pmp_update.raw_addr='1;
      pmp_update.napot_mask='1;
      pmp_update.cfg_we[0]=1;
      pmp_update.mode_off[0]=0;
      pmp_update.mode_napot[0]=1;
      pmp_update.cfg_r[0]=1;
      pmp_update.cfg_w[0]=1;
      pmp_update.cfg_x[0]=1;
      tick(1);
      pmp_update.addr_we=0;
      pmp_update.cfg_we=0;
      if (sram_path) pa = region == 0 ? XLEN'('h0f002000) : XLEN'('h0f00f000);
      else
        pa = region == 0 ? XLEN'('h02000000) : region == 1 ? XLEN'('h20001000) : XLEN'('h30001000);
      va=translated ? XLEN'('h40000000) : pa;
      csr_bcast.dmmu_en=1'(translated);
      if (translated) begin
        csr_bcast.priv=`RAPT_PRIV_S;
        dut.u_dtlb.valid[0]=1;
        dut.u_dtlb.vtags[0]=va[XLEN-1:12];
        dut.u_dtlb.ptags[0]=pa>>12;
        dut.u_dtlb.asids[0]='0;
        dut.u_dtlb.ptes[0]=7'b1100011;
        if (sram_path) begin
          dut.u_dstlb.valid[0]=1;
          dut.u_dstlb.vtags[0]=va[XLEN-1:12];
          dut.u_dstlb.ptags[0]=pa>>12;
          dut.u_dstlb.asids[0]='0;
          dut.u_dstlb.ptes[0]=7'b1100011;
        end
      end
      lsu_l1d.raddr=va;
      lsu_l1d.ralu=2'b10;
      lsu_l1d.atomic_lock=sram_path ? kind==1 : 1;
      lsu_l1d.ordered=1;
      lsu_l1d.rvalid=!sram_path || kind!=2;
      exu_l1d.vaddr=va;
      exu_l1d.walu=`RAPT_SW_WSTRB;
      exu_l1d.valid=sram_path && kind==2;
      exu_l1d.mmu_en=sram_path && kind==2;
      for (int n = 0; n < 30; n++) begin
        #1;
        check(!l1d_bus.arvalid && !l1d_bus.awvalid,
              sram_path ? "SRAM hole access issued external access" : "unsupported LR issued external access");
        check(!exu_l1d.reservation_valid,
              sram_path ? "SRAM hole access established reservation" : "unsupported LR established reservation");
        if (sram_path && kind == 2 ? exu_l1d.trap : lsu_l1d.trap) break;
        tick(1);
      end
      if (sram_path) begin
        check(
            kind == 2 ? (exu_l1d.trap && exu_l1d.cause == 7) : (lsu_l1d.trap && lsu_l1d.cause == 5),
            "SRAM hole must raise access fault");
      end else
        check(lsu_l1d.trap && lsu_l1d.cause == 5, "LR PMA denial did not report load access fault");
    end
    $display("PASS: %s L1D PMA denial before bus/reservation",
             sram_path ? "SRAM-hole" : "LR-device");
    $finish;
  end
endmodule


// ---- tb_l1d_ptw_axi_error ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
module tb_l1d_ptw_axi_error;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] VA = 'h40000120, PA = 'h80000120;
  localparam logic [XLEN-1:0] Root = 'h80001000 + (XLEN == 64 ? 8 : 1024);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  l1i_bus_if l1i_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) mem ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) axi ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  rapt_bus #(
      .XLEN(XLEN)
  ) bus_dut (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .l1d_bus,
      .l1i_bus,
      .mem
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
  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  task automatic request(input int kind, input bit valid_req);
    lsu_l1d.rvalid=kind==0 && valid_req;
    exu_l1d.valid=kind!=0 && valid_req;
  endtask

  task automatic accept_ar(input bit ptw, input int delay_cycles);
    for (int n = 0; n < 60; n++) begin
      #1;
      check(!lsu_l1d.trap && !exu_l1d.trap, "orphan trap before AXI request");
      if (axi.arvalid) begin
        repeat (delay_cycles) begin
          check(axi.araddr == (ptw ? Root : PA) && axi.arid == (ptw ? 4 : 2),
                "stalled AR owner changed");
          tick(1);
        end
        check(axi.araddr == (ptw ? Root : PA) && axi.arid == (ptw ? 4 : 2),
              "incorrect AXI translation/address");
        check(axi.arlen == 0 && axi.arsize == (XLEN == 64 ? 3 : 2),
              "PTE/cacheable refill AXI span incorrect");
        axi.arready = 1;
        tick(1);
        axi.arready = 0;
        return;
      end
      tick(1);
    end
    fail("AXI request timeout");
  endtask

  task automatic response(input bit ptw, input logic [1:0] resp, input logic [XLEN-1:0] data);
    axi.rid=ptw ? 4 : 2;
    axi.rdata=data;
    axi.rlast=1;
    axi.rresp=resp;
    axi.rvalid=1;
    for (int n = 0; n < 30; n++) begin
      #1;
      if (axi.rready) begin
        tick(1);
        axi.rvalid = 0;
        return;
      end
      tick(1);
    end
    fail("AXI error response did not drain");
  endtask

  task automatic run_case(input int kind, input int cancel, input logic [1:0] resp,
                          input int delay_cycles);
    reset = 1;
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
    init_cmu_bcast_defaults();
    lsu_l1d.raddr=VA;
    lsu_l1d.ralu=`RAPT_ALU_LW__;
    lsu_l1d.rmisaligned=0;
    lsu_l1d.rvalid=0;
    lsu_l1d.rvalid_b=0;
    lsu_l1d.raddr_b=0;
    lsu_l1d.ralu_b=0;
    lsu_l1d.atomic_lock=0;
    lsu_l1d.ordered=1;
    lsu_l1d.waddr=0;
    lsu_l1d.wpbmt=0;
    lsu_l1d.walu=0;
    lsu_l1d.wvalid=0;
    lsu_l1d.wdata=0;
    exu_l1d.valid=0;
    exu_l1d.vaddr=VA;
    exu_l1d.mmu_en=kind!=0;
    exu_l1d.cmo_mgmt=kind==2;
    exu_l1d.misaligned=0;
    exu_l1d.reservation_clear=0;
    exu_l1d.walu=kind==2 ? `RAPT_CBO_MGMT_WALU : `RAPT_SW_WSTRB;
    rou_cmu.slot[0].valid=0;
    rou_cmu.atomic_sc=0;
    rou_cmu.fence_time=0;
    rou_cmu.flush_pipe=0;
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
    axi.arready=0;
    axi.rvalid=0;
    axi.rid=0;
    axi.rdata=0;
    axi.rresp=0;
    axi.rlast=0;
    axi.awready=0;
    axi.wready=0;
    axi.bvalid=0;
    axi.bid=0;
    axi.bresp=0;
    pmp_update.addr_we=0;
    pmp_update.addr_idx=0;
    pmp_update.raw_addr='1;
    pmp_update.napot_mask='1;
    pmp_update.cfg_we=0;
    pmp_update.cfg_r=0;
    pmp_update.cfg_w=0;
    pmp_update.cfg_x=0;
    pmp_update.cfg_l=0;
    pmp_update.mode_off='1;
    pmp_update.mode_napot=0;
    pmp_update.mode_na4=0;
    pmp_update.mode_tor=0;
    tick(3);
    reset = 0;
    tick(1);
    pmp_update.addr_we=1;
    pmp_update.cfg_we[0]=1;
    pmp_update.mode_off[0]=0;
    pmp_update.mode_napot[0]=1;
    pmp_update.cfg_r[0]=1;
    pmp_update.cfg_w[0]=1;
    pmp_update.cfg_x[0]=1;
    tick(1);
    pmp_update.addr_we=0;
    pmp_update.cfg_we=0;
    csr_bcast.priv=`RAPT_PRIV_S;
    csr_bcast.dmmu_en=1;
    csr_bcast.satp_ppn='h80001;
    request(kind, 1);
    accept_ar(1, delay_cycles);
    if (cancel == 1) begin
      cmu_bcast.flush_pipe = 1;
      request(kind, 0);
      tick(1);
      cmu_bcast.flush_pipe = 0;
      request(kind, 1);
      tick(3);
      check(!axi.arvalid && dut.ptw_busy, "cancelled PTW owner reused before AXI response");
    end else if (cancel == 2) begin
      cmu_bcast.flush_pipe = 1;
      request(kind, 0);
    end
    response(1, resp, XLEN'('h200000cf));
    // Adapter exposes the R beat directly; the accepting edge must end this
    // walk, either with the original access fault or as a cancelled drain.
    check(!dut.ptw_done && !dut.ptw_fault, "AXI error became a PTE result");
    check(dut.u_dtlb.valid == 0 && dut.u_dstlb.valid == 0, "AXI error polluted TLB");
    cmu_bcast.flush_pipe = 0;
    if (cancel == 0) begin
      if (kind == 0)
        check(lsu_l1d.trap && lsu_l1d.cause == 5, "AXI PTE read did not raise load access fault");
      else
        check(exu_l1d.trap && exu_l1d.cause == 7,
              "AXI PTE read did not raise store/CMO access fault");
      check(dut.rec_addr == VA, "AXI PTE fault lost VA");
      request(kind, 0);
      tick(2);
    end else check(!lsu_l1d.trap && !exu_l1d.trap, "cancelled AXI error escaped");
    request(kind, 1);
    accept_ar(1, delay_cycles);
    response(1, 0, XLEN'('h200000cf));
    if (kind == 0) begin
      accept_ar(0, delay_cycles);
      axi.rid=2;
      axi.rdata='h12345678;
      axi.rlast=1;
      axi.rresp=0;
      axi.rvalid=1;
      #1;
      check(lsu_l1d.rready && !lsu_l1d.trap && lsu_l1d.rdata == 'h12345678,
            "clean AXI retry failed");
      tick(1);
      axi.rvalid = 0;
    end else begin
      tick(2);
      check(exu_l1d.ready && !exu_l1d.trap && exu_l1d.paddr == PA,
            "store AXI retry translation failed");
    end
    request(kind, 0);
    tick(2);
    check(l1d_bus.idle && !dut.ptw_busy, "AXI error/retry left outstanding ownership");
  endtask

  initial begin
    for (int kind = 0; kind < 3; kind++)
    for (int cancel = 0; cancel < 3; cancel++)
    for (int resp = 2; resp < 4; resp++)
    for (int delay_sel = 0; delay_sel < 2; delay_sel++)
    run_case(kind, cancel, 2'(resp), delay_sel * 7);
    $display("PASS: AXI SLVERR/DECERR through bus and D PTW, cancellation, retry and drain");
    $finish;
  end
endmodule


// ---- tb_l1d_ptw_error ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_ptw_error;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Levels = XLEN == 64 ? 3 : 2;
  localparam logic [XLEN-1:0] VA = 'h40000120, PA = 'h80000120;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic request(input int kind, input bit enable);
    lsu_l1d.rvalid=enable && kind==0;
    exu_l1d.valid=enable && kind!=0;
  endtask

  task automatic accept_pte(input int level);
    logic [XLEN-1:0] expected;
    expected = 'h80001000 + XLEN'(level * 4096);
    if (level == 0) expected += XLEN'(XLEN == 64 ? 8 : 1024);
    for (int n = 0; n < 50; n++) begin
      #1;
      check(!lsu_l1d.trap && !exu_l1d.trap, "orphan fault on new translation");
      if (l1d_bus.arvalid) begin
        check(l1d_bus.ar_ptw && l1d_bus.araddr == expected, "wrong PTE request address/owner");
        l1d_bus.rready = 1;
        tick(1);
        l1d_bus.rready = 0;
        return;
      end
      tick(1);
    end
    fail("PTE request timeout: errored PTE may have filled TLB");
  endtask

  task automatic good_pte(input int level);
    l1d_bus.rdata=level==Levels-1 ? XLEN'('h200000cf)
        : XLEN'('h20000801+level*1024);
    l1d_bus.ptw_rvalid=1;
    tick(1);
    l1d_bus.ptw_rvalid = 0;
  endtask

  task automatic run_case(input int kind, input int bad_level, input bit invalid_pte,
                          input int cancel);
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b=0;
    l1d_bus.rready=0;
    tick(3);
    reset = 0;
    tick(1);
    pmp_update.addr_we=1;
    pmp_update.raw_addr='1;
    pmp_update.napot_mask='1;
    pmp_update.cfg_we[0]=1;
    pmp_update.mode_off[0]=0;
    pmp_update.mode_napot[0]=1;
    pmp_update.cfg_r[0]=1;
    pmp_update.cfg_w[0]=1;
    pmp_update.cfg_x[0]=1;
    tick(1);
    pmp_update.addr_we=0;
    pmp_update.cfg_we=0;
    csr_bcast.priv=`RAPT_PRIV_S;
    csr_bcast.dmmu_en=1;
    csr_bcast.satp_ppn='h80001;
    lsu_l1d.raddr=VA;
    lsu_l1d.ralu=`RAPT_ALU_LW__;
    exu_l1d.vaddr=VA;
    exu_l1d.mmu_en=kind!=0;
    exu_l1d.cmo_mgmt=kind==2;
    exu_l1d.walu=kind==2 ? `RAPT_CBO_MGMT_WALU : `RAPT_SW_WSTRB;
    request(kind, 1);
    for (int level = 0; level <= bad_level; level++) begin
      accept_pte(level);
      if (level != bad_level) good_pte(level);
    end
    // Error without a response cannot terminate the outstanding walk.
    l1d_bus.ptw_rerr = 1;
    tick(3);
    check(dut.ptw_busy && !lsu_l1d.trap && !exu_l1d.trap, "stray PTW error consumed");
    l1d_bus.ptw_rerr = 0;
    if (cancel == 1) begin
      cmu_bcast.flush_pipe = 1;
      request(kind, 0);
      tick(1);
      cmu_bcast.flush_pipe = 0;
      request(kind, 1);
      tick(2);
      check(!l1d_bus.arvalid && dut.ptw_busy, "new walk issued before cancelled response drained");
    end else if (cancel == 2) begin
      cmu_bcast.flush_pipe = 1;
      request(kind, 0);
    end
    // Both a plausible leaf and an invalid PTE must cause access-fault,
    // irrespective of the page-table level or PTE contents.
    l1d_bus.rdata=invalid_pte ? '0 : XLEN'('h200000cf);
    l1d_bus.ptw_rvalid=1;
    l1d_bus.ptw_rerr=1;
    tick(1);
    l1d_bus.ptw_rvalid=0;
    l1d_bus.ptw_rerr=0;
    cmu_bcast.flush_pipe=0;
    check(!dut.ptw_done && !dut.ptw_fault, "errored response parsed as a PTE");
    check(dut.u_dtlb.valid == '0 && dut.u_dstlb.valid == '0, "errored walk populated a TLB");
    if (cancel == 0) begin
      if (kind == 0) check(lsu_l1d.trap && lsu_l1d.cause == 5, "load PTE error lost access fault");
      else check(exu_l1d.trap && exu_l1d.cause == 7, "store/CMO PTE error lost access fault");
      check(dut.rec_addr == VA, "PTW access fault lost original VA");
      request(kind, 0);
      tick(2);
    end else check(!lsu_l1d.trap && !exu_l1d.trap, "cancelled PTW error reached new owner");
    request(kind, 1);
    for (int level = 0; level < Levels; level++) begin
      accept_pte(level);
      good_pte(level);
    end
    if (kind == 0) begin
      for (int n = 0; n < 40; n++) begin
        #1;
        check(!lsu_l1d.trap, "clean translation retry faulted");
        if (l1d_bus.arvalid) break;
        tick(1);
      end
      check(l1d_bus.arvalid && !l1d_bus.ar_ptw && l1d_bus.araddr == PA,
            "retry did not translate load");
      l1d_bus.rready = 1;
      tick(1);
      l1d_bus.rready=0;
      l1d_bus.rdata='h12345678;
      l1d_bus.rvalid=1;
      #1;
      check(lsu_l1d.rready && !lsu_l1d.trap && lsu_l1d.rdata == 'h12345678,
            "retry load did not complete");
      tick(1);
      l1d_bus.rvalid = 0;
    end else begin
      tick(2);
      check(exu_l1d.ready && !exu_l1d.trap && exu_l1d.paddr == PA,
            "retry store translation did not complete");
    end
    request(kind, 0);
    tick(2);
    check(dut.u_dtlb.valid != '0 && dut.u_dstlb.valid != '0,
          "clean retry did not fill both TLB views");
  endtask

  initial begin
    for (int kind = 0; kind < 3; kind++)
    for (int level = 0; level < Levels; level++)
    for (int invalid_pte = 0; invalid_pte < 2; invalid_pte++)
    for (int cancel = 0; cancel < 3; cancel++) run_case(kind, level, 1'(invalid_pte), cancel);
    $display("PASS: D PTW errors at every level, load/store/CMO, cancellation and clean retry");
    $finish;
  end
endmodule


// ---- tb_l1d_ptw_pma ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_ptw_pma;
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
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  initial begin
    for (int kind = 0; kind < 3; kind++) begin
      reset = 1;
      init_l1d_inputs();
      lsu_l1d.rvalid_b=0;
      l1d_bus.rready=1;
      tick(3);
      reset = 0;
      tick(1);
      // Permit the entire physical address space in PMP. PMA alone must
      // stop a root table in CLINT for loads, stores and CMO translation.
      pmp_update.addr_we=1;
      pmp_update.addr_idx=0;
      pmp_update.raw_addr='1;
      pmp_update.napot_mask='1;
      pmp_update.cfg_we[0]=1;
      pmp_update.mode_off[0]=0;
      pmp_update.mode_napot[0]=1;
      pmp_update.cfg_r[0]=1;
      pmp_update.cfg_w[0]=1;
      pmp_update.cfg_x[0]=1;
      tick(1);
      pmp_update.addr_we=0;
      pmp_update.cfg_we=0;
      csr_bcast.priv=`RAPT_PRIV_S;
      csr_bcast.dmmu_en=1;
      csr_bcast.satp_ppn='h02000;
      lsu_l1d.raddr='h40000120;
      lsu_l1d.ralu=2'b10;
      lsu_l1d.rvalid=kind==0;
      exu_l1d.vaddr='h40000120;
      exu_l1d.mmu_en=kind!=0;
      exu_l1d.valid=kind!=0;
      exu_l1d.cmo_mgmt=kind==2;
      exu_l1d.walu=kind==2 ? `RAPT_CBO_MGMT_WALU : `RAPT_SW_WSTRB;
      for (int n = 0; n < 30; n++) begin
        #1;
        check(!l1d_bus.arvalid && !l1d_bus.awvalid,
              "implicit physical device access escaped L1D PMA");
        if (kind == 0 ? lsu_l1d.trap : exu_l1d.trap) break;
        tick(1);
      end
      if (kind == 0)
        check(lsu_l1d.trap && lsu_l1d.cause == 5,
              "load PTE PMA denial did not produce load access fault");
      else
        check(exu_l1d.trap && exu_l1d.cause == 7,
              "store/CMO PTE PMA denial did not produce store access fault");
    end
    $display("PASS: L1D load/store/CMO implicit MMIO PTE reads denied before bus issue");
    $finish;
  end
endmodule


// ---- tb_l1d_read_error ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_read_error;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] PA = 'h80000000, VA = 'h40000000;
  localparam logic [XLEN-1:0] Good = 'h12345678, Bad = 'hdeadbeef;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic accept_read;
    for (int n = 0; n < 40; n++) begin
      #1;
      check(!lsu_l1d.rready && !lsu_l1d.trap, "failed response became cached data or a new trap");
      if (l1d_bus.arvalid) begin
        check(!l1d_bus.ar_ptw && l1d_bus.araddr == PA, "wrong retry address/owner");
        l1d_bus.rready = 1;
        tick(1);
        l1d_bus.rready = 0;
        return;
      end
      tick(1);
    end
    fail("read AR timeout");
  endtask

  task automatic good_response;
    l1d_bus.rdata=Good;
    l1d_bus.rvalid=1;
    l1d_bus.rerr=0;
    #1;
    check(lsu_l1d.rready && !lsu_l1d.trap && lsu_l1d.rdata == Good,
          "successful retry did not return clean data");
    tick(1);
    lsu_l1d.rvalid=0;
    l1d_bus.rvalid=0;
    tick(3);
  endtask

  task automatic run_case(input int attr, input bit lr, input int cancel);
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b=0;
    l1d_bus.rready=0;
    tick(3);
    reset = 0;
    tick(1);
    pmp_update.addr_we=1;
    pmp_update.raw_addr='1;
    pmp_update.napot_mask='1;
    pmp_update.cfg_we[0]=1;
    pmp_update.mode_off[0]=0;
    pmp_update.mode_napot[0]=1;
    pmp_update.cfg_r[0]=1;
    pmp_update.cfg_w[0]=1;
    pmp_update.cfg_x[0]=1;
    tick(1);
    pmp_update.addr_we=0;
    pmp_update.cfg_we=0;
    if (attr != 0) begin
      csr_bcast.priv=`RAPT_PRIV_S;
      csr_bcast.dmmu_en=1;
      csr_bcast.menvcfg_pbmte=1;
      dut.u_dtlb.valid[0]=1;
      dut.u_dtlb.vtags[0]=VA[XLEN-1:12];
      dut.u_dtlb.ptags[0]=PA>>12;
      dut.u_dtlb.asids[0]=0;
      dut.u_dtlb.ptes[0]=7'b1100011;
      dut.u_dtlb.pbmts[0]=2'(attr);
    end
    lsu_l1d.raddr=attr==0 ? PA : VA;
    lsu_l1d.ralu=`RAPT_ALU_LW__;
    lsu_l1d.atomic_lock=lr;
    lsu_l1d.ordered=1;
    lsu_l1d.rvalid=1;
    accept_read();
    // An error indication without a valid response must be ignored.
    l1d_bus.rerr = 1;
    repeat (3) begin
      #1;
      check(!lsu_l1d.rready && !lsu_l1d.trap, "stray error consumed without response");
      tick(1);
    end
    l1d_bus.rerr = 0;
    if (cancel == 1) begin
      cmu_bcast.flush_pipe=1;
      lsu_l1d.rvalid=0;
      tick(1);
      cmu_bcast.flush_pipe=0;
      // A new dynamic request at the same VA must not consume the old beat.
      lsu_l1d.rvalid=1;
      tick(2);
      check(!l1d_bus.arvalid && !lsu_l1d.rready, "cancelled response owner reused before drain");
    end else if (cancel == 2) begin
      cmu_bcast.flush_pipe=1;
      lsu_l1d.rvalid=0;
    end
    l1d_bus.rdata=Bad;
    l1d_bus.rerr=1;
    l1d_bus.rvalid=1;
    l1d_bus.difftest_skip=1;
    #1;
    check(!(lsu_l1d.rready && !lsu_l1d.trap), "bus error completed as successful load");
    tick(1);
    l1d_bus.rvalid=0;
    l1d_bus.rerr=0;
    l1d_bus.difftest_skip=0;
    cmu_bcast.flush_pipe=0;
    check(!exu_l1d.reservation_valid, "errored LR established reservation");
    if (cancel == 0) begin
      check(lsu_l1d.rready && lsu_l1d.trap && lsu_l1d.cause == 5,
            "live read error lost access fault");
      check(!lsu_l1d.difftest_skip, "access fault skipped reference");
      tick(1);
      lsu_l1d.rvalid = 0;
      tick(3);
    end else check(!lsu_l1d.trap && !lsu_l1d.rready, "cancelled read error leaked to new owner");
    lsu_l1d.rvalid = 1;
    accept_read();
    good_response();
    check(exu_l1d.reservation_valid == lr, "retry LR reservation state incorrect");
    // Failed data must not poison the cache; successful cacheable retry may fill.
    lsu_l1d.atomic_lock=0;
    lsu_l1d.rvalid=1;
    if (attr == 0) begin
      for (int n = 0; n < 20; n++) begin
        #1;
        check(!l1d_bus.arvalid, "successful retry did not populate cache");
        if (lsu_l1d.rready) break;
        tick(1);
      end
      check(lsu_l1d.rready && !lsu_l1d.trap && lsu_l1d.rdata == Good, "retry cache data corrupted");
    end else begin
      accept_read();
      good_response();
    end
  endtask
  initial begin
    for (int attr = 0; attr < 3; attr++)
    for (int lr = 0; lr < 2; lr++)
    for (int cancel = 0; cancel < 3; cancel++) run_case(attr, 1'(lr), cancel);
    $display("PASS: L1D read error, LR, typed bypass, cancellation drain and clean retry");
    $finish;
  end
endmodule


// ---- tb_l1d_replacement ----
`include "rapt.svh"
module tb_l1d_replacement;
  logic clock = 0, reset = 1, fence_time = 0;
  logic [1:0] clear_set = '0;
  logic addr_idx = 0, waddr_idx = 1, probe_idx = 0, l1d_idx = 0;
  logic addr_offset = 0, waddr_offset = 0, probe_offset = 0, l1d_off = 0;
  logic [3:0] addr_tag = 15, waddr_tag = 15, probe_tag = 15, l1d_tag_u = 0;
  logic load_hit = 0, load_replace = 0, store_replace = 0;
  logic l1d_update = 0, l1d_valid_u = 1, l1d_inv_all_ways = 0;
  logic [1:0] l1d_way = 0;
  wire [3:0] load_way_hit, probe_way_hit;
  wire hit_w;
  wire [1:0] store_hit_way, store_fill_way, ld_fill_way;
  always #5 clock = ~clock;
  rapt_l1d_tags #(
      .L1D_LEN(1),
      .L1D_LINE_LEN(1),
      .L1D_N_WAYS(4),
      .L1dTagW(4)
  ) dut (
      .*
  );
  task automatic tick;
    @(posedge clock);
    #1;
    @(negedge clock);
  endtask
  initial begin
    tick();
    reset = 0;
    // Populate both sets with distinct live tags; writes also mark MRU paths.
    for (int s = 0; s < 2; s++) begin
      for (int way = 0; way < 4; way++) begin
        l1d_update = 1;
        l1d_idx = 1'(s);
        l1d_way = 2'(way);
        l1d_tag_u = 4'(way);
        tick();
      end
    end
    l1d_update = 0;
    // Touch set 0 / way 0: set 0 victim becomes 2, set 1 stays at 0.
    addr_tag = 0;
    load_hit = 1;
    tick();
    load_hit = 0;
    addr_tag = 15;
    #1;
    if (ld_fill_way != 2 || store_fill_way != 0)
      $fatal(1, "load and store victim queries used the same set");
    // Fill set 1 / way 0 while load lookup remains on set 0.
    l1d_update = 1;
    l1d_idx = 1;
    l1d_way = 0;
    l1d_tag_u = 0;
    tick();
    l1d_update = 0;
    #1;
    if (ld_fill_way != 2 || store_fill_way != 2) $fatal(1, "fill did not update its own set/way");
    // Unfilled offset 1: invalid way zero wins even though policy victim is 2.
    addr_offset = 1;
    waddr_offset = 1;
    #1;
    if (ld_fill_way != 0 || store_fill_way != 0)
      $fatal(1, "invalid way zero overwritten by policy");
    // A partial matching line must be reused instead of another invalid way.
    addr_tag = 3;
    waddr_tag = 2;
    #1;
    if (ld_fill_way != 3 || store_fill_way != 2) $fatal(1, "partial matching line was not reused");
    fence_time = 1;
    clear_set = '1;
    tick();
    clear_set = '0;
    fence_time = 0;
    #1;
    if (ld_fill_way != 0 || store_fill_way != 0)
      $fatal(1, "stale invalid tag influenced replacement");
    $display(
        "PASS: L1D independent-set replacement, fill ownership, invalid-zero, partial-tag reuse");
    $finish;
  end
  initial begin
    #2000;
    $fatal(1, "replacement integration timeout");
  end
endmodule


// ---- tb_l1d_reservation_external ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_reservation_external;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_write_valid_i = 0, external_write_pending_i = 0;
  logic [XLEN-1:0] external_write_first_i = '0, external_write_last_i = '0;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (.*);
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  localparam logic [XLEN-1:0] PA = XLEN'('h80001000);
  int cases = 0;
  task automatic boot;
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b=0;
    l1d_bus.rready=0;
    external_write_valid_i=0;
    external_write_pending_i=0;
    tick(3);
    reset = 0;
    tick(1);
  endtask
  task automatic event_at(input logic [XLEN-1:0] first, last);
    external_write_first_i=first;
    external_write_last_i=last;
    external_write_valid_i=1;
    #1;
    check(exu_l1d.reservation_blocked, "valid event must block SC admission");
  endtask
  task automatic start_lr(input logic [XLEN-1:0] addr, input int bytes);
    lsu_l1d.raddr=addr;
    lsu_l1d.ralu=bytes==8 ? 5'b00011 : 5'b00010;
    lsu_l1d.atomic_lock=1;
    lsu_l1d.rvalid=1;
    tick(1);
    for (int n = 0; n < 20 && !l1d_bus.arvalid; n++) tick(1);
    check(l1d_bus.arvalid, "cold LR did not request memory");
    l1d_bus.rready = 1;
    tick(1);
    l1d_bus.rready = 0;
  endtask
  task automatic finish_lr;
    l1d_bus.rdata=XLEN'('h12345678);
    l1d_bus.rvalid=1;
    tick(1);
    l1d_bus.rvalid=0;
    lsu_l1d.rvalid=0;
    lsu_l1d.atomic_lock=0;
  endtask
  initial begin
    for (int bytes = 4; bytes <= XLEN / 8; bytes += 4) begin
      // Established reservation: first/last byte overlaps; adjacent bytes do not.
      for (int mode = 0; mode < 4; mode++) begin
        boot();
        start_lr(PA, bytes);
        finish_lr();
        check(exu_l1d.reservation_valid, "completed LR did not reserve");
        case (mode)
          0: event_at(PA,PA);
          1: event_at(PA+XLEN'(bytes-1),PA+XLEN'(bytes-1));
          2: event_at(PA-1,PA-1);
          3: event_at(PA+XLEN'(bytes),PA+XLEN'(bytes));
        endcase
        check(exu_l1d.reservation_valid == (mode >= 2), "event overlap combinational visibility");
        tick(1);
        external_write_valid_i = 0;
        #1;
        check(exu_l1d.reservation_valid == (mode >= 2), "event overlap registered invalidation");
        cases++;
      end
      // Events during an outstanding miss must survive until LR completion.
      for (int mode = 0; mode < 3; mode++) begin
        boot();
        start_lr(PA, bytes);
        event_at(mode == 2 ? PA + 64 : PA, mode == 2 ? PA + 64 : PA);
        if (mode != 1) begin
          tick(1);
          external_write_valid_i = 0;
          tick(2);
        end
        finish_lr();
        external_write_valid_i = 0;
        #1;
        check(exu_l1d.reservation_valid == (mode == 2), "in-flight/response-edge interference");
        cases++;
      end
      // Invalidating an old range must not poison a different LR's response.
      boot();
      start_lr(PA, bytes);
      finish_lr();
      tick(3);
      start_lr(PA + 64, bytes);
      event_at(PA, PA);
      finish_lr();
      external_write_valid_i = 0;
      #1;
      check(exu_l1d.reservation_valid && exu_l1d.reservation == PA + 64,
            "old-range invalidation overrode unrelated new LR");
      cases++;
      // Explicit SC completion clear wins over a simultaneous LR response.
      boot();
      start_lr(PA, bytes);
      exu_l1d.reservation_clear = 1;
      finish_lr();
      exu_l1d.reservation_clear = 0;
      #1;
      check(!exu_l1d.reservation_valid, "SC clear lost to LR install");
      cases++;
      // Real refill first, then an LR cache hit with event on installation edge.
      for (int overlap = 0; overlap < 2; overlap++) begin
        boot();
        start_lr(PA, bytes);
        finish_lr();
        tick(3);
        exu_l1d.reservation_clear = 1;
        tick(1);
        exu_l1d.reservation_clear=0;
        lsu_l1d.raddr=PA;
        lsu_l1d.ralu=bytes==8 ? 5'd3 : 5'd2;
        lsu_l1d.atomic_lock=1;
        lsu_l1d.rvalid=1;
        tick(1);
        for (int n = 0; n < 20 && !dut.tag_hit; n++) tick(1);
        lsu_l1d.rvalid = 0;
        check(dut.tag_hit && !l1d_bus.arvalid, "hot LR did not hit actual filled cache");
        event_at(overlap == 1 ? PA : PA + 64, overlap == 1 ? PA : PA + 64);
        tick(1);
        external_write_valid_i = 0;
        #1;
        check(exu_l1d.reservation_valid == (overlap == 0), "hot LR event-install race");
        cases++;
      end
      // Isolated hot-TLB setup: the external writer reports PA, never VA.
      boot();
      pmp_update.addr_we=1;
      pmp_update.addr_idx=0;
      pmp_update.raw_addr='1;
      pmp_update.napot_mask='1;
      pmp_update.cfg_we[0]=1;
      pmp_update.mode_off[0]=0;
      pmp_update.mode_napot[0]=1;
      pmp_update.cfg_r[0]=1;
      pmp_update.cfg_w[0]=1;
      pmp_update.cfg_x[0]=1;
      tick(1);
      pmp_update.addr_we=0;
      pmp_update.cfg_we=0;
      csr_bcast.dmmu_en=1;
      csr_bcast.priv=`RAPT_PRIV_S;
      dut.u_dtlb.valid[0]=1;
      dut.u_dtlb.vtags[0]=(XLEN-12)'('h40000);
      dut.u_dtlb.ptags[0]=(XLEN-10)'(PA>>12);
      dut.u_dtlb.asids[0]='0;
      dut.u_dtlb.ptes[0]=7'b1100011;
      start_lr(XLEN'('h40000000), bytes);
      finish_lr();
      check(exu_l1d.reservation == PA && exu_l1d.reservation_valid,
            "translated LR did not reserve physical address");
      event_at(XLEN'('h40000000), XLEN'('h40000000));
      tick(1);
      external_write_valid_i = 0;
      #1;
      check(exu_l1d.reservation_valid, "VA-only event incorrectly invalidated PA");
      event_at(PA, PA);
      tick(1);
      external_write_valid_i = 0;
      #1;
      check(!exu_l1d.reservation_valid, "physical event missed translated LR");
      cases++;
      boot();
      external_write_pending_i=1;
      lsu_l1d.raddr=PA;
      lsu_l1d.ralu=bytes==8 ? 5'b00011 : 5'b00010;
      lsu_l1d.atomic_lock=1;
      lsu_l1d.rvalid=1;
      repeat (4) begin
        tick(1);
        check(exu_l1d.reservation_blocked && !l1d_bus.arvalid, "pending event did not hold new LR");
      end
      external_write_pending_i = 0;
      tick(1);
      for (int n = 0; n < 20 && !l1d_bus.arvalid; n++) tick(1);
      lsu_l1d.rvalid = 0;
      check(l1d_bus.arvalid, "LR did not resume after event drain");
      cases++;
      // Finite unrelated bursts must hold a pending cold LR, then allow its
      // response to install a reservation. Later unrelated events preserve it;
      // a final overlapping event still invalidates it immediately.
      for (int burst = 1; burst <= 257; burst = burst == 1 ? 17 : burst + 240) begin
        boot();
        lsu_l1d.raddr=PA;
        lsu_l1d.ralu=bytes==8 ? 5'd3 : 5'd2;
        lsu_l1d.atomic_lock=1;
        lsu_l1d.rvalid=1;
        external_write_pending_i=1;
        event_at(PA + 64, PA + 71);
        repeat (burst) begin
          tick(1);
          check(!l1d_bus.arvalid && exu_l1d.reservation_blocked,
                "LR escaped finite pending notification burst");
        end
        external_write_valid_i = 0;
        tick(2);  // A hidden queued event still keeps pending asserted.
        check(!l1d_bus.arvalid, "LR escaped pending-only notification tail");
        external_write_pending_i = 0;
        tick(1);
        for (int n = 0; n < 20 && !l1d_bus.arvalid; n++) tick(1);
        check(l1d_bus.arvalid, "LR failed to resume after finite notification burst");
        l1d_bus.rready = 1;
        tick(1);
        l1d_bus.rready = 0;
        finish_lr();
        check(exu_l1d.reservation_valid, "post-burst LR did not install reservation");
        event_at(PA + 64, PA + 71);
        repeat (burst) begin
          tick(1);
          check(exu_l1d.reservation_valid, "unrelated burst invalidated reservation");
        end
        event_at(PA, PA + XLEN'(bytes - 1));
        check(!exu_l1d.reservation_valid, "overlap hidden by unrelated burst");
        tick(1);
        external_write_valid_i = 0;
        #1;
        check(!exu_l1d.reservation_valid && !exu_l1d.reservation_blocked,
              "post-overlap reservation/block state incorrect");
        cases++;
      end
    end
    $display("PASS: external reservation XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
  initial begin
    #60000;
    $fatal(1, "external reservation watchdog");
  end
endmodule


// ---- tb_l1d_store_contract ----
// ---- tb_l1d_store_coherence ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_store_coherence;
  localparam int XLEN = 32;
  localparam logic [31:0] TestAddr = 32'h8000_0000;
  localparam logic [31:0] ConflictAddr1 = TestAddr + 32'h0000_0400;
  localparam logic [31:0] ConflictAddr2 = TestAddr + 32'h0000_0800;
  localparam logic [31:0] ConflictAddr3 = TestAddr + 32'h0000_0c00;
  localparam int RandomOps = 2000;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_rd_pending;
  logic [31:0] bus_rd_addr;
  int bus_rd_delay;
  logic [31:0] mem_word[4][4];
  logic [31:0] expected_word[4][4];
  int bus_read_count;
  int configured_seed = 32'h1d5a_2026;
  int rng_state;
  int requested_seed;
  int random_discard;
  int random_loads;
  int random_stores;
  int random_fences;
  int configured_bus_delay_max = 63;
  int requested_bus_delay_max;
  int max_bus_read_delay;

  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();

  rapt_l1d dut (
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d),
      .rou_cmu(rou_cmu),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic read_word(input logic [31:0] addr, input logic [31:0] expected);
    begin
      @(negedge clock);
      lsu_l1d.raddr = addr;
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.rvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 512; wait_cycle++) begin
        #1;
        if (lsu_l1d.rready) begin
          check(!lsu_l1d.trap, "L1D trapped on cacheable word read");
          check(lsu_l1d.rdata == expected, $sformatf(
                "word mismatch got=%08x expected=%08x", lsu_l1d.rdata, expected));
          @(posedge clock);
          @(negedge clock);
          lsu_l1d.rvalid = 1'b0;
          tick(2);
          return;
        end
        @(negedge clock);
      end
      fail($sformatf("timed out waiting for read addr=%08x", addr));
    end
  endtask

  task automatic write_store(input logic [31:0] addr, input logic [31:0] data,
                             input logic [4:0] walu, input int settle_cycles);
    begin
      @(negedge clock);
      lsu_l1d.waddr = addr;
      lsu_l1d.walu = walu;
      lsu_l1d.wdata = data;
      lsu_l1d.wvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 64; wait_cycle++) begin
        #1;
        if (lsu_l1d.wready) begin
          @(posedge clock);
          @(negedge clock);
          lsu_l1d.wvalid = 1'b0;
          tick(settle_cycles);
          return;
        end
        @(negedge clock);
      end
      fail($sformatf("timed out waiting for write addr=%08x", addr));
    end
  endtask

  task automatic write_word(input logic [31:0] addr, input logic [31:0] data);
    write_store(addr, data, `RAPT_SW_WSTRB, 4);
  endtask

  function automatic int backing_line(input logic [31:0] addr);
    return int'(addr[11:10]);
  endfunction

  function automatic logic [31:0] merge_store(input logic [31:0] old_data,
                                              input logic [31:0] new_data, input logic [4:0] walu,
                                              input logic [1:0] byte_offset);
    logic [3:0] byte_mask;
    logic [31:0] bit_mask;
    begin
      byte_mask = walu[3:0] << byte_offset;
      for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
        bit_mask[byte_idx*8+:8] = {8{byte_mask[byte_idx]}};
      end
      return (old_data & ~bit_mask) | ((new_data << (byte_offset * 8)) & bit_mask);
    end
  endfunction

  assign l1d_bus.rready = !reset && l1d_bus.arvalid && !bus_rd_pending;

  always_ff @(posedge clock) begin : fake_memory_bus
    if (reset) begin
      mem_word[0][0] <= 32'h1122_3344;
      mem_word[0][1] <= 32'h5566_7788;
      mem_word[0][2] <= 32'h99aa_bbcc;
      mem_word[0][3] <= 32'hddee_ff00;
      mem_word[1][0] <= 32'h1111_1111;
      mem_word[2][0] <= 32'h2222_2222;
      mem_word[3][0] <= 32'h3333_3333;
      for (int line_idx = 1; line_idx < 4; line_idx++) begin
        for (int word_idx = 1; word_idx < 4; word_idx++) begin
          mem_word[line_idx][word_idx] <= '0;
        end
      end
      mem_word[1][2] <= 32'h1111_1111;
      mem_word[2][2] <= 32'h2222_2222;
      mem_word[3][2] <= 32'h3333_3333;
      bus_read_count <= 0;
      bus_rd_pending <= 1'b0;
      bus_rd_addr <= '0;
      bus_rd_delay <= 0;
      max_bus_read_delay <= 0;
      l1d_bus.rdata <= '0;
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
    end else begin
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rdata <= mem_word[backing_line(bus_rd_addr)][bus_rd_addr[3:2]];
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;

      if (bus_rd_pending && bus_rd_delay == 0) begin
        l1d_bus.rvalid <= 1'b1;
        bus_rd_pending <= 1'b0;
      end else if (bus_rd_pending) begin
        bus_rd_delay <= bus_rd_delay - 1;
      end
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        automatic int selected_bus_read_delay = $urandom_range(0, configured_bus_delay_max);
        check(l1d_bus.araddr[31:12] == TestAddr[31:12], "unexpected read address");
        bus_rd_addr <= l1d_bus.araddr;
        bus_rd_pending <= 1'b1;
        bus_rd_delay <= selected_bus_read_delay;
        if (selected_bus_read_delay > max_bus_read_delay) begin
          max_bus_read_delay <= selected_bus_read_delay;
        end
        bus_read_count <= bus_read_count + 1;
      end
      if (l1d_bus.wvalid && l1d_bus.wready) begin
        check(l1d_bus.awaddr[31:12] == TestAddr[31:12], "unexpected write address");
        for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (l1d_bus.wstrb[byte_idx] && (byte_idx + l1d_bus.awaddr[1:0]) < 4) begin
            mem_word[backing_line(l1d_bus.awaddr)][l1d_bus.awaddr[3:2]]
                [(byte_idx+l1d_bus.awaddr[1:0])*8+:8] <= l1d_bus.wdata[byte_idx*8+:8];
          end
        end
      end
    end
  end

  initial begin
    if ($value$plusargs("SEED=%d", requested_seed)) configured_seed = requested_seed;
    if ($value$plusargs("BUS_DELAY_MAX=%d", requested_bus_delay_max)) begin
      configured_bus_delay_max = requested_bus_delay_max;
    end
    rng_state = configured_seed;
    random_discard = $urandom(rng_state);
    init_l1d_inputs();
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.walu = `RAPT_SW_WSTRB;
    tick(5);
    reset = 1'b0;
    tick(2);

    read_word(TestAddr + 32'd4, 32'h5566_7788);
    read_word(TestAddr, 32'h1122_3344);
    read_word(TestAddr + 32'd8, 32'h99aa_bbcc);
    read_word(TestAddr + 32'd4, 32'h5566_7788);
    write_word(TestAddr, 32'ha5c3_5a3c);
    read_word(TestAddr, 32'ha5c3_5a3c);
    read_word(TestAddr + 32'd4, 32'h5566_7788);
    read_word(TestAddr + 32'd8, 32'h99aa_bbcc);

    // Linux SLUB regression: a full freelist-pointer update followed
    // immediately by a partial store must not merge the old bit-30 value
    // back into the cached word.
    write_word(TestAddr, 32'h84aa_4680);
    write_store(TestAddr, 32'hc4aa_4680, `RAPT_SW_WSTRB, 0);
    write_store(TestAddr, 32'h0000_0081, `RAPT_SB_WSTRB, 4);
    read_word(TestAddr, 32'hc4aa_4681);

    write_word(TestAddr, 32'h84aa_4680);
    write_store(TestAddr, 32'hc4aa_4680, `RAPT_SW_WSTRB, 0);
    write_store(TestAddr, 32'h0000_beef, `RAPT_SH_WSTRB, 4);
    read_word(TestAddr, 32'hc4aa_beef);

    // Keep a second partial store asserted while the first store's RMW owns
    // the SRAM read port. It must wait and then merge against the first result.
    write_word(TestAddr, 32'hc4aa_4680);
    write_store(TestAddr, 32'h0000_0081, `RAPT_SB_WSTRB, 0);
    write_store(TestAddr + 32'd2, 32'h0000_beef, `RAPT_SH_WSTRB, 4);
    read_word(TestAddr, 32'hbeef_4681);

    // A SLUB object's embedded next-pointer is a full word at cache->offset.
    // Force the line out through three same-set conflicts, then require the
    // pointer to be refilled from backing memory without losing bit 30.
    cmu_bcast.fence_time = 1'b1;
    tick(1);
    cmu_bcast.fence_time = 1'b0;
    tick(1);
    write_word(TestAddr + 32'd8, 32'hc4aa_4680);
    read_word(ConflictAddr1 + 32'd8, 32'h1111_1111);
    read_word(ConflictAddr2 + 32'd8, 32'h2222_2222);
    read_word(ConflictAddr3 + 32'd8, 32'h3333_3333);
    begin
      automatic int reads_before_refill = bus_read_count;
      read_word(TestAddr + 32'd8, 32'hc4aa_4680);
      check(bus_read_count > reads_before_refill,
            "SLUB pointer line was not evicted by same-set conflict pressure");
    end

    random_loads = 0;
    random_stores = 0;
    random_fences = 0;
    cmu_bcast.fence_time = 1'b1;
    tick(1);
    cmu_bcast.fence_time = 1'b0;
    tick(1);
    for (int line_idx = 0; line_idx < 4; line_idx++) begin
      for (int word_idx = 0; word_idx < 4; word_idx++) begin
        automatic
        logic [31:0]
        init_data = 32'hc000_0000 | (line_idx << 12) | (word_idx << 4) | line_idx;
        expected_word[line_idx][word_idx] = init_data;
        write_word(TestAddr + (line_idx << 10) + (word_idx << 2), init_data);
      end
    end

    for (int operation = 0; operation < RandomOps; operation++) begin
      automatic int line_idx = $urandom_range(0, 3);
      automatic int word_idx = $urandom_range(0, 3);
      automatic int op_kind = $urandom_range(0, 4);
      automatic logic [31:0] word_addr = TestAddr + (line_idx << 10) + (word_idx << 2);
      automatic logic [31:0] store_data = $urandom | 32'h4000_0000;
      automatic logic [1:0] byte_offset;
      automatic logic [4:0] store_alu;

      if (operation != 0 && (operation % 97) == 0) begin
        cmu_bcast.fence_time = 1'b1;
        tick(1);
        cmu_bcast.fence_time = 1'b0;
        tick(1);
        random_fences++;
      end

      if (op_kind == 0 || op_kind == 4) begin
        read_word(word_addr, expected_word[line_idx][word_idx]);
        random_loads++;
      end else begin
        case (op_kind)
          1: begin
            byte_offset = 2'd0;
            store_alu = `RAPT_SW_WSTRB;
          end
          2: begin
            byte_offset = $urandom_range(0, 3);
            store_alu = `RAPT_SB_WSTRB;
          end
          default: begin
            byte_offset = $urandom_range(0, 1) ? 2'd2 : 2'd0;
            store_alu = `RAPT_SH_WSTRB;
          end
        endcase
        write_store(word_addr + byte_offset, store_data, store_alu, 0);
        expected_word[line_idx][word_idx] =
            merge_store(expected_word[line_idx][word_idx], store_data, store_alu, byte_offset);
        read_word(word_addr, expected_word[line_idx][word_idx]);
        random_stores++;
      end
    end

    check(random_loads > 500, "insufficient randomized L1D load coverage");
    check(random_stores > 1000, "insufficient randomized L1D store coverage");
    check(random_fences > 10, "insufficient randomized L1D fence coverage");
    check(max_bus_read_delay >= configured_bus_delay_max - 3,
          "insufficient long-latency L1D response coverage");

    $write("PASS: L1D coherence random seed=%0d loads=%0d stores=%0d ", configured_seed,
           random_loads, random_stores);
    $display("fences=%0d max_delay=%0d", random_fences, max_bus_read_delay);
    $finish;
  end
endmodule


// ---- tb_l1d_store_pbmt ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_store_pbmt;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] Addr = 'h80000000;
  localparam logic [4:0] LoadAlu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
  logic clock = 0, reset = 1;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"
  logic [XLEN-1:0] backing;
  int read_delay, reads, writes;
  assign l1d_bus.rready = l1d_bus.arvalid && read_delay == 0;
  always_ff @(posedge clock) begin
    if (reset) begin
      backing <= 'h11223344;
      reads <= 0;
      writes <= 0;
      read_delay <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.rdata <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        reads <= reads + 1;
        read_delay <= 3;
      end else if (read_delay > 0) begin
        read_delay <= read_delay - 1;
        if (read_delay == 1) begin
          l1d_bus.rdata <= backing;
          l1d_bus.rvalid <= 1;
        end
      end
      if (l1d_bus.wvalid && l1d_bus.wready) begin
        writes <= writes + 1;
        for (int b = 0; b < XLEN / 8; b++)
        if (l1d_bus.wstrb[b]) backing[b*8+:8] <= l1d_bus.wdata[b*8+:8];
      end
    end
  end
  task automatic read_value(input logic [XLEN-1:0] value);
    lsu_l1d.raddr = Addr;
    lsu_l1d.ralu = LoadAlu;
    lsu_l1d.rvalid = 1;
    for (int cycle = 0; cycle < 200; cycle++) begin
      #1;
      if (lsu_l1d.rready) begin
        check(!lsu_l1d.trap && lsu_l1d.rdata == value, "backing-memory read mismatch");
        tick(1);
        lsu_l1d.rvalid = 0;
        tick(4);
        return;
      end
      tick(1);
    end
    fail("read timeout");
  endtask
  initial begin
    for (int attr = 1; attr <= 2; attr++) begin
      for (int hot = 0; hot < 2; hot++) begin
        for (int partial = 0; partial < 2; partial++) begin
          reset = 1;
          init_l1d_inputs();
          tick(4);
          reset = 0;
          tick(3);
          if (hot != 0) read_value('h11223344);
          lsu_l1d.waddr = Addr;
          lsu_l1d.wpbmt = 2'(attr);
          lsu_l1d.walu = partial != 0 ? 8'h1 : (XLEN == 64 ? 8'hff : 8'h0f);
          lsu_l1d.wdata = 'h55667788;
          lsu_l1d.wvalid = 1;
          #1;
          check(lsu_l1d.wready && l1d_bus.wvalid, "typed store failed write-through");
          tick(1);
          lsu_l1d.wvalid = 0;
          for (int c = 0; c < 4; c++) begin
            check(!dut.l1d_update && !dut.l1d_rmw, "NC/IO store allocated or updated cache");
            tick(1);
          end
          check(writes == 1, "typed store did not reach backing memory exactly once");
          if (hot != 0) begin
            // Software performs cache maintenance before changing alias type.
            cmu_bcast.fence_time = 1;
            tick(1);
            cmu_bcast.fence_time = 0;
            tick(100);
          end
          begin
            automatic int before_reads = reads;
            read_value(partial != 0 ? 'h11223388 : 'h55667788);
            check(reads > before_reads, "typed write was incorrectly cached");
          end
        end
      end
    end
    $display("PASS: NC/IO full/partial writes bypass cold/hot L1D and preserve backing data");
    $finish;
  end
endmodule


// ---- tb_l1d_tags ----
`include "rapt.svh"

module tb_l1d_tags;
  logic clock = 1'b0;
  logic [5:0] done = '0;
  always #5 clock = ~clock;

  for (genvar way_idx = 0; way_idx < 3; way_idx++) begin : g_ways
    for (genvar line_idx = 0; line_idx < 2; line_idx++) begin : g_line
      localparam int Ways = 1 << way_idx;
      localparam int WayBits = Ways > 1 ? $clog2(Ways) : 1;
      localparam int WordBits = line_idx == 0 ? 1 : 3;
      localparam int Words = 1 << WordBits;
      localparam int CaseId = way_idx * 2 + line_idx;
      logic reset = 1'b1;
      logic [3:0] clear_set = '0;
      logic [1:0] addr_idx = '0, waddr_idx = '0, probe_idx = '0, l1d_idx = '0;
      logic [WordBits-1:0] addr_offset = '0, waddr_offset = '0;
      logic [WordBits-1:0] probe_offset = '0, l1d_off = '0;
      logic [1:0] addr_tag = '0, waddr_tag = '0, probe_tag = '0, l1d_tag_u = '0;
      logic load_hit = 1'b0, load_replace = 1'b0, store_replace = 1'b0;
      logic l1d_update = 1'b0, l1d_valid_u = 1'b0, l1d_inv_all_ways = 1'b0;
      logic [WayBits-1:0] l1d_way = '0;
      wire [Ways-1:0] load_way_hit, probe_way_hit;
      wire hit_w;
      wire [WayBits-1:0] store_hit_way, store_fill_way, ld_fill_way;
      logic [Words-1:0] valid_model[Ways][4];
      logic [1:0] tag_model[Ways][4];
      logic [63:0] rng = 64'hcafe0123456789ab ^ 64'(CaseId);

      rapt_l1d_tags #(
          .L1D_LEN(2),
          .L1D_LINE_LEN(WordBits),
          .L1D_N_WAYS(Ways),
          .L1dTagW(2)
      ) dut (
          .fence_time(|clear_set),
          .*
      );

      // Behavioral reference preserves the original whole-array update order.
      task automatic update_model;
        if (reset) begin
          foreach (valid_model[w, s]) valid_model[w][s] = '0;
        end else begin
          if (!(|clear_set) && l1d_update) begin
            if (l1d_valid_u) begin
              if (tag_model[l1d_way][l1d_idx] == l1d_tag_u)
                valid_model[l1d_way][l1d_idx][l1d_off] = 1'b1;
              else valid_model[l1d_way][l1d_idx] = Words'(1) << l1d_off;
              tag_model[l1d_way][l1d_idx] = l1d_tag_u;
              for (int w = 0; w < Ways; w++)
              if (w != int'(l1d_way) && tag_model[w][l1d_idx] == l1d_tag_u)
                valid_model[w][l1d_idx] = '0;
            end else if (l1d_inv_all_ways) begin
              for (int w = 0; w < Ways; w++) valid_model[w][l1d_idx][l1d_off] = 1'b0;
            end else valid_model[l1d_way][l1d_idx][l1d_off] = 1'b0;
          end
          foreach (valid_model[w, s]) if (clear_set[s]) valid_model[w][s] = '0;
        end
      endtask

      task automatic check_lookup;
        logic [Ways-1:0] load_expected, store_expected, probe_expected;
        logic [WayBits-1:0] store_way_expected;
        store_way_expected = '0;
        for (int w = Ways - 1; w >= 0; w--) begin
          load_expected[w] = valid_model[w][addr_idx][addr_offset]
                             && tag_model[w][addr_idx] == addr_tag;
          store_expected[w] = valid_model[w][waddr_idx][waddr_offset]
                              && tag_model[w][waddr_idx] == waddr_tag;
          probe_expected[w] = valid_model[w][probe_idx][probe_offset]
                              && tag_model[w][probe_idx] == probe_tag;
          if (store_expected[w]) store_way_expected = WayBits'(w);
        end
        if (load_way_hit !== load_expected || probe_way_hit !== probe_expected
            || hit_w !== (|store_expected) || store_hit_way !== store_way_expected)
          $fatal(1, "case %0d: tag lookup/reference mismatch", CaseId);
        if (int'(store_fill_way) >= Ways || int'(ld_fill_way) >= Ways)
          $fatal(1, "case %0d: invalid fill way", CaseId);
      endtask

      initial begin
        @(posedge clock);
        update_model();
        #1;
        check_lookup();
        for (int cycle_idx = 0; cycle_idx < 4000; cycle_idx++) begin
          @(negedge clock);
          rng ^= rng << 13;
          rng ^= rng >> 7;
          rng ^= rng << 17;
          reset = cycle_idx % 127 == 0;
          clear_set = cycle_idx % 17 == 0 ? rng[3:0] : 4'b0;
          l1d_update = rng[4];
          l1d_valid_u = rng[5];
          l1d_inv_all_ways = rng[6];
          l1d_way = WayBits'(int'(rng[8:7]) % Ways);
          l1d_idx = rng[10:9];
          l1d_off = WordBits'(rng[13:11]);
          l1d_tag_u = rng[15:14];
          addr_idx = rng[17:16];
          addr_offset = WordBits'(rng[20:18]);
          addr_tag = rng[22:21];
          waddr_idx = rng[24:23];
          waddr_offset = WordBits'(rng[27:25]);
          waddr_tag = rng[29:28];
          probe_idx = rng[31:30];
          probe_offset = WordBits'(rng[34:32]);
          probe_tag = rng[36:35];
          load_hit = rng[37];
          load_replace = rng[38];
          store_replace = rng[39];
          // Observe before and after the edge: lookup must not gain latency.
          #1;
          check_lookup();
          @(posedge clock);
          update_model();
          #1;
          check_lookup();
        end
        done[CaseId] = 1'b1;
      end
    end
  end

  initial begin
    wait (&done);
    $display("PASS: L1D tags: 6 geometries, 4000 reference-checked cycles each");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "L1D tags timeout");
  end
endmodule


// ---- tb_l1d_trap_owner ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_trap_owner;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] VA = 'h40000120;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic accept_walk;
    for (int n = 0; n < 50 && !l1d_bus.arvalid; n++) tick(1);
    check(l1d_bus.arvalid && l1d_bus.ar_ptw, "expected page-table request");
    l1d_bus.rready = 1;
    tick(1);
    l1d_bus.rready = 0;
  endtask

  task automatic run_case(input bit store_fault, input bit same_address);
    logic [XLEN-1:0] other_va, expected_pa;
    other_va=VA+(same_address ? XLEN'(0) : XLEN'('h2000));
    expected_pa=other_va+XLEN'('h40000000);
    reset=1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b=0;
    l1d_bus.rready=0;
    tick(3);
    reset = 0;
    tick(1);
    pmp_update.addr_we=1;
    pmp_update.raw_addr='1;
    pmp_update.napot_mask='1;
    pmp_update.cfg_we[0]=1;
    pmp_update.mode_off[0]=0;
    pmp_update.mode_napot[0]=1;
    pmp_update.cfg_r[0]=1;
    pmp_update.cfg_w[0]=1;
    pmp_update.cfg_x[0]=1;
    tick(1);
    pmp_update.addr_we=0;
    pmp_update.cfg_we=0;
    csr_bcast.priv=`RAPT_PRIV_S;
    csr_bcast.dmmu_en=1;
    csr_bcast.satp_ppn='h80001;
    lsu_l1d.raddr=store_fault ? other_va : VA;
    lsu_l1d.ralu=`RAPT_ALU_LW__;
    exu_l1d.vaddr=store_fault ? VA : other_va;
    exu_l1d.mmu_en=1;
    exu_l1d.walu=`RAPT_SW_WSTRB;
    lsu_l1d.rvalid=!store_fault;
    exu_l1d.valid=store_fault;
    accept_walk();
    // The other port arrives after this walk has acquired its owner.
    // An invalid root PTE faults only the original request.
    lsu_l1d.rvalid=1;
    exu_l1d.valid=1;
    l1d_bus.rdata='0;
    l1d_bus.ptw_rvalid=1;
    tick(1);
    l1d_bus.ptw_rvalid = 0;
    for (int n = 0; n < 10 && !(store_fault ? exu_l1d.trap : lsu_l1d.trap); n++) tick(1);
    #1;
    if (store_fault) begin
      check(exu_l1d.ready && exu_l1d.trap && exu_l1d.cause == 15, "store lost its page fault");
      check(!lsu_l1d.rready && !lsu_l1d.trap, "store fault completed unrelated load");
      exu_l1d.valid = 0;
    end else begin
      check(lsu_l1d.rready && lsu_l1d.trap && lsu_l1d.cause == 13, "load lost its page fault");
      check(!exu_l1d.ready && !exu_l1d.trap, "load fault completed unrelated store translation");
      lsu_l1d.rvalid = 0;
    end
    tick(1);
    // Without reset or flush, the waiting request must obtain its own PA.
    accept_walk();
    l1d_bus.rdata=XLEN'('h200000cf);
    l1d_bus.ptw_rvalid=1;
    tick(1);
    l1d_bus.ptw_rvalid = 0;
    if (store_fault) begin
      for (int n = 0; n < 50 && !l1d_bus.arvalid; n++) tick(1);
      check(l1d_bus.arvalid && !l1d_bus.ar_ptw && l1d_bus.araddr == expected_pa,
            "waiting load did not obtain its own translation");
      l1d_bus.rready = 1;
      tick(1);
      l1d_bus.rready=0;
      l1d_bus.rdata=XLEN'('h12345678);
      l1d_bus.rvalid=1;
      #1;
      check(lsu_l1d.rready && !lsu_l1d.trap && lsu_l1d.rdata == 'h12345678,
            "waiting load failed after other port's trap");
      tick(1);
      l1d_bus.rvalid=0;
      lsu_l1d.rvalid=0;
    end else begin
      for (int n = 0; n < 10 && !exu_l1d.ready; n++) tick(1);
      check(exu_l1d.ready && !exu_l1d.trap && exu_l1d.paddr == expected_pa,
            "waiting store captured stale translation");
      exu_l1d.valid = 0;
    end
    tick(3);
  endtask

  initial begin
    for (int store_fault = 0; store_fault < 2; store_fault++)
    for (int same_address = 0; same_address < 2; same_address++)
    run_case(1'(store_fault), 1'(same_address));
    $display("PASS: L1D trap ownership, concurrent ports and fresh translation XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_l1d_write_error ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_write_error;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] Addr = 'h80000000, Before = 'h11223344, After = 'h66778899;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  rapt_l1d dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic memory_read(input logic [XLEN-1:0] value);
    lsu_l1d.raddr=Addr;
    lsu_l1d.ralu=`RAPT_ALU_LW__;
    lsu_l1d.rvalid=1;
    for (int n = 0; n < 40; n++) begin
      #1;
      check(!lsu_l1d.rready, "failed store left a cached copy");
      if (l1d_bus.arvalid) break;
      tick(1);
    end
    check(l1d_bus.arvalid && l1d_bus.araddr == Addr, "read miss did not issue");
    l1d_bus.rready = 1;
    tick(1);
    l1d_bus.rready=0;
    l1d_bus.rdata=value;
    l1d_bus.rvalid=1;
    #1;
    check(lsu_l1d.rready && !lsu_l1d.trap && lsu_l1d.rdata == value, "refill returned wrong data");
    tick(1);
    l1d_bus.rvalid=0;
    lsu_l1d.rvalid=0;
    tick(3);
  endtask

  initial begin
    for (int attr = 0; attr < 3; attr++)
    for (int hot = 0; hot < 2; hot++)
    for (int partial = 0; partial < 2; partial++) begin
      reset = 1;
      init_l1d_inputs();
      lsu_l1d.rvalid_b=0;
      l1d_bus.rready=0;
      l1d_bus.wready=0;
      tick(3);
      reset = 0;
      tick(3);
      if (hot) memory_read(Before);
      lsu_l1d.waddr=Addr;
      lsu_l1d.wdata='hdeadbeef;
      lsu_l1d.wpbmt=2'(attr);
      lsu_l1d.walu=partial ? 8'h01 : (XLEN==64 ? 8'hff : 8'h0f);
      lsu_l1d.wvalid=1;
      // Error without B completion must not consume or mutate the write.
      l1d_bus.werr=1;
      tick(3);
      check(!lsu_l1d.wready && !lsu_l1d.werr && !dut.l1d_rmw, "stray write error consumed");
      l1d_bus.wready = 1;
      #1;
      check(lsu_l1d.wready && lsu_l1d.werr, "write failure was not exposed to SQ");
      tick(1);
      lsu_l1d.wvalid=0;
      l1d_bus.wready=0;
      l1d_bus.werr=0;
      tick(3);
      // Slave may have partially modified memory before returning error.
      // Neither the pre-write value nor intended write value is trustworthy.
      memory_read(After);
      check(!lsu_l1d.trap && !exu_l1d.trap, "posted store error became a young load/store trap");
    end
    $display("PASS: failed writes expose error and invalidate hot/cold PMA/NC/IO copies");
    $finish;
  end
endmodule
