// RTL8211F RX delay must be disabled (Linux phy-mode = "rgmii-txid").
// The compensated, inverted RX MMCM clock samples the edge-aligned PHY data.
module rapt_rk_rgmii_rx (
    input wire clk,
    reset,
    input wire [3:0] pins,
    input wire ctl,
    output logic [7:0] data,
    output logic valid,
    error
);
  wire [4:0] pad = {ctl, pins};
  wire [4:0] low, high;
  logic [4:0] low_d;
  for (genvar b = 0; b < 5; b++) begin : g_lane
    wire buffered, delayed;
    IBUF input_buf (
        .I(pad[b]),
        .O(buffered)
    );
    IDELAYE3 #(
        .DELAY_SRC("IDATAIN"),
        .CASCADE("NONE"),
        .DELAY_TYPE("FIXED"),
        .DELAY_VALUE(100),
        .REFCLK_FREQUENCY(300.0),
        .DELAY_FORMAT("TIME"),
        .UPDATE_MODE("ASYNC"),
        .SIM_DEVICE("ULTRASCALE_PLUS")
    ) delay_input (
        .CASC_IN(1'b0),
        .CASC_RETURN(1'b0),
        .CE(1'b0),
        .CLK(1'b0),
        .INC(1'b0),
        .LOAD(1'b0),
        .CNTVALUEIN(9'b0),
        .IDATAIN(buffered),
        .DATAIN(1'b0),
        .RST(1'b0),
        .EN_VTC(1'b1),
        .DATAOUT(delayed)
    );
    IDDRE1 #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .IS_C_INVERTED(1'b0),
        .IS_CB_INVERTED(1'b1)
    ) capture (
        .C(clk),
        .CB(clk),
        .R(1'b0),
        .D(delayed),
        .Q1(high[b]),
        .Q2(low[b])
    );
  end
  // Q1 contains high[N-1] while Q2 contains low[N]. Align low and RX_DV
  // with their matching high samples, preserving per-byte RX_ER.
  always_ff @(posedge clk) begin
    low_d <= low;
    data <= {high[3:0], low_d[3:0]};
    valid <= !reset && low_d[4];
    error <= !reset && low_d[4] && (low_d[4] ^ high[4]);
  end
endmodule
