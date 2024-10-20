`include "ysyx.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx_bus (
    input clock,
    input reset,

    // AXI4 Master bus
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output io_master_arvalid,
    input io_master_arready,

    input [3:0] io_master_rid,
    input io_master_rlast,
    input [XLEN-1:0] io_master_rdata,
    input [1:0] io_master_rresp,
    input io_master_rvalid,
    output io_master_rready,

    output [     1:0] io_master_awburst,
    output [     2:0] io_master_awsize,
    output [     7:0] io_master_awlen,
    output [     3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,   // reqired
    output            io_master_awvalid,  // reqired
    input             io_master_awready,  // reqired

    output            io_master_wlast,   // reqired
    output [XLEN-1:0] io_master_wdata,   // reqired
    output [     3:0] io_master_wstrb,
    output            io_master_wvalid,  // reqired
    input             io_master_wready,  // reqired

    input  [3:0] io_master_bid,
    input  [1:0] io_master_bresp,
    input        io_master_bvalid,  // reqired
    output       io_master_bready,  // reqired

    // ifu
    input [XLEN-1:0] ifu_araddr,
    input ifu_arvalid,
    input ifu_required,
    output [XLEN-1:0] out_ifu_rdata,
    output out_ifu_rvalid,

    // lsu:load
    input [XLEN-1:0] lsu_araddr,
    input lsu_arvalid,
    input [7:0] lsu_rstrb,
    output [XLEN-1:0] out_lsu_rdata,
    output out_lsu_rvalid,

    // lsu:store
    input [XLEN-1:0] lsu_awaddr,
    input lsu_awvalid,
    input [XLEN-1:0] lsu_wdata,
    input [7:0] lsu_wstrb,
    input lsu_wvalid,
    output out_lsu_wready
);
  parameter bit [7:0] XLEN = 32;

  wire arready;
  wire [XLEN-1:0] out_rdata;

  wire rvalid;

  // typedef enum [2:0] {IF_A, IF_D, LS_A, LS_R} state_t;
  //                      000,  001,  010,    011
  parameter bit [3:0] IF_A = 'b0001, IF_D = 'b0010, LS_A = 'b0100, LS_R = 'b1000;
  parameter bit [2:0] LS_S_A = 'b001, LS_S_W = 'b010, LS_S_B = 'b100;

  reg [3:0] state;
  reg first = 1;
  reg write_done = 0, awrite_done = 0;

  assign io_master_arid = 0;

  assign io_master_awburst = 0;
  assign io_master_awlen = 0;
  assign io_master_awid = 0;

  always @(posedge clock) begin
    if (reset) begin
      state <= IF_A;
      first <= 1;
    end else begin
      // $display("state: %d, arready: %d",
      //          state, io_master_arready,);
      case (state)
        IF_A: begin
          if (first) begin
            state <= IF_D;
            first <= 0;
          end
          if (ifu_arvalid) begin
            if (io_master_arready) begin
              state <= IF_D;
            end
          end else if (!ifu_required & (lsu_arvalid)) begin
            state <= LS_A;
          end
        end
        IF_D: begin
          if (io_master_rvalid) begin
            begin
              state <= IF_A;
            end
          end
        end
        LS_A: begin
          if (io_master_arvalid & io_master_arready) begin
            state <= LS_R;
          end else if (clint_en | ifu_arvalid) begin
            state <= IF_A;
          end
        end
        LS_R: begin
          if (io_master_rvalid) begin
            state <= IF_A;
          end
        end
        default: state <= IF_A;
      endcase
    end
  end

  reg [2:0] state_store;
  always @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_A;
    end else begin
      case (state_store)
        LS_S_A: begin
          if (lsu_awvalid) begin
            state_store <= LS_S_W;
            awrite_done <= 0;
            write_done  <= 0;
          end
        end
        LS_S_W: begin
          if (lsu_wvalid) begin
            if (io_master_awready) begin
              awrite_done <= 1;
            end
            if (io_master_wready) begin
              write_done <= 1;
            end
            if (io_master_bvalid) begin
              state_store <= LS_S_B;
            end
          end
        end
        LS_S_B: begin
          state_store <= LS_S_A;
        end
        default: state_store <= LS_S_W;
      endcase
    end
  end

  // read
  wire [XLEN-1:0] sram_araddr = (
    ({XLEN{lsu_arvalid}} & lsu_araddr) |
    ({XLEN{ifu_arvalid}} & ifu_araddr)
  );

  // ifu read
  assign out_ifu_rdata  = ({XLEN{out_ifu_rvalid}} & (out_rdata));
  assign out_ifu_rvalid = (state == IF_D | state == IF_A) & ((rvalid));

  // lsu read
  wire clint_en = (lsu_araddr == `YSYX_BUS_RTC_ADDR) | (lsu_araddr == `YSYX_BUS_RTC_ADDR_UP);
  assign out_lsu_rdata = ({XLEN{lsu_arvalid}} & (
                          ({XLEN{clint_en}} & out_clint_rdata) |
                          ({XLEN{!clint_en}} & out_rdata)
                        ));
  assign out_lsu_rvalid = (
    (state == LS_R | clint_arvalid) &
    (lsu_arvalid) &
    (rvalid | out_clint_rvalid));

  // lsu write
  assign out_lsu_wready = io_master_bvalid;

  // io lsu read
  wire ifu_sdram_arburst = (
    `YSYX_I_SDRAM_ARBURST & ifu_arvalid &
    (ifu_araddr >= 'ha0000000) & (ifu_araddr <= 'hc0000000));
  assign io_master_arburst = ifu_sdram_arburst ? 2'b01 : 2'b00;
  assign io_master_arsize = (
           ({3{lsu_rstrb == 8'h1}} & 3'b000) |
           ({3{lsu_rstrb == 8'h3}} & 3'b001) |
           ({3{lsu_rstrb == 8'hf | ifu_arvalid}} & 3'b010) |
           (3'b000)
         );
  assign io_master_arlen = ifu_sdram_arburst ? 'h1 : 'h0;
  assign io_master_araddr = sram_araddr;
  assign io_master_arvalid = !reset & (
           ((state == IF_A) & ifu_arvalid) |
           ((state == LS_A) & lsu_arvalid & !clint_en) // for new soc
      );
  assign arready = io_master_arready & io_master_bvalid;

  // wire [XLEN-1:0] io_rdata = (io_master_araddr[2:2] == 1) ?
  //      io_master_rdata[63:32]:
  //      io_master_rdata[31:00];
  wire [XLEN-1:0] io_rdata = io_master_rdata;
  wire [1:0] araddr_lo = io_master_araddr[1:0];
  assign out_rdata = io_rdata;
  assign rvalid = io_master_rvalid;
  assign io_master_rready = 1;

  // io lsu write
  assign io_master_awsize = (
           ({3{lsu_wstrb == 8'h1}} & 3'b000) |
           ({3{lsu_wstrb == 8'h3}} & 3'b001) |
           ({3{lsu_wstrb == 8'hf}} & 3'b010) |
           (3'b000)
         );
  assign io_master_awaddr = lsu_awaddr;
  assign io_master_awvalid = (state_store == LS_S_W) & (lsu_wvalid) & !awrite_done;

  assign io_master_wlast = io_master_wvalid;
  wire [1:0] awaddr_lo = io_master_awaddr[1:0];
  wire [XLEN-1:0] wdata = {
    ({XLEN{awaddr_lo == 2'b00}} & {{lsu_wdata}}) |
    ({XLEN{awaddr_lo == 2'b01}} & {{lsu_wdata[23:0]}, {8'b0}}) |
    ({XLEN{awaddr_lo == 2'b10}} & {{lsu_wdata[15:0]}, {16'b0}}) |
    ({XLEN{awaddr_lo == 2'b11}} & {{lsu_wdata[7:0]}, {24'b0}}) |
    (0)
  };
  assign io_master_wdata = wdata;
  assign io_master_wstrb = {wstrb};
  wire [3:0] wstrb = {lsu_wstrb[3:0] << awaddr_lo};
  assign io_master_wvalid = (state_store == LS_S_W) & (lsu_wvalid) & !write_done;

  assign io_master_bready = 1;

  always @(posedge clock) begin
    `YSYX_ASSERT(io_master_rresp, 2'b00);
    `YSYX_ASSERT(io_master_bresp, 2'b00);
    if (io_master_awvalid) begin
      `YSYX_DPI_C_NPC_DIFFTEST_MEM_DIFF
      if (
              (io_master_awaddr >= 'h10000000 && io_master_awaddr <= 'h10000005) ||
              (io_master_awaddr >= 'h10001000 && io_master_awaddr <= 'h10001fff) ||
              (io_master_awaddr >= 'h10002000 && io_master_awaddr <= 'h1000200f) ||
              (io_master_awaddr >= 'h10011000 && io_master_awaddr <= 'h10011007) ||
              (io_master_awaddr >= 'h21000000 && io_master_awaddr <= 'h211fffff) ||
              (io_master_awaddr >= 'hc0000000) ||
              (0)
            )
              begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        // $display("DIFFTEST: skip ref at aw: %h", io_master_awaddr);
      end
    end
    if (io_master_arvalid) begin
      if (
                (io_master_araddr >= 'h10000000 && io_master_araddr <= 'h10000005) ||
                (io_master_araddr >= 'h10001000 && io_master_araddr <= 'h10001fff) ||
                (io_master_araddr >= 'h10002000 && io_master_araddr <= 'h1000200f) ||
                (io_master_araddr >= 'h10011000 && io_master_araddr <= 'h10011007) ||
                (io_master_araddr >= 'h21000000 && io_master_araddr <= 'h211fffff) ||
                (io_master_araddr >= 'hc0000000) ||
                (0)
              )
                begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        // $display("DIFFTEST: skip ref at ar: %h", io_master_araddr);
      end
    end
  end

  wire clint_arvalid = (lsu_arvalid & clint_en);
  wire out_clint_arready;
  wire [XLEN-1:0] out_clint_rdata;
  wire [1:0] out_clint_rresp;
  wire out_clint_rvalid;
  ysyx_clint clint (
      .clock(clock),
      .reset(reset),
      .araddr(sram_araddr),
      .arvalid(clint_arvalid),
      .out_arready(out_clint_arready),
      .out_rdata(out_clint_rdata),
      .out_rresp(out_clint_rresp),
      .out_rvalid(out_clint_rvalid)
  );
endmodule

// Core Local INTerrupt controller
module ysyx_clint (
    input clock,
    input reset,

    input [XLEN-1:0] araddr,
    input arvalid,
    output out_arready,

    output [XLEN-1:0] out_rdata,
    output [1:0] out_rresp,
    output reg out_rvalid
);
  parameter bit [7:0] XLEN = 32;

  reg [63:0] mtime = 0;
  assign out_rdata = (
    ({32{araddr == `YSYX_BUS_RTC_ADDR}} & mtime[31:0]) |
    ({32{araddr == `YSYX_BUS_RTC_ADDR_UP}} & mtime[63:32])
  );
  assign out_arready = 0;
  assign out_rresp = 0;
  always @(posedge clock) begin
    if (reset) begin
      mtime <= 0;
    end else begin
      mtime <= mtime + 1;
      if (arvalid) begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        out_rvalid <= 1;
      end else begin
        out_rvalid <= 0;
      end
    end
  end
endmodule  //ysyx_CLINT
