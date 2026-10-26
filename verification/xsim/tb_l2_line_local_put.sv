`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_line_local_put;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000200);
  localparam logic [XLEN-1:0] ErrorAddr = XLEN'('h80000300);
  localparam logic [XLEN-1:0] NarrowMissAddr = XLEN'('h80000400);
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
      .cbo_inval_i(1'b0),
      .cbo_block_i('0),
      .probe_ready_i(1'b1),
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  task automatic read_resident(input int word, input logic [XLEN-1:0] expected);
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr + XLEN'(word * (XLEN / 8)), 4'h3);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && !axi_m.arvalid && axi_s.rdata == expected && axi_s.rresp == 2'b00,
          $sformatf(
          "line-local Put readback word %0d got %h expected %h", word, axi_s.rdata, expected));
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
  endtask

  task automatic write_resident_shape(input logic [XLEN-1:0] addr, input logic [IdW-1:0] id,
                                      input logic [7:0] len, input logic [2:0] size,
                                      input logic [1:0] burst, input int shape);
    bit accepted;
    axi_s.awaddr = addr;
    axi_s.awid = id;
    axi_s.awlen = len;
    axi_s.awsize = size;
    axi_s.awburst = burst;
    axi_s.awcache = 4'hf;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "resident burst shape did not allocate locally");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat <= int'(len); beat++) begin
      case (shape)
        0: begin  // FIXED: two different bytes of the same word.
          axi_s.wdata = beat == 0 ? XLEN'('h55) : XLEN'('h6600);
          axi_s.wstrb = (XLEN / 8)'(1 << beat);
        end
        1: begin  // WRAP: word 7, then words 4, 5, 6.
          axi_s.wdata = XLEN'(beat == 0 ? 'h700 : 'h3ff + beat);
          axi_s.wstrb = '1;
        end
        default: begin  // Narrow INCR: four bytes of word 2.
          axi_s.wdata = XLEN'(((beat + 1) * 'h11) << (8 * beat));
          axi_s.wstrb = (XLEN / 8)'(1 << beat);
        end
      endcase
      axi_s.wlast = beat == int'(len);
      axi_s.wvalid = 1;
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "resident shaped Put W stalled");
      #1;
      axi_s.wvalid = 0;
    end
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      check(!axi_m.awvalid && !axi_m.arvalid, "resident shaped Put reached outer memory");
      tick(1);
    end
    check(axi_s.bvalid && axi_s.bid == id && axi_s.bresp == 2'b00,
          "resident shaped Put returned the wrong local B");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
  endtask

  initial begin
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
    logic [7:0] outer_len;
    bit accepted;
    init_l2_axi(0);
    tick(5);
    reset = 0;
    for (int cycle = 0; cycle < 1200 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "directory wipe timed out");

    // Two partial beats start at word one. BOOM's local Put policy fetches
    // the untouched words, merges the masks, and returns a local B.
    axi_s.awaddr = LineAddr + XLEN'(XLEN / 8);
    axi_s.awid = 4'h2;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'hf;
    axi_s.awvalid = 1'b1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "short cacheable Put was not allocated");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata = beat == 0 ? XLEN'('haa) : XLEN'('hbeef);
      axi_s.wstrb = beat == 0 ? (XLEN / 8)'(1) : '1;
      axi_s.wlast = beat == 1;
      axi_s.wvalid = 1;
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "short Put W stalled");
      #1;
      axi_s.wvalid = 0;
    end
    check(!axi_m.awvalid, "short allocated Put wrote through to memory");
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr && outer_len == 8'(LineBeats - 1),
          "short Put refill was not line aligned");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h100 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      check(!axi_m.awvalid, "short allocated Put issued an outer write");
      tick(1);
    end
    check(axi_s.bvalid && axi_s.bid == 4'h2 && axi_s.bresp == 2'b00,
          "short allocated Put did not return a local B");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    read_resident(0, XLEN'('h100));
    read_resident(1, XLEN'('h1aa));
    read_resident(2, XLEN'('hbeef));
    read_resident(3, XLEN'('h103));

    write_resident_shape(LineAddr + XLEN'(4 * (XLEN / 8)), 4'h6, 8'd1, 3'($clog2(XLEN / 8)), 2'b00,
                         0);
    read_resident(4, XLEN'('h6655));
    write_resident_shape(LineAddr + XLEN'(7 * (XLEN / 8)), 4'h7, 8'd3, 3'($clog2(XLEN / 8)), 2'b10,
                         1);
    read_resident(7, XLEN'('h700));
    read_resident(4, XLEN'('h400));
    read_resident(5, XLEN'('h401));
    read_resident(6, XLEN'('h402));
    write_resident_shape(LineAddr + XLEN'(2 * (XLEN / 8)), 4'h8, 8'd3, 3'd0, 2'b01, 2);
    read_resident(2, XLEN'('h44332211));

    // A narrow miss must accumulate all four byte lanes before it merges
    // them with the fetched word. Each Put beat addresses the same word.
    axi_s.awaddr = NarrowMissAddr + XLEN'(2 * (XLEN / 8));
    axi_s.awid = 4'h9;
    axi_s.awlen = 8'd3;
    axi_s.awsize = 3'd0;
    axi_s.awburst = 2'b01;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "narrow miss was not allocated locally");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat < 4; beat++) begin
      axi_s.wdata = XLEN'(((beat + 1) * 'h11) << (8 * beat));
      axi_s.wstrb = (XLEN / 8)'(1 << beat);
      axi_s.wlast = beat == 3;
      axi_s.wvalid = 1;
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "narrow miss Put W stalled");
      #1;
      axi_s.wvalid = 0;
    end
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == NarrowMissAddr && outer_len == 8'(LineBeats - 1),
          "narrow miss refill was not line aligned");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h300 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'h9 && axi_s.bresp == 2'b00 && !axi_m.awvalid,
          "narrow miss did not return a local B");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    axi_s.rready = 0;
    send_l2_ar(NarrowMissAddr + XLEN'(2 * (XLEN / 8)), 4'ha);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && !axi_m.arvalid && axi_s.rdata == XLEN'('h44332211),
          "narrow miss lost one or more Put byte lanes");
    axi_s.rready = 1;
    tick(1);
    axi_s.rready = 0;

    // A failed refill must return an error B and leave the target uncached.
    axi_s.awaddr = ErrorAddr + XLEN'(XLEN / 8);
    axi_s.awid = 4'h4;
    axi_s.awlen = 8'd1;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "error-case short Put was not allocated");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata = XLEN'('hcafe + beat);
      axi_s.wstrb = '1;
      axi_s.wlast = beat == 1;
      axi_s.wvalid = 1;
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "error-case short Put W stalled");
      #1;
      axi_s.wvalid = 0;
    end
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ErrorAddr && outer_len == 8'(LineBeats - 1),
          "error-case short Put refill shape changed");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h200 + beat), beat == LineBeats - 1,
                           beat == LineBeats - 1 ? 2'b10 : 2'b00);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'h4 && axi_s.bresp == 2'b10 && !axi_m.awvalid,
          "failed short Put returned the wrong B or wrote through");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    send_l2_ar(ErrorAddr + XLEN'(XLEN / 8), 4'h5);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ErrorAddr && outer_len == 8'(LineBeats - 1),
          "failed short Put left speculative data resident");
    $display("PASS: line-local INCR/FIXED/WRAP/narrow Put and error XLEN=%0d", XLEN);
    $finish;
  end
endmodule
