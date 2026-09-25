`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1i_16k;
  localparam int Ways = `RAPT_L1I_N_WAYS;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Sets = 2 ** `RAPT_L1I_LEN;
  localparam int LineBytes = `RAPT_CACHE_LINE_BYTES;
  // One index wrap; also the address stride between ways of the same set.
  localparam int SetStrideBytes = Sets * LineBytes;
  localparam int CapacityBytes = Sets * Ways * LineBytes;
  localparam int CapacityLines = Sets * Ways;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i #(
      .L1I_N_WAYS(Ways)
  ) dut (
      .*,
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc()
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  int unsigned requests[$], address;
  int reads = 0;
  function automatic logic [31:0] word_at(input int unsigned addr);
    return (((addr >> 2) ^ (addr >> 14)) & 4095) << 20 | 32'h00000093;
  endfunction
  assign l1i_bus.rready = l1i_bus.arvalid;
  always @(posedge clock)
    if (!reset && l1i_bus.arvalid && l1i_bus.rready) begin
      assert (!l1i_bus.ar_ptw)
      else $fatal(1, "unexpected PTW");
      reads++;
      requests.push_back(32'(l1i_bus.araddr));
    end
  always @(negedge clock) begin
    l1i_bus.rvalid = 0;
    if (!reset && requests.size() != 0) begin
      address = requests.pop_front();
      // AXI word reads occupy the addressed lane of the XLEN-wide data bus.
      l1i_bus.rdata = XLEN'(word_at(address)) << ((XLEN == 64 && address[2]) ? 32 : 0);
      l1i_bus.rvalid = 1;
    end
  end
  task automatic fetch(input int unsigned pc, input bit hot);
    int before_reads;
    @(negedge clock);
    before_reads = reads;
    ifu_l1i.pc = XLEN'(pc);
    for (int cycle = 0; cycle < 100; cycle++) begin
      @(posedge clock);
      if (ifu_l1i.valid) begin
        if (ifu_l1i.trap || ifu_l1i.inst_n0 != word_at(pc))
          $fatal(1, "fetch pc=%h got=%h expected=%h", pc, ifu_l1i.inst_n0, word_at(pc));
        // Allow the sector refill to finish before moving to another line.
        repeat (20) @(negedge clock);
        if (hot && reads != before_reads) $fatal(1, "resident I line missed pc=%h", pc);
        return;
      end
    end
    $fatal(1, "fetch timeout pc=%h", pc);
  endtask
  task automatic reject_alias(input logic [XLEN-1:0] pc);
    int before_reads;
    @(negedge clock);
    before_reads = reads;
    ifu_l1i.pc = pc;
    for (int cycle = 0; cycle < 40; cycle++) begin
      @(posedge clock);
      if (reads != before_reads || l1i_bus.arvalid) $fatal(1, "invalid PA reached I bus: %h", pc);
      if (ifu_l1i.valid) begin
        if (!ifu_l1i.trap || ifu_l1i.cause != 1 || ifu_l1i.tval != pc)
          $fatal(1, "invalid high PA aliased a resident I tag: %h", pc);
        @(negedge clock);
        cmu_bcast.flush_pipe = 1;
        @(negedge clock);
        cmu_bcast.flush_pipe = 0;
        return;
      end
    end
    $fatal(1, "invalid I PA did not fault: %h", pc);
  endtask
  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
    init_pmp_state_defaults(1);
    ifu_l1i.pc = XLEN'('h80000000);
    ifu_l1i.consumed = 0;
    ifu_l1i.cancel = 0;
    ifu_l1i.invalid = 0;
    ifu_l1i.prefetch_valid = 0;
    ifu_l1i.prefetch_pc = 0;
    l1i_bus.rvalid = 0;
    l1i_bus.rdata = 0;
    l1i_bus.ptw_rerr = 0;
    l1i_bus.ptw_rvalid = 0;
    l1i_bus.rlast = 1;
    l1i_bus.rerr = 0;
    l1i_bus.wready = 0;
    l1i_bus.werr = 0;
    l1i_bus.ptw_wready = 0;
    l1i_bus.ptw_werr = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    if ($bits(dut.addr_tag) != `RAPT_PADDR_BITS - `RAPT_L1I_LEN - `RAPT_L1I_LINE_LEN - 2)
      $fatal(1, "I tag must exclude non-physical, index and offset bits");
    if (`RAPT_CACHE_LINE_BYTES != 64 || Sets < 2 || Ways < 2)
      $fatal(1, "test requires 64 B lines and at least two sets and ways");
    // All ways for every set, both refill sectors: occupy the whole cache.
    for (int line = 0; line < CapacityLines; line++) begin
      fetch('h80000000 + LineBytes * line, 0);
      fetch('h80000000 + LineBytes / 2 + LineBytes * line, 0);
    end
    for (int word_idx = 0; word_idx < CapacityBytes / 4; word_idx++)
    fetch('h80000000 + 4 * word_idx, 1);
    begin
      int before_reads;
      before_reads = reads;
      fetch('h80000000 + SetStrideBytes * Ways, 0);
      if (reads == before_reads) $fatal(1, "conflicting I tag did not miss");
      fetch('h80000000 + SetStrideBytes * Ways, 1);
      // Replacement of set 0 must leave neighboring set 1 resident in all ways.
      for (int way = 0; way < Ways; way++) fetch('h80000000 + LineBytes + SetStrideBytes * way, 1);
      @(negedge clock);
      ifu_l1i.invalid = 1;
      ifu_l1i.pc = XLEN'('h80008000);
      repeat (4) @(negedge clock);
      ifu_l1i.invalid = 0;
      // The held PC has a distinct tag if it refills on invalidation release.
      for (int line = 0; line < CapacityLines; line++) begin
        before_reads = reads;
        fetch('h80000000 + LineBytes * line, 0);
        if (reads == before_reads) $fatal(1, "invalidation left I line %0d valid", line);
        fetch('h80000000 + LineBytes * line, 1);
      end
    end
    if (XLEN == 64) begin
      reject_alias(XLEN'(64'h0100000080000040));
      reject_alias(XLEN'(64'h0080000080000040));
      fetch('h80000040, 1);
    end
    $display(
        "PASS: L1I RV%0d PA%0d compact tags, %0d sets x %0d ways = %0d KiB capacity, replacement, invalidate/refill, invalid aliases",
        XLEN, `RAPT_PADDR_BITS, Sets, Ways, CapacityBytes / 1024);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "L1I window timeout");
  end
endmodule
