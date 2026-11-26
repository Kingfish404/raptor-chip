// Self-checking Verilator testbench for rapt_eth_axi_dma (AXI4 Ring DMA).
module tb_eth_axi_dma;
  logic clk;
  logic reset;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  logic rd, wr;
  logic [15:0] raddr, waddr;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic irq, enabled;
  logic [2:0] mdio_control;
  logic mdio_input;

  // Loopback MAC TX (8b) -> rapt_eth_stream32_adapter (32b) -> MAC RX (8b)
  logic [7:0] mac_tx_data, mac_rx_data;
  logic mac_tx_valid, mac_tx_last, mac_tx_ready;
  logic mac_rx_valid, mac_rx_last, mac_rx_ready;
  logic [31:0] s32_data;
  logic [3:0] s32_last_be;
  logic s32_valid, s32_last, s32_ready;

  rapt_eth_stream32_adapter u_stream32 (
      .clk,
      .reset,
      .rx32_data(s32_data),
      .rx32_last_be(s32_last_be),
      .rx32_valid(s32_valid),
      .rx32_last(s32_last),
      .rx32_ready(s32_ready),
      .rx8_data(mac_rx_data),
      .rx8_valid(mac_rx_valid),
      .rx8_last(mac_rx_last),
      .rx8_ready(mac_rx_ready),
      .tx8_data(mac_tx_data),
      .tx8_valid(mac_tx_valid),
      .tx8_last(mac_tx_last),
      .tx8_ready(mac_tx_ready),
      .tx32_data(s32_data),
      .tx32_last_be(s32_last_be),
      .tx32_valid(s32_valid),
      .tx32_last(s32_last),
      .tx32_ready(s32_ready)
  );

  // 64-bit AXI4 memory model (64 KiB at 0x8000_0000..0x8000_FFFF)
  logic [3:0] awid, arid, bid, rid;
  logic [63:0] awaddr, araddr, wdata_axi, rdata_axi;
  logic [7:0] awlen, arlen, wstrb_axi;
  logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst, bresp, rresp;
  logic [3:0] awcache, arcache;
  logic awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rlast, rvalid, rready;
  logic ext_wr_valid;
  logic [63:0] ext_wr_first, ext_wr_last;

  rapt_eth_axi_dma dut (
      .clk,
      .reset,
      .clocks_ready(1'b1),
      .rd,
      .wr,
      .raddr,
      .waddr,
      .wdata,
      .wstrb,
      .rdata,
      .irq,
      .enabled,
      .mdio_control,
      .mdio_input,
      .mac_rx_data(mac_rx_data),
      .mac_rx_valid(mac_rx_valid),
      .mac_rx_last(mac_rx_last),
      .mac_rx_error(1'b0),
      .mac_rx_ready(mac_rx_ready),
      .mac_tx_data(mac_tx_data),
      .mac_tx_valid(mac_tx_valid),
      .mac_tx_last(mac_tx_last),
      .mac_tx_ready(mac_tx_ready),
      .m_axi_awid(awid),
      .m_axi_awaddr(awaddr),
      .m_axi_awlen(awlen),
      .m_axi_awsize(awsize),
      .m_axi_awburst(awburst),
      .m_axi_awcache(awcache),
      .m_axi_awvalid(awvalid),
      .m_axi_awready(awready),
      .m_axi_wdata(wdata_axi),
      .m_axi_wstrb(wstrb_axi),
      .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid),
      .m_axi_wready(wready),
      .m_axi_bid(bid),
      .m_axi_bresp(bresp),
      .m_axi_bvalid(bvalid),
      .m_axi_bready(bready),
      .m_axi_arid(arid),
      .m_axi_araddr(araddr),
      .m_axi_arlen(arlen),
      .m_axi_arsize(arsize),
      .m_axi_arburst(arburst),
      .m_axi_arcache(arcache),
      .m_axi_arvalid(arvalid),
      .m_axi_arready(arready),
      .m_axi_rid(rid),
      .m_axi_rdata(rdata_axi),
      .m_axi_rresp(rresp),
      .m_axi_rlast(rlast),
      .m_axi_rvalid(rvalid),
      .m_axi_rready(rready),
      .ext_wr_valid_o(ext_wr_valid),
      .ext_wr_first_o(ext_wr_first),
      .ext_wr_last_o(ext_wr_last)
  );

  // Simple 64 KiB byte-addressable AXI4 slave memory
  logic [7:0] mem[65536];
  logic rd_act, wr_act, b_pend;
  logic [63:0] rd_cur, wr_cur;
  logic [7:0] rd_rem, wr_rem;
  int unsigned ext_wr_pulses;
  int unsigned total_cycles;

  assign arready = !rd_act;
  assign rvalid  = rd_act;
  assign rresp   = 2'b00;
  assign rid     = 4'd0;
  assign rlast   = rd_act && (rd_rem == 8'd0);
  always_comb begin
    for (int b = 0; b < 8; b++) begin
      rdata_axi[b*8+:8] = mem[rd_cur[15:0]+16'(b)];
    end
  end

  assign awready = !wr_act && !b_pend;
  assign wready  = wr_act;
  assign bvalid  = b_pend;
  assign bresp   = 2'b00;
  assign bid     = 4'd0;

  always_ff @(posedge clk) begin
    if (reset) begin
      rd_act <= 1'b0;
      wr_act <= 1'b0;
      b_pend <= 1'b0;
      ext_wr_pulses <= 0;
      total_cycles <= 0;
    end else begin
      total_cycles <= total_cycles + 1;
      if (ext_wr_valid) ext_wr_pulses <= ext_wr_pulses + 1;
      // Read channel
      if (!rd_act && arvalid) begin
        rd_act <= 1'b1;
        rd_cur <= araddr;
        rd_rem <= arlen;
      end else if (rd_act && rready) begin
        if (rd_rem == 8'd0) begin
          rd_act <= 1'b0;
        end else begin
          rd_cur <= rd_cur + 64'd8;
          rd_rem <= rd_rem - 8'd1;
        end
      end
      // Write channel
      if (!wr_act && !b_pend && awvalid) begin
        wr_act <= 1'b1;
        wr_cur <= awaddr;
        wr_rem <= awlen;
      end else if (wr_act && wvalid) begin
        for (int b = 0; b < 8; b++) begin
          if (wstrb_axi[b]) mem[wr_cur[15:0]+16'(b)] <= wdata_axi[b*8+:8];
        end
        wr_cur <= wr_cur + 64'd8;
        if (wlast) begin
          wr_act <= 1'b0;
          b_pend <= 1'b1;
        end else begin
          wr_rem <= wr_rem - 8'd1;
        end
      end
      if (b_pend && bready) b_pend <= 1'b0;
    end
  end

  task automatic mmio_write(input logic [15:0] addr, input logic [31:0] val);
    @(negedge clk);
    wr = 1'b1;
    waddr = addr;
    wdata = val;
    wstrb = 4'hf;
    @(posedge clk);
    @(negedge clk);
    wr = 1'b0;
  endtask

  task automatic mmio_read(input logic [15:0] addr, output logic [31:0] val);
    @(negedge clk);
    rd = 1'b1;
    raddr = addr;
    @(posedge clk);
    @(negedge clk);
    rd = 1'b0;
    val = rdata;
  endtask

  task automatic run_frame(input int len, input logic [63:0] tx_addr, input logic [63:0] rx_addr,
                           input byte seed);
    logic [31:0] comp;
    int cyc;
    for (int i = 0; i < len; i++) begin
      mem[tx_addr[15:0] + 16'(i)] = byte'(seed ^ byte'(i * 13 + 7));
      mem[rx_addr[15:0] + 16'(i)] = 8'hAA;
    end
    // Sentinel byte right after rx buffer must stay untouched
    mem[rx_addr[15:0]+16'(len)] = 8'h5A;

    // Post RX buffer
    mmio_write(16'h0080, rx_addr[31:0]);
    mmio_write(16'h0084, rx_addr[63:32]);
    mmio_write(16'h0088, 32'd1);

    // Post TX frame
    mmio_write(16'h00a0, tx_addr[31:0]);
    mmio_write(16'h00a4, tx_addr[63:32]);
    mmio_write(16'h00a8, 32'(len));

    // Wait for RX completion
    cyc = 0;
    comp = 32'd0;
    while (comp == 32'd0 && cyc < 5000) begin
      mmio_read(16'h008c, comp);
      cyc++;
    end
    if (int'(comp) != len) begin
      $fatal(1, "FAIL len=%0d: got rx_comp=%0d after %0d polls", len, comp, cyc);
    end
    // Pop RX & acknowledge TX
    mmio_write(16'h008c, 32'd1);
    mmio_write(16'h00ac, 32'd1);

    // Verify payload byte-for-byte + sentinel untouched
    for (int i = 0; i < len; i++) begin
      if (mem[rx_addr[15:0]+16'(i)] !== mem[tx_addr[15:0]+16'(i)]) begin
        $fatal(1, "MISMATCH len=%0d byte=%0d: got 0x%02x exp 0x%02x", len, i,
               mem[rx_addr[15:0]+16'(i)], mem[tx_addr[15:0]+16'(i)]);
      end
    end
    if (mem[rx_addr[15:0]+16'(len)] !== 8'h5A) begin
      $fatal(1, "SENTINEL OVERWRITE len=%0d: got 0x%02x", len, mem[rx_addr[15:0]+16'(len)]);
    end
  endtask

  initial begin
    logic [31:0] id, ver, rx_good, tx_good;
    int unsigned t0, t1;
    reset = 1'b1;
    mdio_input = 1'b1;
    rd = 1'b0;
    wr = 1'b0;
    raddr = '0;
    waddr = '0;
    wdata = '0;
    wstrb = '0;
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    mmio_read(16'h0000, id);
    mmio_read(16'h0004, ver);
    if (id !== 32'h524e4554 || ver !== 32'd2) $fatal(1, "Bad ID/VER: 0x%08x / %0d", id, ver);

    // Enable MAC + DMA + IRQs
    mmio_write(16'h0008, 32'd3);
    mmio_write(16'h0010, 32'd3);

    // Test various frame sizes including 4 KiB boundary crossing (0x8000_0FC0)
    run_frame(60, 64'h8000_0000, 64'h8000_4000, 8'h11);
    run_frame(64, 64'h8000_0100, 64'h8000_4100, 8'h22);
    run_frame(127, 64'h8000_0fc0, 64'h8000_4fc0, 8'h33);  // crosses 4 KiB page!
    run_frame(513, 64'h8000_1000, 64'h8000_5000, 8'h44);
    t0 = total_cycles;
    run_frame(1514, 64'h8000_2000, 64'h8000_6000, 8'h55);
    t1 = total_cycles;
    $display("INFO 1514B TX+MAC_loopback+RX DMA round-trip: %0d cycles", t1 - t0);

    // Wrap around the 16-entry descriptor ring (20 frames)
    for (int f = 0; f < 20; f++) begin
      run_frame(64 + f * 37, 64'h8000_0200, 64'h8000_4200, byte'(8'h80 + 8'(f)));
    end

    mmio_read(16'h0028, rx_good);
    mmio_read(16'h0034, tx_good);
    if (rx_good !== 32'd25 || tx_good !== 32'd25 || ext_wr_pulses !== 25) begin
      $fatal(1, "Bad counters: rx=%0d tx=%0d ext_wr=%0d", rx_good, tx_good, ext_wr_pulses);
    end
    $display(
        "PASS tb_eth_axi_dma: 25/25 frames verified (incl. odd lengths, 4KiB crossing, ring wrap)");
    $finish;
  end
endmodule
