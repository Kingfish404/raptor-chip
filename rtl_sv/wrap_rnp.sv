// rnp: reduce net protocol (Ring-necked Pheasant)
// axi2rnp: AXI4 to rnp
// rnp2axi: rnp to AXI4
/* verilator lint_off DECLFILENAME */
/* verilator lint_off VARHIDDEN */

module axi2rnp #(
    parameter bit [7:0] XLEN = 32
) (
    input clk,
    input reset,

    // AXI4 signals
    input [1:0] axi_arburst,  // No info
    input [2:0] axi_arsize,  // No info
    input [7:0] axi_arlen,  // No info
    input [3:0] axi_arid,  // No info
    input [XLEN-1:0] axi_araddr,  // rnp_cdata
    input axi_arvalid,  // rnp_arvalid
    output logic axi_arready,  // rnp_arready

    output logic [3:0] axi_rid,  // No info
    output logic axi_rlast,  // No info
    output logic [XLEN-1:0] axi_rdata,  // rnp_mdata
    output logic [1:0] axi_rresp,  // No info
    output logic axi_rvalid,  // rnp_rvalid
    input axi_rready,  // rnp_rready

    input [1:0] axi_awburst,  // No info
    input [2:0] axi_awsize,  // No info
    input [7:0] axi_awlen,  // No info
    input [3:0] axi_awid,  // No info
    input [XLEN-1:0] axi_awaddr,  // rnp_cdata
    input axi_awvalid,  // rnp_awvalid
    output logic axi_awready,  // rnp_awready

    input axi_wlast,  // No info
    input [XLEN-1:0] axi_wdata,  // rnp_cdata
    input [3:0] axi_wstrb,  // rnp_wstrb
    input axi_wvalid,  // rnp_wvalid
    output logic axi_wready,  // rnp_wready

    output logic [3:0] axi_bid,  // No info
    output logic [1:0] axi_bresp,  // No info
    output logic axi_bvalid,  // rnp_bvalid
    input axi_bready,  // rnp_bready

    // RNP signals
    input [XLEN-1:0] rnp_mdata,
    output logic [XLEN-1:0] rnp_cdata,

    output logic rnp_arvalid,
    input rnp_arready,

    input rnp_rvalid,
    output logic rnp_rready,

    output logic rnp_awvalid,
    input rnp_awready,

    output logic [3:0] rnp_wstrb,
    output logic rnp_wvalid,
    input rnp_wready,

    input rnp_bvalid,
    output logic rnp_bready,

    output logic [1:0] rnp_rwstate
);

  assign rnp_arvalid = axi_arvalid;
  // assign axi_arready = rnp_arready;

  assign axi_rid = 0;
  assign axi_rlast = rnp_rvalid && axi_rready;
  assign axi_rdata = rnp_mdata;
  assign axi_rresp = 0;
  // assign axi_rvalid = rnp_rvalid;
  assign rnp_rready = axi_rready;

  assign rnp_awvalid = axi_awvalid;
  // assign axi_awready = rnp_awready;


  assign rnp_wstrb = axi_wstrb;
  assign rnp_wvalid = axi_wvalid;
  // assign axi_wready = rnp_wready;

  assign axi_bid = 0;
  assign axi_bresp = 0;
  // assign axi_bvalid = rnp_bvalid;
  assign rnp_bready = axi_bready;

  reg   [1:0] rwstate_last;  // 00: idle, 01: read, 10: write, 11: undefined
  logic [1:0] rwstate;

  assign rnp_rwstate = rwstate;

  logic state_rst;
  reg [19:0] state_rst_cnt;
  logic state_rst_cnt_rst;

  always @(posedge clk) begin
    if (reset || state_rst_cnt_rst) begin
      state_rst_cnt <= 0;
    end else begin
      state_rst_cnt <= state_rst_cnt + 1;
    end
  end

  assign state_rst = &state_rst_cnt;

  always @(posedge clk) begin
    if (reset || state_rst) begin
      rwstate_last <= 2'b00;
    end else begin
      rwstate_last <= rwstate;
    end
  end

  always_comb begin
    if (reset || state_rst) begin
      rwstate = 2'b00;
      state_rst_cnt_rst = 1;
    end else begin
      if (rwstate_last == 2'b00) begin  // idle
        state_rst_cnt_rst = 1;
        if (axi_awvalid) begin
          rwstate = 2'b10;
        end else if (axi_arvalid) begin
          rwstate = 2'b01;
        end else begin
          rwstate = 2'b00;
        end
      end else if (rwstate_last == 2'b01) begin  // read
        if (rnp_rvalid && axi_rready) begin  // read end
          state_rst_cnt_rst = 1;
          if (axi_awvalid) begin
            rwstate = 2'b10;
          end else if (axi_arvalid) begin
            rwstate = 2'b01;
          end else begin
            rwstate = 2'b00;
          end
        end else begin
          state_rst_cnt_rst = 0;
          rwstate = 2'b01;  // read
        end
      end else begin  // write
        if (rnp_bvalid && axi_bready) begin  // write end
          state_rst_cnt_rst = 1;
          if (axi_awvalid) begin
            rwstate = 2'b10;
          end else if (axi_arvalid) begin
            rwstate = 2'b01;
          end else begin
            rwstate = 2'b00;
          end
        end else begin
          state_rst_cnt_rst = 0;
          rwstate = 2'b10;  // write
        end
      end
    end
  end

  always_comb begin
    case (rwstate)
      2'b01: begin
        axi_arready = rnp_arready;
        axi_rvalid  = rnp_rvalid;
        axi_awready = 0;
        axi_wready  = rnp_wready;
        axi_bvalid  = rnp_bvalid;
        rnp_cdata   = axi_araddr;
      end
      2'b10: begin
        axi_arready = 0;
        axi_rvalid  = rnp_rvalid;
        axi_awready = rnp_awready;
        axi_wready  = rnp_wready;
        axi_bvalid  = rnp_bvalid;
        if (axi_awvalid) begin
          rnp_cdata = axi_awaddr;
        end else begin
          rnp_cdata = axi_wdata;
        end
      end
      default: begin
        axi_arready = rnp_arready;
        axi_rvalid  = rnp_rvalid;
        axi_awready = rnp_awready;
        axi_wready  = rnp_wready;
        axi_bvalid  = rnp_bvalid;
        rnp_cdata   = 0;
      end
    endcase
  end

endmodule

module rnp2axi #(
    parameter bit [7:0] XLEN = 32
) (
    input clk,
    input reset,

    // AXI4 signals
    output logic [1:0] axi_arburst,  // No info
    output logic [2:0] axi_arsize,  // No info
    output logic [7:0] axi_arlen,  // No info
    output logic [3:0] axi_arid,  // No info
    output logic [XLEN-1:0] axi_araddr,  // rnp_cdata
    output logic axi_arvalid,  // rnp_arvalid
    input axi_arready,  // rnp_arready

    input [3:0] axi_rid,  // No info
    input axi_rlast,  // No info
    input [XLEN-1:0] axi_rdata,  // rnp_mdata
    input [1:0] axi_rresp,  // No info
    input axi_rvalid,  // rnp_rvalid
    output logic axi_rready,  // rnp_rready

    output logic [1:0] axi_awburst,  // No info
    output logic [2:0] axi_awsize,  // No info
    output logic [7:0] axi_awlen,  // No info
    output logic [3:0] axi_awid,  // No info
    output logic [XLEN-1:0] axi_awaddr,  // rnp_cdata
    output logic axi_awvalid,  // rnp_awvalid
    input axi_awready,  // rnp_awready

    output logic axi_wlast,  // No info
    output logic [XLEN-1:0] axi_wdata,  // rnp_cdata
    output logic [3:0] axi_wstrb,  // rnp_wstrb
    output logic axi_wvalid,  // rnp_wvalid
    input axi_wready,  // rnp_wready

    input [3:0] axi_bid,  // No info
    input [1:0] axi_bresp,  // No info
    input axi_bvalid,  // rnp_bvalid
    output logic axi_bready,  // rnp_bready

    // RNP signals
    output logic [XLEN-1:0] rnp_mdata,
    input  logic [XLEN-1:0] rnp_cdata,

    input rnp_arvalid,
    output logic rnp_arready,

    output logic rnp_rvalid,
    input rnp_rready,

    input rnp_awvalid,
    output logic rnp_awready,

    input [3:0] rnp_wstrb,
    input rnp_wvalid,
    output logic rnp_wready,

    output logic rnp_bvalid,
    input rnp_bready,

    input [1:0] rnp_rwstate
);

  assign axi_arburst = 0;
  assign axi_arsize = 2;
  assign axi_arlen = 0;
  assign axi_arid = 0;
  assign axi_araddr = rnp_cdata;
  // assign axi_arvalid = rnp_arvalid;
  assign rnp_arready = axi_arready;

  assign rnp_rvalid = axi_rvalid;
  // assign axi_rready = rnp_rready;

  assign axi_awburst = 0;
  assign axi_awsize = 2;
  assign axi_awlen = 0;
  assign axi_awid = 0;
  assign axi_awaddr = rnp_cdata;
  // assign axi_awvalid = rnp_awvalid;
  assign rnp_awready = axi_awready;

  assign axi_wlast = rnp_wvalid && axi_wready;
  assign axi_wdata = rnp_cdata;
  assign axi_wstrb = rnp_wstrb;
  // assign axi_wvalid = rnp_wvalid;
  assign rnp_wready = axi_wready;

  assign rnp_bvalid = axi_bvalid;
  // assign axi_bready = rnp_bready;

  assign rnp_mdata = axi_rdata;

  always_comb begin
    case (rnp_rwstate)
      2'b01: begin
        axi_arvalid = rnp_arvalid;
        axi_rready  = rnp_rready;
        axi_awvalid = 0;
        axi_wvalid  = rnp_wvalid;
        axi_bready  = rnp_bready;

      end
      2'b10: begin
        axi_arvalid = 0;
        axi_rready  = rnp_rready;
        axi_awvalid = rnp_awvalid;
        axi_wvalid  = rnp_wvalid;
        axi_bready  = rnp_bready;
      end
      default: begin
        axi_arvalid = rnp_arvalid;
        axi_rready  = rnp_rready;
        axi_awvalid = rnp_awvalid;
        axi_wvalid  = rnp_wvalid;
        axi_bready  = rnp_bready;
      end
    endcase
  end

endmodule
