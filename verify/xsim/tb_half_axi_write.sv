`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

module tb_half_axi_write;
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
  localparam int Bytes = XLEN / 8;
  int aw_count, w_count, b_count, total = 0;
  logic [XLEN-1:0] expected_addr, expected_data;
  logic [Bytes-1:0] expected_mask;
  always @(posedge clock) begin
    if (reset) begin
      aw_count<=0;
      w_count<=0;
      b_count<=0;
    end else begin
      if (axi.awvalid)
        check(axi.awaddr == expected_addr && axi.awsize == 1 && axi.awlen == 0 && axi.awid == 2,
              "half AW address/size/length/owner changed");
      if (axi.wvalid)
        check(axi.wdata == expected_data && axi.wstrb == expected_mask && axi.wlast,
              "half W payload/mask/last changed under backpressure");
      if (axi.awvalid && axi.awready) aw_count <= aw_count + 1;
      if (axi.wvalid && axi.wready) w_count <= w_count + 1;
      if (axi.bvalid && axi.bready) begin
        b_count<=b_count+1;
        total<=total+1;
      end
    end
  end
  initial begin
    for (int offset = 0; offset < Bytes; offset += 2)
    for (int order = 0; order < 3; order++)
    for (int late = 0; late < 2; late++)
    for (int response = 0; response < 3; response++) begin
      reset = 1;
      init_bus_inputs();
      expected_addr=XLEN'('h80002000)+XLEN'(offset);
      expected_data=XLEN'('h55aa)<<(8*offset);
      expected_mask=Bytes'(3)<<offset;
      tick(4);
      reset = 0;
      tick(1);
      l1d_bus.awaddr=expected_addr;
      l1d_bus.wdata=XLEN'('h55aa);
      l1d_bus.wstrb=3;
      l1d_bus.awvalid=1;
      l1d_bus.wvalid=1;
      for (int c = 0; c < 128 && (aw_count == 0 || w_count == 0); c++) begin
        axi.awready=c>=(order==0 ? 0 : order==1 ? 7 : 63);
        axi.wready=c>=(order==0 ? 7 : order==1 ? 0 : 63);
        #1;
        check(!l1d_bus.wready, "store completed before B response");
        tick(1);
      end
      check(aw_count == 1 && w_count == 1, "AW/W missing or repeated");
      axi.awready=0;
      axi.wready=0;
      repeat (late ? 7 : 0) begin
        check(!l1d_bus.wready && !axi.awvalid && !axi.wvalid,
              "write replayed or completed during delayed B");
        tick(1);
      end
      axi.bid=2;
      axi.bresp=response==0 ? 2'b00 : response==1 ? 2'b10 : 2'b11;
      axi.bvalid=1;
      #1;
      check(l1d_bus.wready && l1d_bus.werr == (response != 0), "B result not propagated to owner");
      tick(1);
      axi.bvalid=0;
      l1d_bus.awvalid=0;
      l1d_bus.wvalid=0;
      tick(4);
      check(aw_count == 1 && w_count == 1 && b_count == 1, "duplicate write/response handshake");
    end
    check(total == Bytes * 9, "incomplete half AXI transaction coverage");
    $display("PASS: half bus/AXI XLEN=%0d transactions=%0d", XLEN, total);
    $finish;
  end
endmodule
