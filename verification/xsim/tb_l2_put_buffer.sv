`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_put_buffer;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int PutEntries = 40;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000100);

  logic clock = 1'b0;
  logic reset = 1'b1;
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

  initial begin
    logic [IdW-1:0] downstream_id;
    logic [XLEN-1:0] downstream_addr;
    logic [7:0] downstream_len;
    int unsigned next_descriptor;
    bit got_read;

    init_l2_axi(1'b0);
    tick(5);
    reset = 1'b0;
    for (int cycle = 0; cycle < (1 << `RAPT_L2_LEN) + 64 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "L2 directory reset wipe timed out");

    // Install one line so every queued store uses the local write-back path.
    send_l2_ar(LineAddr, 4'h1);
    accept_l2_downstream_ar(downstream_id, downstream_addr, downstream_len);
    check(downstream_addr == LineAddr && downstream_len == 8'(LineBeats - 1),
          "initial line refill used the wrong outer request");
    check(downstream_id == 4'd0, "normal L2 MSHR did not remap the outer AXI ID");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(downstream_id, XLEN'(beat), beat == LineBeats - 1);
    tick(5);

    // BOOM's default put buffer has 40 lists and 40 beats. Keep all AWs
    // resident before supplying W so the write-slot capacity is exercised.
    for (int entry = 0; entry < PutEntries; entry++) send_l2_aw(LineAddr, IdW'(entry));
    check(dut.put_list_claimed == '0, "AW claimed a Put list before its first W beat");
    axi_s.awaddr  = LineAddr;
    axi_s.awvalid = 1'b1;
    #1;
    check(!axi_s.awready, "41st AW bypassed the 40-entry write buffer");
    axi_s.awvalid = 1'b0;

    send_l2_w_full(XLEN'('hface0000));
    check(dut.wbuf[0].put_list == '0 && dut.put_list_claimed[0],
          "first W did not claim the lowest free Put list");
    send_l2_w_full(XLEN'('hface0001));
    check(dut.put_list_claimed[dut.wbuf[1].put_list], "second W did not claim a Put list");
    tick(4);
    check(!dut.wbuf[0].busy && !dut.wbuf[1].busy && dut.wbuf[2].busy,
          "first two writes did not drain ahead of queued AWs");
    check(dut.any_write_in_flight, "write-in-flight scan missed later buffer entries");
    // Reuse a freed AW slot before the B queue fills. Its W must wait once
    // the 40 older responses occupy every B slot.
    send_l2_aw(LineAddr, IdW'(PutEntries));
    // AR may be accepted early, but must wait for every older write before
    // it is issued on the outer AXI port.
    send_l2_ar_len(XLEN'('hf0001000), 4'h3, 8'd0, 2'b01, 4'h0);
    check(!axi_m.arvalid, "MMIO read issued before queued writes drained");

    for (int entry = 2; entry < PutEntries; entry++) begin
      send_l2_w_full(XLEN'('hface0000) + XLEN'(entry));
      check(!axi_m.arvalid, "MMIO read issued before the last queued write drained");
    end
    axi_s.wdata  = XLEN'('hface0000) + XLEN'(PutEntries);
    axi_s.wstrb  = '1;
    axi_s.wlast  = 1'b1;
    axi_s.wvalid = 1'b1;
    #1;
    check(!axi_s.wready, "pending W overran the full 40-entry B queue");
    axi_s.wvalid = 1'b0;
    axi_s.wstrb  = '0;

    check(axi_s.bvalid && axi_s.bid == 4'h0 && axi_s.bresp == 2'b00,
          "first B response was unavailable to release a queue credit");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    send_l2_w_full(XLEN'('hface0000) + XLEN'(PutEntries));
    tick(4);
    check(!axi_m.awvalid, "resident writes unexpectedly reached outer memory");
    accept_l2_downstream_ar(downstream_id, downstream_addr, downstream_len);
    check(downstream_id == 4'h3 && downstream_addr == XLEN'('hf0001000) && downstream_len == 8'd0,
          "deferred MMIO read used the wrong outer request");
    return_l2_downstream_r(4'h3, XLEN'('h1234), 1'b1);
    tick(3);
    check(dut.b_count == PutEntries, "write response queue did not hold 40 entries");
    axi_s.awaddr  = LineAddr;
    axi_s.awvalid = 1'b1;
    #1;
    check(!axi_s.awready, "41st AW bypassed the full response queue");
    axi_s.awvalid = 1'b0;

    axi_s.bready  = 1'b1;
    for (int entry = 1; entry <= PutEntries; entry++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) tick(1);
      check(axi_s.bvalid && axi_s.bid == IdW'(entry) && axi_s.bresp == 2'b00, $sformatf(
            "write response %0d lost its ordering or ID", entry));
      tick(1);
    end
    axi_s.bready = 1'b0;
    check(dut.b_count == 0, "write response queue did not drain");
    check(dut.put_list_claimed == '0, "completed stores did not free their Put lists");

    // The descriptor ring has wrapped to slot 1, while BOOM's list
    // allocator starts again from the lowest free index, list 0.
    next_descriptor = int'(dut.aw_wptr);
    check(next_descriptor != 0, "descriptor ring did not advance past list 0");
    send_l2_aw(LineAddr, 4'hd);
    check(dut.put_list_claimed == '0, "later AW claimed a Put list before W");
    send_l2_w_full(XLEN'('hface0000) + XLEN'(PutEntries));
    check(dut.wbuf[next_descriptor].put_list == '0 && dut.put_list_claimed[0],
          "new W did not claim the lowest free Put list");
    for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'hd && axi_s.bresp == 2'b00,
          "reused Put list lost its ordered response");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    tick(4);

    send_l2_ar(LineAddr, 4'h2);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_read; cycle++) begin
      check(!axi_m.arvalid, "resident line was refetched after queued writes");
      if (axi_s.rvalid) begin
        check(axi_s.rdata == XLEN'('hface0000) + XLEN'(PutEntries) && axi_s.rresp == 2'b00,
              "last queued store did not update the resident word");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "resident read timed out after queued writes");
    $display("PASS: BOOM-size L2 put buffer holds and drains 40 ordered stores");
    $finish;
  end
endmodule
