`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

module tb_bus_pbmt;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW  = 4;

  logic clock = 1'b0;
  logic reset = 1'b1;

  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi ();
  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) mem ();

  l1i_bus_if #(.XLEN(XLEN)) l1i_bus ();
  l1d_bus_if #(.XLEN(XLEN)) l1d_bus ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();

  rapt_bus #(
      .XLEN(XLEN)
  ) dut (
      .clock(clock),
      .mem(mem),
      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),
      .reset(reset)
  );

  rapt_axi_master #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) adapter (
      .clock(clock),
      .reset(reset),
      .mem(mem),
      .axi(axi)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_bus_defaults.svh"
  task automatic read_case(input bit instruction, input bit ptw, input int attr);
    logic [3:0] expected, owner;
    expected = ptw || attr == 0 ? 4'hf : attr == 1 ? 4'h2 : 4'h0;
    owner = instruction ? (ptw ? 3 : 1) : (ptw ? 4 : 2);
    axi.arready = 0;
    if (instruction) begin
      l1i_bus.araddr = 'h80000000;
      l1i_bus.rpbmt = 2'(attr);
      l1i_bus.ar_ptw = ptw;
      l1i_bus.arvalid = 1;
    end else begin
      l1d_bus.araddr = 'h80000000;
      l1d_bus.rpbmt = 2'(attr);
      l1d_bus.ar_ptw = ptw;
      l1d_bus.arvalid = 1;
    end
    #1;
    check(instruction ? l1i_bus.rready : l1d_bus.rready, "read slot not accepted");
    tick(1);
    l1i_bus.arvalid = 0;
    l1d_bus.arvalid = 0;
    l1i_bus.rpbmt = 3;
    l1d_bus.rpbmt = 3;
    tick(2);
    repeat (5) begin
      check(axi.arvalid && axi.arcache == expected && axi.arid == owner && axi.araddr == 'h80000000,
            "read skid lost attribute or owner");
      tick(1);
    end
    axi.arready = 1;
    tick(1);
    axi.arready = 0;
    axi.rid = owner;
    axi.rlast = 1;
    axi.rvalid = 1;
    #1;
    check(
        instruction ? (ptw ? l1i_bus.ptw_rvalid : l1i_bus.rvalid)
                       : (ptw ? l1d_bus.ptw_rvalid : l1d_bus.rvalid),
        "response owner lost");
    tick(1);
    axi.rvalid = 0;
    tick(2);
  endtask
  task automatic write_case(input int attr, input bit data_first);
    logic [3:0] expected;
    // Cacheable core writes retain allocation but cannot be acknowledged
    // by an intermediate buffer: downstream errors belong to this owner.
    expected = attr == 0 ? 4'he : attr == 1 ? 4'h2 : 4'h0;
    l1d_bus.awaddr = 'h80000000;
    l1d_bus.wdata = 'h12345678;
    l1d_bus.wstrb = 8'h0f;
    l1d_bus.wpbmt = 2'(attr);
    l1d_bus.awvalid = 1;
    l1d_bus.wvalid = 1;
    tick(1);
    repeat (5) begin
      check(axi.awvalid && axi.awcache == expected && axi.awaddr == 'h80000000,
            "write attribute not captured or unstable under backpressure");
      check(!l1d_bus.wready, "write completed before downstream B");
      check(!l1d_bus.idle, "bus advertised idle while an older write awaited B");
      tick(1);
    end
    if (data_first) axi.wready = 1;
    else axi.awready = 1;
    tick(1);
    axi.wready = 0;
    axi.awready = 0;
    repeat (3) begin
      check(!l1d_bus.wready, "partial AW/W handshake completed store");
      check(!l1d_bus.idle, "partial AW/W handshake advertised memory idle");
      check(axi.awcache == expected, "AW/W split lost attribute");
      tick(1);
    end
    if (data_first) axi.awready = 1;
    else axi.wready = 1;
    tick(1);
    axi.wready = 0;
    axi.awready = 0;
    tick(3);
    axi.bid = 2;
    axi.bvalid = 1;
    #1;
    check(l1d_bus.wready, "downstream B did not complete store");
    tick(1);
    axi.bvalid = 0;
    l1d_bus.awvalid = 0;
    l1d_bus.wvalid = 0;
    tick(2);
  endtask
  task automatic concurrent_reads;
    axi.arready = 0;
    l1i_bus.araddr = 'h80001000;
    l1i_bus.ar_ptw = 0;
    l1i_bus.rpbmt = 2;
    l1i_bus.arvalid = 1;
    tick(1);
    l1i_bus.arvalid = 0;
    tick(2);
    l1d_bus.araddr = 'h80002000;
    l1d_bus.ar_ptw = 0;
    l1d_bus.rpbmt = 1;
    l1d_bus.arvalid = 1;
    tick(1);
    l1d_bus.arvalid = 0;
    tick(3);
    check(axi.arvalid && axi.arid == 1 && axi.arcache == 0,
          "younger L1D replaced stalled I-side attributes");
    axi.arready = 1;
    tick(1);
    check(axi.arvalid && axi.arid == 2 && axi.arcache == 2,
          "second read inherited first request attributes");
    tick(1);
    axi.arready = 0;
    // Different IDs may return out of order.
    axi.rlast = 1;
    axi.rvalid = 1;
    axi.rid = 2;
    #1;
    check(l1d_bus.rvalid && !l1i_bus.rvalid, "reverse response lost D owner");
    tick(1);
    axi.rid = 1;
    #1;
    check(l1i_bus.rvalid && !l1d_bus.rvalid, "reverse response lost I owner");
    tick(1);
    axi.rvalid = 0;
    tick(2);
  endtask
  initial begin
    init_bus_inputs();
    tick(4);
    reset = 0;
    tick(1);
    concurrent_reads();
    for (int attr = 0; attr < 3; attr++) begin
      read_case(0, 0, attr);
      read_case(1, 0, attr);
      write_case(attr, 0);
      write_case(attr, 1);
    end
    read_case(0, 1, 2);
    read_case(1, 1, 2);
    $display("PASS: bus/AXI PBMT ownership, skid holding, AW/W backpressure and PTW PMA override");
    $finish;
  end
endmodule
