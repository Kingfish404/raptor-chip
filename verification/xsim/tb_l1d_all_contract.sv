`include "tb_l1d_unused_release_ports.svh"

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

  rapt_l1d #(
      .LineRefill(0)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d),
      .reset(reset),
      .coherent_request(1'b0),
      .coherent_write(1'b0),
      .coherent_addr('0),
      .probe_valid_i(1'b0),
      .probe_addr_i('0),
      .probe_release_ready_i(1'b0),
      .release_ready_i(1'b0),
      .release_ack_i(1'b0),
      .probe_window_i(1'b0),
      .writeback_drain(1'b0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0)
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
  function automatic int tlb_slot(input logic [`RAPT_XLEN-1:0] vpn);
    return `RAPT_DTLB_WAYS == 0 ? 0
        : int'(vpn) % (`RAPT_DTLB_ENTRIES / (`RAPT_DTLB_WAYS == 0 ? 1 : `RAPT_DTLB_WAYS));
  endfunction
  localparam int XLEN = 64;
  localparam logic [63:0] Vaddr = 64'h0000_0000_4000_0123;
  logic [63:0] Paddr = 64'h0000_0000_8000_0123;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic coherent_request = 1'b0;
  logic coherent_write = 1'b0;
  logic coherent_ready;
  logic writeback_error;
  logic writeback_idle;
  logic writeback_drain = 1'b0;
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
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      `TB_L1D_UNUSED_RELEASE_PORTS,
      .writeback_cbo_done(),
      .coherent_addr('0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
      .*
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic install_store_tlb(input logic [6:0] pte);
    begin
      dut.u_dtlb.valid[tlb_slot(Vaddr >> 12)] = 1'b1;
      dut.u_dtlb.vtags[tlb_slot(Vaddr >> 12)] = $bits(dut.u_dtlb.vtags[0])'(Vaddr >> 12);
      dut.u_dtlb.ptags[tlb_slot(Vaddr >> 12)] = $bits(dut.u_dtlb.ptags[0])'(Paddr >> 12);
      dut.u_dtlb.asids[tlb_slot(Vaddr >> 12)] = '0;
      dut.u_dtlb.ptes[tlb_slot(Vaddr >> 12)] = pte;
      dut.u_dtlb.verdicts[tlb_slot(Vaddr >> 12)] = '0;
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
      check(!exu_l1d.ready, {name, " bypassed registered translation"});
      tick(1);
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

    // An older store translation must not wait for a load's stalled bus AR.
    Paddr = 64'h80000123;
    install_store_tlb(7'b110_0011);
    csr_bcast.dmmu_en = 0;
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = 'h80002000;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    l1d_bus.rready = 0;
    tick(1);
    check(l1d_bus.arvalid, "load did not hold a pending bus request");
    csr_bcast.dmmu_en = 1;
    expect_cmo_success("CMO concurrent with stalled load");
    check(l1d_bus.arvalid && !lsu_l1d.rready, "translation disturbed stalled load");
    cmu_bcast.flush_pipe = 1;
    lsu_l1d.rvalid = 0;
    tick(1);
    cmu_bcast.flush_pipe = 0;

    // Cancel both before capture and while a translated response is pending.
    for (int after_capture = 0; after_capture < 2; after_capture++) begin
      exu_l1d.vaddr = Vaddr;
      exu_l1d.walu = `RAPT_CBO_MGMT_WALU;
      exu_l1d.cmo_mgmt = 1;
      exu_l1d.mmu_en = 1;
      exu_l1d.valid = 1;
      if (after_capture != 0) tick(1);
      cmu_bcast.flush_pipe = 1;
      #1;
      check(!exu_l1d.ready && !l1d_bus.awvalid, "flushed translation completed a store");
      tick(1);
      exu_l1d.valid = 0;
      exu_l1d.mmu_en = 0;
      cmu_bcast.flush_pipe = 0;
      #1;
      check(!dut.store_check_valid && !exu_l1d.ready, "cancelled response survived flush");
      tick(1);
    end
    expect_cmo_success("CMO retry after response cancellation");

    // A response no longer depends on its CAM entry, nor may an eviction
    // start a duplicate walk for the request completing on this edge.
    exu_l1d.vaddr = Vaddr;
    exu_l1d.walu = `RAPT_CBO_MGMT_WALU;
    exu_l1d.cmo_mgmt = 1;
    exu_l1d.mmu_en = 1;
    exu_l1d.valid = 1;
    tick(1);
    dut.u_dtlb.valid = '0;
    #1;
    check(exu_l1d.ready && !exu_l1d.trap && exu_l1d.paddr == Paddr,
          "TLB eviction changed the captured response");
    check(!dut.ptw_req, "completed translation started a duplicate walk");
    tick(1);
    exu_l1d.valid = 0;
    exu_l1d.mmu_en = 0;
    tick(1);

    $display("PASS: Zicbom R-or-W, A-only PTE permission and store-fault semantics");
    $finish;
  end
endmodule

// diagonal SRAM scoreboard, including partial groups and port conflicts.

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

  rapt_l1d #(
      .LineRefill(0)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d),
      .reset(reset),
      .coherent_request(1'b0),
      .coherent_write(1'b0),
      .coherent_addr('0),
      .probe_valid_i(1'b0),
      .probe_addr_i('0),
      .probe_release_ready_i(1'b0),
      .release_ready_i(1'b0),
      .release_ack_i(1'b0),
      .probe_window_i(1'b0),
      .writeback_drain(1'b0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0)
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
    for (int c = 0; c < 20 && !lsu_l1d.rretry; c++) tick(1);
    check(lsu_l1d.rretry && !lsu_l1d.rready && !l1d_bus.arvalid,
          "unordered MMIO did not retry without completion or bus side effect");
    tick(1);
    lsu_l1d.rvalid = 0;
    tick(1);
    begin_load(MmioAddr, 1'b1);
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
  // The first PTW read returns a 1 GiB leaf for VA[38:30] == 1. RAM maps to
  // the gigapage at 0x80000000; the device case uses the gigapage at 0 and
  // offsets VA into the UART/peripheral window at 0x10000000.
  localparam logic [63:0] RamVa = 64'h40000000;
  localparam logic [63:0] DeviceVa = 64'h50000000;
  logic [63:0] va;
  logic clock = 0, reset = 1;
  `include "tb_l1d_harness.svh"
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
    physical_page = device ? 64'h00000000 : 64'h80000000;
    va = device ? DeviceVa : RamVa;
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
      lsu_l1d.raddr = va;
      lsu_l1d.ralu = `RAPT_ALU_LD__;
      lsu_l1d.rmisaligned = misaligned;
      lsu_l1d.ordered = 1;
      lsu_l1d.rvalid = !store;
      exu_l1d.vaddr = va;
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
  rapt_l1d #(
      .LineRefill(0)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
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
      .probe_valid_i(1'b0),
      .probe_addr_i('0),
      .probe_ready_o(),
      .probe_release_valid_o(),
      .probe_release_addr_o(),
      .probe_release_data_o(),
      .probe_release_ready_i(1'b0),
      .release_valid_o(),
      .release_addr_o(),
      .release_data_o(),
      .release_has_data_o(),
      .release_mask_o(),
      .release_last_o(),
      .release_ready_i(1'b0),
      .release_ack_i(1'b0),
      .probe_window_i(1'b0),
      .writeback_bus_pending_o(),
      .writeback_cbo_done(),
      .coherent_addr('0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
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
        response_data <= l1d_bus.ar_ptw ? ((PA >> 2) | 64'hcf | (64'(pte_pbmt) << 61)) : data_value;
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
    for (int c = 0; c < 100 && !lsu_l1d.rretry; c++) tick(1);
    check(lsu_l1d.rretry, "typed unordered request did not release ownership");
    check(ptw_reads == before_ptw + 1, "test did not perform one real page walk");
    check(data_reads == before_data && !l1d_bus.arvalid && !lsu_l1d.rready,
          "unretired typed request accessed memory or hit a cached alias");
    // A deferred request has no data-side effect. Its TLB payload retains
    // the original type even if the backing PTE changes before replay.
    pte_pbmt = 2'(3 - attr);
    if (cancel) begin
      cmu_bcast.flush_pipe = 1;
      tick(1);
      lsu_l1d.rvalid = 0;
      cmu_bcast.flush_pipe = 0;
      tick(5);
      check(data_reads == before_data, "cancelled IO request caused a data read");
      return;
    end
    tick(1);
    lsu_l1d.rvalid = 0;
    tick(1);
    lsu_l1d.ordered = 1;
    lsu_l1d.rvalid = 1;
    for (int c = 0; c < 20 && !l1d_bus.arvalid; c++) tick(1);
    // Change the live enable only after the replay captured translation.
    csr_bcast.menvcfg_pbmte = 0;
    for (int c = 0; c < 5; c++) begin
      #1;
      check(
          l1d_bus.arvalid && !l1d_bus.ar_ptw && l1d_bus.rpbmt == 2'(attr)
            && l1d_bus.araddr == PA && l1d_bus.rstrb == (byte_load ? 8'h01 : 8'hff),
          "held request lost PBMT, PA or access size");
      l1d_bus.arlen = 0;
      l1d_bus.noallocate = 0;
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

`include "rapt.svh"
`include "rapt_if.svh"

// ---- tb_l1d_page_permissions ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_page_permissions;
  localparam int XLEN = `RAPT_XLEN;
  csr_bcast_if csr_bcast ();
  rapt_pkg::mem_context_t check_context;
  assign check_context = '{
          mmu_en: csr_bcast.dmmu_en,
          eff_priv:
          (
          csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv
          ) ?
          csr_bcast.mpp
          :
          csr_bcast.priv,
          sum: csr_bcast.sum,
          mxr: csr_bcast.mxr,
          pbmte: csr_bcast.menvcfg_pbmte,
          asid: csr_bcast.satp_asid,
          version: 8'd0
      };
  pmp_state_if pmp_state ();
  logic tlb_hit, stlb_hit;
  logic [6:0] dtlb_pte, dstlb_pte, ptw_result_pte;
  logic pf_load_tlb, pf_store_tlb, pf_load_ptw, pf_store_ptw;
  rapt_l1d_access #(
      .XLEN(XLEN)
  ) dut (
      .load_context(check_context),
      .store_context(check_context),
      .ptw_context(check_context),
      .pmp_state(pmp_state),
      .load_addr(XLEN'('h80000000)),
      .store_addr(XLEN'('h80000000)),
      .ptw_addr(XLEN'('h80001000)),
      .ptw_check_active(1'b0),
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

`include "rapt.svh"
`include "rapt_if.svh"

`include "rapt.svh"
`include "rapt_if.svh"

// ---- tb_l1d_pma ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_pma;
  function automatic int tlb_slot(input logic [`RAPT_XLEN-1:0] vpn);
    return `RAPT_DTLB_WAYS == 0 ? 0
        : int'(vpn) % (`RAPT_DTLB_ENTRIES / (`RAPT_DTLB_WAYS == 0 ? 1 : `RAPT_DTLB_WAYS));
  endfunction
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  `include "tb_l1d_harness.svh"
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
      // Observe the PMP flush before manually installing a test translation.
      tick(1);
      if (sram_path) pa = region == 0 ? XLEN'('h0f002000) : XLEN'('h0f00f000);
      else
        pa = region == 0 ? XLEN'('h02000000) : region == 1 ? XLEN'('h20001000) : XLEN'('h30001000);
      va=translated ? XLEN'('h40000000) : pa;
      csr_bcast.dmmu_en=1'(translated);
      if (translated) begin
        csr_bcast.priv=`RAPT_PRIV_S;
        dut.u_dtlb.valid[tlb_slot(va>>12)]=1;
        dut.u_dtlb.vtags[tlb_slot(va>>12)]=$bits(dut.u_dtlb.vtags[tlb_slot(va>>12)])'(va>>12);
        dut.u_dtlb.ptags[tlb_slot(va>>12)]=$bits(dut.u_dtlb.ptags[tlb_slot(va>>12)])'(pa>>12);
        dut.u_dtlb.asids[tlb_slot(va>>12)]='0;
        dut.u_dtlb.ptes[tlb_slot(va>>12)]=7'b1100011;
        dut.u_dtlb.verdicts[tlb_slot(va>>12)] = '0;

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
  // This manual AXI harness carries the same captured-request context as
  // the common L1D harness; the architectural CSR source is not the request.
  assign lsu_l1d.rcontext = '{
          mmu_en: csr_bcast.dmmu_en,
          eff_priv:
          (
          csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv
          ) ?
          csr_bcast.mpp
          :
          csr_bcast.priv,
          sum: csr_bcast.sum,
          mxr: csr_bcast.mxr,
          pbmte: csr_bcast.menvcfg_pbmte,
          asid: csr_bcast.satp_asid,
          version: 8'd0
      };
  assign lsu_l1d.rcontext_b = lsu_l1d.rcontext;
  assign exu_l1d.mem_context = lsu_l1d.rcontext;
  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) mem ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) axi ();
  rapt_l1d #(
      .LineRefill(0)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
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
      .writeback_cbo_done(),
      .coherent_addr('0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
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
      .mem,
      .coherent_ready(1'b1)
  );
  rapt_axi_master #(
      .XLEN(XLEN),
      .ID_W(4)
  ) adapter (
      .clock,
      .reset,
      .mem,
      .axi,
      .rd_req_cacheable(1'b0)
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
    lsu_l1d.wzero = 0;
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
    rou_cmu.cbo_inval = 0;
    rou_cmu.cbo_block = '0;
    rou_cmu.flush_pipe=0;
    l1i_bus.arvalid=0;
    l1i_bus.araddr=0;
    l1i_bus.arburst=0;
    l1i_bus.ar_ptw=0;
    l1i_bus.rpbmt=0;
    l1i_bus.noallocate = 0;
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
    check(dut.u_dtlb.valid == 0, "AXI error polluted TLB");
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
      for (int n = 0; n < 20 && !exu_l1d.ready; n++) tick(1);
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

`include "rapt.svh"
`include "rapt_if.svh"

// ---- tb_l1d_ptw_pma ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_ptw_pma;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  `include "tb_l1d_harness.svh"
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
  function automatic int tlb_slot(input logic [`RAPT_XLEN-1:0] vpn);
    return `RAPT_DTLB_WAYS == 0 ? 0
        : int'(vpn) % (`RAPT_DTLB_ENTRIES / (`RAPT_DTLB_WAYS == 0 ? 1 : `RAPT_DTLB_WAYS));
  endfunction
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] PA = 'h80000000, VA = 'h40000000;
  localparam logic [XLEN-1:0] Good = 'h12345678, Bad = 'hdeadbeef;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  `include "tb_l1d_harness.svh"
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
    // Observe the PMP flush before manually installing a test translation.
    tick(1);
    if (attr != 0) begin
      csr_bcast.priv=`RAPT_PRIV_S;
      csr_bcast.dmmu_en=1;
      csr_bcast.menvcfg_pbmte=1;
      dut.u_dtlb.valid[tlb_slot(VA>>12)]=1;
      dut.u_dtlb.vtags[tlb_slot(VA>>12)]=$bits(dut.u_dtlb.vtags[tlb_slot(VA>>12)])'(VA>>12);
      dut.u_dtlb.ptags[tlb_slot(VA>>12)]=$bits(dut.u_dtlb.ptags[tlb_slot(VA>>12)])'(PA>>12);
      dut.u_dtlb.asids[tlb_slot(VA>>12)]=0;
      dut.u_dtlb.ptes[tlb_slot(VA>>12)]=7'b1100011;
      dut.u_dtlb.pbmts[tlb_slot(VA>>12)]=2'(attr);
      dut.u_dtlb.verdicts[tlb_slot(VA>>12)] = '0;
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

`include "rapt.svh"

// ---- tb_l1d_reservation_external ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_reservation_external;
  function automatic int tlb_slot(input logic [`RAPT_XLEN-1:0] vpn);
    return `RAPT_DTLB_WAYS == 0 ? 0
        : int'(vpn) % (`RAPT_DTLB_ENTRIES / (`RAPT_DTLB_WAYS == 0 ? 1 : `RAPT_DTLB_WAYS));
  endfunction
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
  rapt_l1d #(
      .LineRefill(0)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .coherent_request(1'b0),
      .coherent_write(1'b0),
      .coherent_ready(),
      .writeback_error(),
      .writeback_idle(),
      .writeback_drain(1'b0),
      `TB_L1D_UNUSED_RELEASE_PORTS,
      .writeback_cbo_done(),
      .coherent_addr('0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
      .*
  );
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
      // Observe the PMP flush before manually installing a test translation.
      tick(1);
      csr_bcast.dmmu_en=1;
      csr_bcast.priv=`RAPT_PRIV_S;
      dut.u_dtlb.valid[tlb_slot('h40000)]=1;
      dut.u_dtlb.vtags[tlb_slot('h40000)]=$bits(dut.u_dtlb.vtags[tlb_slot('h40000)])'('h40000);
      dut.u_dtlb.ptags[tlb_slot('h40000)]=$bits(dut.u_dtlb.ptags[tlb_slot('h40000)])'(PA>>12);
      dut.u_dtlb.asids[tlb_slot('h40000)]='0;
      dut.u_dtlb.ptes[tlb_slot('h40000)]=7'b1100011;
      dut.u_dtlb.verdicts[tlb_slot('h40000)] = '0;
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

module tb_l1d_store_coherence #(
    parameter bit WriteBack = 1'b0,
    parameter bit TargetedCoherence = `RAPT_L1D_TARGETED_COHERENCE,
    parameter bit LineRefill = 1'b0
);
  // public probe inputs for writeback/load handoff coverage.
  logic probe_valid = 0;
  logic [`RAPT_XLEN-1:0] probe_addr = '0;
  logic coherent_request = 0, coherent_write = 0;
  logic coherent_ready, writeback_error, writeback_idle;
  logic writeback_drain = 0;
  logic writeback_cbo = 0, writeback_cbo_invalidate = 0, writeback_cbo_done;
  logic [`RAPT_XLEN-1:6] writeback_block = '0;
  function automatic int tlb_slot(input logic [`RAPT_XLEN-1:0] vpn);
    return `RAPT_DTLB_WAYS == 0 ? 0
        : int'(vpn) % (`RAPT_DTLB_ENTRIES / (`RAPT_DTLB_WAYS == 0 ? 1 : `RAPT_DTLB_WAYS));
  endfunction
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [31:0] TestAddr = 32'h8000_0000;
  logic [XLEN-1:0] coherent_addr = XLEN'(TestAddr);
  localparam int ConflictShift = `RAPT_L1D_LEN + `RAPT_L1D_LINE_LEN + $clog2(XLEN / 8);
  localparam int ConflictLines = `RAPT_L1D_N_WAYS + 2;
  localparam int RandomOps = 2000;
  localparam int LineWords = (1 << `RAPT_L1D_LINE_LEN) * (XLEN / 32);
  // Keep distinct cache sets physically distinct in the backing model. The
  // dense-store scenarios reach beyond one 16-byte line in a 16-byte-line preset.
  localparam int BackingWords = (1 << ConflictShift) / 4;
  logic bus_write_pending = 0, bus_write_enable = 1;
  bit merge_stress = 0;
  int merge_fires = 0, merge_allocs = 0;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_rd_pending;
  logic [31:0] bus_rd_addr;
  logic bus_rd_mshr;
  logic [1:0] bus_rd_mshr_id;
  int bus_rd_remaining;
  int bus_rd_delay;
  logic [31:0] mem_word[ConflictLines][BackingWords];
  logic [31:0] expected_word[ConflictLines][4];
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
  int random_max_bus_read_delay;

  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  l1d_bus_if l1d_bus ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();

  rapt_l1d #(
      .WriteBack(WriteBack),
      .TargetedCoherence(TargetedCoherence),
      .LineRefill(LineRefill)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      // exercise a probe while an A load is held.
      .probe_valid_i(probe_valid),
      .probe_addr_i(probe_addr),
      .probe_release_ready_i(1'b1),
      .coherent_request(coherent_request),
      .coherent_addr(coherent_addr),
      .coherent_write(coherent_write),
      .coherent_ready(coherent_ready),
      .writeback_error(writeback_error),
      .writeback_idle(writeback_idle),
      .writeback_drain(writeback_drain),
      .writeback_cbo(writeback_cbo),
      .writeback_cbo_invalidate(writeback_cbo_invalidate),
      .writeback_block(writeback_block),
      .writeback_cbo_done(writeback_cbo_done),
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d),
      .reset(reset),
      .release_ready_i(1'b0),
      .release_ack_i(1'b0),
      .probe_window_i(1'b0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `define TB_L1D_WRITE_RESPONSE_MODEL
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_WRITE_RESPONSE_MODEL

  task automatic read_word(input logic [31:0] addr, input logic [31:0] expected);
    begin
      @(negedge clock);
      lsu_l1d.raddr = addr;
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.rvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < (merge_stress ? 16384 : 512); wait_cycle++) begin
        #1;
        if (lsu_l1d.rready) begin
          check(!lsu_l1d.trap, "L1D trapped on cacheable word read");
          check(lsu_l1d.rdata[(int'(addr[2:0])&(XLEN/8-1))*8+:32] == expected, $sformatf(
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
                             input logic [7:0] walu, input int settle_cycles);
    bit masked_hit;
    begin
      masked_hit = 0;
      @(negedge clock);
      lsu_l1d.waddr = addr;
      lsu_l1d.walu = walu;
      lsu_l1d.wzero = 0;
      lsu_l1d.wdata = data;
      lsu_l1d.wvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < (WriteBack ? 4096 : 64); wait_cycle++) begin
        #1;
        if (dut.store_accept) begin
          masked_hit = dut.hit_w && dut.cacheable_w && !dut.store_error
              && !dut.wb_hold && !dut.probe_valid_i && !dut.line_clearing
              && !(|dut.fence_clear_set);
        end
        if (lsu_l1d.wready) begin
          if (masked_hit) begin
            check(dut.l1d_update && dut.l1d_valid_u && !dut.l1d_inv_all_ways,
                  "store acknowledgement did not accompany its masked update");
            check(dut.l1d_strobe_u == (walu[XLEN/8-1:0] << (addr % (XLEN / 8))),
                  "store hit byte enables do not match the address lanes");
          end
          @(posedge clock);
          @(negedge clock);
          lsu_l1d.wvalid = 1'b0;
          tick(settle_cycles);
          return;
        end
        @(negedge clock);
      end
      fail($sformatf(
           "timed out waiting for write addr=%08x state=%0d wb_state=%0d dirty=%b busy=%b valid=%b hold=%b local=%b bus_idle=%b bus_wready=%b",
           addr,
           dut.l1d_state,
           dut.wb_state,
           dut.dirty_any,
           dut.wb_busy,
           dut.wb_valid,
           dut.wb_hold,
           dut.local_store,
           l1d_bus.idle,
           l1d_bus.wready
           ));
    end
  endtask

  // a probe can hold a same-set hit in another way until WB exits.
  task automatic probe_load_resume(input bit same_set, input int word_index);
    logic [31:0] load_addr;
    int idle_cycles;
    bit saw_idle;
    load_addr = TestAddr + (same_set ? (1 << ConflictShift) : LineWords * 4);
    for (int word_idx = 0; word_idx < LineWords; word_idx += XLEN / 32) begin
      write_store(TestAddr + word_idx * 4, XLEN'(32'h1090 + word_idx), {XLEN / 8{1'b1}}, 0);
      write_store(load_addr + word_idx * 4, XLEN'(32'h2050 + word_idx), {XLEN / 8{1'b1}}, 0);
    end
    tick(3);
    @(negedge clock);
    lsu_l1d.raddr = XLEN'(load_addr + word_index * (XLEN / 8));
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = 1;
    @(posedge clock);
    @(negedge clock);
    check(dut.l1d_state == 1, "probe/load handoff did not enter LD_A");
    probe_addr = XLEN'(TestAddr);
    probe_valid = 1;
    #1;
    check(!lsu_l1d.rready, "probe did not hold the A response");
    idle_cycles = 0;
    saw_idle = 0;
    for (int n = 0; n < 512; n++) begin
      @(negedge clock);
      #1;
      if (dut.wb_state == 0) begin
        if (saw_idle) idle_cycles++;
        saw_idle = 1;
      end
      if (lsu_l1d.rready) begin
        check(!lsu_l1d.trap && lsu_l1d.rdata[31:0] == 32'h2050 + word_index * (XLEN / 32),
              "held A consumed a victim line chunk after writeback");
        check(saw_idle && idle_cycles == (same_set ? 0 : 1),
              "writeback handoff changed the original load response cycle");
        $display("PASS: WB resume XLEN=%0d same_set=%0d word=%0d idle_cycles=%0d", XLEN, same_set,
                 word_index, idle_cycles);
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.rvalid = 0;
        probe_valid = 0;
        tick(3);
        return;
      end
    end
    fail("probe/load handoff timed out");
  endtask

  task automatic write_word(input logic [31:0] addr, input logic [31:0] data);
    write_store(addr, data, `RAPT_SW_WSTRB, 4);
  endtask

  task automatic store_check_drain_policy;
    check(dut.dirty_any && dut.wb_state == 3'd0,
          "bare store-check test needs an idle dirty write-back cache");
    @(negedge clock);
    exu_l1d.valid = 1'b1;
    exu_l1d.mmu_en = 1'b0;
    #1;
    check(!dut.wb_global_request && !dut.wb_hold,
          "bare store address check requested a global dirty-line drain");
    tick(2);
    check(dut.wb_state == 3'd0 && dut.dirty_any,
          "bare store address check started a write-back scan");
    exu_l1d.vaddr = XLEN'(TestAddr);
    exu_l1d.mem_context.asid = '0;
    dut.u_dtlb.valid[tlb_slot(TestAddr >> 12)] = 1'b1;
    dut.u_dtlb.vtags[tlb_slot(TestAddr >> 12)] = $bits(dut.u_dtlb.vtags[0])'(TestAddr >> 12);
    dut.u_dtlb.asids[tlb_slot(TestAddr >> 12)] = '0;
    dut.u_dtlb.ptes[tlb_slot(TestAddr >> 12)] = 7'b1100011;
    dut.u_dtlb.verdicts[tlb_slot(TestAddr >> 12)] = '0;
    exu_l1d.mmu_en = 1'b1;
    #1;
    check(dut.stlb_hit && !dut.wb_global_request && !dut.wb_hold,
          "hot store TLB lookup requested a global dirty-line drain");
    dut.u_dtlb.valid[tlb_slot(TestAddr>>12)] = 1'b0;
    #1;
    check(!dut.wb_global_request && !dut.wb_hold,
          "store TLB miss drained before an actual PTE read");
    exu_l1d.valid = 1'b0;
    exu_l1d.mmu_en = 1'b0;
    lsu_l1d.raddr = XLEN'(TestAddr);
    csr_bcast.dmmu_en = 1'b1;
    dut.u_dtlb.valid[tlb_slot(TestAddr >> 12)] = 1'b1;
    dut.u_dtlb.vtags[tlb_slot(TestAddr >> 12)] = $bits(dut.u_dtlb.vtags[0])'(TestAddr >> 12);
    dut.u_dtlb.asids[tlb_slot(TestAddr >> 12)] = '0;
    dut.u_dtlb.ptes[tlb_slot(TestAddr >> 12)] = 7'b1100011;
    dut.u_dtlb.verdicts[tlb_slot(TestAddr >> 12)] = '0;
    lsu_l1d.rvalid = 1'b1;
    #1;
    check(dut.tlb_hit && !dut.wb_global_request && !dut.wb_hold,
          "hot load TLB lookup requested a global dirty-line drain");
    dut.u_dtlb.valid[tlb_slot(TestAddr>>12)] = 1'b0;
    #1;
    check(!dut.wb_global_request && !dut.wb_hold, $sformatf(
          "load TLB miss drained before PTE read state=%0d hit=%b miss=%b req=%b hold=%b dirty=%b",
          dut.l1d_state,
          dut.tlb_hit,
          dut.load_tlb_miss,
          dut.wb_global_request,
          dut.wb_hold,
          dut.dirty_any
          ));
    lsu_l1d.rvalid = 1'b0;
    csr_bcast.dmmu_en = 1'b0;
  endtask

  task automatic concurrent_partial_store(input logic [4:0] store_mask,
                                          input logic [31:0] expected);
    for (int wait_cycle = 0; wait_cycle < 4096; wait_cycle++) begin
      if (lsu_l1d.idle && writeback_idle) break;
      tick(1);
    end
    check(lsu_l1d.idle && writeback_idle, "concurrent test did not reach idle");
    @(negedge clock);
    lsu_l1d.raddr = TestAddr;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = 1;
    lsu_l1d.waddr = TestAddr;
    lsu_l1d.walu = store_mask;
    lsu_l1d.wdata = 32'h7654_abcd;
    lsu_l1d.wvalid = 1;
    #1;
    check(!lsu_l1d.wready, "local store bypassed its response register");
    tick(1);
    check(lsu_l1d.wready && !l1d_bus.wvalid, "concurrent partial store was not accepted locally");
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    for (int wait_cycle = 0; wait_cycle < 4096; wait_cycle++) begin
      #1;
      if (lsu_l1d.rready) begin
        check(!lsu_l1d.trap && lsu_l1d.rdata[31:0] == expected,
              "concurrent load lost locally accepted partial store");
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.rvalid = 0;
        tick(2);
        check(!writeback_idle && dut.dirty_any, "dirty hit unexpectedly drained cache");
        tick(512);
        check(!writeback_idle && dut.dirty_any && !l1d_bus.wvalid,
              "idle cache unexpectedly started background writeback");
        writeback_drain = 1;
        for (int drain_cycle = 0; drain_cycle < 4096; drain_cycle++) begin
          if (writeback_idle) break;
          tick(1);
        end
        check(writeback_idle, "explicit writeback drain timed out");
        writeback_drain = 0;
        check(mem_word[0][0] == expected, "concurrent partial store not written back");
        return;
      end
      @(negedge clock);
    end
    fail("concurrent partial store/load timed out");
  endtask

  // Cold-cache scenarios use explicit block maintenance. Translation fences
  // intentionally retain data now, including dirty ownership during stress.
  task automatic invalidate_backed_lines;
    for (int wait_cycle = 0; wait_cycle < 4096 && !lsu_l1d.idle; wait_cycle++) tick(1);
    check(lsu_l1d.idle, "cache setup has an unfinished refill");
    for (int line_idx = 0; line_idx < ConflictLines; line_idx++) begin
      @(negedge clock);
      writeback_block = (XLEN-6)'((XLEN'(TestAddr) + (XLEN'(line_idx) << ConflictShift)) >> 6);
      writeback_cbo = 1;
      writeback_cbo_invalidate = 1;
      for (int wait_cycle = 0; wait_cycle < 4096 && !writeback_cbo_done; wait_cycle++) tick(1);
      check(writeback_cbo_done, "cold-cache setup block maintenance timed out");
      @(negedge clock);
      writeback_cbo = 0;
      writeback_cbo_invalidate = 0;
      cmu_bcast.cbo_block = writeback_block;
      cmu_bcast.cbo_inval = 1;
      tick(1);
      cmu_bcast.cbo_inval = 0;
      tick(1);
    end
  endtask

  task automatic targeted_writeback_error(input bit store_miss, input bit inject_error,
                                          input bit partial_miss = 0);
    logic [XLEN-1:0] held_addr, held_data;
    logic [31:0] original_word[`RAPT_L1D_N_WAYS];
    bit store_done = 0;
    @(negedge clock);
    reset = 1;
    init_l1d_inputs();
    coherent_request = 0;
    coherent_write = 0;
    writeback_drain = 0;
    tick(5);
    reset = 0;
    tick(2);
    for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
      original_word[line_idx] = mem_word[line_idx][0];
      read_word(TestAddr + (line_idx << ConflictShift), original_word[line_idx]);
    end
    for (int wait_cycle = 0; wait_cycle < 4096 && !lsu_l1d.idle; wait_cycle++) tick(1);
    check(lsu_l1d.idle, "target error setup refill did not finish");
    for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
      write_word(TestAddr + (line_idx << ConflictShift), ~original_word[line_idx]);
    end
    @(negedge clock);
    bus_write_enable = 0;
    if (partial_miss) begin
      lsu_l1d.waddr = TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift);
      lsu_l1d.walu = 8'h01;
      lsu_l1d.wdata = 8'hab;
      lsu_l1d.wvalid = 1;
      #1;
      if (dut.MergeStores) begin
        // Answered without any write; its bytes wait for the refill to install.
        for (int n = 0; n < 64 && !lsu_l1d.wready; n++) begin
          check(!l1d_bus.wvalid, "partial miss reached the bus");
          tick(1);
        end
        check(lsu_l1d.wready && !lsu_l1d.werr, "partial miss was not answered by its MSHR");
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.wvalid = 0;
        bus_write_enable = 1;
        begin
          automatic logic [31:0] merged = mem_word[`RAPT_L1D_N_WAYS][0];
          merged[7:0] = 8'hab;
          read_word(TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift), merged);
        end
        for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
          if (mem_word[line_idx][0] == original_word[line_idx])
            read_word(TestAddr + (line_idx << ConflictShift), ~original_word[line_idx]);
        end
        $display("PASS: partial miss joins its refill error=%0d XLEN=%0d", inject_error, XLEN);
        return;
      end
      check(l1d_bus.wvalid && l1d_bus.awaddr == lsu_l1d.waddr && !dut.wb_busy,
            "partial miss drained unrelated dirty data");
      l1d_bus.werr = inject_error;
      bus_write_enable = 1;
      #1;
      check(!lsu_l1d.wready, "partial miss bypassed its response register");
      for (int n = 0; n < 16 && !l1d_bus.wready; n++) tick(1);
      check(l1d_bus.wready, "partial miss did not acquire a response owner");
      tick(1);
      check(lsu_l1d.wready && lsu_l1d.werr == inject_error,
            "partial miss response did not reach LSU");
      @(posedge clock);
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      l1d_bus.werr = 0;
      tick(4);
      check(dut.dirty_any && !writeback_error, "partial miss lost dirty ownership");
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        check(mem_word[line_idx][0] == original_word[line_idx],
              "partial miss wrote unrelated dirty data back");
        read_word(TestAddr + (line_idx << ConflictShift), ~original_word[line_idx]);
      end
      check(
          mem_word[`RAPT_L1D_N_WAYS][0][7:0]
        == (inject_error ? 8'(32'h1111_1111 * `RAPT_L1D_N_WAYS) : 8'hab),
          "partial miss backing data mismatch");
      $display("PASS: partial miss dirty isolation error=%0d XLEN=%0d", inject_error, XLEN);
      return;
    end
    if (store_miss) begin
      lsu_l1d.waddr = TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift);
      lsu_l1d.walu = 8'({XLEN / 8{1'b1}});
      lsu_l1d.wdata = '1;
      lsu_l1d.wvalid = 1;
    end else begin
      lsu_l1d.raddr = TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift);
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.rvalid = 1;
    end
    for (int wait_cycle = 0; wait_cycle < 4096 && !l1d_bus.wvalid; wait_cycle++) tick(1);
    check(l1d_bus.wvalid && dut.wb_targeted, "miss did not start targeted writeback");
    held_addr = l1d_bus.awaddr;
    held_data = l1d_bus.wdata;
    repeat (32) begin
      tick(1);
      check(l1d_bus.wvalid && l1d_bus.awaddr == held_addr && l1d_bus.wdata == held_data,
            "targeted writeback payload changed under backpressure");
      // Its dirty victim has left the array, so a store now owns the way.
      if (store_miss && dut.MergeStores && lsu_l1d.wready && !store_done) begin
        store_done = 1;
        tick(1);
        lsu_l1d.wvalid = 0;
      end
      check(!lsu_l1d.rready && (store_done || !lsu_l1d.wready) && !l1d_bus.arvalid,
            "miss escaped before targeted writeback response");
    end
    @(negedge clock);
    if (!inject_error) begin
      coherent_addr = XLEN'(TestAddr + ((`RAPT_L1D_N_WAYS - 1) << ConflictShift));
      coherent_request = 1;
      tick(2);
      check(!coherent_ready, "coherence escaped blocked targeted writeback");
      @(negedge clock);
      bus_write_enable = 1;
      for (int wait_cycle = 0; wait_cycle < 4096 && !coherent_ready; wait_cycle++) tick(1);
      check(coherent_ready && !writeback_error,
            "targeted coherence did not complete after the queued victim");
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        if (!TargetedCoherence || XLEN'(TestAddr + (line_idx << ConflictShift)) == coherent_addr
            || XLEN'(TestAddr + (line_idx << ConflictShift)) == held_addr)
          check(mem_word[line_idx][0] == ~original_word[line_idx],
                "coherence released before its target or queued victim reached memory");
        else
          check(mem_word[line_idx][0] == original_word[line_idx],
                "targeted coherence published unrelated dirty data");
      end
      @(negedge clock);
      coherent_request = 0;
      if (store_miss) begin
        if (!store_done) begin
          tick(1);
          check(lsu_l1d.wready, "store did not resume after coherence drain");
          @(posedge clock);
          @(negedge clock);
          lsu_l1d.wvalid = 0;
        end
        tick(4);
        read_word(TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift), '1);
      end else begin
        lsu_l1d.rvalid = 0;
        read_word(TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift), mem_word[`RAPT_L1D_N_WAYS][0]);
      end
      $display("PASS: targeted coherence upgrade store_miss=%0d XLEN=%0d", store_miss, XLEN);
      return;
    end
    l1d_bus.werr = 1;
    bus_write_enable = 1;
    tick(1);
    @(negedge clock);
    l1d_bus.werr = 0;
    repeat (64) begin
      tick(1);
      check(
          writeback_error && dut.wb_busy && !writeback_idle
            && dut.wb_addr == held_addr && dut.wb_data == held_data,
          "targeted error lost dirty ownership");
      check(!l1d_bus.wvalid && !l1d_bus.arvalid && !lsu_l1d.rready && !lsu_l1d.wready,
            "targeted error retried or completed the blocked miss");
    end
    for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
      check(mem_word[line_idx][0] == original_word[line_idx],
            "failed targeted writeback changed memory");
    end
    $display("PASS: targeted writeback fail-stop store_miss=%0d XLEN=%0d", store_miss, XLEN);
  endtask

  function automatic int backing_line(input logic [31:0] addr);
    return int'((addr - TestAddr) >> ConflictShift);
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
  // Flushes land at any cycle; the bench's held loads simply replay.
  always @(negedge clock) begin
    if (merge_stress) begin
      bus_write_enable = $urandom_range(0, 3) != 0;
      cmu_bcast.flush_pipe = $urandom_range(0, 255) == 0;
    end
  end
  always @(posedge clock) begin
    if (dut.store_mshr_fire) begin
      merge_fires++;
      if (!dut.store_mshr_match) merge_allocs++;
    end
  end
  // Model a bus without posting: acquire an owner before returning B.
  // A nonposted response on the request's first edge is impossible in
  // rapt_bus and can precede a pending refill's final tag installation.
  assign l1d_bus.wready = bus_write_enable && bus_write_pending;
  assign l1d_bus.idle = !bus_write_pending;
  always_ff @(posedge clock) begin
    if (reset) bus_write_pending <= 0;
    else if (l1d_bus.wready) bus_write_pending <= 0;
    else if (l1d_bus.awvalid && l1d_bus.wvalid) bus_write_pending <= 1;
  end

  always_ff @(posedge clock) begin : fake_memory_bus
    if (reset) begin
      for (int line_idx = 0; line_idx < ConflictLines; line_idx++) begin
        for (int word_idx = 0; word_idx < BackingWords; word_idx++) begin
          mem_word[line_idx][word_idx] <= 32'h1111_1111 * line_idx;
        end
      end
      mem_word[0][0] <= 32'h1122_3344;
      mem_word[0][1] <= 32'h5566_7788;
      mem_word[0][2] <= 32'h99aa_bbcc;
      mem_word[0][3] <= 32'hddee_ff00;
      for (int line_idx = 1; line_idx < ConflictLines; line_idx++) begin
        for (int word_idx = 0; word_idx < 4; word_idx++) begin
          mem_word[line_idx][word_idx] <= 32'h1111_1111 * line_idx;
        end
      end
      bus_read_count <= 0;
      bus_rd_pending <= 1'b0;
      bus_rd_addr <= '0;
      bus_rd_mshr <= 1'b0;
      bus_rd_mshr_id <= '0;
      bus_rd_remaining <= 0;
      bus_rd_delay <= 0;
      max_bus_read_delay <= 0;
      l1d_bus.rdata <= '0;
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
    end else begin
      l1d_bus.rvalid <= 1'b0;
      for (int lane = 0; lane < XLEN / 32; lane++) begin
        l1d_bus.rdata[lane*32+:32] <= mem_word[
            backing_line(bus_rd_addr)][((int'(bus_rd_addr>>2)%BackingWords)&~(XLEN/32-1))+lane];
      end
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;

      if (bus_rd_pending && bus_rd_delay == 0) begin
        l1d_bus.rvalid <= 1'b1;
        l1d_bus.r_mshr <= bus_rd_mshr;
        l1d_bus.r_mshr_id <= bus_rd_mshr_id;
        l1d_bus.rlast <= bus_rd_remaining == 0;
        bus_rd_pending <= bus_rd_remaining != 0;
        if (bus_rd_remaining != 0) begin
          bus_rd_remaining <= bus_rd_remaining - 1;
          bus_rd_addr <= bus_rd_addr + XLEN / 8;
        end
      end else if (bus_rd_pending) begin
        bus_rd_delay <= bus_rd_delay - 1;
      end
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        automatic int selected_bus_read_delay = $urandom_range(0, configured_bus_delay_max);
        check(l1d_bus.araddr >= TestAddr && backing_line(l1d_bus.araddr) < ConflictLines,
              "unexpected read address");
        bus_rd_addr <= l1d_bus.araddr;
        bus_rd_mshr <= l1d_bus.ar_mshr;
        bus_rd_mshr_id <= l1d_bus.ar_mshr_id;
        bus_rd_remaining <= int'(l1d_bus.arlen);
        bus_rd_pending <= 1'b1;
        bus_rd_delay <= selected_bus_read_delay;
        if (selected_bus_read_delay > max_bus_read_delay) begin
          max_bus_read_delay <= selected_bus_read_delay;
        end
        bus_read_count <= bus_read_count + 1;
      end
      if (l1d_bus.wvalid && l1d_bus.wready && !l1d_bus.werr) begin
        check(l1d_bus.awaddr >= TestAddr && backing_line(l1d_bus.awaddr) < ConflictLines,
              "unexpected write address");
        for (int byte_idx = 0; byte_idx < XLEN / 8; byte_idx++) begin
          if (l1d_bus.wstrb[byte_idx]) begin
            mem_word[backing_line(l1d_bus.awaddr)][(int'(l1d_bus.awaddr%(BackingWords*4))+byte_idx)/
                                                   4][((int'(l1d_bus.awaddr[1:0])+byte_idx)%4)*8+:8]
                <= l1d_bus.wdata[byte_idx*8+:8];
          end
        end
      end
    end
  end

  initial begin
    string trace_file;
    if ($test$plusargs("TRACE_WB_B")) begin
      if (!$value$plusargs("WAVE_FILE=%s", trace_file)) trace_file = "/tmp/raptor-l1d-wb-bscan.vcd";
      $dumpfile(trace_file);
      $dumpvars(0, tb_l1d_store_coherence);
    end
    if ($value$plusargs("SEED=%d", requested_seed)) configured_seed = requested_seed;
    if ($value$plusargs("BUS_DELAY_MAX=%d", requested_bus_delay_max)) begin
      configured_bus_delay_max = requested_bus_delay_max;
    end
    rng_state = configured_seed;
    random_discard = $urandom(rng_state);
    init_l1d_inputs();
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.walu = `RAPT_SW_WSTRB;
    lsu_l1d.wzero = 0;
    tick(5);
    reset = 1'b0;
    tick(2);

    // cover each SRAM chunk and the unchanged different-set bubble.
    if ($test$plusargs("MIN_WB_RESUME")) begin
      check(WriteBack && `RAPT_L1D_N_WAYS >= 2, "WB resume needs at least two writeback ways");
      for (int word_idx = 0; word_idx < (1 << `RAPT_L1D_LINE_LEN); word_idx++) begin
        probe_load_resume(1, word_idx);
        probe_load_resume(0, word_idx);
      end
      $display("PASS: probe/writeback load handoff all chunks");
      $finish;
    end

    if ($test$plusargs("MIN_REFILL_STORE")) begin
      logic [31:0] last_word_addr;
      last_word_addr = TestAddr + 4 * (LineWords - 1);
      check(WriteBack && LineRefill, "refill/store race requires WB line refills");
      @(negedge clock);
      lsu_l1d.raddr = XLEN'(TestAddr);
      lsu_l1d.rvalid = 1;
      for (int n = 0; n < 512; n++) begin
        #1;
        if (l1d_bus.rvalid && l1d_bus.rlast) break;
        @(negedge clock);
      end
      check(l1d_bus.rvalid && l1d_bus.rlast, "refill did not reach final beat");
      @(posedge clock);
      @(negedge clock);
      lsu_l1d.rvalid = 0;
      check(dut.l1d_update && dut.l1d_state == 0, "final refill installation window was missed");
      lsu_l1d.waddr = XLEN'(last_word_addr);
      lsu_l1d.wdata = 'h6f;
      lsu_l1d.walu = `RAPT_SB_WSTRB;
      lsu_l1d.wvalid = 1;
      #1;
      // The final beat is not yet visible to hit_w. Offering the store now
      // would send a hit as write-through; its B response could then be
      // unable to update the resident copy, leaving a stale clean word.
      check(!dut.hit_w && !l1d_bus.wvalid, "store offered before final tag installation");
      for (int n = 0; n < 32 && !lsu_l1d.wready; n++) begin
        check(!l1d_bus.wvalid, "refill-adjacent hit store went to the bus");
        tick(1);
      end
      check(lsu_l1d.wready, "refill-adjacent store did not complete");
      @(posedge clock);
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      tick(2);
      read_word(last_word_addr, LineWords == 4 ? 32'hddee_ff6f : 32'h0000_006f);
      writeback_drain = 1'b1;
      for (int n = 0; n < 4096 && !writeback_idle; n++) tick(1);
      check(writeback_idle, "refill-adjacent store writeback timed out");
      writeback_drain = 1'b0;
      check(mem_word[0][LineWords-1][7:0] == 8'h6f, "store did not reach backing memory");
      $display("PASS: final refill beat followed by byte store XLEN=%0d", XLEN);
      $finish;
    end

    if ($test$plusargs("MIN_WB_B")) begin
      check(WriteBack && XLEN == 64, "minimal writeback B payload requires RV64 WB");
      write_store(TestAddr + 16, 32'd9, 8'hff, 0);
      write_store(TestAddr + 64 + 16, 32'd5, 8'hff, 0);
      write_store(TestAddr + 128 + 16, 32'd3, 8'hff, 0);
      tick(2);
      writeback_drain = 1'b1;
      for (int scan_cycle = 0; scan_cycle < 4096; scan_cycle++) begin
        @(negedge clock);
        if (dut.wb_state == 3'd1 && dut.wb_set == 1) break;
      end
      check(dut.wb_state == 3'd1 && dut.wb_set == 1,
            "minimal payload did not reach writeback scan of set 1");
      lsu_l1d.raddr_b = TestAddr + 16;
      lsu_l1d.ralu_b = `RAPT_ALU_LW__;
      lsu_l1d.rvalid_b = 1'b1;
      @(posedge clock);
      @(negedge clock);
      #1;
      check(!lsu_l1d.rready_b, "minimal payload: B load consumed writeback-owned SRAM data");
      lsu_l1d.rvalid_b = 1'b0;
      for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
      check(writeback_idle, "minimal payload: writeback drain timed out");
      writeback_drain = 1'b0;
      @(negedge clock);
      lsu_l1d.rvalid_b = 1'b1;
      for (int b_cycle = 0; b_cycle < 16; b_cycle++) begin
        #1;
        if (lsu_l1d.rready_b) begin
          check(lsu_l1d.rdata_b[31:0] == 32'd9,
                "minimal payload: B load returned wrong value after writeback");
          break;
        end
        @(negedge clock);
      end
      check(lsu_l1d.rready_b, "minimal payload: B load did not recover after writeback");
      @(posedge clock);
      @(negedge clock);
      lsu_l1d.rvalid_b = 1'b0;
      $display("PASS: minimal writeback B contention XLEN=%0d", XLEN);
      $finish;
    end

    read_word(TestAddr + 32'd4, 32'h5566_7788);
    read_word(TestAddr, 32'h1122_3344);
    read_word(TestAddr + 32'd8, 32'h99aa_bbcc);
    read_word(TestAddr + 32'd4, 32'h5566_7788);
    write_word(TestAddr, 32'ha5c3_5a3c);
    if (WriteBack) store_check_drain_policy();
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

    // Consecutive partial stores must preserve both writes in the same word.
    write_word(TestAddr, 32'hc4aa_4680);
    write_store(TestAddr, 32'h0000_0081, `RAPT_SB_WSTRB, 0);
    write_store(TestAddr + 32'd2, 32'h0000_beef, `RAPT_SH_WSTRB, 4);
    read_word(TestAddr, 32'hbeef_4681);

    // A SLUB object's embedded next-pointer is a full word at cache->offset.
    // Force the line out through more than Ways same-set conflicts, then require the
    // pointer to be refilled from backing memory without losing bit 30.
    cmu_bcast.fence_time = 1'b1;
    tick(1);
    cmu_bcast.fence_time = 1'b0;
    tick(1);
    write_word(TestAddr + 32'd8, 32'hc4aa_4680);
    for (int line_idx = 1; line_idx < ConflictLines; line_idx++)
    read_word(TestAddr + (line_idx << ConflictShift) + 32'd8, 32'h1111_1111 * line_idx);
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
    for (int line_idx = 0; line_idx < ConflictLines; line_idx++) begin
      for (int word_idx = 0; word_idx < 4; word_idx++) begin
        automatic
        logic [31:0]
        init_data = 32'hc000_0000 | (line_idx << 12) | (word_idx << 4) | line_idx;
        expected_word[line_idx][word_idx] = init_data;
        write_word(TestAddr + (line_idx << ConflictShift) + (word_idx << 2), init_data);
      end
    end

    // Stress the store-miss path: replayable loads, flushes between operations,
    // a stalling write channel, and memory compared word by word after drains.
    merge_stress = $test$plusargs("STORE_MERGE_STRESS");
    lsu_l1d.replay_allowed = merge_stress;
    for (int operation = 0; operation < RandomOps; operation++) begin
      automatic int line_idx = $urandom_range(0, ConflictLines - 1);
      automatic int word_idx = $urandom_range(0, 3);
      automatic int op_kind = $urandom_range(0, 4);
      automatic logic [31:0] word_addr = TestAddr + (line_idx << ConflictShift) + (word_idx << 2);
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
      if (merge_stress && (operation % 23) == 22) begin
        // A block operation and a coherent read both follow any store bytes
        // still in a refill buffer: the target's memory must be current after.
        automatic logic [31:0] line_addr = TestAddr + (line_idx << ConflictShift);
        if ($urandom_range(0, 1) == 0) begin
          @(negedge clock);
          writeback_block = (XLEN'(line_addr) >> 6);
          writeback_cbo_invalidate = $urandom_range(0, 1) == 0;
          writeback_cbo = 1'b1;
          for (int n = 0; n < 8192 && !writeback_cbo_done; n++) tick(1);
          check(writeback_cbo_done, "stress block operation timed out");
          for (int n = 0; n < 8192 && !writeback_idle && dut.wb_busy; n++) tick(1);
          @(negedge clock);
          writeback_cbo = 1'b0;
          writeback_cbo_invalidate = 1'b0;
        end else begin
          @(negedge clock);
          coherent_addr = XLEN'(line_addr);
          coherent_request = 1'b1;
          for (int n = 0; n < 8192 && !coherent_ready; n++) tick(1);
          check(coherent_ready, "stress coherent read timed out");
          @(negedge clock);
          coherent_request = 1'b0;
        end
        for (int n = 0; n < 8192 && dut.wb_busy; n++) tick(1);
        for (int word = 0; word < 4; word++) begin
          check(mem_word[line_idx][word] == expected_word[line_idx][word], $sformatf(
                "operation left line=%0d word=%0d mem=%08x expected=%08x",
                line_idx,
                word,
                mem_word[line_idx][word],
                expected_word[line_idx][word]
                ));
        end
      end
      if (merge_stress && (operation % 61) == 60) begin
        writeback_drain = 1'b1;
        for (int n = 0; n < 8192 && !writeback_idle; n++) tick(1);
        check(writeback_idle, "stress drain timed out");
        writeback_drain = 1'b0;
        for (int line = 0; line < ConflictLines; line++) begin
          for (int word = 0; word < 4; word++) begin
            check(mem_word[line][word] == expected_word[line][word], $sformatf(
                  "drain left line=%0d word=%0d mem=%08x expected=%08x",
                  line,
                  word,
                  mem_word[line][word],
                  expected_word[line][word]
                  ));
          end
        end
      end

      if (op_kind == 0 || op_kind == 4) begin
        read_word(word_addr, expected_word[line_idx][word_idx]);
        random_loads++;
      end else begin
        // A full XLEN store allocates in place without a read. In RV64 the
        // bench's word and byte stores cannot reach that path otherwise.
        if (merge_stress && XLEN == 64 && op_kind == 1 && $urandom_range(0, 1) == 0) begin
          automatic int base = word_idx & ~1;
          automatic logic [63:0] wide = {$urandom | 32'h4000_0000, store_data};
          write_store(TestAddr + (line_idx << ConflictShift) + (base << 2), 32'(wide), 8'hff, 0);
          // write_store drives only the low word of its 32-bit data argument.
          expected_word[line_idx][base] = 32'(wide);
          expected_word[line_idx][base+1] = 32'b0;
          random_stores++;
          continue;
        end
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
        // Under stress, later stores can join the refill this one started.
        if (!merge_stress || $urandom_range(0, 1) == 0)
          read_word(word_addr, expected_word[line_idx][word_idx]);
        random_stores++;
      end
    end

    if (merge_stress) begin
      lsu_l1d.replay_allowed = 1'b0;
      merge_stress = 0;
      cmu_bcast.flush_pipe = 1'b0;
      bus_write_enable = 1'b1;
      writeback_drain = 1'b1;
      for (int n = 0; n < 8192 && !writeback_idle; n++) tick(1);
      check(writeback_idle, "final stress drain timed out");
      for (int line = 0; line < ConflictLines; line++) begin
        for (int word = 0; word < 4; word++) begin
          check(mem_word[line][word] == expected_word[line][word], "final drain lost a store");
        end
      end
      if (dut.MergeStores) check(merge_fires > 100, "stress did not exercise store merging");
      $display("PASS: L1D merge stress seed=%0d fires=%0d allocs=%0d", configured_seed,
               merge_fires, merge_allocs);
      $finish;
    end
    check(random_loads > 500, "insufficient randomized L1D load coverage");
    check(random_stores > 1000, "insufficient randomized L1D store coverage");
    check(random_fences > 10, "insufficient randomized L1D fence coverage");
    random_max_bus_read_delay = max_bus_read_delay;
    check(max_bus_read_delay >= configured_bus_delay_max - 3,
          "insufficient long-latency L1D response coverage");

    if (WriteBack) begin
      int written_lines;
      logic [31:0] original_word[`RAPT_L1D_N_WAYS];
      writeback_drain = 1;
      for (int drain_cycle = 0; drain_cycle < 4096; drain_cycle++) begin
        if (writeback_idle) break;
        tick(1);
      end
      check(writeback_idle, "initial writeback drain timed out");
      writeback_drain = 0;
      invalidate_backed_lines();
      tick(512);
      if (LineRefill) begin
        @(negedge clock);
        lsu_l1d.raddr = TestAddr;
        lsu_l1d.ralu = `RAPT_ALU_LW__;
        lsu_l1d.rvalid = 1;
        for (int wait_cycle = 0; wait_cycle < 512; wait_cycle++) begin
          #1;
          if (l1d_bus.arvalid) break;
          @(negedge clock);
        end
        check(l1d_bus.arvalid, "overlap load did not reach refill request");
        lsu_l1d.waddr = TestAddr;
        lsu_l1d.walu = 8'({XLEN / 8{1'b1}});
        lsu_l1d.wdata = XLEN'({expected_word[0][1], expected_word[0][0]});
        lsu_l1d.wvalid = 1;
        for (int wait_cycle = 0; wait_cycle < 4096; wait_cycle++) begin
          #1;
          check(!lsu_l1d.wready, "overlap store completed before load");
          if (lsu_l1d.rready) break;
          @(negedge clock);
        end
        check(lsu_l1d.rready && !lsu_l1d.trap, "local store blocked refill");
        check(lsu_l1d.rdata[31:0] == expected_word[0][0], "overlap load data mismatch");
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.rvalid = 0;
        for (int wait_cycle = 0; wait_cycle < 4096; wait_cycle++) begin
          #1;
          if (lsu_l1d.wready) break;
          @(negedge clock);
        end
        check(lsu_l1d.wready && !l1d_bus.wvalid, "overlap store did not complete locally");
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.wvalid = 0;
        tick(4);
        read_word(TestAddr, expected_word[0][0]);
        writeback_drain = 1;
        for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
        check(writeback_idle, "overlap cleanup drain timed out");
        writeback_drain = 0;
        invalidate_backed_lines();
        tick(512);
        $display("PASS: local store overlaps pending line refill XLEN=%0d", XLEN);
      end
      @(negedge clock);
      lsu_l1d.waddr = TestAddr;
      lsu_l1d.walu = 8'({XLEN / 8{1'b1}});
      lsu_l1d.wdata = XLEN'(64'h7654_3210_abcd_1234);
      lsu_l1d.wvalid = 1;
      #1;
      check(!lsu_l1d.wready, "cold store bypassed its response register");
      tick(1);
      check(lsu_l1d.wready && !l1d_bus.wvalid, "cold full-word store was not allocated locally");
      @(posedge clock);
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      tick(4);
      check(mem_word[0][0] == expected_word[0][0], "cold full-word store wrote through");
      expected_word[0][0] = 32'habcd_1234;
      if (XLEN == 64) expected_word[0][1] = 32'h7654_3210;
      read_word(TestAddr, expected_word[0][0]);
      if (XLEN == 64) read_word(TestAddr + 4, expected_word[0][1]);
      begin
        logic [31:0] backing_before;
        backing_before = mem_word[0][0];
        read_word(TestAddr + XLEN / 8, expected_word[0][XLEN/32]);
        if (!LineRefill) begin
          check(dut.dirty_any && !writeback_idle && mem_word[0][0] == backing_before,
                "same-tag word refill unnecessarily drained dirty data");
        end
        read_word(TestAddr, expected_word[0][0]);
      end
      writeback_drain = 1;
      for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
      check(writeback_idle && mem_word[0][0] == expected_word[0][0],
            "cold allocation drain lost low word");
      if (XLEN == 64)
        check(mem_word[0][1] == expected_word[0][1], "cold allocation drain lost high word");
      writeback_drain = 0;
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        read_word(TestAddr + (line_idx << ConflictShift), expected_word[line_idx][0]);
      end
      for (int wait_cycle = 0; wait_cycle < 4096 && !lsu_l1d.idle; wait_cycle++) tick(1);
      check(lsu_l1d.idle, "victim setup refill did not finish");
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        original_word[line_idx] = mem_word[line_idx][0];
        expected_word[line_idx][0] = ~original_word[line_idx];
        write_word(TestAddr + (line_idx << ConflictShift), expected_word[line_idx][0]);
        check(mem_word[line_idx][0] == original_word[line_idx],
              "resident store unexpectedly reached memory");
      end
      read_word(TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift), expected_word[`RAPT_L1D_N_WAYS][0]);
      written_lines = 0;
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        if (mem_word[line_idx][0] == expected_word[line_idx][0]) written_lines++;
        else
          check(mem_word[line_idx][0] == original_word[line_idx],
                "victim writeback corrupted unrelated backing word");
      end
      check(written_lines == 1, "load miss did not write exactly one dirty victim");
      if (`RAPT_L1D_N_WAYS > 1)
        check(dut.dirty_any && !writeback_idle, "victim drain cleaned unrelated dirty lines");
      writeback_drain = 1;
      for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
      check(writeback_idle, "post-victim explicit drain timed out");
      writeback_drain = 0;
      invalidate_backed_lines();
      tick(512);
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        read_word(TestAddr + (line_idx << ConflictShift), expected_word[line_idx][0]);
      end
      for (int wait_cycle = 0; wait_cycle < 4096 && !lsu_l1d.idle; wait_cycle++) tick(1);
      check(lsu_l1d.idle, "store victim setup refill did not finish");
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        original_word[line_idx] = mem_word[line_idx][0];
        expected_word[line_idx][0] = ~original_word[line_idx];
        write_word(TestAddr + (line_idx << ConflictShift), expected_word[line_idx][0]);
      end
      @(negedge clock);
      lsu_l1d.waddr = TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift);
      lsu_l1d.walu = 8'({XLEN / 8{1'b1}});
      lsu_l1d.wdata = XLEN'(64'h1020_3040_5060_7080);
      lsu_l1d.wvalid = 1;
      for (int wait_cycle = 0; wait_cycle < 4096; wait_cycle++) begin
        #1;
        if (lsu_l1d.wready) break;
        @(negedge clock);
      end
      check(lsu_l1d.wready && !l1d_bus.wvalid, "store victim did not resume local allocation");
      @(posedge clock);
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      tick(4);
      written_lines = 0;
      for (int line_idx = 0; line_idx < `RAPT_L1D_N_WAYS; line_idx++) begin
        if (mem_word[line_idx][0] == expected_word[line_idx][0]) written_lines++;
        else
          check(mem_word[line_idx][0] == original_word[line_idx],
                "store victim corrupted unrelated backing word");
      end
      check(written_lines == 1, "store miss did not write exactly one dirty victim");
      check(mem_word[`RAPT_L1D_N_WAYS][0] == expected_word[`RAPT_L1D_N_WAYS][0],
            "store victim allocation wrote new data through");
      expected_word[`RAPT_L1D_N_WAYS][0] = 32'h5060_7080;
      if (XLEN == 64) expected_word[`RAPT_L1D_N_WAYS][1] = 32'h1020_3040;
      read_word(TestAddr + (`RAPT_L1D_N_WAYS << ConflictShift), expected_word[`RAPT_L1D_N_WAYS][0]);
      writeback_drain = 1;
      for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
      check(writeback_idle, "post-store-victim drain timed out");
      for (int line_idx = 0; line_idx <= `RAPT_L1D_N_WAYS; line_idx++) begin
        check(mem_word[line_idx][0] == expected_word[line_idx][0],
              "store victim sequence lost dirty data");
      end
      if (XLEN == 64)
        check(mem_word[`RAPT_L1D_N_WAYS][1] == expected_word[`RAPT_L1D_N_WAYS][1],
              "store victim sequence lost upper word");
      writeback_drain = 0;
      read_word(TestAddr, expected_word[0][0]);
      expected_word[0][0][7:0] = 8'hcd;
      concurrent_partial_store(`RAPT_SB_WSTRB, expected_word[0][0]);
      expected_word[0][0][15:0] = 16'habcd;
      concurrent_partial_store(`RAPT_SH_WSTRB, expected_word[0][0]);
      if (LineWords > 4) begin
        read_word(TestAddr + 4 * (LineWords - 1), 32'b0);
        write_word(TestAddr + 4 * (LineWords - 1), 32'h5a3c_c3a5);
        read_word(TestAddr + 4 * (LineWords - 1), 32'h5a3c_c3a5);
      end
      // Exercise rapid full-width hits to one word and then several words in
      // the same dirty line. A store miss to each distinct line cannot cover
      // an overwrite lost by the local write-back hit path.
      for (int burst = 0; burst < 4; burst++)
      write_store(TestAddr + 16, 32'(8 + burst), XLEN == 64 ? 8'hff : 8'h0f, 0);
      read_word(TestAddr + 16, 32'd11);
      for (int word_idx = 0; word_idx < 6; word_idx++)
      write_store(TestAddr + 16 + word_idx * (XLEN / 8), 32'(48 + word_idx),
                  XLEN == 64 ? 8'hff : 8'h0f, 0);
      for (int word_idx = 0; word_idx < 6; word_idx++)
      read_word(TestAddr + 16 + word_idx * (XLEN / 8), 32'(48 + word_idx));
      // Match the whole-core failure pattern: 64 same-word stores followed
      // by 64 stores cycling through all eight words of one cache line.
      if (XLEN == 64) begin
        for (int burst = 0; burst < 64; burst++) write_store(TestAddr + 16, 32'd7, 8'hff, 0);
        for (int burst = 0; burst < 64; burst++)
        write_store(TestAddr + 8 * (burst % 8), 32'd7, 8'hff, 0);
        for (int word_idx = 0; word_idx < 8; word_idx++) read_word(TestAddr + 8 * word_idx, 32'd7);
        // SQ keeps wvalid asserted and presents the next committed store
        // immediately after each handshake. Do not insert the gap used by
        // write_store(), which can hide a back-to-back writeback bug.
        @(negedge clock);
        lsu_l1d.wvalid = 1'b1;
        lsu_l1d.wzero = 1'b0;
        lsu_l1d.walu = 8'hff;
        lsu_l1d.wdata = 64'd7;
        for (int burst = 0; burst < 64; burst++) begin
          lsu_l1d.waddr = TestAddr + 8 * (burst % 8);
          for (int wait_cycle = 0; wait_cycle < 4096; wait_cycle++) begin
            #1;
            if (lsu_l1d.wready) break;
            @(negedge clock);
          end
          check(lsu_l1d.wready, "continuous local store stalled");
          @(posedge clock);
          @(negedge clock);
        end
        lsu_l1d.wvalid = 1'b0;
        for (int word_idx = 0; word_idx < 8; word_idx++) read_word(TestAddr + 8 * word_idx, 32'd7);
        writeback_drain = 1'b1;
        for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
        check(writeback_idle, "dense-line writeback drain timed out");
        writeback_drain = 1'b0;
        invalidate_backed_lines();
        tick(512);
        for (int word_idx = 0; word_idx < 8; word_idx++) begin
          check(mem_word[0][2*word_idx] == 32'd7, "dense-line writeback lost backing data");
          read_word(TestAddr + 8 * word_idx, 32'd7);
        end
        // In the core, the ROB raises drain while older committed SQ stores
        // are still arriving. Change the value so a lost update stays visible.
        writeback_drain = 1'b1;
        @(negedge clock);
        lsu_l1d.wvalid = 1'b1;
        lsu_l1d.wdata = 64'd9;
        for (int burst = 0; burst < 64; burst++) begin
          lsu_l1d.waddr = TestAddr + 8 * (burst % 8);
          for (int wait_cycle = 0; wait_cycle < 4096; wait_cycle++) begin
            #1;
            if (lsu_l1d.wready) break;
            @(negedge clock);
          end
          check(lsu_l1d.wready, "store stalled during writeback drain");
          @(posedge clock);
          @(negedge clock);
        end
        lsu_l1d.wvalid = 1'b0;
        for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
        check(writeback_idle, "overlapped writeback drain timed out");
        writeback_drain = 1'b0;
        invalidate_backed_lines();
        tick(512);
        for (int word_idx = 0; word_idx < 8; word_idx++) begin
          check(mem_word[0][2*word_idx] == 32'd9, "overlapped drain lost backing data");
          read_word(TestAddr + 8 * word_idx, 32'd9);
        end
        expected_word[0][0] = 32'd9;
      end
      read_word(TestAddr, expected_word[0][0]);
      write_store(TestAddr, 32'h0000_005a, `RAPT_SB_WSTRB, 0);
      invalidate_backed_lines();
      tick(512);
      expected_word[0][0][7:0] = 8'h5a;
      read_word(TestAddr, expected_word[0][0]);
      // Establish the backing value explicitly before injecting a B error.
      writeback_drain = 1;
      for (int drain_cycle = 0; drain_cycle < 4096 && !writeback_idle; drain_cycle++) tick(1);
      check(writeback_idle, "write-error setup drain timed out");
      writeback_drain = 0;
      @(negedge clock);
      bus_write_enable = 0;
      write_store(TestAddr, 32'h1234_abcd, `RAPT_SW_WSTRB, 0);
      check(mem_word[0][0] == expected_word[0][0], "dirty store reached memory before B");
      coherent_addr = XLEN'(TestAddr);
      coherent_request = 1;
      cmu_bcast.fence_time = 1;
      tick(1);
      cmu_bcast.fence_time = 0;
      tick(512);
      check(!coherent_ready && !writeback_idle, "drain released before B response");
      check(l1d_bus.wvalid && l1d_bus.wdata[31:0] == 32'h1234_abcd,
            "writeback payload lost under backpressure");
      @(negedge clock);
      l1d_bus.werr = 1;
      bus_write_enable = 1;
      tick(1);
      @(negedge clock);
      l1d_bus.werr = 0;
      tick(512);
      check(writeback_error && !writeback_idle && !coherent_ready,
            "writeback error did not hold maintenance");
      check(dut.wb_busy && !l1d_bus.wvalid && dut.wb_data[31:0] == 32'h1234_abcd,
            "writeback error lost dirty ownership or retried");
      check(mem_word[0][0] == expected_word[0][0], "failed write changed backing memory");
      targeted_writeback_error(0, 1);
      targeted_writeback_error(1, 1);
      targeted_writeback_error(0, 0);
      targeted_writeback_error(1, 0);
      targeted_writeback_error(1, 0, 1);
      targeted_writeback_error(1, 1, 1);
    end

    $write("PASS: L1D coherence random seed=%0d loads=%0d stores=%0d ", configured_seed,
           random_loads, random_stores);
    $display("fences=%0d max_delay=%0d", random_fences, random_max_bus_read_delay);
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
  `include "tb_l1d_harness.svh"
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
          lsu_l1d.wzero = 0;
          lsu_l1d.wdata = 'h55667788;
          lsu_l1d.wvalid = 1;
          #1;
          check(!lsu_l1d.wready && l1d_bus.wvalid, "typed store failed write-through offer");
          tick(1);
          check(lsu_l1d.wready && !l1d_bus.wvalid, "typed store response was lost or repeated");
          tick(1);
          lsu_l1d.wvalid = 0;
          for (int c = 0; c < 4; c++) begin
            check(!dut.l1d_update, "NC/IO store allocated or updated cache");
            tick(1);
          end
          check(writes == 1, "typed store did not reach backing memory exactly once");
          if (hot != 0) begin
            // Returning to cacheable access requires CBO maintenance, not SFENCE.
            // This test only warmed a clean line; no dirty writeback is needed.
            check(!dut.dirty_any, "PBMT alias maintenance unexpectedly found dirty data");
            cmu_bcast.cbo_block = Addr[XLEN-1:6];
            cmu_bcast.cbo_inval = 1;
            tick(1);
            cmu_bcast.cbo_inval = 0;
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

`include "rapt.svh"

// ---- tb_l1d_trap_owner ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_trap_owner;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] VA = 'h40000120;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  `include "tb_l1d_harness.svh"
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
  rapt_l1d #(
      // This case checks precise B errors on synchronous write-through stores.
      // Dirty write-back errors have a separate fail-stop regression.
      .WriteBack(1'b0),
      .LineRefill(0)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
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
      .writeback_cbo_done(),
      .coherent_addr('0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
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
      lsu_l1d.wzero = 0;
      lsu_l1d.wvalid=1;
      // Error without B completion must not consume or mutate the write.
      l1d_bus.werr=1;
      tick(3);
      check(!lsu_l1d.wready && !lsu_l1d.werr, "stray write error consumed");
      l1d_bus.wready = 1;
      #1;
      check(!lsu_l1d.wready, "write response bypassed its boundary register");
      tick(1);
      l1d_bus.wready=0;
      l1d_bus.werr=0;
      check(lsu_l1d.wready && lsu_l1d.werr, "write failure was not exposed to SQ");
      check(!l1d_bus.wvalid, "registered acknowledgement repeated the failed write");
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

`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"

`include "rapt.svh"

`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
`include "tb_l1d_unused_release_ports.svh"
// Exercise response ownership across a newly requested victim scan and
// an array refill. Uses the production L1D and bus with held responses.

`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
`include "tb_l1d_unused_release_ports.svh"

// Real D-side walker and I-side bus owner share delayed backing memory.
// Writes become visible only on B; unrelated dirty data must remain private.

`include "rapt.svh"

// ---- tb_cbo_refill_order ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

// Exercise the memory wrapper's precommit CBO owner against an older AXI
// refill. Cleaning an empty tag before RLAST would let its late fill survive.
module tb_cbo_refill_order;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam logic [XLEN-1:0] Target = XLEN'('h80000000);
  localparam logic [XLEN-1:0] Other = Target + 'h1000;
  localparam logic [XLEN-1:0] OrderedTarget = Target + 'h200;
  localparam logic [XLEN-1:0] Device = XLEN'('h10000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  ifu_l1i_if ifu_l1i ();
  l2_client_if l2_client ();
  axi4_if io_master ();
  logic writeback_drain_i = 0, writeback_cbo_i = 0;
  logic stores_empty_i = 1;
  bit ordered_fence_done = 0;
  logic writeback_done_o, writeback_error_o;
  rapt_memory #(
      .L1dWriteBack(1)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .ifetch_io_authorized_i(1'b0),
      .ifetch_io_start_o(),
      .ifetch_io_owner_pc_o(),
      .data_idle_o(),
      .writeback_idle_o(),
      .writeback_clean_i(1'b0),
      .writeback_cbo_invalidate_i(1'b1),
      .writeback_block_i(Target[XLEN-1:6]),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  rapt_l2_subsystem l2_subsystem (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock,
      .reset,
      .client(l2_client),
      .io_master
  );
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS

  logic reading = 0, hold_read = 1;
  logic [XLEN-1:0] read_addr;
  logic [3:0] read_id;
  int beats_left, read_step, reads = 0;
  function automatic logic [XLEN-1:0] memory_word(input logic [XLEN-1:0] addr);
    return addr ^ XLEN'('h12345678);
  endfunction
  assign io_master.arready = !reading;
  assign io_master.rvalid = reading && !hold_read;
  assign io_master.rid = read_id;
  assign io_master.rdata = memory_word(read_addr);
  assign io_master.rresp = 0;
  assign io_master.rlast = beats_left == 1;
  assign io_master.awready = 1;
  assign io_master.wready = 1;
  assign io_master.bvalid = 0;
  assign io_master.bid = 0;
  assign io_master.bresp = 0;
  always @(posedge clock) begin
    if (reset) begin
      reading <= 0;
      reads = 0;
    end else begin
      if (io_master.arvalid && io_master.arready) begin
        if (!(io_master.araddr inside {Target, OrderedTarget, Device}))
          $fatal(1, "unexpected read %h", io_master.araddr);
        if (io_master.araddr == Device && !ordered_fence_done)
          $fatal(1, "device read overtook ordinary fence completion");
        reading <= 1;
        read_addr <= io_master.araddr;
        read_id <= io_master.arid;
        read_step <= 1 << io_master.arsize;
        beats_left <= int'(io_master.arlen) + 1;
        reads++;
      end else if (io_master.rvalid && io_master.rready) begin
        beats_left <= beats_left - 1;
        read_addr <= read_addr + XLEN'(read_step);
        if (beats_left == 1) reading <= 0;
      end
      if (io_master.awvalid || io_master.wvalid) $fatal(1, "CBO swept unrelated dirty cache line");
      if (writeback_error_o) $fatal(1, "unexpected writeback error");
    end
  end

  task automatic begin_load(input logic [XLEN-1:0] addr);
    @(negedge clock);
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = addr;
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
  endtask
  task automatic finish_load(input logic [XLEN-1:0] expected);
    for (int n = 0; n < 10000; n++) begin
      @(posedge clock);
      if (lsu_l1d.rready) begin
        if (lsu_l1d.trap || lsu_l1d.rdata != expected)
          $fatal(1, "load expected=%h got=%h trap=%b", expected, lsu_l1d.rdata, lsu_l1d.trap);
        @(negedge clock);
        lsu_l1d.rvalid = 0;
        return;
      end
    end
    $fatal(1, "load timeout");
  endtask
  initial begin
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    ifu_l1i.pc = 0;
    ifu_l1i.invalid = 1;
    ifu_l1i.consumed = 0;
    ifu_l1i.cancel = 0;
    ifu_l1i.prefetch_pc = 0;
    ifu_l1i.prefetch_valid = 0;
    repeat (5) @(negedge clock);
    reset = 0;
    @(negedge clock);
    lsu_l1d.waddr = Other;
    lsu_l1d.wdata = XLEN'('h13579bdf);
    lsu_l1d.walu = 8'({Bytes{1'b1}});
    lsu_l1d.wvalid = 1;
    for (int n = 0; n < 10000; n++) begin
      @(posedge clock);
      if (lsu_l1d.wready) break;
    end
    if (!lsu_l1d.wready) $fatal(1, "sentinel store timeout");
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    repeat (5) @(negedge clock);

    // Ordinary fences drain SQ and outstanding memory while preserving
    // dirty resident data. Neither condition may be mistaken for completion.
    stores_empty_i = 0;
    writeback_drain_i = 1;
    repeat (10) begin
      @(negedge clock);
      if (writeback_done_o) $fatal(1, "ordinary fence ignored nonempty SQ");
    end
    begin_load(OrderedTarget);
    for (int n = 0; n < 10000 && !reading; n++) @(negedge clock);
    if (!reading) $fatal(1, "ordered refill did not reach AXI");
    stores_empty_i = 1;
    repeat (10) begin
      @(negedge clock);
      if (writeback_done_o) $fatal(1, "ordinary fence ignored outstanding memory");
    end
    hold_read = 0;
    finish_load(memory_word(OrderedTarget));
    for (int n = 0; n < 10000 && !writeback_done_o; n++) @(negedge clock);
    if (!writeback_done_o) $fatal(1, "ordinary fence failed to finish");
    ordered_fence_done = 1;
    writeback_drain_i = 0;
    repeat (10) @(negedge clock);
    begin_load(Device);
    finish_load(memory_word(Device));
    repeat (10) @(negedge clock);
    begin_load(Other);
    finish_load(XLEN'('h13579bdf));
    if (reads != 2) $fatal(1, "ordinary fence swept or invalidated dirty sentinel");
    $display("PASS: RV%0d ordinary fence waits SQ/memory and orders device read without sweep",
             XLEN);

    hold_read = 1;
    begin_load(Target);
    for (int n = 0; n < 10000 && !reading; n++) @(negedge clock);
    if (!reading) $fatal(1, "refill did not reach AXI");
    writeback_cbo_i = 1;
    writeback_drain_i = 1;
    repeat (20) begin
      @(negedge clock);
      if (dut.cache_cbo_active_q || writeback_done_o)
        $fatal(1, "CBO armed before older refill completed");
    end
    hold_read = 0;
    finish_load(memory_word(Target));
    for (int n = 0; n < 10000 && !writeback_done_o; n++) @(negedge clock);
    if (!writeback_done_o) $fatal(1, "CBO did not finish after RLAST");
    writeback_drain_i = 0;
    writeback_cbo_i = 0;
    repeat (10) @(negedge clock);
    begin_load(Target);
    finish_load(memory_word(Target));
    if (reads != 4) $fatal(1, "late refill survived CBO invalidation");
    repeat (20) @(negedge clock);
    begin_load(Other);
    finish_load(XLEN'('h13579bdf));
    if (reads != 4) $fatal(1, "CBO invalidated unrelated same-set line");
    $display("PASS: RV%0d precommit CBO waits for older refill and prevents late resurrection",
             XLEN);
    $finish;
  end
  initial begin
    #10000000;
    $fatal(1, "CBO refill order timeout");
  end
endmodule

module tb_l1d_mmio_retry_wb;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  localparam logic [XLEN-1:0] Other = Base + 'h9080;
  localparam logic [XLEN-1:0] Target = Base + 'h2080;
  localparam logic [XLEN-1:0] Va = XLEN'('h40000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  l1d_bus_if l1d_bus ();
  l1i_bus_if l1i_bus ();
  mem_link_if mem ();
  logic coherent_request, coherent_write, coherent_ready;
  logic [XLEN-1:0] coherent_addr;
  logic writeback_error, writeback_idle;
  logic writeback_drain = 0;
  logic writeback_cbo = 0, writeback_cbo_invalidate = 0, writeback_cbo_done;
  logic [XLEN-1:6] writeback_block = 0;
  rapt_pkg::l2tlb_req_t l2tlb_req[2];
  rapt_pkg::l2tlb_rsp_t l2tlb_rsp[2];
  logic [1:0] l2tlb_ready;
  assign l2tlb_req[0] = '0;
  if (`RAPT_L2TLB_ENTRIES > 0) begin : g_l2tlb
    rapt_l2tlb #(
        .Entries(`RAPT_L2TLB_ENTRIES),
        .XLEN(XLEN)
    ) u_l2tlb (
        .sram_ctrl_i(rapt_pkg::SramCtrlReset),
        .clock(clock),
        .reset(reset),
        .flush(cmu_bcast.fence_time),
        .req_i(l2tlb_req),
        .ready_o(l2tlb_ready),
        .rsp_o(l2tlb_rsp),
        .cancel(1'b0),
        .sfence_valid(1'b0),
        .sfence_vpn('0),
        .sfence_asid('0),
        .sfence_all_vpn(1'b1),
        .sfence_all_asid(1'b1)
    );
  end else begin : g_no_l2tlb
    assign l2tlb_ready = '0;
    assign l2tlb_rsp[0] = '0;
    assign l2tlb_rsp[1] = '0;
  end
  rapt_l1d #(
      .WriteBack(1),
      .TargetedCoherence(0),
      .DirtySkip(1'b0),
      .L2Tlb(`RAPT_L2TLB_ENTRIES > 0)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(l2tlb_req[1]),
      .l2tlb_ready_i(l2tlb_ready[1]),
      .l2tlb_rsp_i(l2tlb_rsp[1]),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      `TB_L1D_UNUSED_RELEASE_PORTS,
      .*
  );
  rapt_bus bus_dut (
      .rd_req_cacheable(),
      .*
  );
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS

  byte unsigned backing[131072];
  logic reading = 0, writing = 0;
  logic [3:0] read_id, write_id;
  logic [XLEN-1:0] read_addr, write_addr, write_data;
  logic [Bytes-1:0] write_strb;
  int read_beats, read_step, read_delay, write_delay;
  int writes, dptw_reads, iptw_reads, device_writes, device_reads;
  bit fail_writes = 0;
  int delay_max = 7;
  int unsigned rng = 1;

  function automatic logic [XLEN-1:0] memory_word(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] result;
    result = '0;
    if (addr >= Base && addr < Base + 131072)
      for (int b = 0; b < Bytes; b++) result[b*8+:8] = backing[int'(addr-Base)+b];
    else result = XLEN'('h13579bdf);
    return result;
  endfunction
  task automatic seed_word(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] value);
    for (int b = 0; b < Bytes; b++) backing[int'(addr-Base)+b] = value[b*8+:8];
  endtask

  assign mem.rd_req_ready = !reading;
  assign mem.rd_rsp_valid = reading && read_delay == 0;
  assign mem.rd_rsp_id = read_id;
  assign mem.rd_rsp_data = memory_word(read_addr);
  assign mem.rd_rsp_last = read_beats == 1;
  assign mem.rd_rsp_error = 0;
  assign mem.wr_req_ready = !writing;
  assign mem.wr_rsp_valid = writing && write_delay == 0;
  assign mem.wr_rsp_id = write_id;
  assign mem.wr_rsp_error = fail_writes;
  always @(posedge clock) begin
    if (reset) begin
      reading <= 0;
      writing <= 0;
      writes = 0;
      dptw_reads = 0;
      iptw_reads = 0;
      device_writes = 0;
      device_reads = 0;
    end else begin
      rng = rng * 1664525 + 1013904223;
      if (mem.rd_req_valid && mem.rd_req_ready) begin
        if ($test$plusargs("TRACE"))
          $display(
              "READ id=%0d addr=%h data=%h",
              mem.rd_req_id,
              mem.rd_req_addr,
              memory_word(
                  mem.rd_req_addr
              )
          );
        if (writing && ((mem.rd_req_addr ^ write_addr) >> $clog2(`RAPT_CACHE_LINE_BYTES)) == 0)
          $fatal(1, "read escaped before target write response addr=%h", mem.rd_req_addr);
        reading <= 1;
        if (mem.rd_req_addr == XLEN'('h10000000)) device_reads++;
        read_addr <= mem.rd_req_addr;
        read_id <= mem.rd_req_id;
        read_beats <= int'(mem.rd_req_len) + 1;
        read_step <= 1 << mem.rd_req_size;
        read_delay <= int'(rng % unsigned'(delay_max + 1));
        if (mem.rd_req_id == 4) dptw_reads++;
        if (mem.rd_req_id == 3) iptw_reads++;
      end else if (mem.rd_rsp_valid && mem.rd_rsp_ready) begin
        read_addr <= read_addr + XLEN'(read_step);
        read_beats <= read_beats - 1;
        read_delay <= int'((rng >> 8) % unsigned'(delay_max + 1));
        if (read_beats == 1) reading <= 0;
      end else if (reading && read_delay != 0) read_delay <= read_delay - 1;
      if (mem.wr_req_valid && mem.wr_req_ready) begin
        writing <= 1;
        write_addr <= mem.wr_req_addr & ~XLEN'(Bytes-1);
        write_data <= mem.wr_req_data;
        write_strb <= mem.wr_req_strb;
        write_id <= mem.wr_req_id;
        write_delay <= 16 + int'(rng % unsigned'(delay_max + 1));
      end else if (mem.wr_rsp_valid && mem.wr_rsp_ready) begin
        writing <= 0;
        if ($test$plusargs("TRACE"))
          $display("WRITE addr=%h data=%h mask=%h", write_addr, write_data, write_strb);
        writes++;
        if (fail_writes) begin
          // A failed response must leave the writeback queue owning the data.
        end else if (write_addr >= Base && write_addr < Base + 131072) begin
          for (int b = 0; b < Bytes; b++)
          if (write_strb[b]) backing[int'(write_addr-Base)+b] = write_data[b*8+:8];
        end else device_writes++;
      end else if (writing && write_delay != 0) write_delay <= write_delay - 1;
      if (writeback_error && !fail_writes) $fatal(1, "unexpected writeback error");
    end
  end

  task automatic init;
    @(negedge clock);
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    l1i_bus.arvalid = 0;
    l1i_bus.araddr = 0;
    l1i_bus.arburst = 0;
    l1i_bus.ar_ptw = 0;
    l1i_bus.rpbmt = 0;
    l1i_bus.noallocate = 0;
    writeback_drain = 0;
    fail_writes = 0;
    writeback_cbo = 0;
    writeback_cbo_invalidate = 0;
    writeback_block = 0;
    foreach (backing[b]) backing[b] = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    repeat (4) @(negedge clock);
  endtask
  task automatic store(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                       input logic [1:0] pbmt = 0);
    @(negedge clock);
    lsu_l1d.wvalid = 1;
    lsu_l1d.waddr = addr;
    lsu_l1d.wdata = data;
    lsu_l1d.walu = 8'({Bytes{1'b1}});
    lsu_l1d.wpbmt = pbmt;
    for (int n = 0; n < 10000; n++) begin
      @(posedge clock);
      if (lsu_l1d.wready) begin
        @(negedge clock);
        lsu_l1d.wvalid = 0;
        lsu_l1d.wpbmt = 0;
        repeat (4) @(negedge clock);
        return;
      end
    end
    $fatal(1, "store timeout addr=%h wb=%h", addr, dut.wb_state);
  endtask
  task automatic load(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] expected,
                      input bit atomic_access = 0);
    @(negedge clock);
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = addr;
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    lsu_l1d.atomic_lock = atomic_access;
    for (int n = 0; n < 10000; n++) begin
      @(posedge clock);
      if (lsu_l1d.rready) begin
        if (lsu_l1d.trap || lsu_l1d.rdata != expected)
          $fatal(
              1,
              "load addr=%h expected=%h got=%h trap=%b",
              addr,
              expected,
              lsu_l1d.rdata,
              lsu_l1d.trap
          );
        @(negedge clock);
        lsu_l1d.rvalid = 0;
        lsu_l1d.atomic_lock = 0;
        repeat (20) @(negedge clock);
        return;
      end
    end
    $fatal(1, "load timeout addr=%h", addr);
  endtask

  task automatic retry_during_writeback;
    localparam logic [XLEN-1:0] Device = XLEN'('h10000000);
    int reads_before;
    bit retried, completed;
    init();
    // Warm a device translation before making the unrelated cached word dirty.
    // The following retry must therefore collide with writeback in LD_A.
    seed_word(Base + 'h10000 + XLEN'(XLEN == 64 ? 8 : 1024),
              XLEN == 64 ? XLEN'(('h80011 << 10) | 1) : (Device >> 2) | XLEN'('hcf));
    if (XLEN == 64) seed_word(Base + 'h11000, (Device >> 2) | XLEN'('hcf));
    seed_word(Base + 'h10000 + XLEN'(XLEN == 64 ? 16 : 2048), (Base >> 2) | XLEN'('hcf));
    pmp_update.addr_we = 1;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we = 1;
    pmp_update.cfg_r = 1;
    pmp_update.cfg_w = 1;
    pmp_update.mode_off[0] = 0;
    pmp_update.mode_napot = 1;
    @(negedge clock);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we = 0;
    csr_bcast.mprv = 1;
    csr_bcast.mpp = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.satp_ppn = 'h80010;
    load(Va, XLEN'('h13579bdf));
    store(Target, XLEN'('h12345678));
    reads_before = device_reads;
    retried = 0;
    completed = 0;
    @(negedge clock);
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = Va;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.ordered = 0;
    for (int n = 0; n < 1000; n++) begin
      @(posedge clock);
      if (lsu_l1d.rretry) begin
        if (!dut.load_miss_wb_hold || lsu_l1d.rready)
          $fatal(1, "retry did not overlap a dirty writeback hold");
        retried = 1;
        break;
      end
    end
    if (!retried) $fatal(1, "translated device retry timeout");
    // Model IOQ releasing the old owner and selecting an older ordered RAM
    // load. That owner's permission must never authorize the abandoned IO.
    @(negedge clock);
    lsu_l1d.raddr = Other;
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    lsu_l1d.ordered = 1;
    for (int n = 0; n < 10000; n++) begin
      @(posedge clock);
      if (device_reads != reads_before)
        $fatal(1, "retried MMIO request borrowed the next owner's ordered permission");
      if (lsu_l1d.rready) begin
        if (lsu_l1d.trap || lsu_l1d.rdata != 0)
          $fatal(1, "replacement RAM owner received an incorrect response");
        completed = 1;
        break;
      end
    end
    if (!completed) $fatal(1, "replacement RAM load timeout");
    @(negedge clock);
    lsu_l1d.rvalid = 0;
    repeat (20) @(negedge clock);
    if (memory_word(Target) != XLEN'('h12345678))
      $fatal(1, "retry lost the dirty writeback payload");
    load(Va, XLEN'('h13579bdf));
    if (device_reads != reads_before + 1)
      $fatal(1, "ordered device retry was not issued exactly once");
    $display("PASS: RV%0d translated MMIO retry releases ownership during writeback", XLEN);
  endtask
  initial begin
    retry_during_writeback();
    $finish;
  end
  initial begin
    #20000000;
    $fatal(1, "targeted coherence timeout");
  end
endmodule

`include "rapt.svh"

`include "rapt.svh"
