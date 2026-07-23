`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_ordered_mmio;
  localparam int XLEN = 32;
  localparam int IdW = 4;
  localparam int L2LineBeats = 1 << `RAPT_L2_LINE_LEN;

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
      .clock(clock),
      .reset(reset),
      .axi_s(axi_s),
      .axi_m(axi_m)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  task automatic expect_upstream_r(input logic [XLEN-1:0] data, input logic last,
                                   input string msg);
    bit seen;
    begin
      seen = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 32 && !seen; wait_cycle++) begin
        check(!axi_m.arvalid, {msg, ": L2 issued duplicate downstream AR"});
        if (axi_s.rvalid) begin
          check(axi_s.rdata == data, {msg, ": upstream rdata mismatch"});
          check(axi_s.rlast == last, {msg, ": upstream rlast mismatch"});
          tick(1);
          seen = 1'b1;
        end else begin
          tick(1);
        end
      end
      if (!seen) fail({msg, ": timed out waiting for upstream R"});
    end
  endtask

  task automatic expect_posted_b(input logic [IdW-1:0] id);
    bit seen;
    begin
      seen = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 64 && !seen; wait_cycle++) begin
        if (axi_s.bvalid) begin
          if (axi_s.bid !== id) fail("posted B id mismatch");
          if (axi_s.bresp !== 2'b00) fail("posted B resp mismatch");
          axi_s.bready = 1'b1;
          tick(1);
          axi_s.bready = 1'b0;
          seen = 1'b1;
        end else begin
          tick(1);
        end
      end
      if (!seen) fail("timed out waiting for posted B");
    end
  endtask

  task automatic send_posted_write(input logic [XLEN-1:0] addr,
                                   input logic [XLEN-1:0] data,
                                   input logic [IdW-1:0] id);
    begin
      send_l2_aw(addr, id);
      send_l2_w_full(data);
      expect_posted_b(id);
    end
  endtask

  initial begin
    logic [IdW-1:0] downstream_id;
    logic [XLEN-1:0] downstream_addr;
    logic [XLEN-1:0] downstream_data;
    logic [XLEN/8-1:0] downstream_strb;
    logic downstream_last;
    logic [7:0] downstream_len;

    init_l2_axi(1'b1);
    tick(5);
    reset = 1'b0;
    tick(2);

    send_l2_ar_len(32'h8000_2000, 4'h5, 8'd1, 2'b01);
    accept_l2_downstream_ar(downstream_id, downstream_addr, downstream_len);
    check(downstream_id == 4'h5, "cacheable burst miss changed downstream AR id");
    check(downstream_addr == 32'h8000_2000,
          "cacheable burst miss did not issue aligned line fill address");
    check(downstream_len == 8'(L2LineBeats - 1),
          "cacheable burst miss did not request a full L2 line");
    for (int beat = 0; beat < L2LineBeats; beat++) begin
      return_l2_downstream_r(4'h5, 32'ha500_0000 + XLEN'(beat), beat == (L2LineBeats - 1));
    end
    expect_upstream_r(32'ha500_0000, 1'b0, "cacheable burst miss first beat");
    expect_upstream_r(32'ha500_0001, 1'b1, "cacheable burst miss second beat");

    axi_s.bready = 1'b0;
    send_l2_aw(32'hf000_1800, 4'h1);
    send_l2_w(32'h0000_0041, 4'hf);
    tick(3);
    check(!axi_s.bvalid, "non-cacheable MMIO write produced posted upstream B");

    accept_l2_downstream_write(downstream_id, downstream_addr, downstream_data,
                  downstream_strb, downstream_last);
    check(downstream_id == 4'h1, "non-cacheable write id changed on downstream AW");
    tick(2);
    check(!axi_s.bvalid, "non-cacheable MMIO write B appeared before downstream B");
    return_l2_downstream_b(4'h1, 2'b00);
    check(axi_s.bvalid && axi_s.bid == 4'h1 && axi_s.bresp == 2'b00,
          "non-cacheable MMIO write did not forward downstream B");
    axi_s.bready = 1'b1;
    tick(1);

    axi_s.bready = 1'b0;
    send_l2_aw(32'h8000_1000, 4'h2);
    send_l2_w(32'hcafe_babe, 4'hf);
    tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'h2,
          "cacheable DDR write was not posted upstream");
    check(!axi_m.awvalid || !axi_m.awready,
          "testbench unexpectedly accepted posted write downstream early");
    axi_s.bready = 1'b1;
    tick(1);
    accept_l2_downstream_write(downstream_id, downstream_addr, downstream_data,
                  downstream_strb, downstream_last);
    return_l2_downstream_b(4'h2, 2'b00);
    tick(1);

    send_l2_aw(32'hf000_1800, 4'h3);
    send_l2_w(32'h0000_0042, 4'hf);
    send_l2_ar(32'hf000_1804, 4'h4);
    tick(3);
    check(!axi_m.arvalid, "non-cacheable read bypassed an older MMIO write");
    accept_l2_downstream_write(downstream_id, downstream_addr, downstream_data,
                  downstream_strb, downstream_last);
    return_l2_downstream_b(4'h3, 2'b00);
    tick(2);
    check(axi_m.arvalid && axi_m.araddr == 32'hf000_1804 && axi_m.arid == 4'h4,
          "non-cacheable read did not issue after older write drained");
        $display("PASS: L2 ordered-MMIO xsim checks passed");

        reset = 1'b1;
        init_l2_axi(1'b0);
        tick(2);
        reset = 1'b0;
        tick(2);

        send_posted_write(32'h8000_0000, 32'h1111_0000, 4'h2);
        send_posted_write(32'h8000_0004, 32'h2222_0000, 4'h2);

        axi_s.awaddr  = 32'h8000_0008;
        axi_s.awid    = 4'h2;
        axi_s.awlen   = 8'd0;
        axi_s.awsize  = 3'd2;
        axi_s.awburst = 2'b01;
        axi_s.awvalid = 1'b1;
        tick(4);
        check(!axi_s.awready, "third AW was accepted while both posted slots were full");

        accept_l2_downstream_write(downstream_id, downstream_addr, downstream_data,
          downstream_strb, downstream_last);
        check(downstream_id == 4'h2, "first downstream write id mismatch");
        check(downstream_addr == 32'h8000_0000, "first downstream write addr mismatch");
        check(downstream_data == 32'h1111_0000, "first downstream write data mismatch");
        check(downstream_strb == 4'hf, "first downstream write strobe mismatch");
        check(downstream_last, "first downstream write did not assert wlast");
        return_l2_downstream_b(4'h2, 2'b00);

        do @(posedge clock); while (!axi_s.awready);
        #1;
        axi_s.awvalid = 1'b0;
        send_l2_w_full(32'h3333_0000);
        expect_posted_b(4'h2);

        send_l2_ar(32'hf000_1000, 4'h4);
        tick(4);
        check(!axi_m.arvalid, "MMIO read bypassed posted DDR writes still draining");

        accept_l2_downstream_write(downstream_id, downstream_addr, downstream_data,
          downstream_strb, downstream_last);
        check(downstream_addr == 32'h8000_0004, "second downstream write addr mismatch");
        check(downstream_data == 32'h2222_0000, "second downstream write data mismatch");
        check(downstream_strb == 4'hf, "second downstream write strobe mismatch");
        check(downstream_last, "second downstream write did not assert wlast");
        return_l2_downstream_b(4'h2, 2'b00);
        tick(2);
        check(!axi_m.arvalid, "MMIO read issued before final posted write drained");

        accept_l2_downstream_write(downstream_id, downstream_addr, downstream_data,
          downstream_strb, downstream_last);
        check(downstream_addr == 32'h8000_0008, "third downstream write addr mismatch");
        check(downstream_data == 32'h3333_0000, "third downstream write data mismatch");
        check(downstream_strb == 4'hf, "third downstream write strobe mismatch");
        check(downstream_last, "third downstream write did not assert wlast");
        return_l2_downstream_b(4'h2, 2'b00);

        accept_l2_downstream_ar(downstream_id, downstream_addr, downstream_len);
        check(downstream_id == 4'h4, "MMIO read id mismatch after writes drained");
        check(downstream_addr == 32'hf000_1000,
          "MMIO read addr mismatch after writes drained");

        $display("PASS: L2 posted write stream xsim checks passed");
    $finish;
  end
endmodule
