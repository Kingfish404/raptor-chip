`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_flush_ordered;
  localparam int XLEN = 32;
  localparam logic [31:0] CacheAddr = 32'h8000_0000;
  localparam logic [31:0] MmioAddr = 32'h1000_0000;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_accept;

  cmu_bcast_if cmu_bcast();
  lsu_l1d_if lsu_l1d();
  l1d_bus_if l1d_bus();
  csr_bcast_if csr_bcast();
  exu_l1d_if exu_l1d();
  rou_cmu_if rou_cmu();

  rapt_l1d dut (
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
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
        check(exu_l1d.reservation == CacheAddr + 32'h40,
          "LR cache hit reserved the wrong address");
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
