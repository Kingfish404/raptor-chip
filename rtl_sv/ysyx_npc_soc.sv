`include "ysyx.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

// verilator lint_off UNDRIVEN
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off DECLFILENAME
// verilator lint_off UNUSEDSIGNAL
module ysyxSoC #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset
);
  logic auto_master_out_awready;
  logic auto_master_out_awvalid;
  logic [3:0] auto_master_out_awid;
  logic [XLEN-1:0] auto_master_out_awaddr;
  logic [7:0] auto_master_out_awlen;
  logic [2:0] auto_master_out_awsize;
  logic [1:0] auto_master_out_awburst;
  logic auto_master_out_wready;
  logic auto_master_out_wvalid;
  logic [XLEN-1:0] auto_master_out_wdata;
  logic [3:0] auto_master_out_wstrb;
  logic auto_master_out_wlast;
  logic auto_master_out_bready;
  logic auto_master_out_bvalid;
  logic [3:0] auto_master_out_bid;
  logic [1:0] auto_master_out_bresp;
  logic auto_master_out_arready;
  logic auto_master_out_arvalid;
  logic [3:0] auto_master_out_arid;
  logic [XLEN-1:0] auto_master_out_araddr;
  logic [7:0] auto_master_out_arlen;
  logic [2:0] auto_master_out_arsize;
  logic [1:0] auto_master_out_arburst;
  logic auto_master_out_rready;
  logic auto_master_out_rvalid;
  logic [3:0] auto_master_out_rid;
  logic [XLEN-1:0] auto_master_out_rdata;
  logic [1:0] auto_master_out_rresp;
  logic auto_master_out_rlast;

  ysyx cpu (  // src/CPU.scala:38:21
      .clock            (clock),
      .io_interrupt     (1'h0),
      .io_master_awready(auto_master_out_awready),
      .io_master_awvalid(auto_master_out_awvalid),
      .io_master_awid   (auto_master_out_awid),
      .io_master_awaddr (auto_master_out_awaddr),
      .io_master_awlen  (auto_master_out_awlen),
      .io_master_awsize (auto_master_out_awsize),
      .io_master_awburst(auto_master_out_awburst),
      .io_master_wready (auto_master_out_wready),
      .io_master_wvalid (auto_master_out_wvalid),
      .io_master_wdata  (auto_master_out_wdata),
      .io_master_wstrb  (auto_master_out_wstrb),
      .io_master_wlast  (auto_master_out_wlast),
      .io_master_bready (auto_master_out_bready),
      .io_master_bvalid (auto_master_out_bvalid),
      .io_master_bid    (auto_master_out_bid),
      .io_master_bresp  (auto_master_out_bresp),
      .io_master_arready(auto_master_out_arready),
      .io_master_arvalid(auto_master_out_arvalid),
      .io_master_arid   (auto_master_out_arid),
      .io_master_araddr (auto_master_out_araddr),
      .io_master_arlen  (auto_master_out_arlen),
      .io_master_arsize (auto_master_out_arsize),
      .io_master_arburst(auto_master_out_arburst),
      .io_master_rready (auto_master_out_rready),
      .io_master_rvalid (auto_master_out_rvalid),
      .io_master_rid    (auto_master_out_rid),
      .io_master_rdata  (auto_master_out_rdata),
      .io_master_rresp  (auto_master_out_rresp),
      .io_master_rlast  (auto_master_out_rlast),

`ifdef YSYX_USE_SLAVE
      .io_slave_awready(  /* unused */),
      .io_slave_awvalid(1'h0),
      .io_slave_awid   (4'h0),
      .io_slave_awaddr ('h0),
      .io_slave_awlen  (8'h0),
      .io_slave_awsize (3'h0),
      .io_slave_awburst(2'h0),
      .io_slave_wready (  /* unused */),
      .io_slave_wvalid (1'h0),
      .io_slave_wdata  ('h0),
      .io_slave_wstrb  (4'h0),
      .io_slave_wlast  (1'h0),
      .io_slave_bready (1'h0),
      .io_slave_bvalid (  /* unused */),
      .io_slave_bid    (  /* unused */),
      .io_slave_bresp  (  /* unused */),
      .io_slave_arready(  /* unused */),
      .io_slave_arvalid(1'h0),
      .io_slave_arid   (4'h0),
      .io_slave_araddr ('h0),
      .io_slave_arlen  (8'h0),
      .io_slave_arsize (3'h0),
      .io_slave_arburst(2'h0),
      .io_slave_rready (1'h0),
      .io_slave_rvalid (  /* unused */),
      .io_slave_rid    (  /* unused */),
      .io_slave_rdata  (  /* unused */),
      .io_slave_rresp  (  /* unused */),
      .io_slave_rlast  (  /* unused */),
`endif

      .reset(reset)
  );
  ysyx_npc_soc perip (
      .clock(clock),
      .arburst(auto_master_out_arburst),
      .arsize(auto_master_out_arsize),
      .arlen(auto_master_out_arlen),
      .arid(auto_master_out_arid),
      .araddr(auto_master_out_araddr),
      .arvalid(auto_master_out_arvalid),
      .out_arready(auto_master_out_arready),
      .out_rid(auto_master_out_rid),
      .out_rlast(auto_master_out_rlast),
      .out_rdata(auto_master_out_rdata),
      .out_rresp(auto_master_out_rresp),
      .out_rvalid(auto_master_out_rvalid),
      .rready(auto_master_out_rready),
      .awburst(auto_master_out_awburst),
      .awsize(auto_master_out_awsize),
      .awlen(auto_master_out_awlen),
      .awid(auto_master_out_awid),
      .awaddr(auto_master_out_awaddr),
      .awvalid(auto_master_out_awvalid),
      .out_awready(auto_master_out_awready),
      .wlast(auto_master_out_wlast),
      .wdata(auto_master_out_wdata),
      .wstrb(auto_master_out_wstrb),
      .wvalid(auto_master_out_wvalid),
      .out_wready(auto_master_out_wready),
      .out_bid(auto_master_out_bid),
      .out_bresp(auto_master_out_bresp),
      .out_bvalid(auto_master_out_bvalid),
      .bready(auto_master_out_bready),
      .reset(reset)
  );
endmodule

module ysyx_npc_soc #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input [1:0] arburst,
    input [2:0] arsize,
    input [7:0] arlen,
    input [3:0] arid,
    input [XLEN-1:0] araddr,
    input arvalid,
    output logic out_arready,

    output logic [3:0] out_rid,
    output logic out_rlast,
    output logic [XLEN-1:0] out_rdata,
    output logic [1:0] out_rresp,
    output logic out_rvalid,
    input rready,

    input [1:0] awburst,
    input [2:0] awsize,
    input [7:0] awlen,
    input [3:0] awid,
    input [XLEN-1:0] awaddr,
    input awvalid,
    output out_awready,

    input wlast,
    input [XLEN-1:0] wdata,
    input [3:0] wstrb,
    input wvalid,
    output logic out_wready,

    output logic [3:0] out_bid,
    output logic [1:0] out_bresp,
    output logic out_bvalid,
    input bready,

    input reset
);
  typedef enum {
    WIDLE   = 'b000,
    WAREADY = 'b001,
    WDWRITE = 'b010,
    WDREADY = 'b011,
    WFINISH = 'b100
  } state_w_t;
  typedef enum {
    RIDLE  = 'b000,
    RVALID = 'b101
  } state_r_t;

  logic [XLEN-1:0] awaddr_buf;
  logic [31:0] mem_rdata_buf;
  state_r_t state_r;
  state_w_t state_w;

  // read transaction
  assign out_arready = (state_r == RIDLE);
  assign out_rdata   = mem_rdata_buf;
  assign out_rvalid  = (state_r == RVALID);

  // write transaction
  assign out_awready = (state_w == WIDLE);
  assign out_wready  = ((state_w == WIDLE || state_w == WDREADY || state_w == WDWRITE) && wvalid);
  assign out_bvalid  = (state_w == WFINISH);
  logic [7:0] wmask;
  assign wmask = (
    ({{8{awsize == 3'b000}} & 8'h1 }) |
    ({{8{awsize == 3'b001}} & 8'h3 }) |
    ({{8{awsize == 3'b010}} & 8'hf }) |
    (8'h00)
  );

  always @(posedge clock) begin
    if (reset) begin
      state_w <= WIDLE;
      state_r <= RIDLE;
    end else begin
      // AXI4 write transaction
      unique case (state_w)
        WIDLE: begin
          if (awvalid) begin
            if (wvalid) begin
              begin
                if (wstrb[0]) begin
                  `YSYX_DPI_C_PMEM_WRITE((awaddr & ~'h3) + 0, {wdata >>  0}[31:0], 1);
                end
                if (wstrb[1]) begin
                  `YSYX_DPI_C_PMEM_WRITE((awaddr & ~'h3) + 1, {wdata >>  8}[31:0], 1);
                end
                if (wstrb[2]) begin
                  `YSYX_DPI_C_PMEM_WRITE((awaddr & ~'h3) + 2, {wdata >> 16}[31:0], 1);
                end
                if (wstrb[3]) begin
                  `YSYX_DPI_C_PMEM_WRITE((awaddr & ~'h3) + 3, {wdata >> 24}[31:0], 1);
                end
              end
            end
            if (wlast) begin
              state_w <= WFINISH;
            end else begin
              state_w <= WDWRITE;
            end
            awaddr_buf <= awaddr;
          end
        end
        WDWRITE: begin
          if (wvalid) begin
            begin
              if (wstrb[0]) begin
                `YSYX_DPI_C_PMEM_WRITE((awaddr_buf & ~'h3) + 0, {wdata >>  0}[31:0], 1);
              end
              if (wstrb[1]) begin
                `YSYX_DPI_C_PMEM_WRITE((awaddr_buf & ~'h3) + 1, {wdata >>  8}[31:0], 1);
              end
              if (wstrb[2]) begin
                `YSYX_DPI_C_PMEM_WRITE((awaddr_buf & ~'h3) + 2, {wdata >> 16}[31:0], 1);
              end
              if (wstrb[3]) begin
                `YSYX_DPI_C_PMEM_WRITE((awaddr_buf & ~'h3) + 3, {wdata >> 24}[31:0], 1);
              end
            end
          end
          if (wlast) begin
            state_w <= WFINISH;
          end
        end
        WDREADY: begin
          state_w <= WFINISH;
        end
        WFINISH: begin
          if (bready) begin
            state_w <= WIDLE;
          end
        end
        default: begin
          state_w <= WIDLE;
        end
      endcase

      // AXI4 read transaction
      unique case (state_r)
        RIDLE: begin
          // wait for arvalid
          if (arvalid) begin
            state_r <= RVALID;
            `YSYX_DPI_C_PMEM_READ((araddr), mem_rdata_buf);
          end
        end
        RVALID: begin
          state_r <= RIDLE;
        end
        default: begin
          state_r <= RIDLE;
        end
      endcase
    end
  end
endmodule

// verilator lint_on PINCONNECTEMPTY
// verilator lint_on UNDRIVEN
// verilator lint_on DECLFILENAME
// verilator lint_on UNUSEDSIGNAL
