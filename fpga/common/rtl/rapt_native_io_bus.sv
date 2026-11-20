// DMA-capable native SoC interconnect supporting local virtio-mmio NIC,
// remote FPGA-to-QEMU I/O + DMA bridge (VirtIO-Blk / VirtIO-Net / SDHCI /
// PCIe ECAM + NVMe), non-coherent DMA arbitration onto BRAM or DDR4, and
// architectural LR/SC reservation invalidation via external_write_* signals.
module rapt_native_io_bus #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit WithDdr = 0,
    parameter bit WithPeripheral = 0,
    parameter bit WithLocalVirtioNet = 1,
    parameter bit WithQemuBridge = 1,
    parameter logic [31:0] PeripheralBase = 32'h1800_0000,
    parameter int RamBytes = 131072,
    parameter int ClockHz = 50_000_000,
    parameter string RomFile = "boot.hex"
) (
    input logic clk,
    input logic reset,
    input logic uart_rx,
    output logic uart_tx,
    output logic uart_irq,
    // Legacy board peripheral window (0x1800_0000)
    output logic peripheral_rd,
    output logic peripheral_wr,
    output logic [15:0] peripheral_raddr,
    output logic [15:0] peripheral_waddr,
    output logic [31:0] peripheral_wdata,
    output logic [3:0] peripheral_wstrb,
    input logic [31:0] peripheral_rdata,
    // Local pure-RTL virtio-mmio NIC window (0x1000_2000..0x1000_2fff)
    output logic vnet_req_valid_o,
    output logic vnet_req_write_o,
    output logic [11:0] vnet_req_addr_o,
    output logic [1:0] vnet_req_size_o,
    output logic [63:0] vnet_req_wdata_o,
    output logic [7:0] vnet_req_wstrb_o,
    input logic vnet_resp_valid_i,
    input logic [63:0] vnet_resp_rdata_i,
    input logic vnet_resp_err_i,
    // Remote QEMU I/O bridge window (0x1000_1000..0x1000_8fff & 0x4100_0000..0x5fff_ffff)
    output logic bridge_req_valid_o,
    output logic bridge_req_write_o,
    output logic [31:0] bridge_req_addr_o,
    output logic [1:0] bridge_req_size_o,
    output logic [63:0] bridge_req_wdata_o,
    output logic [7:0] bridge_req_wstrb_o,
    input logic bridge_resp_valid_i,
    input logic [63:0] bridge_resp_rdata_i,
    input logic bridge_resp_err_i,
    // External write notification toward rapt core (LR/SC reservation clear)
    output logic external_write_valid_o,
    output logic external_write_pending_o,
    output logic [XLEN-1:0] external_write_first_o,
    output logic [XLEN-1:0] external_write_last_o,
    output logic idle_o,
    axi4_if.slave cpu,
    axi4_if.slave dma,
    axi4_if.master ddr
);
  import rapt_native_map_pkg::*;
  localparam int Bytes = XLEN / 8;
  localparam int ByteBits = $clog2(Bytes);
  localparam int RomWords = int'(RomBytes) / Bytes;
  localparam int SramWords = int'(SramBytes) / Bytes;
  localparam int RamWords = RamBytes / Bytes;

  typedef enum logic [3:0] {
    Bad,
    Rom,
    Sram,
    Ram,
    Uart,
    Ddr,
    Peripheral,
    VirtioNet,
    IoBridge
  } target_t;

  typedef enum logic [2:0] {
    RIdle,
    RIssue,
    RIoWait,
    RReply,
    RDdr
  } read_state_t;

  typedef enum logic [2:0] {
    WIdle,
    WAddr,
    WData,
    WIoIssue,
    WIoWait,
    WReply,
    WDdrB
  } write_state_t;

  typedef enum logic [2:0] {
    DmaRIdle,
    DmaRRam,
    DmaRRamReply,
    DmaRDdrAr,
    DmaRDdrR
  } dma_rstate_t;

  typedef enum logic [2:0] {
    DmaWIdle,
    DmaWRamW,
    DmaWRamB,
    DmaWDdrAw,
    DmaWDdrW,
    DmaWDdrB
  } dma_wstate_t;

  read_state_t rs_q;
  write_state_t ws_q;
  dma_rstate_t dma_rs_q;
  dma_wstate_t dma_ws_q;
  target_t rt_q, wt_q;
  logic [XLEN-1:0] ra_q, wa_q;
  logic [7:0] rleft_q, wleft_q, rlen_q, wlen_q;
  logic [2:0] rsize_q, wsize_q;
  logic [1:0] rburst_q, wburst_q;
  logic [3:0] rid_q, wid_q, rcache_q, wcache_q;
  logic [XLEN-1:0] wdata_hold_q;
  logic [Bytes-1:0] wstrb_hold_q;
  logic [XLEN-1:0] rdata_mux, rom_q, sram_q, ram_q, uart_q, io_rdata_q;
  logic [1:0] rresp_q, bresp_q;
  logic io_req_pulsed_q;

  logic [XLEN-1:0] dma_ra_q, dma_wa_q, dma_ram_q;
  logic [3:0] dma_rid_q, dma_wid_q;
  logic [7:0] dma_rlen_q, dma_rleft_q, dma_wlen_q, dma_wleft_q;
  logic [2:0] dma_rsize_q, dma_wsize_q;
  logic [1:0] dma_rburst_q, dma_wburst_q;
  logic [3:0] dma_rcache_q, dma_wcache_q;
  logic [1:0] dma_rresp_q, dma_bresp_q;
  logic dma_r_valid_t_q, dma_w_valid_t_q;

  (* ram_style = "block" *) logic [XLEN-1:0] rom [RomWords];
  (* ram_style = "block" *) logic [XLEN-1:0] sram [SramWords];

  initial begin
    for (int i = 0; i < RomWords; i++) rom[i] = '0;
    if (RomFile != "") $readmemh(RomFile, rom);
  end

  assign idle_o = (rs_q == RIdle) && (ws_q == WIdle)
               && (dma_rs_q == DmaRIdle) && (dma_ws_q == DmaWIdle);

  function automatic target_t decode(input logic [XLEN-1:0] addr);
    logic [63:0] a;
    a = 64'(addr);
    if (a >= RomBase && a < RomBase + RomBytes) return Rom;
    if (a >= SramBase && a < SramBase + SramBytes) return Sram;
    if (a >= UartBase && a < UartBase + 64'd8) return Uart;
    if (WithLocalVirtioNet && a >= 64'h1000_2000 && a < 64'h1000_3000) return VirtioNet;
    if (WithQemuBridge && ((a >= 64'h1000_1000 && a < 64'h1000_9000)
                        || (a >= 64'h4100_0000 && a < 64'h6000_0000)))
      return IoBridge;
    if (WithPeripheral && a >= 64'(PeripheralBase) && a < 64'(PeripheralBase) + 64'h10000)
      return Peripheral;
    if (a >= RamBase && (a - RamBase) < (WithDdr ? DdrBytes : 64'(RamBytes)))
      return WithDdr ? Ddr : Ram;
    return Bad;
  endfunction

  function automatic target_t request_target(input logic [XLEN-1:0] addr, input logic [7:0] len,
                                             input logic [2:0] size, input logic [1:0] burst);
    logic [XLEN:0] aligned_addr, last_addr;
    target_t dest;
    dest = decode(addr);
    aligned_addr = {1'b0, addr} & ~(((XLEN + 1)'(1) << size) - 1'b1);
    last_addr = aligned_addr + ((burst == 2'd1 ? (XLEN + 1)'(len) : '0) << size)
                + ((XLEN + 1)'(1) << size) - 1'b1;
    if (int'(size) > ByteBits || burst > 2'd1 || last_addr[XLEN] || decode(
            last_addr[XLEN-1:0]
        ) != dest || last_addr[XLEN-1:12] != addr[XLEN-1:12])
      return Bad;
    if (dest == Uart && (len != 8'd0 || size != 3'd0)) return Bad;
    if (dest == Peripheral && (len != 8'd0 || size != 3'd2 || addr[1:0] != 2'd0)) return Bad;
    if ((dest == VirtioNet || dest == IoBridge) && len != 8'd0) return Bad;
    if ((dest == VirtioNet || dest == IoBridge) && ((addr & ((XLEN'(1) << size) - 1'b1)) != '0))
      return Bad;
    return dest;
  endfunction

  function automatic logic dma_addr_ok(input logic [XLEN-1:0] addr, input logic [7:0] len,
                                       input logic [2:0] size, input logic [1:0] burst);
    logic [63:0] a, last_a;
    a = 64'(addr);
    last_a = (a & ~((64'd1 << size) - 64'd1))
           + ((burst == 2'd1 ? 64'(len) : 64'd0) << size) + (64'd1 << size) - 64'd1;
    if (int'(size) > ByteBits || burst > 2'd1) return 1'b0;
    return (a >= RamBase) && ((last_a - RamBase) < (WithDdr ? DdrBytes : 64'(RamBytes)));
  endfunction

  // Order CPU reads behind CPU writes, while keeping DMA independent of CPU IoBridge stalls!
  wire cpu_read_blocked  = (ws_q != WIdle) || cpu.awvalid;
  wire cpu_write_blocked = (rs_q != RIdle);

  assign cpu.arready = !reset && (rs_q == RIdle) && !cpu_read_blocked;
  assign cpu.rid     = (rt_q == Ddr) ? ddr.rid : rid_q;
  assign cpu.rdata   = (rt_q == Ddr) ? ddr.rdata : rdata_mux;
  assign cpu.rresp   = (rt_q == Ddr) ? ddr.rresp : rresp_q;
  assign cpu.rlast   = (rt_q == Ddr) ? ddr.rlast : (rleft_q == 8'd0);
  assign cpu.rvalid  = (rs_q == RReply) || (rs_q == RDdr && ddr.rvalid);

  assign cpu.awready = !reset && (ws_q == WIdle) && !cpu_write_blocked;
  wire uart_rd = (rs_q == RIssue) && (rt_q == Uart);
  wire ram_write_collision = (wt_q == Ram) && (dma_rs_q == DmaRRam || dma_ws_q == DmaWRamW);
  assign cpu.wready = (ws_q == WData)
      && ((wt_q == Ddr) ? (ddr.wready && dma_ws_q != DmaWDdrW)
                        : (!uart_rd && !ram_write_collision));
  assign cpu.bid    = wid_q;
  assign cpu.bresp  = bresp_q;
  assign cpu.bvalid = (ws_q == WReply);

  // Arbitrate DDR4 port between CPU (when rt_q/wt_q == Ddr) and DMA (dma_rs_q/dma_ws_q)
  // Note: when CPU is parked in RIoWait or WIoWait, rs_q != RIssue/RDdr and ws_q != WAddr/WData,
  // so DMA has 100% unobstructed access to DDR4!
  wire dma_owns_ddr_ar = (dma_rs_q == DmaRDdrAr);
  wire dma_owns_ddr_r  = (dma_rs_q == DmaRDdrR);
  wire cpu_wants_ddr_ar = (rs_q == RIssue) && (rt_q == Ddr) && !dma_owns_ddr_ar && !dma_owns_ddr_r;

  assign ddr.arvalid = dma_owns_ddr_ar || cpu_wants_ddr_ar;
  assign ddr.araddr  = (dma_owns_ddr_ar ? dma_ra_q : ra_q) - XLEN'(RamBase);
  assign ddr.arid    = dma_owns_ddr_ar ? dma_rid_q : rid_q;
  assign ddr.arlen   = dma_owns_ddr_ar ? dma_rlen_q : rlen_q;
  assign ddr.arsize  = dma_owns_ddr_ar ? dma_rsize_q : rsize_q;
  assign ddr.arburst = dma_owns_ddr_ar ? dma_rburst_q : rburst_q;
  assign ddr.arcache = dma_owns_ddr_ar ? dma_rcache_q : rcache_q;
  assign ddr.rready  = dma_owns_ddr_r ? dma.rready : ((rs_q == RDdr) && cpu.rready);

  wire dma_owns_ddr_aw = (dma_ws_q == DmaWDdrAw);
  wire dma_owns_ddr_w  = (dma_ws_q == DmaWDdrW);
  wire dma_owns_ddr_b  = (dma_ws_q == DmaWDdrB);
  wire cpu_wants_ddr_aw = (ws_q == WAddr) && (wt_q == Ddr)
                       && (dma_ws_q == DmaWIdle);

  assign ddr.awvalid = dma_owns_ddr_aw || cpu_wants_ddr_aw;
  assign ddr.awaddr  = (dma_owns_ddr_aw ? dma_wa_q : wa_q) - XLEN'(RamBase);
  assign ddr.awid    = dma_owns_ddr_aw ? dma_wid_q : 4'd0;
  assign ddr.awlen   = dma_owns_ddr_aw ? dma_wlen_q : wlen_q;
  assign ddr.awsize  = dma_owns_ddr_aw ? dma_wsize_q : wsize_q;
  assign ddr.awburst = dma_owns_ddr_aw ? dma_wburst_q : wburst_q;
  assign ddr.awcache = dma_owns_ddr_aw ? dma_wcache_q : wcache_q;

  assign ddr.wvalid  = dma_owns_ddr_w ? (dma.wvalid && dma_w_valid_t_q)
                                      : ((ws_q == WData) && (wt_q == Ddr) && cpu.wvalid);
  assign ddr.wdata   = dma_owns_ddr_w ? dma.wdata : cpu.wdata;
  assign ddr.wstrb   = dma_owns_ddr_w ? dma.wstrb : cpu.wstrb;
  assign ddr.wlast   = dma_owns_ddr_w ? (dma_wleft_q == 8'd0) : (wleft_q == 8'd0);
  assign ddr.bready  = (dma_owns_ddr_b && dma_w_valid_t_q) ? 1'b1 : (ws_q == WDdrB);

  // DMA slave interface responses
  assign dma.arready = !reset && (dma_rs_q == DmaRIdle)
                    && !(rs_q == RDdr || ((rs_q == RIssue) && (rt_q == Ddr)));
  assign dma.rid     = (WithDdr && dma_r_valid_t_q) ? ddr.rid : dma_rid_q;
  assign dma.rdata   = (WithDdr && dma_r_valid_t_q) ? ddr.rdata : dma_ram_q;
  assign dma.rresp   = (WithDdr && dma_r_valid_t_q) ? ddr.rresp : dma_rresp_q;
  assign dma.rlast   = (WithDdr && dma_r_valid_t_q) ? ddr.rlast : (dma_rleft_q == 8'd0);
  assign dma.rvalid  = (dma_rs_q == DmaRRamReply)
                    || (dma_rs_q == DmaRDdrR && (!dma_r_valid_t_q || ddr.rvalid));

  assign dma.awready = !reset && (dma_ws_q == DmaWIdle)
                    && !(ws_q == WAddr && wt_q == Ddr)
                    && !(ws_q == WData && wt_q == Ddr)
                    && !(ws_q == WDdrB);
  assign dma.wready  = (dma_ws_q == DmaWRamW)
                    || (dma_ws_q == DmaWDdrW && (!dma_w_valid_t_q || ddr.wready));
  assign dma.bid     = dma_wid_q;
  assign dma.bresp   = dma_bresp_q;
  assign dma.bvalid  = (dma_ws_q == DmaWRamB) || (dma_ws_q == DmaWDdrB && !dma_w_valid_t_q);

  // Report external DMA writes to rapt core so matching L1D LR reservations clear
  logic ext_wr_valid_q;
  logic [XLEN-1:0] ext_wr_first_q, ext_wr_last_q;
  wire dma_commit_beat = ((dma_ws_q == DmaWRamW) && dma_w_valid_t_q && dma.wvalid && dma.wready)
                      || ((dma_ws_q == DmaWDdrW) && dma_w_valid_t_q && dma.wvalid && dma.wready);
  assign external_write_valid_o   = ext_wr_valid_q;
  assign external_write_pending_o = (dma_ws_q != DmaWIdle);
  assign external_write_first_o   = ext_wr_first_q;
  assign external_write_last_o    = ext_wr_last_q;

  always_ff @(posedge clk) begin
    if (reset) begin
      ext_wr_valid_q <= 1'b0;
      ext_wr_first_q <= '0;
      ext_wr_last_q  <= '0;
    end else begin
      ext_wr_valid_q <= dma_commit_beat && (dma.wstrb != '0);
      if (dma_commit_beat) begin
        automatic logic [XLEN-1:0] base_w = dma_wa_q & ~XLEN'(Bytes - 1);
        ext_wr_first_q <= base_w;
        ext_wr_last_q  <= base_w + XLEN'(Bytes - 1);
      end
    end
  end

  // Local UART & legacy peripheral signals
  logic [2:0] uart_addr;
  logic [7:0] uart_wdata, uart_rdata;
  wire uart_wr = (ws_q == WData) && (wt_q == Uart) && cpu.wvalid && cpu.wready
               && cpu.wstrb[wa_q[ByteBits-1:0]];
  assign uart_addr  = uart_rd ? ra_q[2:0] : wa_q[2:0];
  assign uart_wdata = cpu.wdata[8*wa_q[ByteBits-1:0]+:8];

  assign peripheral_rd    = !reset && (rs_q == RIssue) && (rt_q == Peripheral);
  assign peripheral_wr    = !reset && (ws_q == WData) && (wt_q == Peripheral)
                          && cpu.wvalid && cpu.wready;
  assign peripheral_raddr = ra_q[15:0];
  assign peripheral_waddr = wa_q[15:0];
  assign peripheral_wdata = 32'(cpu.wdata >> (8 * wa_q[ByteBits-1:0]));
  assign peripheral_wstrb = 4'(cpu.wstrb >> wa_q[ByteBits-1:0]);

  rapt_native_uart #(
      .ClockHz(ClockHz)
  ) uart (
      .clk,
      .reset,
      .rx(uart_rx),
      .tx(uart_tx),
      .irq(uart_irq),
      .rd(uart_rd),
      .wr(uart_wr),
      .addr(uart_addr),
      .wdata(uart_wdata),
      .rdata(uart_rdata)
  );

  // Variable-latency VirtioNet & IoBridge MMIO signals
  wire [63:0] wdata64_aligned = (XLEN == 64)
      ? 64'(wdata_hold_q)
      : (wa_q[2] ? {32'(wdata_hold_q), 32'd0} : {32'd0, 32'(wdata_hold_q)});
  wire [7:0] wstrb8_aligned = (XLEN == 64)
      ? 8'(wstrb_hold_q)
      : (wa_q[2] ? {4'(wstrb_hold_q), 4'b0000} : {4'b0000, 4'(wstrb_hold_q)});

  wire rd_vnet_pulse   = (rs_q == RIssue) && (rt_q == VirtioNet);
  wire wr_vnet_pulse   = (ws_q == WIoIssue) && (wt_q == VirtioNet);
  wire rd_bridge_pulse = (rs_q == RIssue) && (rt_q == IoBridge);
  wire wr_bridge_pulse = (ws_q == WIoIssue) && (wt_q == IoBridge);

  assign vnet_req_valid_o = !reset && (rd_vnet_pulse || wr_vnet_pulse);
  assign vnet_req_write_o = wr_vnet_pulse;
  assign vnet_req_addr_o  = wr_vnet_pulse ? wa_q[11:0] : ra_q[11:0];
  assign vnet_req_size_o  = wr_vnet_pulse ? wsize_q[1:0] : rsize_q[1:0];
  assign vnet_req_wdata_o = wdata64_aligned;
  assign vnet_req_wstrb_o = wstrb8_aligned;

  // Keep bridge_req_valid_o asserted until bridge_resp_valid_i is observed
  wire bridge_rd_active = ((rs_q == RIssue) || (rs_q == RIoWait && !io_req_pulsed_q))
                       && (rt_q == IoBridge);
  wire bridge_wr_active = ((ws_q == WIoIssue) || (ws_q == WIoWait && !io_req_pulsed_q))
                       && (wt_q == IoBridge);
  assign bridge_req_valid_o = !reset && (bridge_rd_active || bridge_wr_active);
  assign bridge_req_write_o = (ws_q == WIoIssue || ws_q == WIoWait) && (wt_q == IoBridge);
  assign bridge_req_addr_o  = bridge_req_write_o ? wa_q[31:0] : ra_q[31:0];
  assign bridge_req_size_o  = bridge_req_write_o ? wsize_q[1:0] : rsize_q[1:0];
  assign bridge_req_wdata_o = wdata64_aligned;
  assign bridge_req_wstrb_o = wstrb8_aligned;

  always_comb begin
    case (rt_q)
      Rom:        rdata_mux = rom_q;
      Sram:       rdata_mux = sram_q;
      Ram:        rdata_mux = ram_q;
      Uart:       rdata_mux = uart_q;
      Peripheral: rdata_mux = XLEN'(peripheral_rdata) << (8 * ra_q[ByteBits-1:0]);
      VirtioNet,
      IoBridge:   rdata_mux = io_rdata_q;
      default:    rdata_mux = '0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rs_q == RIssue && rt_q == Rom) rom_q <= rom[ra_q[$clog2(RomBytes)-1:ByteBits]];
    if (rs_q == RIssue && rt_q == Uart) uart_q <= XLEN'(uart_rdata) << (8 * ra_q[ByteBits-1:0]);
  end

  always_ff @(posedge clk) begin
    if (rs_q == RIssue && rt_q == Sram) sram_q <= sram[ra_q[$clog2(SramBytes)-1:ByteBits]];
    if (!reset && ws_q == WData && wt_q == Sram && cpu.wvalid && cpu.wready) begin
      for (int b = 0; b < Bytes; b++) begin
        if (cpu.wstrb[b]) sram[wa_q[$clog2(SramBytes)-1:ByteBits]][b*8+:8] <= cpu.wdata[b*8+:8];
      end
    end
  end

  if (!WithDdr) begin : g_ram
    (* ram_style = "block" *) logic [XLEN-1:0] ram[RamWords];
    always_ff @(posedge clk) begin
      if (dma_rs_q == DmaRRam && dma_r_valid_t_q)
        dma_ram_q <= ram[dma_ra_q[$clog2(RamBytes)-1:ByteBits]];
      else if (rs_q == RIssue && rt_q == Ram) ram_q <= ram[ra_q[$clog2(RamBytes)-1:ByteBits]];

      if (!reset && dma_ws_q == DmaWRamW && dma_w_valid_t_q && dma.wvalid && dma.wready) begin
        for (int b = 0; b < Bytes; b++) begin
          if (dma.wstrb[b]) ram[dma_wa_q[$clog2(RamBytes)-1:ByteBits]][b*8+:8] <= dma.wdata[b*8+:8];
        end
      end else if (!reset && ws_q == WData && wt_q == Ram && cpu.wvalid && cpu.wready) begin
        for (int b = 0; b < Bytes; b++) begin
          if (cpu.wstrb[b]) ram[wa_q[$clog2(RamBytes)-1:ByteBits]][b*8+:8] <= cpu.wdata[b*8+:8];
        end
      end
    end
  end else begin : g_no_ram
    assign ram_q = '0;
    assign dma_ram_q = '0;
  end

  // CPU Read/Write + DMA Read/Write state machines
  always_ff @(posedge clk) begin
    if (reset) begin
      rs_q <= RIdle;
      ws_q <= WIdle;
      dma_rs_q <= DmaRIdle;
      dma_ws_q <= DmaWIdle;
      rt_q <= Bad;
      wt_q <= Bad;
      ra_q <= '0;
      wa_q <= '0;
      rid_q <= '0;
      wid_q <= '0;
      rlen_q <= '0;
      wlen_q <= '0;
      rleft_q <= '0;
      wleft_q <= '0;
      rsize_q <= '0;
      wsize_q <= '0;
      rburst_q <= '0;
      wburst_q <= '0;
      rcache_q <= '0;
      wcache_q <= '0;
      wdata_hold_q <= '0;
      wstrb_hold_q <= '0;
      io_rdata_q <= '0;
      rresp_q <= '0;
      bresp_q <= '0;
      io_req_pulsed_q <= 1'b0;
      dma_ra_q <= '0;
      dma_wa_q <= '0;
      dma_rid_q <= '0;
      dma_wid_q <= '0;
      dma_rlen_q <= '0;
      dma_rleft_q <= '0;
      dma_wlen_q <= '0;
      dma_wleft_q <= '0;
      dma_rsize_q <= '0;
      dma_wsize_q <= '0;
      dma_rburst_q <= '0;
      dma_wburst_q <= '0;
      dma_rcache_q <= '0;
      dma_wcache_q <= '0;
      dma_rresp_q <= '0;
      dma_bresp_q <= '0;
      dma_r_valid_t_q <= 1'b0;
      dma_w_valid_t_q <= 1'b0;
    end else begin
      // CPU Read FSM
      case (rs_q)
        RIdle: begin
          if (cpu.arvalid && cpu.arready) begin
            ra_q <= cpu.araddr;
            rid_q <= cpu.arid;
            rlen_q <= cpu.arlen;
            rleft_q <= cpu.arlen;
            rsize_q <= cpu.arsize;
            rburst_q <= cpu.arburst;
            rcache_q <= cpu.arcache;
            rt_q <= request_target(cpu.araddr, cpu.arlen, cpu.arsize, cpu.arburst);
            io_req_pulsed_q <= 1'b0;
            rs_q <= RIssue;
          end
        end
        RIssue: begin
          if (rt_q == Ddr) begin
            if (cpu_wants_ddr_ar && ddr.arready) rs_q <= RDdr;
          end else if (rt_q == Ram && (dma_rs_q == DmaRRam || dma_ws_q == DmaWRamW)) begin
            rs_q <= RIssue;
          end else if (rt_q == VirtioNet || rt_q == IoBridge) begin
            io_req_pulsed_q <= 1'b0;
            rs_q <= RIoWait;
          end else begin
            rresp_q <= (rt_q == Bad) ? 2'b11 : 2'b00;
            rs_q <= RReply;
          end
        end
        RIoWait: begin
          if (rt_q == VirtioNet && vnet_resp_valid_i) begin
            io_rdata_q <= (XLEN == 64) ? XLEN'(vnet_resp_rdata_i)
                        : (ra_q[2] ? XLEN'(vnet_resp_rdata_i[63:32])
                                   : XLEN'(vnet_resp_rdata_i[31:0]));
            rresp_q <= vnet_resp_err_i ? 2'b10 : 2'b00;
            rs_q <= RReply;
          end else if (rt_q == IoBridge && bridge_resp_valid_i) begin
            io_rdata_q <= (XLEN == 64) ? XLEN'(bridge_resp_rdata_i)
                        : (ra_q[2] ? XLEN'(bridge_resp_rdata_i[63:32])
                                   : XLEN'(bridge_resp_rdata_i[31:0]));
            rresp_q <= bridge_resp_err_i ? 2'b10 : 2'b00;
            io_req_pulsed_q <= 1'b1;
            rs_q <= RReply;
          end
        end
        RReply: begin
          if (cpu.rready) begin
            if (rleft_q == 8'd0) rs_q <= RIdle;
            else begin
              rleft_q <= rleft_q - 8'd1;
              if (rburst_q == 2'd1)
                ra_q <= (ra_q & ~((XLEN'(1) << rsize_q) - 1'b1)) + (XLEN'(1) << rsize_q);
              rs_q <= RIssue;
            end
          end
        end
        RDdr: begin
          if (!dma_owns_ddr_r && ddr.rvalid && cpu.rready && ddr.rlast) rs_q <= RIdle;
        end
        default: rs_q <= RIdle;
      endcase

      // CPU Write FSM
      case (ws_q)
        WIdle: begin
          if (cpu.awvalid && cpu.awready) begin
            wa_q <= cpu.awaddr;
            wid_q <= cpu.awid;
            wlen_q <= cpu.awlen;
            wleft_q <= cpu.awlen;
            wsize_q <= cpu.awsize;
            wburst_q <= cpu.awburst;
            wcache_q <= cpu.awcache;
            wt_q <= request_target(cpu.awaddr, cpu.awlen, cpu.awsize, cpu.awburst);
            bresp_q <= 2'b00;
            io_req_pulsed_q <= 1'b0;
            ws_q <= WAddr;
          end
        end
        WAddr: begin
          if (wt_q != Ddr || (cpu_wants_ddr_aw && ddr.awready)) ws_q <= WData;
        end
        WData: begin
          if (cpu.wvalid && cpu.wready) begin
            wdata_hold_q <= cpu.wdata;
            wstrb_hold_q <= cpu.wstrb;
            if (wt_q == Bad) bresp_q <= 2'b11;
            else if (wt_q == Rom || cpu.wlast != (wleft_q == 8'd0)) bresp_q <= 2'b10;

            if (wleft_q == 8'd0) begin
              if (wt_q == VirtioNet || wt_q == IoBridge) ws_q <= WIoIssue;
              else if (wt_q == Ddr) ws_q <= WDdrB;
              else ws_q <= WReply;
            end else begin
              wleft_q <= wleft_q - 8'd1;
              if (wburst_q == 2'd1)
                wa_q <= (wa_q & ~((XLEN'(1) << wsize_q) - 1'b1)) + (XLEN'(1) << wsize_q);
            end
          end
        end
        WIoIssue: begin
          io_req_pulsed_q <= 1'b0;
          ws_q <= WIoWait;
        end
        WIoWait: begin
          if (wt_q == VirtioNet && vnet_resp_valid_i) begin
            bresp_q <= vnet_resp_err_i ? 2'b10 : 2'b00;
            ws_q <= WReply;
          end else if (wt_q == IoBridge && bridge_resp_valid_i) begin
            bresp_q <= bridge_resp_err_i ? 2'b10 : 2'b00;
            io_req_pulsed_q <= 1'b1;
            ws_q <= WReply;
          end
        end
        WDdrB: begin
          if (!dma_owns_ddr_b && ddr.bvalid) begin
            bresp_q <= ddr.bresp;
            ws_q <= WReply;
          end
        end
        WReply: begin
          if (cpu.bvalid && cpu.bready) ws_q <= WIdle;
        end
        default: ws_q <= WIdle;
      endcase

      // DMA Read FSM
      case (dma_rs_q)
        DmaRIdle: begin
          if (dma.arvalid && dma.arready) begin
            automatic logic ok = dma_addr_ok(dma.araddr, dma.arlen, dma.arsize, dma.arburst);
            dma_ra_q <= dma.araddr;
            dma_rid_q <= dma.arid;
            dma_rlen_q <= dma.arlen;
            dma_rleft_q <= dma.arlen;
            dma_rsize_q <= dma.arsize;
            dma_rburst_q <= dma.arburst;
            dma_rcache_q <= dma.arcache;
            dma_r_valid_t_q <= ok;
            dma_rresp_q <= ok ? 2'b00 : 2'b11;
            if (!ok) dma_rs_q <= DmaRRamReply;
            else if (WithDdr) dma_rs_q <= DmaRDdrAr;
            else dma_rs_q <= DmaRRam;
          end
        end
        DmaRRam: begin
          dma_rs_q <= DmaRRamReply;
        end
        DmaRRamReply: begin
          if (dma.rready) begin
            if (dma_rleft_q == 8'd0) dma_rs_q <= DmaRIdle;
            else begin
              dma_rleft_q <= dma_rleft_q - 8'd1;
              if (dma_rburst_q == 2'd1)
                dma_ra_q <= (dma_ra_q & ~((XLEN'(1) << dma_rsize_q) - 1'b1))
                          + (XLEN'(1) << dma_rsize_q);
              dma_rs_q <= dma_r_valid_t_q ? DmaRRam : DmaRRamReply;
            end
          end
        end
        DmaRDdrAr: begin
          if (ddr.arready) dma_rs_q <= DmaRDdrR;
        end
        DmaRDdrR: begin
          if (ddr.rvalid && dma.rready && ddr.rlast) dma_rs_q <= DmaRIdle;
        end
        default: dma_rs_q <= DmaRIdle;
      endcase

      // DMA Write FSM
      case (dma_ws_q)
        DmaWIdle: begin
          if (dma.awvalid && dma.awready) begin
            automatic logic ok = dma_addr_ok(dma.awaddr, dma.awlen, dma.awsize, dma.awburst);
            dma_wa_q <= dma.awaddr;
            dma_wid_q <= dma.awid;
            dma_wlen_q <= dma.awlen;
            dma_wleft_q <= dma.awlen;
            dma_wsize_q <= dma.awsize;
            dma_wburst_q <= dma.awburst;
            dma_wcache_q <= dma.awcache;
            dma_w_valid_t_q <= ok;
            dma_bresp_q <= ok ? 2'b00 : 2'b11;
            if (!ok) dma_ws_q <= DmaWRamW;
            else if (WithDdr) dma_ws_q <= DmaWDdrAw;
            else dma_ws_q <= DmaWRamW;
          end
        end
        DmaWRamW: begin
          if (dma.wvalid && dma.wready) begin
            if (dma_wleft_q == 8'd0) dma_ws_q <= DmaWRamB;
            else begin
              dma_wleft_q <= dma_wleft_q - 8'd1;
              if (dma_wburst_q == 2'd1)
                dma_wa_q <= (dma_wa_q & ~((XLEN'(1) << dma_wsize_q) - 1'b1))
                          + (XLEN'(1) << dma_wsize_q);
            end
          end
        end
        DmaWRamB: begin
          if (dma.bready) dma_ws_q <= DmaWIdle;
        end
        DmaWDdrAw: begin
          if (ddr.awready) dma_ws_q <= DmaWDdrW;
        end
        DmaWDdrW: begin
          if (dma.wvalid && dma.wready) begin
            if (dma_wleft_q == 8'd0) dma_ws_q <= DmaWDdrB;
            else begin
              dma_wleft_q <= dma_wleft_q - 8'd1;
              if (dma_wburst_q == 2'd1)
                dma_wa_q <= (dma_wa_q & ~((XLEN'(1) << dma_wsize_q) - 1'b1))
                          + (XLEN'(1) << dma_wsize_q);
            end
          end
        end
        DmaWDdrB: begin
          if (dma_w_valid_t_q && ddr.bvalid) begin
            dma_bresp_q <= ddr.bresp;
            dma_w_valid_t_q <= 1'b0;
          end else if (!dma_w_valid_t_q && dma.bready) begin
            dma_ws_q <= DmaWIdle;
          end
        end
        default: dma_ws_q <= DmaWIdle;
      endcase
    end
  end
endmodule
