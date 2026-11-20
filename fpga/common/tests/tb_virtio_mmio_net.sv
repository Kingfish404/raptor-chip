`timescale 1ns / 1ps
`include "native_ddr_model.svh"

module tb_virtio_mmio_net;
  localparam int X = `RAPT_XLEN;
  localparam int Bytes = X / 8;
  localparam int ByteBits = $clog2(Bytes);
  localparam logic [X-1:0] VnetBase = X'(64'h1000_2000);
  localparam logic [X-1:0] RamStart = X'(64'h8000_0000);

  logic clk = 0, reset = 1;
  always #5 clk = ~clk;

  axi4_if #(.XLEN(X)) cpu ();
  axi4_if #(.XLEN(X)) dma ();
  axi4_if #(.XLEN(X)) ddr ();

  logic vnet_req_valid, vnet_req_write, vnet_resp_valid, vnet_resp_err, vnet_irq;
  logic [11:0] vnet_req_addr;
  logic [1:0] vnet_req_size;
  logic [63:0] vnet_req_wdata, vnet_resp_rdata;
  logic [7:0] vnet_req_wstrb;

  logic [7:0] rx_tdata, tx_tdata;
  logic rx_tvalid, rx_tlast, rx_tready;
  logic tx_tvalid, tx_tlast, tx_tready;

  logic ext_wr_valid, ext_wr_pending;
  logic [X-1:0] ext_wr_first, ext_wr_last;
  int ext_wr_events = 0;

  always_ff @(posedge clk) begin
    if (!reset && ext_wr_valid) ext_wr_events <= ext_wr_events + 1;
  end

  rapt_virtio_mmio_net #(
      .XLEN(X)
  ) u_vnet (
      .clk(clk),
      .reset(reset),
      .link_up_i(1'b1),
      .req_valid_i(vnet_req_valid),
      .req_write_i(vnet_req_write),
      .req_addr_i(vnet_req_addr),
      .req_size_i(vnet_req_size),
      .req_wdata_i(vnet_req_wdata),
      .req_wstrb_i(vnet_req_wstrb),
      .resp_valid_o(vnet_resp_valid),
      .resp_rdata_o(vnet_resp_rdata),
      .resp_err_o(vnet_resp_err),
      .irq_o(vnet_irq),
      .dma(dma),
      .rx_axis_tdata_i(rx_tdata),
      .rx_axis_tvalid_i(rx_tvalid),
      .rx_axis_tlast_i(rx_tlast),
      .rx_axis_tready_o(rx_tready),
      .tx_axis_tdata_o(tx_tdata),
      .tx_axis_tvalid_o(tx_tvalid),
      .tx_axis_tlast_o(tx_tlast),
      .tx_axis_tready_i(tx_tready)
  );

  rapt_native_io_bus #(
      .XLEN(X),
      .WithDdr(`NATIVE_DDR),
      .WithPeripheral(0),
      .WithLocalVirtioNet(1),
      .WithQemuBridge(0),
      .RamBytes(131072),
      .RomFile("")
  ) u_bus (
      .clk(clk),
      .reset(reset),
      .uart_rx(1'b1),
      .uart_tx(),
      .uart_irq(),
      .peripheral_rd(),
      .peripheral_wr(),
      .peripheral_raddr(),
      .peripheral_waddr(),
      .peripheral_wdata(),
      .peripheral_wstrb(),
      .peripheral_rdata(32'd0),
      .vnet_req_valid_o(vnet_req_valid),
      .vnet_req_write_o(vnet_req_write),
      .vnet_req_addr_o(vnet_req_addr),
      .vnet_req_size_o(vnet_req_size),
      .vnet_req_wdata_o(vnet_req_wdata),
      .vnet_req_wstrb_o(vnet_req_wstrb),
      .vnet_resp_valid_i(vnet_resp_valid),
      .vnet_resp_rdata_i(vnet_resp_rdata),
      .vnet_resp_err_i(vnet_resp_err),
      .bridge_req_valid_o(),
      .bridge_req_write_o(),
      .bridge_req_addr_o(),
      .bridge_req_size_o(),
      .bridge_req_wdata_o(),
      .bridge_req_wstrb_o(),
      .bridge_resp_valid_i(1'b1),
      .bridge_resp_rdata_i(64'd0),
      .bridge_resp_err_i(1'b0),
      .external_write_valid_o(ext_wr_valid),
      .external_write_pending_o(ext_wr_pending),
      .external_write_first_o(ext_wr_first),
      .external_write_last_o(ext_wr_last),
      .idle_o(),
      .cpu(cpu),
      .dma(dma),
      .ddr(ddr)
  );

  native_ddr_model #(
      .XLEN(X)
  ) u_ddr (
      .clk(clk),
      .reset(reset),
      .axi(ddr)
  );

  task automatic axi_write(input logic [X-1:0] addr, input logic [2:0] size,
                           input logic [63:0] val);
    logic [ByteBits-1:0] off;
    int nbytes;
    bit aw_ok, w_ok;
    off = addr[ByteBits-1:0];
    nbytes = 1 << size;
    aw_ok = 0;
    w_ok = 0;
    @(negedge clk);
    cpu.awaddr  = addr;
    cpu.awid    = 4'd0;
    cpu.awlen   = 8'd0;
    cpu.awsize  = size;
    cpu.awburst = 2'b01;
    cpu.awcache = 4'b0000;
    cpu.awvalid = 1'b1;
    cpu.wdata   = X'(val) << (int'(off) * 8);
    cpu.wstrb   = Bytes'((1 << nbytes) - 1) << off;
    cpu.wlast   = 1'b1;
    cpu.wvalid  = 1'b1;
    cpu.bready  = 1'b1;
    while (!aw_ok || !w_ok) begin
      @(posedge clk);
      if (cpu.awvalid && cpu.awready) aw_ok = 1;
      if (cpu.wvalid && cpu.wready) w_ok = 1;
      @(negedge clk);
      if (aw_ok) cpu.awvalid = 1'b0;
      if (w_ok) cpu.wvalid = 1'b0;
    end
    while (1) begin
      @(posedge clk);
      if (cpu.bvalid && cpu.bready) begin
        if (cpu.bresp != 2'b00) $fatal(1, "AXI write error addr=%h resp=%0d", addr, cpu.bresp);
        break;
      end
    end
    @(negedge clk);
    cpu.bready = 1'b0;
  endtask

  task automatic axi_read(input logic [X-1:0] addr, input logic [2:0] size,
                          output logic [63:0] val);
    logic [ByteBits-1:0] off;
    off = addr[ByteBits-1:0];
    @(negedge clk);
    cpu.araddr  = addr;
    cpu.arid    = 4'd0;
    cpu.arlen   = 8'd0;
    cpu.arsize  = size;
    cpu.arburst = 2'b01;
    cpu.arcache = 4'b0000;
    cpu.arvalid = 1'b1;
    cpu.rready  = 1'b1;
    while (1) begin
      @(posedge clk);
      if (cpu.arvalid && cpu.arready) break;
    end
    @(negedge clk);
    cpu.arvalid = 1'b0;
    while (1) begin
      @(posedge clk);
      if (cpu.rvalid && cpu.rready) begin
        if (cpu.rresp != 2'b00) $fatal(1, "AXI read error addr=%h resp=%0d", addr, cpu.rresp);
        val = 64'(cpu.rdata >> (int'(off) * 8));
        break;
      end
    end
    @(negedge clk);
    cpu.rready = 1'b0;
  endtask

  task automatic write_desc(input logic [X-1:0] table_base, input int idx,
                            input logic [63:0] buf_addr, input logic [31:0] len,
                            input logic [15:0] flags, input logic [15:0] next_idx);
    logic [X-1:0] dbase;
    dbase = table_base + X'(idx * 16);
    axi_write(dbase + X'(0), 3'd2, {32'd0, buf_addr[31:0]});
    axi_write(dbase + X'(4), 3'd2, {32'd0, buf_addr[63:32]});
    axi_write(dbase + X'(8), 3'd2, {32'd0, len});
    axi_write(dbase + X'(12), 3'd2, {32'd0, next_idx, flags});
  endtask

  logic [7:0] captured_tx[0:255];
  int captured_tx_len = 0;
  logic captured_tx_done = 0;

  always_ff @(posedge clk) begin
    if (!reset && tx_tvalid && tx_tready) begin
      captured_tx[captured_tx_len] <= tx_tdata;
      captured_tx_len <= captured_tx_len + 1;
      if (tx_tlast) captured_tx_done <= 1'b1;
    end
  end

  initial begin
    #2_000_000;
    $fatal(1, "tb_virtio_mmio_net watchdog timeout");
  end

  initial begin
    logic [63:0] v;
    logic [X-1:0] rx_desc, rx_avail, rx_used, rx_buf;
    logic [X-1:0] tx_desc, tx_avail, tx_used, tx_hdr_buf, tx_pay_buf;

    cpu.arvalid = 0;
    cpu.rready  = 0;
    cpu.awvalid = 0;
    cpu.wvalid  = 0;
    cpu.bready  = 0;
    rx_tdata    = 8'h00;
    rx_tvalid   = 1'b0;
    rx_tlast    = 1'b0;
    tx_tready   = 1'b1;

    repeat (6) @(posedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // 1. Verify VirtIO 1.2 Modern header + features + MAC + status
    axi_read(VnetBase + X'('h000), 3'd2, v);
    if (v[31:0] != 32'h74726976) $fatal(1, "bad magic %h", v[31:0]);
    axi_read(VnetBase + X'('h004), 3'd2, v);
    if (v[31:0] != 32'd2) $fatal(1, "bad version %0d", v[31:0]);
    axi_read(VnetBase + X'('h008), 3'd2, v);
    if (v[31:0] != 32'd1) $fatal(1, "bad device id %0d", v[31:0]);

    axi_write(VnetBase + X'('h014), 3'd2, 64'd0);
    axi_read(VnetBase + X'('h010), 3'd2, v);
    if (v[31:0] != ((32'd1 << 5) | (32'd1 << 16))) $fatal(1, "bad feat0 %h", v[31:0]);

    axi_write(VnetBase + X'('h014), 3'd2, 64'd1);
    axi_read(VnetBase + X'('h010), 3'd2, v);
    if (v[31:0] != 32'h0000_0003) $fatal(1, "missing VERSION_1 | ACCESS_PLATFORM: %h", v[31:0]);

    axi_read(VnetBase + X'('h100), 3'd0, v);
    if (v[7:0] != 8'h02) $fatal(1, "bad MAC[0] %h", v[7:0]);
    axi_read(VnetBase + X'('h106), 3'd1, v);
    if (v[15:0] != 16'h0001) $fatal(1, "expected LINK_UP=1, got %h", v[15:0]);

    // 2. Configure RX (queue 0) and TX (queue 1) Split Virtqueues in RAM
    rx_desc  = RamStart + X'('h1000);
    rx_avail = RamStart + X'('h1400);
    rx_used  = RamStart + X'('h1800);
    rx_buf   = RamStart + X'('h2002);  // Intentionally 2-byte aligned (Linux NET_IP_ALIGN=2)

    tx_desc    = RamStart + X'('h3000);
    tx_avail   = RamStart + X'('h3400);
    tx_used    = RamStart + X'('h3800);
    tx_hdr_buf = RamStart + X'('h4000);
    tx_pay_buf = RamStart + X'('h4102);  // Odd halfword alignment + chained descriptor!

    // Zero avail/used headers
    axi_write(rx_avail, 3'd2, 64'd0);
    axi_write(rx_used, 3'd2, 64'd0);
    axi_write(tx_avail, 3'd2, 64'd0);
    axi_write(tx_used, 3'd2, 64'd0);

    // Program queue 0 (RX)
    axi_write(VnetBase + X'('h030), 3'd2, 64'd0);
    axi_write(VnetBase + X'('h038), 3'd2, 64'd8);
    axi_write(VnetBase + X'('h080), 3'd2, {32'd0, 32'(rx_desc)});
    axi_write(VnetBase + X'('h084), 3'd2, 64'd0);
    axi_write(VnetBase + X'('h090), 3'd2, {32'd0, 32'(rx_avail)});
    axi_write(VnetBase + X'('h094), 3'd2, 64'd0);
    axi_write(VnetBase + X'('h0a0), 3'd2, {32'd0, 32'(rx_used)});
    axi_write(VnetBase + X'('h0a4), 3'd2, 64'd0);
    axi_write(VnetBase + X'('h044), 3'd2, 64'd1);

    // Program queue 1 (TX)
    axi_write(VnetBase + X'('h030), 3'd2, 64'd1);
    axi_write(VnetBase + X'('h038), 3'd2, 64'd8);
    axi_write(VnetBase + X'('h080), 3'd2, {32'd0, 32'(tx_desc)});
    axi_write(VnetBase + X'('h084), 3'd2, 64'd0);
    axi_write(VnetBase + X'('h090), 3'd2, {32'd0, 32'(tx_avail)});
    axi_write(VnetBase + X'('h094), 3'd2, 64'd0);
    axi_write(VnetBase + X'('h0a0), 3'd2, {32'd0, 32'(tx_used)});
    axi_write(VnetBase + X'('h0a4), 3'd2, 64'd0);
    axi_write(VnetBase + X'('h044), 3'd2, 64'd1);

    // Set STATUS = ACKNOWLEDGE | DRIVER | FEATURES_OK | DRIVER_OK (0x0f)
    axi_write(VnetBase + X'('h070), 3'd2, 64'h0f);

    // 3. Test TX chained descriptor DMA (12B virtio_net_hdr_v1 in desc 0 -> 18B frame in desc 1)
    for (int i = 0; i < 12; i++) axi_write(tx_hdr_buf + X'(i), 3'd0, 64'd0);
    for (int i = 0; i < 18; i++) axi_write(tx_pay_buf + X'(i), 3'd0, 64'(8'ha0 + i));
    write_desc(tx_desc, 0, 64'(tx_hdr_buf), 32'd12, 16'h0001, 16'd1);  // NEXT -> 1
    write_desc(tx_desc, 1, 64'(tx_pay_buf), 32'd18, 16'h0000, 16'd0);
    axi_write(tx_avail + X'(4), 3'd1, 64'd0);  // avail.ring[0] = head 0
    axi_write(tx_avail + X'(2), 3'd1, 64'd1);  // avail.idx = 1
    axi_write(VnetBase + X'('h050), 3'd2, 64'd1);  // QUEUE_NOTIFY(1)

    begin
      int guard = 0;
      while (!vnet_irq && guard < 2000) begin
        @(posedge clk);
        guard++;
      end
      if (!vnet_irq || !captured_tx_done) $fatal(1, "TX DMA timeout irq=%0d", vnet_irq);
    end
    if (captured_tx_len != 18) $fatal(1, "TX len mismatch: %0d", captured_tx_len);
    for (int i = 0; i < 18; i++) begin
      if (captured_tx[i] != 8'(8'ha0 + i))
        $fatal(1, "TX byte[%0d] mismatch: got %h", i, captured_tx[i]);
    end
    axi_read(tx_used + X'(2), 3'd1, v);
    if (v[15:0] != 16'd1) $fatal(1, "TX used.idx mismatch: %0d", v[15:0]);
    // Clear interrupt
    axi_write(VnetBase + X'('h064), 3'd2, 64'd3);

    // 4. Test RX DMA (post 2-descriptor chain on queue 0, inject 20B Ethernet frame)
    write_desc(rx_desc, 0, 64'(rx_buf), 32'd16, 16'h0003, 16'd1);  // WRITE | NEXT
    write_desc(rx_desc, 1, 64'(rx_buf + X'(32)), 32'd64, 16'h0002, 16'd0);  // WRITE
    axi_write(rx_avail + X'(4), 3'd1, 64'd0);  // avail.ring[0] = 0
    axi_write(rx_avail + X'(2), 3'd1, 64'd1);  // avail.idx = 1

    for (int i = 0; i < 20; i++) begin
      @(negedge clk);
      rx_tdata  = 8'(8'h40 + i);
      rx_tvalid = 1'b1;
      rx_tlast  = (i == 19);
      while (1) begin
        @(posedge clk);
        if (rx_tvalid && rx_tready) break;
      end
    end
    @(negedge clk);
    rx_tvalid = 1'b0;
    rx_tlast  = 1'b0;

    begin
      int guard = 0;
      while (!vnet_irq && guard < 2000) begin
        @(posedge clk);
        guard++;
      end
      if (!vnet_irq) $fatal(1, "RX DMA timeout");
    end

    // Verify num_buffers=1 at header[10..11], first 4 frame bytes in desc 0, rest in desc 1
    axi_read(rx_buf + X'(10), 3'd1, v);
    if (v[15:0] != 16'd1) $fatal(1, "RX virtio_net_hdr num_buffers=%h", v[15:0]);
    for (int i = 0; i < 4; i++) begin
      axi_read(rx_buf + X'(12 + i), 3'd0, v);
      if (v[7:0] != 8'(8'h40 + i)) $fatal(1, "RX desc0 byte[%0d]=%h", i, v[7:0]);
    end
    for (int i = 4; i < 20; i++) begin
      axi_read(rx_buf + X'(28) + X'(i), 3'd0, v);
      if (v[7:0] != 8'(8'h40 + i)) $fatal(1, "RX desc1 byte[%0d]=%h", i, v[7:0]);
    end
    axi_read(rx_used + X'(2), 3'd1, v);
    if (v[15:0] != 16'd1) $fatal(1, "RX used.idx=%0d", v[15:0]);
    axi_read(rx_used + X'(8), 3'd2, v);
    if (v[31:0] != 32'd32) $fatal(1, "RX used.len=%0d expected 32", v[31:0]);
    if (ext_wr_events == 0) $fatal(1, "DMA writes did not assert external_write_valid_o");

    $display("PASS: tb_virtio_mmio_net (XLEN=%0d, ext_wr_events=%0d)", X, ext_wr_events);
    $finish;
  end
endmodule
