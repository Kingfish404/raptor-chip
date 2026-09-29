`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_pbmt_boom;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] HotLine = XLEN'('h80000100);
  localparam logic [XLEN-1:0] ColdLine = XLEN'('h80000200);
  logic clock = 0;
  logic reset = 1;
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_s ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_m ();
  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) dut (
      .clock,
      .reset,
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  task automatic read_hot(input logic [XLEN-1:0] expected);
    axi_s.rready = 0;
    send_l2_ar(HotLine, 4'h1);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'h1 && axi_s.rdata == expected && !axi_m.arvalid,
          "typed access changed a resident cacheable alias");
    axi_s.rready = 1;
    tick(1);
  endtask

  initial begin
    logic [IdW-1:0] id;
    logic [XLEN-1:0] addr, data;
    logic [7:0] len;
    logic [XLEN/8-1:0] strb;
    logic last;
    init_l2_axi(0);
    tick(5);
    reset = 0;
    for (int cycle = 0; cycle < 1200 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "BOOM L2 directory wipe timed out");

    send_l2_ar(HotLine, 4'h1);
    accept_l2_downstream_ar(id, addr, len);
    check(addr == HotLine && len == 8'(LineBeats - 1), "cacheable prime shape");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(id, XLEN'('h100 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "cacheable prime did not retire");

    // PBMT NC and IO reads keep their type and single-beat length on the
    // outer bus even when a cacheable alias of the same PA is resident.
    for (int typed = 0; typed < 2; typed++) begin
      logic [3:0] cache_attr;
      cache_attr = typed == 0 ? 4'h2 : 4'h0;
      axi_s.rready = 0;
      send_l2_ar(HotLine, 4'(typed + 4), cache_attr);
      for (int cycle = 0; cycle < 64 && !axi_m.arvalid; cycle++) tick(1);
      check(axi_m.arvalid && axi_m.arcache == cache_attr && axi_m.arlen == 0 && !axi_s.rvalid,
            "typed read hit cache or lost its outer attribute");
      accept_l2_downstream_ar(id, addr, len);
      check(addr == HotLine && len == 0 && id == 4'(typed + 4), "typed read outer shape");
      return_l2_downstream_r(id, XLEN'('h220 + typed), 1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(axi_s.rvalid && axi_s.rid == id && axi_s.rdata == XLEN'('h220 + typed),
            "typed read did not return outer data");
      axi_s.rready = 1;
      tick(1);
      read_hot(XLEN'('h100));
    end

    // A cold typed write forwards its AW/W/B and does not allocate an L2
    // line. The later cacheable read must still fetch a complete line.
    axi_s.bready = 0;
    send_l2_aw(ColdLine, 4'h8, 4'h2);
    send_l2_w_full(XLEN'('h3344));
    for (int cycle = 0; cycle < 64 && !axi_m.awvalid; cycle++) tick(1);
    check(axi_m.awvalid && axi_m.awcache == 4'h2 && !axi_s.bvalid,
          "typed write was posted or changed its outer attribute");
    accept_l2_downstream_write(id, addr, data, strb, last);
    check(id == 4'h8 && addr == ColdLine && data == XLEN'('h3344) && (&strb) && last,
          "typed write changed its outer payload");
    return_l2_downstream_b(id, 2'b00);
    check(axi_s.bvalid && axi_s.bid == id && axi_s.bresp == 0, "typed write lost the outer B");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    send_l2_ar(ColdLine, 4'h9);
    accept_l2_downstream_ar(id, addr, len);
    check(addr == ColdLine && len == 8'(LineBeats - 1), "cold typed write allocated a cache line");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(id, beat == 0 ? XLEN'('h3344) : XLEN'('h300 + beat),
                           beat == LineBeats - 1);

    // A failed typed write to a clean resident alias invalidates it, so a
    // possible partial outer side effect cannot be hidden by stale L2 data.
    axi_s.bready = 0;
    send_l2_aw(HotLine, 4'ha, 4'h0);
    send_l2_w_full(XLEN'('h5555));
    accept_l2_downstream_write(id, addr, data, strb, last);
    return_l2_downstream_b(id, 2'b10);
    check(axi_s.bvalid && axi_s.bresp == 2'b10, "typed write error was lost");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    send_l2_ar(HotLine, 4'hb);
    accept_l2_downstream_ar(id, addr, len);
    check(addr == HotLine && len == 8'(LineBeats - 1),
          "failed typed write left a stale cacheable alias");
    $display("PASS: BOOM L2 PBMT NC/IO bypass, forwarded B and alias invalidation RV%0d", XLEN);
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "BOOM L2 PBMT test watchdog");
  end
endmodule
