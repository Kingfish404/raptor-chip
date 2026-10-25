`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_chip_router_early_write #(
    parameter int WriteOutstanding = 4
);
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  axi4_if core_axi (), offchip_axi ();
  clint_bus_if clint_bus ();
  plic_bus_if plic_bus ();
  rapt_router #(.WriteOutstanding(WriteOutstanding)) dut (.*);
  `include "tb_common.svh"
  assign clint_bus.rdata='0;
  assign plic_bus.rdata='0;

  task automatic write_case(input int aw_delay, input int w_delay, input logic [1:0] response);
    bit aw_done, w_done;
    int aw_count, w_count;
    aw_done=0;
    w_done=0;
    aw_count=0;
    w_count=0;
    @(negedge clock);
    core_axi.awaddr=XLEN'('h80001000);
    core_axi.awid=7;
    core_axi.awlen=0;
    core_axi.awsize=3'($clog2(XLEN/8));
    core_axi.awburst=1;
    core_axi.awcache=4'he;
    core_axi.awvalid=1;
    core_axi.wdata=XLEN'('h12345678);
    core_axi.wstrb='1;
    core_axi.wlast=1;
    core_axi.wvalid=1;
    for (int cycle = 0; cycle < 20 && !(aw_done && w_done); cycle++) begin
      offchip_axi.awready=cycle>=aw_delay;
      offchip_axi.wready=cycle>=w_delay;
      @(posedge clock);
      if (core_axi.awvalid && core_axi.awready) begin
        aw_done = 1;
        aw_count++;
      end
      if (core_axi.wvalid && core_axi.wready) begin
        w_done = 1;
        w_count++;
      end
      #1;
      if (aw_done) core_axi.awvalid = 0;
      if (w_done) core_axi.wvalid = 0;
      @(negedge clock);
    end
    check(aw_count == 1 && w_count == 1, "AW/W not accepted exactly once");
    offchip_axi.awready=0;
    offchip_axi.wready=0;
    offchip_axi.bid=7;
    offchip_axi.bresp=response;
    offchip_axi.bvalid=1;
    #1;
    repeat (4) begin
      check(core_axi.bvalid && core_axi.bid == 7 && core_axi.bresp == response,
            "B response lost after independent AW/W handshakes");
      check(!offchip_axi.bready, "B consumed while upstream stalled");
      tick(1);
    end
    core_axi.bready = 1;
    #1;
    check(offchip_axi.bready, "B ready not forwarded");
    tick(1);
    core_axi.bready=0;
    offchip_axi.bvalid=0;
    tick(2);
  endtask
  task automatic pipelined_writes;
    // Four AW/W pairs must leave before the first B. IDs and errors remain
    // owned by the offchip path even while the next pair is being offered.
    for (int i = 0; i < WriteOutstanding; i++) begin
      core_axi.awaddr=XLEN'('h80001000+i*64);
      core_axi.awid=4'(i+1);
      core_axi.awvalid=1;
      core_axi.wvalid=1;
      core_axi.wlast=1;
      offchip_axi.awready=1;
      offchip_axi.wready=1;
      #1;
      check(core_axi.awready && core_axi.wready && offchip_axi.awvalid && offchip_axi.wvalid,
            "router serialized offchip AW/W on B");
      tick(1);
      core_axi.awvalid=0;
      core_axi.wvalid=0;
      tick(1);
    end
    // Internal requests cannot bypass pending DDR completion. An internal
    // read may have side effects (PLIC claim), so AR also waits for B drain.
    core_axi.awaddr=XLEN'('h02000000);
    core_axi.awvalid=1;
    core_axi.wvalid=1;
    core_axi.araddr=XLEN'('h0c200004);
    core_axi.arvalid=1;
    repeat (3) begin
      #1;
      check(
          !core_axi.awready && !core_axi.wready && !core_axi.arready
            && !plic_bus.ar_commit && !clint_bus.wvalid,
          "internal MMIO bypassed pending offchip B");
      tick(1);
    end
    core_axi.arvalid=0;
    core_axi.awaddr=XLEN'('h80002000);
    core_axi.awid=9;
    #1;
    check(!core_axi.awready && !core_axi.wready && !offchip_axi.awvalid && !offchip_axi.wvalid,
          "full router window accepted extra AW/W");
    offchip_axi.bid=1;
    offchip_axi.bresp=2;
    offchip_axi.bvalid=1;
    repeat (3) begin
      #1;
      check(core_axi.bvalid && core_axi.bid == 1 && core_axi.bresp == 2 && !offchip_axi.bready,
            "stalled posted B lost ID/error");
      tick(1);
    end
    core_axi.bready = 1;
    tick(1);
    offchip_axi.bvalid = 0;
    #1;
    check(core_axi.awready && core_axi.wready, "B did not release write capacity");
    // The replacement request refills the vacated slot.
    tick(1);
    core_axi.awvalid=0;
    core_axi.wvalid=0;
    for (int i = 1; i < WriteOutstanding + 1; i++) begin
      offchip_axi.bvalid=1;
      offchip_axi.bid=i==WriteOutstanding ? 4'd9 : 4'(i+1);
      offchip_axi.bresp=2'(i);
      #1;
      check(
          core_axi.bvalid && core_axi.bid==offchip_axi.bid
            && core_axi.bresp==offchip_axi.bresp && offchip_axi.bready,
          "posted B route lost response ownership");
      tick(1);
    end
    offchip_axi.bvalid=0;
    // Simultaneous issue/retire must neither lose nor duplicate the remaining
    // response owner. Keep a two-beat payload attached to its AW throughout.
    core_axi.awvalid=1;
    core_axi.awid=10;
    core_axi.awlen=1;
    core_axi.wvalid=1;
    core_axi.wlast=0;
    tick(1);
    core_axi.awvalid = 0;
    #1;
    check(!core_axi.awready && core_axi.wready, "burst W owner released before WLAST");
    core_axi.wlast = 1;
    tick(1);
    core_axi.awvalid=1;
    core_axi.awid=11;
    core_axi.awlen=0;
    offchip_axi.bvalid=1;
    offchip_axi.bid=10;
    offchip_axi.bresp=0;
    #1;
    check(core_axi.awready && core_axi.wready && core_axi.bvalid && core_axi.bid == 10,
          "router cannot issue and retire together");
    tick(1);
    core_axi.awvalid=0;
    core_axi.wvalid=0;
    offchip_axi.bid=11;
    offchip_axi.bresp=3;
    #1;
    check(core_axi.bvalid && core_axi.bid == 11 && core_axi.bresp == 3,
          "simultaneous issue/retire lost final B");
    tick(1);
    offchip_axi.bvalid=0;
    core_axi.bready=0;
    core_axi.awaddr=XLEN'('h02000000);
    core_axi.awid=12;
    core_axi.awvalid=1;
    core_axi.araddr=XLEN'('h0c200004);
    core_axi.arid=11;
    core_axi.arvalid=1;
    core_axi.rready=1;
    #1;
    check(core_axi.awready && core_axi.arready && plic_bus.ar_commit,
          "internal MMIO did not resume after B drain");
    tick(1);
    core_axi.awvalid=0;
    core_axi.arvalid=0;
    core_axi.wvalid=1;
    #1;
    check(core_axi.wready && clint_bus.wvalid, "internal write lost ownership after drain");
    tick(1);
    core_axi.wvalid = 0;
    #1;
    check(core_axi.bvalid && core_axi.bid == 12 && core_axi.bresp == 0,
          "internal B mixed with offchip responses");
    core_axi.bready = 1;
    tick(1);
    core_axi.bready=0;
    core_axi.rready=0;
  endtask
  initial begin
    core_axi.arvalid=0;
    core_axi.rready=0;
    core_axi.awvalid=0;
    core_axi.wvalid=0;
    core_axi.bready=0;
    offchip_axi.arready=0;
    offchip_axi.rvalid=0;
    offchip_axi.rid=0;
    offchip_axi.rdata=0;
    offchip_axi.rlast=0;
    offchip_axi.rresp=0;
    offchip_axi.awready=0;
    offchip_axi.wready=0;
    offchip_axi.bvalid=0;
    offchip_axi.bid=0;
    offchip_axi.bresp=0;
    tick(4);
    reset = 0;
    tick(2);
    write_case(7, 0, 0);
    write_case(0, 7, 2);
    write_case(0, 0, 0);
    write_case(3, 1, 3);
    if (WriteOutstanding > 1) pipelined_writes();
    $display(
        "PASS: router independent AW/W, B ownership, capacity, bursts and MMIO drain RV%0d depth%0d",
        XLEN, WriteOutstanding);
    $finish;
  end
endmodule
