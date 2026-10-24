// Physical Ethernet evaluation shell: real board pins and clocks, no CPU/MIG.
// MMIO stimulus keeps the full SRAM, descriptor, IRQ and MDIO paths observable.
module rapt_rk_eth_test_top (
    input wire sys_clk_p,
    sys_clk_n,
    cpu_resetn,
    serial_rx,
    output wire serial_tx,
    fan_enable,
    output wire [3:0] user_led,
    input wire eth_rxc,
    eth_rx_ctl,
    input wire [3:0] eth_rxd,
    output wire eth_txc,
    eth_tx_ctl,
    output wire [3:0] eth_txd,
    output wire eth_mdc,
    inout wire eth_mdio
);
  wire clk_in, clk_ref, clk, fb, fb_buf, raw, locked;
  wire eth_tx_raw, eth_delay_raw, eth_tx_clk, eth_delay_clk;
  IBUFDS input_buf (
      .I(sys_clk_p),
      .IB(sys_clk_n),
      .O(clk_in)
  );
  BUFG ref_buf (
      .I(clk_in),
      .O(clk_ref)
  );
  MMCME4_ADV #(
      .CLKIN1_PERIOD(5.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(7.5),
      .CLKOUT0_DIVIDE_F(30.0),
      .CLKOUT1_DIVIDE(12),
      .CLKOUT2_DIVIDE(5),
      .STARTUP_WAIT("FALSE")
  ) pll (
      .CLKIN1(clk_ref),
      .CLKIN2(1'b0),
      .CLKINSEL(1'b1),
      .CLKFBIN(fb_buf),
      .CLKFBOUT(fb),
      .CLKOUT0(raw),
      .CLKOUT1(eth_tx_raw),
      .CLKOUT2(eth_delay_raw),
      .LOCKED(locked),
      .RST(1'b0),
      .PWRDWN(1'b0),
      .DADDR(7'b0),
      .DCLK(1'b0),
      .DEN(1'b0),
      .DI(16'b0),
      .DWE(1'b0),
      .PSCLK(1'b0),
      .PSEN(1'b0),
      .PSINCDEC(1'b0),
      .CDDCREQ(1'b0)
  );
  BUFG feedback_buf (
      .I(fb),
      .O(fb_buf)
  );
  BUFG core_buf (
      .I(raw),
      .O(clk)
  );
  BUFG eth_tx_buffer (
      .I(eth_tx_raw),
      .O(eth_tx_clk)
  );
  BUFG eth_delay_buffer (
      .I(eth_delay_raw),
      .O(eth_delay_clk)
  );
  (* ASYNC_REG = "TRUE" *) logic [2:0] release_reset = 0;
  always_ff @(posedge clk or negedge locked) begin
    if (!locked) release_reset <= 0;
    else release_reset <= {release_reset[1:0], 1'b1};
  end
  wire reset = !release_reset[2];
  logic [15:0] step = 0;
  logic [31:0] checksum = 0;
  wire [31:0] rdata;
  wire irq;
  logic [15:0] waddr;
  logic [31:0] wdata;
  always_ff @(posedge clk) begin
    if (reset) begin
      step <= 0;
      checksum <= 0;
    end else begin
      step <= step + 1'b1;
      checksum <= {checksum[30:0], checksum[31]} ^ rdata;
    end
  end
  always_comb begin
    waddr = 16'h2000 + {5'b0, step[8:0], 2'b0};
    wdata = {step, step};
    case (step[9:0])
      0: begin
        waddr = 8;
        wdata = 1;
      end
      1: begin
        waddr = 16'h10;
        wdata = 3;
      end
      2: begin
        waddr = 16'h14;
        wdata = 2;
      end
      3: begin
        waddr = 16'h1c;
        wdata = 1;
      end
      4: begin
        waddr = 16'h20;
        wdata = 1536;
      end
      5: begin
        waddr = 16'h40;
        wdata = {29'b0, step[12:10]};
      end
      default: ;
    endcase
  end
  rapt_rk_ethernet ethernet (
      .clk,
      .reset,
      .tx_clk(eth_tx_clk),
      .delay_clk(eth_delay_clk),
      .clock_locked(locked),
      .rd(1'b1),
      .wr(!reset),
      .raddr({step[15:2], 2'b0}),
      .waddr,
      .wdata,
      .wstrb(4'hf),
      .rdata,
      .irq,
      .eth_rxc,
      .eth_rx_ctl,
      .eth_rxd,
      .eth_txc,
      .eth_tx_ctl,
      .eth_txd,
      .eth_mdc,
      .eth_mdio
  );
  assign fan_enable = 1'b1;
  assign user_led = {checksum[31], checksum[23], checksum[15], checksum[7]};
  assign serial_tx = irq;
endmodule
