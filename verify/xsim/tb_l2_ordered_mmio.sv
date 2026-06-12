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
    begin
      for (int wait_cycle = 0; wait_cycle < 32; wait_cycle++) begin
        check(!axi_m.arvalid, {msg, ": L2 issued duplicate downstream AR"});
        if (axi_s.rvalid) begin
          check(axi_s.rdata == data, {msg, ": upstream rdata mismatch"});
          check(axi_s.rlast == last, {msg, ": upstream rlast mismatch"});
          tick(1);
          return;
        end
        tick(1);
      end
      fail({msg, ": timed out waiting for upstream R"});
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
    $finish;
  end
endmodule
