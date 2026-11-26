`timescale 1ns / 1ps
`include "native_ddr_model.svh"

module tb_qemu_io_bridge;
  localparam int X = `RAPT_XLEN;
  localparam int Bytes = X / 8;
  localparam int ByteBits = $clog2(Bytes);
  localparam logic [X-1:0] RamStart = X'(64'h8000_0000);

  logic clk = 0, reset = 1;
  always #5 clk = ~clk;

  axi4_if #(.XLEN(X)) cpu ();
  axi4_if #(.XLEN(X)) dma_vnet ();
  axi4_if #(.XLEN(X)) dma_bridge ();
  axi4_if #(.XLEN(X)) dma_bus ();
  axi4_if #(.XLEN(X)) ddr ();

  logic use_slip = 0;
  logic [7:0] mac_rx_data, mac_tx_data;
  logic mac_rx_valid, mac_rx_last, mac_rx_ready;
  logic mac_tx_valid, mac_tx_last, mac_tx_ready;

  logic [7:0] rqio_rx_data, rqio_tx_data, vnet_rx_data, vnet_tx_data;
  logic rqio_rx_valid, rqio_rx_last, rqio_rx_ready;
  logic rqio_tx_valid, rqio_tx_last, rqio_tx_ready;
  logic vnet_rx_valid, vnet_rx_last, vnet_rx_ready;
  logic vnet_tx_valid, vnet_tx_last, vnet_tx_ready;

  logic [7:0] slip_rx_data, slip_tx_data;
  logic slip_rx_valid, slip_rx_ready, slip_tx_valid, slip_tx_ready;

  logic bridge_req_valid, bridge_req_write, bridge_resp_valid, bridge_resp_err;
  logic [31:0] bridge_req_addr, irq_mask;
  logic [1:0] bridge_req_size;
  logic [63:0] bridge_req_wdata, bridge_resp_rdata;
  logic [7:0] bridge_req_wstrb;

  logic ext_wr_valid, ext_wr_pending;
  logic [X-1:0] ext_wr_first, ext_wr_last;
  int ext_wr_count = 0;

  always_ff @(posedge clk) begin
    if (!reset && ext_wr_valid) ext_wr_count <= ext_wr_count + 1;
  end

  // Tie off unused vnet DMA master in this focused bridge + mux testbench
  assign dma_vnet.arvalid = 1'b0;
  assign dma_vnet.araddr  = '0;
  assign dma_vnet.arid    = '0;
  assign dma_vnet.arlen   = '0;
  assign dma_vnet.arsize  = '0;
  assign dma_vnet.arburst = '0;
  assign dma_vnet.arcache = '0;
  assign dma_vnet.rready  = 1'b0;
  assign dma_vnet.awvalid = 1'b0;
  assign dma_vnet.awaddr  = '0;
  assign dma_vnet.awid    = '0;
  assign dma_vnet.awlen   = '0;
  assign dma_vnet.awsize  = '0;
  assign dma_vnet.awburst = '0;
  assign dma_vnet.awcache = '0;
  assign dma_vnet.wvalid  = 1'b0;
  assign dma_vnet.wdata   = '0;
  assign dma_vnet.wstrb   = '0;
  assign dma_vnet.wlast   = 1'b0;
  assign dma_vnet.bready  = 1'b0;

  assign vnet_tx_data  = 8'h00;
  assign vnet_tx_valid = 1'b0;
  assign vnet_tx_last  = 1'b0;

  int vnet_rx_bytes = 0;
  assign vnet_rx_ready = 1'b1;
  always_ff @(posedge clk) begin
    if (!reset && vnet_rx_valid && vnet_rx_ready) vnet_rx_bytes <= vnet_rx_bytes + 1;
  end

  rapt_eth_rqio_mux u_mux (
      .clk(clk),
      .reset(reset),
      .mac_rx_data_i(mac_rx_data),
      .mac_rx_valid_i(mac_rx_valid),
      .mac_rx_last_i(mac_rx_last),
      .mac_rx_ready_o(mac_rx_ready),
      .mac_tx_data_o(mac_tx_data),
      .mac_tx_valid_o(mac_tx_valid),
      .mac_tx_last_o(mac_tx_last),
      .mac_tx_ready_i(mac_tx_ready),
      .rqio_rx_data_o(rqio_rx_data),
      .rqio_rx_valid_o(rqio_rx_valid),
      .rqio_rx_last_o(rqio_rx_last),
      .rqio_rx_ready_i(rqio_rx_ready),
      .rqio_tx_data_i(rqio_tx_data),
      .rqio_tx_valid_i(rqio_tx_valid),
      .rqio_tx_last_i(rqio_tx_last),
      .rqio_tx_ready_o(rqio_tx_ready),
      .vnet_rx_data_o(vnet_rx_data),
      .vnet_rx_valid_o(vnet_rx_valid),
      .vnet_rx_last_o(vnet_rx_last),
      .vnet_rx_ready_i(vnet_rx_ready),
      .vnet_tx_data_i(vnet_tx_data),
      .vnet_tx_valid_i(vnet_tx_valid),
      .vnet_tx_last_i(vnet_tx_last),
      .vnet_tx_ready_o(vnet_tx_ready)
  );

  rapt_qemu_io_bridge #(
      .XLEN(X)
  ) u_bridge (
      .clk(clk),
      .reset(reset),
      .use_slip_i(use_slip),
      .mmio_valid_i(bridge_req_valid),
      .mmio_write_i(bridge_req_write),
      .mmio_addr_i(bridge_req_addr),
      .mmio_size_i(bridge_req_size),
      .mmio_wdata_i(bridge_req_wdata),
      .mmio_wstrb_i(bridge_req_wstrb),
      .mmio_ready_o(bridge_resp_valid),
      .mmio_rdata_o(bridge_resp_rdata),
      .mmio_err_o(bridge_resp_err),
      .irq_mask_o(irq_mask),
      .dma(dma_bridge),
      .eth_rx_data_i(rqio_rx_data),
      .eth_rx_valid_i(rqio_rx_valid),
      .eth_rx_last_i(rqio_rx_last),
      .eth_rx_ready_o(rqio_rx_ready),
      .eth_tx_data_o(rqio_tx_data),
      .eth_tx_valid_o(rqio_tx_valid),
      .eth_tx_last_o(rqio_tx_last),
      .eth_tx_ready_i(rqio_tx_ready),
      .slip_rx_data_i(slip_rx_data),
      .slip_rx_valid_i(slip_rx_valid),
      .slip_rx_ready_o(slip_rx_ready),
      .slip_tx_data_o(slip_tx_data),
      .slip_tx_valid_o(slip_tx_valid),
      .slip_tx_ready_i(slip_tx_ready)
  );

  rapt_axi4_dma_arb #(
      .XLEN(X)
  ) u_arb (
      .clk(clk),
      .reset(reset),
      .m0(dma_vnet),
      .m1(dma_bridge),
      .out(dma_bus)
  );

  rapt_native_io_bus #(
      .XLEN(X),
      .WithDdr(`NATIVE_DDR),
      .WithPeripheral(0),
      .WithLocalVirtioNet(0),
      .WithQemuBridge(1),
      .RamBytes(131072),
      .RomFile("")
  ) u_bus (
      .clk(clk),
      .reset(reset),
      .uart_rx(1'b1),
      .uart_tx(),
      .uart_irq(),
      .rtc_irq(),
      .peripheral_rd(),
      .peripheral_wr(),
      .peripheral_raddr(),
      .peripheral_waddr(),
      .peripheral_wdata(),
      .peripheral_wstrb(),
      .peripheral_rdata(32'd0),
      .vnet_req_valid_o(),
      .vnet_req_write_o(),
      .vnet_req_addr_o(),
      .vnet_req_size_o(),
      .vnet_req_wdata_o(),
      .vnet_req_wstrb_o(),
      .vnet_resp_valid_i(1'b1),
      .vnet_resp_rdata_i(64'd0),
      .vnet_resp_err_i(1'b0),
      .bridge_req_valid_o(bridge_req_valid),
      .bridge_req_write_o(bridge_req_write),
      .bridge_req_addr_o(bridge_req_addr),
      .bridge_req_size_o(bridge_req_size),
      .bridge_req_wdata_o(bridge_req_wdata),
      .bridge_req_wstrb_o(bridge_req_wstrb),
      .bridge_resp_valid_i(bridge_resp_valid),
      .bridge_resp_rdata_i(bridge_resp_rdata),
      .bridge_resp_err_i(bridge_resp_err),
      .external_write_valid_o(ext_wr_valid),
      .external_write_pending_o(ext_wr_pending),
      .external_write_first_o(ext_wr_first),
      .external_write_last_o(ext_wr_last),
      .idle_o(),
      .cpu(cpu),
      .dma(dma_bus),
      .ddr(ddr)
  );

  native_ddr_model #(
      .XLEN(X)
  ) u_ddr (
      .clk(clk),
      .reset(reset),
      .axi(ddr)
  );

  // Capture outgoing Ethernet & SLIP frames from bridge
  logic [7:0] eth_cap[0:511];
  int eth_cap_len = 0;
  logic eth_cap_done = 0;

  logic [7:0] slip_cap[0:511];
  int slip_cap_len = 0;
  logic slip_cap_done = 0, slip_in_frame = 0, slip_esc = 0;

  always_ff @(posedge clk) begin
    if (!reset && mac_tx_valid && mac_tx_ready) begin
      eth_cap[eth_cap_len] <= mac_tx_data;
      eth_cap_len <= eth_cap_len + 1;
      if (mac_tx_last) eth_cap_done <= 1'b1;
    end
    if (!reset && slip_tx_valid && slip_tx_ready) begin
      if (slip_tx_data == 8'hc0) begin
        if (slip_in_frame && slip_cap_len > 0) slip_cap_done <= 1'b1;
        slip_in_frame <= 1'b1;
        slip_esc <= 1'b0;
      end else if (slip_in_frame) begin
        if (slip_tx_data == 8'hdb) slip_esc <= 1'b1;
        else begin
          automatic logic [7:0] b = slip_tx_data;
          if (slip_esc) begin
            if (slip_tx_data == 8'hdc) b = 8'hc0;
            else if (slip_tx_data == 8'hdd) b = 8'hdb;
            slip_esc <= 1'b0;
          end
          slip_cap[slip_cap_len] <= b;
          slip_cap_len <= slip_cap_len + 1;
        end
      end
    end
  end

  function automatic logic [15:0] crc16_ccitt(input logic [7:0] buf_in[0:63], input int len);
    logic [15:0] c;
    c = 16'hffff;
    for (int i = 0; i < len; i++) begin
      c = c ^ {buf_in[i], 8'h00};
      for (int bit_i = 0; bit_i < 8; bit_i++) begin
        if (c[15]) c = (c << 1) ^ 16'h1021;
        else c = c << 1;
      end
    end
    return c;
  endfunction

  task automatic send_eth_frame(input logic [15:0] ethertype, input logic [7:0] payload[0:63],
                                input int plen);
    for (int i = 0; i < 14 + plen; i++) begin
      @(negedge clk);
      if (i < 12) mac_rx_data = 8'(i);
      else if (i == 12) mac_rx_data = ethertype[15:8];
      else if (i == 13) mac_rx_data = ethertype[7:0];
      else mac_rx_data = payload[i-14];
      mac_rx_valid = 1'b1;
      mac_rx_last  = (i == 14 + plen - 1);
      while (1) begin
        @(posedge clk);
        if (mac_rx_valid && mac_rx_ready) break;
      end
    end
    @(negedge clk);
    mac_rx_valid = 1'b0;
    mac_rx_last  = 1'b0;
  endtask

  task automatic send_slip_byte(input logic [7:0] b);
    @(negedge clk);
    slip_rx_data  = b;
    slip_rx_valid = 1'b1;
    while (1) begin
      @(posedge clk);
      if (slip_rx_valid && slip_rx_ready) break;
    end
  endtask

  task automatic send_slip_frame(input logic [7:0] payload[0:63], input int plen);
    logic [15:0] crc;
    logic [7:0] raw[0:65];
    crc = crc16_ccitt(payload, plen);
    for (int i = 0; i < plen; i++) raw[i] = payload[i];
    raw[plen]     = crc[15:8];
    raw[plen + 1] = crc[7:0];

    send_slip_byte(8'hc0);
    for (int i = 0; i < plen + 2; i++) begin
      if (raw[i] == 8'hc0 || raw[i] == 8'hdb) begin
        send_slip_byte(8'hdb);
        send_slip_byte((raw[i] == 8'hc0) ? 8'hdc : 8'hdd);
      end else begin
        send_slip_byte(raw[i]);
      end
    end
    send_slip_byte(8'hc0);
    @(negedge clk);
    slip_rx_valid = 1'b0;
  endtask

  task automatic cpu_write32(input logic [X-1:0] addr, input logic [31:0] val);
    logic [ByteBits-1:0] off;
    bit aw_ok, w_ok;
    off = addr[ByteBits-1:0];
    aw_ok = 0;
    w_ok = 0;
    @(negedge clk);
    cpu.awaddr  = addr;
    cpu.awid    = 4'd0;
    cpu.awlen   = 8'd0;
    cpu.awsize  = 3'd2;
    cpu.awburst = 2'b01;
    cpu.awcache = 4'b0000;
    cpu.awvalid = 1'b1;
    cpu.wdata   = X'(val) << (int'(off) * 8);
    cpu.wstrb   = Bytes'(4'hf) << off;
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
        if (cpu.bresp != 2'b00) $fatal(1, "CPU write error %h resp=%0d", addr, cpu.bresp);
        break;
      end
    end
    @(negedge clk);
    cpu.bready = 1'b0;
  endtask

  task automatic cpu_read32(input logic [X-1:0] addr, output logic [31:0] val);
    logic [ByteBits-1:0] off;
    off = addr[ByteBits-1:0];
    @(negedge clk);
    cpu.araddr  = addr;
    cpu.arid    = 4'd0;
    cpu.arlen   = 8'd0;
    cpu.arsize  = 3'd2;
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
        if (cpu.rresp != 2'b00) $fatal(1, "CPU read error %h resp=%0d", addr, cpu.rresp);
        val = 32'(cpu.rdata >> (int'(off) * 8));
        break;
      end
    end
    @(negedge clk);
    cpu.rready = 1'b0;
  endtask

  initial begin
    #2_000_000;
    $fatal(1, "tb_qemu_io_bridge watchdog timeout");
  end

  initial begin
    logic [7:0] pkt[0:63];
    logic [31:0] rval;
    logic [15:0] req_seq;

    cpu.arvalid   = 0;
    cpu.rready    = 0;
    cpu.awvalid   = 0;
    cpu.wvalid    = 0;
    cpu.bready    = 0;
    mac_rx_data   = 0;
    mac_rx_valid  = 0;
    mac_rx_last   = 0;
    mac_tx_ready  = 1;
    slip_rx_data  = 0;
    slip_rx_valid = 0;
    slip_tx_ready = 1;

    repeat (6) @(posedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // Pre-populate guest RAM at 0x8000_0100 with NVMe SQ command word 0xdead_beef
    cpu_write32(RamStart + X'('h100), 32'hdead_beef);

    // Verify L2 EtherType demux: IPv4 frame (0x0800) must go to vnet, NOT rqio
    for (int i = 0; i < 20; i++) pkt[i] = 8'(i);
    send_eth_frame(16'h0800, pkt, 20);
    repeat (25) @(posedge clk);
    if (vnet_rx_bytes != 34) $fatal(1, "Expected 34B routed to vnet, got %0d", vnet_rx_bytes);

    // Deadlock-free concurrent test over L2 Ethernet (0x88B5):
    // Fork a CPU MMIO write to NVMe Doorbell (0x5000_1000). While CPU waits on
    // bridge_resp_valid, host QEMU issues DMA_READ(0x8000_0100, 4B) +
    // DMA_WRITE(0x8000_0200, 4B = 0xcafe_babe) + MMIO_RESP(irq=1<<11)!
    eth_cap_len  = 0;
    eth_cap_done = 0;
    fork
      begin
        cpu_write32(X'(64'h5000_1000), 32'h0000_0001);
      end
      begin
        while (!eth_cap_done) @(posedge clk);
        if ({eth_cap[12], eth_cap[13]} != 16'h88b5) $fatal(1, "Bad TX ethertype");
        if (eth_cap[14] != 8'h52 || eth_cap[15] != 8'h51 || eth_cap[17] != 8'h01)
          $fatal(1, "Expected MSG_MMIO_REQ");
        req_seq = {eth_cap[19], eth_cap[18]};

        // Host sends MSG_DMA_READ_REQ(seq=0x10, len=4, addr=0x8000_0100)
        eth_cap_len  = 0;
        eth_cap_done = 0;
        pkt[0] = 8'h52;
        pkt[1] = 8'h51;
        pkt[2] = 8'h01;
        pkt[3] = 8'h03;
        pkt[4] = 8'h10;
        pkt[5] = 8'h00;
        pkt[6] = 8'h04;
        pkt[7] = 8'h00;
        pkt[8] = 8'h00;
        pkt[9] = 8'h01;
        pkt[10] = 8'h00;
        pkt[11] = 8'h80;
        pkt[12] = 0;
        pkt[13] = 0;
        pkt[14] = 0;
        pkt[15] = 0;
        send_eth_frame(16'h88b5, pkt, 16);

        while (!eth_cap_done) @(posedge clk);
        if (eth_cap[17] != 8'h04) $fatal(1, "Expected MSG_DMA_READ_RESP, got %h", eth_cap[17]);
        if ({eth_cap[29], eth_cap[28], eth_cap[27], eth_cap[26]} != 32'hdead_beef)
          $fatal(1, "DMA read data mismatch");

        // Host sends MSG_DMA_WRITE_REQ(seq=0x11, len=4, addr=0x8000_0200, data=0xcafe_babe)
        eth_cap_len  = 0;
        eth_cap_done = 0;
        pkt[0] = 8'h52;
        pkt[1] = 8'h51;
        pkt[2] = 8'h01;
        pkt[3] = 8'h06;
        pkt[4] = 8'h11;
        pkt[5] = 8'h00;
        pkt[6] = 8'h04;
        pkt[7] = 8'h00;
        pkt[8] = 8'h00;
        pkt[9] = 8'h02;
        pkt[10] = 8'h00;
        pkt[11] = 8'h80;
        pkt[12] = 0;
        pkt[13] = 0;
        pkt[14] = 0;
        pkt[15] = 0;
        pkt[16] = 8'hbe;
        pkt[17] = 8'hba;
        pkt[18] = 8'hfe;
        pkt[19] = 8'hca;
        send_eth_frame(16'h88b5, pkt, 20);

        while (!eth_cap_done) @(posedge clk);
        if (eth_cap[17] != 8'h05) $fatal(1, "Expected MSG_DMA_WRITE_RESP");

        // Finally host sends MSG_MMIO_RESP completing the parked CPU doorbell write
        pkt[0] = 8'h52;
        pkt[1] = 8'h51;
        pkt[2] = 8'h01;
        pkt[3] = 8'h02;
        pkt[4] = req_seq[7:0];
        pkt[5] = req_seq[15:8];
        pkt[6] = 0;
        pkt[7] = 0;
        pkt[8] = 8'h00;
        pkt[9] = 8'h08;
        pkt[10] = 0;
        pkt[11] = 0;  // IRQ 11 (NVMe INTA)
        for (int i = 12; i < 20; i++) pkt[i] = 0;
        send_eth_frame(16'h88b5, pkt, 20);
      end
    join

    if (irq_mask != 32'h0000_0800) $fatal(1, "Expected IRQ 11 set, got %h", irq_mask);
    cpu_read32(RamStart + X'('h200), rval);
    if (rval != 32'hcafe_babe) $fatal(1, "DMA write not visible in RAM: %h", rval);
    if (ext_wr_count == 0) $fatal(1, "DMA write did not assert external_write_valid_o");

    // Now switch to SLIP + CRC16 fallback mode and test SDHCI MMIO read (0x4200_00fe)
    use_slip = 1'b1;
    slip_cap_len  = 0;
    slip_cap_done = 0;
    slip_in_frame = 0;
    fork
      begin
        cpu_read32(X'(64'h4200_00fc), rval);
      end
      begin
        while (!slip_cap_done) @(posedge clk);
        if (slip_cap[3] != 8'h01) $fatal(1, "SLIP expected MSG_MMIO_REQ");
        req_seq = {slip_cap[5], slip_cap[4]};
        pkt[0] = 8'h52;
        pkt[1] = 8'h51;
        pkt[2] = 8'h01;
        pkt[3] = 8'h02;
        pkt[4] = req_seq[7:0];
        pkt[5] = req_seq[15:8];
        pkt[6] = 0;
        pkt[7] = 0;
        pkt[8] = 8'h10;
        pkt[9] = 0;
        pkt[10] = 0;
        pkt[11] = 0;  // IRQ 4 (SDHCI)
        // Read data includes SLIP END/ESC bytes.
        pkt[12] = 8'h02;
        pkt[13] = 8'h00;
        pkt[14] = 8'hc0;
        pkt[15] = 8'hdb;
        pkt[16] = 8'h02;
        pkt[17] = 8'h00;
        pkt[18] = 8'hc0;
        pkt[19] = 8'hdb;
        send_slip_frame(pkt, 20);
      end
    join
    if (rval != 32'hdbc0_0002) $fatal(1, "SLIP MMIO rdata mismatch: %h", rval);
    if (irq_mask != 32'h0000_0010) $fatal(1, "SLIP IRQ mismatch: %h", irq_mask);

    $display("PASS: tb_qemu_io_bridge (XLEN=%0d, Eth+SLIP+DMA+IRQ)", X);
    $finish;
  end
endmodule
