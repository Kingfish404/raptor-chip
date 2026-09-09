// rnp: reduce net protocol (Ring-necked Pheasant)
// axi2rnp: AXI4 to rnp
// rnp2axi: rnp to AXI4
/* verilator lint_off DECLFILENAME */
/* verilator lint_off VARHIDDEN */

module axi2rnp #(
    parameter int XLEN = 32
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

  // The shared payload pins carry one address or one data word at a time.
  // Keep exactly one transaction in flight and retain its AXI response ID.
  typedef enum logic [2:0] {
    IDLE, READ_ADDR, READ_DATA, WRITE_ADDR, WRITE_DATA, WRITE_RESP
  } state_t;
  state_t state;
  logic [3:0] read_id, write_id;

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= IDLE;
      read_id <= '0;
      write_id <= '0;
    end else begin
      case (state)
        IDLE: begin
          if (axi_awvalid) state <= WRITE_ADDR;
          else if (axi_arvalid) state <= READ_ADDR;
        end
        READ_ADDR: if (axi_arvalid && axi_arready) begin
          read_id <= axi_arid;
          state <= READ_DATA;
        end
        READ_DATA: if (axi_rvalid && axi_rready) state <= IDLE;
        WRITE_ADDR: if (axi_awvalid && axi_awready) begin
          write_id <= axi_awid;
          state <= WRITE_DATA;
        end
        WRITE_DATA: if (axi_wvalid && axi_wready) state <= WRITE_RESP;
        WRITE_RESP: if (axi_bvalid && axi_bready) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end

  assign rnp_rwstate = (state == READ_ADDR || state == READ_DATA) ? 2'b01
                    : (state == WRITE_ADDR || state == WRITE_DATA || state == WRITE_RESP) ? 2'b10
                    : 2'b00;
  assign rnp_cdata = state == READ_ADDR ? axi_araddr
                  : state == WRITE_ADDR ? axi_awaddr : axi_wdata;
  assign rnp_arvalid = !reset && state == READ_ADDR && axi_arvalid;
  assign axi_arready = !reset && state == READ_ADDR && rnp_arready;
  assign rnp_rready = !reset && state == READ_DATA && axi_rready;
  assign axi_rvalid = !reset && state == READ_DATA && rnp_rvalid;
  assign axi_rid = read_id;
  assign axi_rlast = 1'b1;
  assign axi_rdata = rnp_mdata;
  assign axi_rresp = 2'b00;

  assign rnp_awvalid = !reset && state == WRITE_ADDR && axi_awvalid;
  assign axi_awready = !reset && state == WRITE_ADDR && rnp_awready;
  assign rnp_wvalid = !reset && state == WRITE_DATA && axi_wvalid;
  assign axi_wready = !reset && state == WRITE_DATA && rnp_wready;
  assign rnp_wstrb = axi_wstrb;
  assign rnp_bready = !reset && state == WRITE_RESP && axi_bready;
  assign axi_bvalid = !reset && state == WRITE_RESP && rnp_bvalid;
  assign axi_bid = write_id;
  assign axi_bresp = 2'b00;

endmodule

module rnp2axi #(
    parameter int XLEN = 32
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

  // RNP transports single-beat writes; LAST is payload, independent of READY.
  assign axi_wlast = 1'b1;
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

// placeholder for top-level module, which can be used for testing or integration
module wrap_rnp #(
) (
    input clk,
    input reset
);

endmodule
