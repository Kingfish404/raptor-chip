`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_16k;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Sets = 2 ** `RAPT_L1D_LEN;
  localparam int Ways = `RAPT_L1D_N_WAYS;
  localparam int LineBytes = `RAPT_CACHE_LINE_BYTES;
  // One index wrap; also the address stride between ways of the same set.
  localparam int SetStrideBytes = Sets * LineBytes;
  localparam int CapacityBytes = Sets * Ways * LineBytes;
  localparam int CapacityLines = Sets * Ways;
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
  // Explicit widen keeps RV64 builds warning-clean: the 32-bit byte offset is
  // cast before the XLEN-wide add instead of being implicitly widened.
  function automatic logic [XLEN-1:0] load_addr(input int unsigned offset);
    return XLEN'('h80000000) + XLEN'(offset);
  endfunction
  function automatic logic [XLEN-1:0] word_at(input logic [XLEN-1:0] addr);
    return (addr * XLEN'('h1020305)) ^ XLEN'('hfedcba9876543210);
  endfunction

  task automatic load(input logic [XLEN-1:0] addr, input bit hot);
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
        @(posedge clock);
        @(negedge clock);
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
  task automatic reject_alias(input logic [XLEN-1:0] addr);
    @(negedge clock);
    lsu_l1d.raddr = addr;
    lsu_l1d.rvalid = 1;
    for (int cycle = 0; cycle < 30; cycle++) begin
      @(negedge clock);
      if (l1d_bus.arvalid) $fatal(1, "invalid PA reached D bus: %h", addr);
      if (lsu_l1d.rready) begin
        if (!lsu_l1d.trap || lsu_l1d.cause != 5)
          $fatal(1, "invalid high PA aliased a resident D tag: %h", addr);
        lsu_l1d.rvalid = 0;
        cmu_bcast.flush_pipe = 1;
        @(negedge clock);
        cmu_bcast.flush_pipe = 0;
        repeat (3) @(negedge clock);
        return;
      end
    end
    $fatal(1, "invalid PA did not fault: %h", addr);
  endtask
  initial begin
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    l1d_bus.rready = 1;
    repeat (4) @(negedge clock);
    reset = 0;
    if ($bits(
            dut.u_tags.l1d_tag[0][0]
        ) != `RAPT_PADDR_BITS -
        `RAPT_L1D_LEN
        - `RAPT_L1D_LINE_LEN - $clog2(
            XLEN / 8
        ))
      $fatal(1, "D tag must exclude non-physical, index and offset bits");
    if (`RAPT_CACHE_LINE_BYTES != 64 || Sets < 2 || Ways < 2)
      $fatal(1, "test requires 64 B lines and at least two sets and ways");
    for (int offset = 0; offset < CapacityBytes; offset += XLEN / 8) load(load_addr(offset), 0);
    for (int offset = 0; offset < CapacityBytes; offset += XLEN / 8) load(load_addr(offset), 1);
    begin
      int before_reads;
      before_reads = reads;
      load(load_addr(SetStrideBytes * Ways), 0);
      if (reads == before_reads) $fatal(1, "conflicting D tag did not miss");
      load(load_addr(SetStrideBytes * Ways), 1);
      for (int way = 0; way < Ways; way++) load(load_addr(LineBytes + SetStrideBytes * way), 1);
      @(negedge clock);
      cmu_bcast.fence_time = 1;
      @(negedge clock);
      cmu_bcast.fence_time = 0;
      repeat (3) @(negedge clock);
      // Every formerly resident line must miss after the whole-cache fence.
      for (int line = 0; line < CapacityLines; line++) begin
        before_reads = reads;
        load(load_addr(LineBytes * line), 0);
        if (reads != before_reads + 1) $fatal(1, "fence left D line %0d valid", line);
        load(load_addr(LineBytes * line), 1);
      end
    end
    if (XLEN == 64) begin
      reject_alias(XLEN'(64'h0100000080000040));
      reject_alias(XLEN'(64'h0080000080000040));
      load(XLEN'('h80000040), 1);
    end
    $display(
        "PASS: L1D RV%0d PA%0d compact tags, %0d sets x %0d ways = %0d KiB capacity, replacement, fence/refill, invalid aliases",
        XLEN, `RAPT_PADDR_BITS, Sets, Ways, CapacityBytes / 1024);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "L1D capacity timeout");
  end
endmodule
