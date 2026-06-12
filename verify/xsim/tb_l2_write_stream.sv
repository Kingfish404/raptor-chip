`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_write_stream;
  localparam int XLEN = 32;
  localparam int IdW = 4;

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
                                   input logic [IdW-1:0] id,
                                   input string msg);
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

    init_l2_axi(1'b0);
    tick(5);
    reset = 1'b0;
    tick(2);

    send_posted_write(32'h8000_0000, 32'h1111_0000, 4'h2, "first DDR write");
    send_posted_write(32'h8000_0004, 32'h2222_0000, 4'h2, "second DDR write");

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
    check(downstream_addr == 32'hf000_1000, "MMIO read addr mismatch after writes drained");

    $display("PASS: L2 posted write stream xsim checks passed");
    $finish;
  end
endmodule
