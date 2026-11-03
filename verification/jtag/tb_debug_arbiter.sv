`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_debug_arbiter;
  localparam int Xlen = `RAPT_XLEN;
  logic clock = 0;
  always #5 clock = ~clock;
  logic reset = 1, block_core = 0, idle;
  axi4_if #(.XLEN(Xlen)) core ();
  axi4_if #(.XLEN(Xlen)) sb ();
  axi4_if #(.XLEN(Xlen)) bus ();
  rapt_debug_arbiter #(
      .CoreWriteOutstanding(4)
  ) dut (
      .clock,
      .reset,
      .core_block_i(block_core),
      .core_idle_o(idle),
      .core_axi(core),
      .sb_axi(sb),
      .merged_axi(bus)
  );

  task automatic read_response(input logic [3:0] id, input bit last = 1);
    @(negedge clock);
    bus.rvalid = 1;
    bus.rid = id;
    bus.rlast = last;
    bus.rdata = Xlen'(32'hac00_0000) | Xlen'(id);
    if (id == 15) sb.rready = 0;
    else core.rready = 0;
    #1;
    if (bus.rready) $fatal(1, "R backpressure routed to wrong owner");
    repeat (2) @(negedge clock);
    if (id == 15) sb.rready = 1;
    else core.rready = 1;
    #1;
    if (id == 15) begin
      if (!sb.rvalid || core.rvalid || sb.rdata != bus.rdata) $fatal(1, "SBA R routing");
    end else begin
      if (!core.rvalid || sb.rvalid || core.rid != id) $fatal(1, "core R routing");
    end
    @(negedge clock);
    bus.rvalid = 0;
  endtask

  task automatic write_response(input logic [3:0] id);
    @(negedge clock);
    bus.bvalid = 1;
    bus.bid = id;
    if (id == 15) sb.bready = 0;
    else core.bready = 0;
    #1;
    if (bus.bready) $fatal(1, "B backpressure routed to wrong owner");
    repeat (2) @(negedge clock);
    if (id == 15) sb.bready = 1;
    else core.bready = 1;
    #1;
    if (id == 15 ? (!sb.bvalid || core.bvalid) : (!core.bvalid || sb.bvalid))
      $fatal(1, "B routing");
    @(negedge clock);
    bus.bvalid = 0;
  endtask

  initial begin
    core.araddr = Xlen'(32'h8000_0000);
    core.arid = 8;
    core.arlen = 1;
    core.arsize = 2;
    core.arburst = 1;
    core.arcache = 15;
    core.arvalid = 0;
    core.rready = 1;
    core.awaddr = Xlen'(32'h8000_0100);
    core.awid = 2;
    core.awlen = 2;
    core.awsize = 2;
    core.awburst = 1;
    core.awcache = 0;
    core.awvalid = 0;
    core.wdata = 1;
    core.wstrb = '1;
    core.wlast = 0;
    core.wvalid = 0;
    core.bready = 1;
    sb.araddr = Xlen'(32'h0200_bff8);
    sb.arid = 0;
    sb.arlen = 0;
    sb.arsize = 2;
    sb.arburst = 1;
    sb.arcache = 0;
    sb.arvalid = 0;
    sb.rready = 1;
    sb.awaddr = Xlen'(32'h8000_0200);
    sb.awid = 0;
    sb.awlen = 0;
    sb.awsize = 2;
    sb.awburst = 1;
    sb.awcache = 0;
    sb.awvalid = 0;
    sb.wdata = Xlen'(32'hf00d);
    sb.wstrb = '1;
    sb.wlast = 1;
    sb.wvalid = 0;
    sb.bready = 1;
    bus.arready = 0;
    bus.rvalid = 0;
    bus.rid = 0;
    bus.rdata = 0;
    bus.rlast = 0;
    bus.rresp = 0;
    bus.awready = 0;
    bus.wready = 0;
    bus.bvalid = 0;
    bus.bid = 0;
    bus.bresp = 0;
    repeat (3) @(negedge clock);
    reset = 0;

    // Continuous competing requests alternate grants. Multiple core IDs remain
    // live simultaneously and may return out of order relative to SBA.
    core.arvalid = 1;
    sb.arvalid = 1;
    repeat (3) @(negedge clock);
    if (bus.arid != 15) $fatal(1, "initial fair read grant");
    bus.arready = 1;
    for (int i = 0; i < 6; i++) begin
      #1;
      if (bus.arid != (i[0] ? 8 : 15)) $fatal(1, "read starvation at %0d", i);
      @(negedge clock);
    end
    core.arid  = 4;
    sb.arvalid = 0;
    @(negedge clock);
    core.arvalid = 0;
    bus.arready  = 0;
    read_response(4);
    for (int i = 0; i < 3; i++) begin
      read_response(15);
      read_response(8, 0);
      read_response(8);
    end
    if (!idle) $fatal(1, "read count did not drain");

    // Once offered, a stalled core AR survives a reset request and a new SBA
    // contender. No new core AR may slip through after it finishes.
    core.arid = 1;
    core.arvalid = 1;
    repeat (2) @(negedge clock);
    block_core = 1;
    sb.arvalid = 1;
    #1;
    if (bus.arid != 1 || !bus.arvalid || idle) $fatal(1, "stalled AR lost on block");
    bus.arready = 1;
    @(negedge clock);
    core.arvalid = 0;
    @(negedge clock);
    sb.arvalid  = 0;
    bus.arready = 0;
    if (idle) $fatal(1, "reset allowed before core R");
    read_response(1);
    if (!idle) $fatal(1, "SBA must not hold core reset drain");
    read_response(15);
    block_core = 0;

    // W-before-AW on SBA, then AW-before-W on a core burst. A waiting master's
    // W must never cross the current owner's AW, including during reset drain.
    core.awvalid = 1;
    core.wvalid = 1;
    sb.awvalid = 1;
    sb.wvalid = 1;
    bus.wready = 1;
    @(negedge clock);
    sb.wvalid = 0;
    #1;
    if (!bus.awvalid || bus.awid != 15 || core.wready) $fatal(1, "W-before-AW owner");
    repeat (2) @(negedge clock);
    bus.awready = 1;
    @(negedge clock);
    sb.awvalid = 0;
    bus.wready = 0;
    @(negedge clock);
    core.awvalid = 0;
    bus.awready  = 0;
    block_core   = 1;
    if (idle) $fatal(1, "reset allowed with AW pending W/B");
    write_response(15);
    bus.wready = 1;
    for (int beat = 0; beat < 3; beat++) begin
      core.wdata = Xlen'(beat + 1);
      core.wlast = beat == 2;
      #1;
      if (!bus.wvalid || bus.wdata != Xlen'(beat + 1) || sb.wready)
        $fatal(1, "core burst W ownership");
      @(negedge clock);
    end
    core.wvalid = 0;
    bus.wready  = 0;
    if (idle) $fatal(1, "reset allowed before B");
    write_response(2);
    if (!idle) $fatal(1, "write count did not drain");
    block_core = 0;

    // Sustained AW/W contention, alternating complete single-beat writes.
    core.awlen = 0;
    core.wlast = 1;
    core.awvalid = 1;
    core.wvalid = 1;
    sb.awvalid = 1;
    sb.wvalid = 1;
    bus.awready = 1;
    bus.wready = 1;
    for (int i = 0; i < 6; i++) begin
      #1;
      if (bus.awid != (i[0] ? 2 : 15)) $fatal(1, "write starvation at %0d", i);
      @(negedge clock);
    end
    core.awvalid = 0;
    core.wvalid = 0;
    sb.awvalid = 0;
    sb.wvalid = 0;
    bus.awready = 0;
    bus.wready = 0;
    for (int i = 0; i < 3; i++) begin
      write_response(2);
      write_response(15);
    end
    if (!idle) $fatal(1, "final drain");
    $display("PASS: AXI debug arbitration RV%0d", Xlen);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
