`include "ysyx_macro.v"

module ysyx_BUS_ARBITER(
    input clk, rst,

    // AXI4 Master bus
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [ADDR_W-1:0] io_master_araddr,
    output io_master_arvalid,
    input reg io_master_arready,

    input reg [3:0] io_master_rid,
    input reg io_master_rlast,
    input reg [63:0] io_master_rdata,
    input reg [1:0] io_master_rresp,
    input reg io_master_rvalid,
    output io_master_rready,

    output [1:0] io_master_awburst,
    output [2:0] io_master_awsize,
    output [7:0] io_master_awlen,
    output [3:0] io_master_awid,
    output [ADDR_W-1:0] io_master_awaddr, // reqired
    output io_master_awvalid,             // reqired
    input reg io_master_awready,          // reqired

    output io_master_wlast,               // reqired
    output [63:0] io_master_wdata,        // reqired
    output [7:0] io_master_wstrb,
    output io_master_wvalid,              // reqired
    input reg io_master_wready,           // reqired

    input reg [3:0] io_master_bid,
    input reg [1:0] io_master_bresp,
    input reg io_master_bvalid,           // reqired
    output io_master_bready,              // reqired

    // ifu
    input [DATA_W-1:0] ifu_araddr,
    input ifu_arvalid,
    output [DATA_W-1:0] ifu_rdata_o,
    output ifu_rvalid_o,

    // lsu:load
    input [DATA_W-1:0] lsu_araddr,
    input lsu_arvalid,
    input [7:0] lsu_rstrb,
    output [DATA_W-1:0] lsu_rdata_o,
    output lsu_rvalid_o,

    // lsu:store
    input [DATA_W-1:0] lsu_awaddr,
    input lsu_awvalid,
    input [DATA_W-1:0] lsu_wdata,
    input [7:0] lsu_wstrb,
    input lsu_wvalid,
    output lsu_wready_o
  );
  parameter ADDR_W = 32, DATA_W = 32;

  wire arready_o;
  wire [DATA_W-1:0] rdata_o;

  wire [1:0] rresp_o;
  wire rvalid_o;

  wire sram_wready_o;

  wire [1:0] sram_bresp_o;
  wire sram_bvalid_o;

  // reg lsu_loading = 0, awvalid_record = 0, arvalid_record = 0;
  // always @(posedge clk)
  //   begin
  //     if (rst)
  //       begin
  //         lsu_loading <= 0;
  //         arvalid_record <= 0;
  //         awvalid_record <= 0;
  //       end
  //     else
  //       begin
  //         lsu_loading <= lsu_arvalid;
  //         arvalid_record <= io_master_arvalid;
  //         awvalid_record <= io_master_awready;
  //       end
  //   end

  // read
  wire [ADDR_W-1:0] sram_araddr = (
         (lsu_arvalid) ? lsu_araddr :
         (ifu_arvalid) ? ifu_araddr : 0);

  // ifu read
  assign ifu_rdata_o = ({DATA_W{ifu_arvalid}} & (rdata_o));
  assign ifu_rvalid_o = !lsu_arvalid & (ifu_arvalid & (rvalid_o));

  // lsu read
  wire clint_en = (lsu_araddr == `ysyx_BUS_RTC_ADDR) | (lsu_araddr == `ysyx_BUS_RTC_ADDR_UP);
  assign lsu_rdata_o = ({DATA_W{lsu_arvalid}} & (
                          ({DATA_W{clint_en}} & clint_rdata_o) |
                          ({DATA_W{!clint_en}} & rdata_o)
                        ));
  assign lsu_rvalid_o = lsu_arvalid & (rvalid_o | clint_rvalid_o);
  wire sram_arvalid = (ifu_arvalid | (lsu_arvalid & !clint_en));

  // lsu write
  // wire uart_en = (lsu_awaddr == `ysyx_BUS_SERIAL_PORT);
  // wire uart_wvalid = (lsu_awvalid & (uart_en));
  wire sram_en = (lsu_awaddr != `ysyx_BUS_SERIAL_PORT);
  wire sram_wvalid = (lsu_wvalid & (sram_en));
  wire sram_awvalid = (lsu_wvalid & (sram_en));
  wire [ADDR_W-1:0] awaddr = lsu_awaddr;
  assign lsu_wready_o = (
           //  (uart_en & uart_wready_o) |
           (sram_en & sram_wready_o)
         );

  reg [19:0] lfsr = 1;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk )
    begin
      lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]};
    end

  // io lsu read
  assign io_master_arsize = (
           ({3{lsu_rstrb == 8'h1}} & 3'b000) |
           ({3{lsu_rstrb == 8'h3}} & 3'b001) |
           ({3{lsu_rstrb == 8'hf}} & 3'b010) |
           (3'b000)
         );
  assign io_master_araddr = sram_araddr;
  assign io_master_arvalid = sram_arvalid;
  assign arready_o = io_master_arready & io_master_bvalid;

  // assign rdata_o = io_master_rdata[31:0];
  wire [DATA_W-1:0] io_rdata = (io_master_araddr[2:2] == 1) ?
       io_master_rdata[63:32]:
       io_master_rdata[31:00];
  wire [1:0] araddr_lo = io_master_araddr[1:0];
  assign rdata_o = (
           ({DATA_W{araddr_lo == 2'b00}} & io_rdata) |
           ({DATA_W{araddr_lo == 2'b01}} & {{8'b0}, {io_rdata[31:8]}}) |
           ({DATA_W{araddr_lo == 2'b10}} & {{16'b0}, {io_rdata[31:16]}}) |
           ({DATA_W{araddr_lo == 2'b11}} & {{24'b0}, {io_rdata[31:24]}}) |
           (0)
         );
  // assign rdata_o = (io_master_araddr[2:2] == 1) ?
  //        io_master_rdata[63:32]:
  //        io_master_rdata[31:00];
  assign rresp_o = io_master_rresp;
  assign rvalid_o = io_master_rvalid;
  assign io_master_rready = 1;

  // io lsu write
  assign io_master_awsize = (
           ({3{lsu_wstrb == 8'h1}} & 3'b000) |
           ({3{lsu_wstrb == 8'h3}} & 3'b001) |
           ({3{lsu_wstrb == 8'hf}} & 3'b010) |
           (3'b000)
         );
  assign io_master_awaddr = awaddr;
  assign io_master_awvalid = sram_awvalid;
  wire sram_awready_o = io_master_awready;

  assign io_master_wlast = sram_awvalid;
  // wire [DATA_W-1:0] wdata = lsu_wdata;
  wire [1:0] awaddr_lo = io_master_awaddr[1:0];
  wire [DATA_W-1:0] wdata = {
         ({DATA_W{awaddr_lo == 2'b00}} & lsu_wdata) |
         ({DATA_W{awaddr_lo == 2'b01}} & {{lsu_wdata[23:0]}, {8'b0}}) |
         ({DATA_W{awaddr_lo == 2'b10}} & {{lsu_wdata[15:0]}, {16'b0}}) |
         ({DATA_W{awaddr_lo == 2'b11}} & {{lsu_wdata[7:0]}, {24'b0}}) |
         (0)
       };
  assign io_master_wdata[31:0] = wdata;
  assign io_master_wdata[63:32] = wdata;
  assign io_master_wstrb = (io_master_awaddr[2:2] == 1) ?
         {{lsu_wstrb[3:0] << awaddr_lo}, {4'b0}}:
         {{4'b0}, {lsu_wstrb[3:0] << awaddr_lo}};
  assign io_master_wvalid = sram_wvalid;
  assign sram_wready_o = io_master_wready;

  assign sram_bresp_o = io_master_bresp;
  assign sram_bvalid_o = io_master_bvalid;
  assign io_master_bready = 1;

  // ysyx_MEM_SRAM
  //   #(.ADDR_W(ADDR_W), .DATA_W(DATA_W))
  //   sram(
  //   .clk(clk),
  //   .arburst(2'b00), .arsize(3'b000), .arlen(8'b00000000), .arid(4'b0000),
  //   .araddr(sram_araddr), .arvalid(sram_arvalid), .arready_o(arready_o),
  //   .rid(), .rlast_o(),
  //   .rdata_o(rdata_o), .rresp_o(rresp_o), .rvalid_o(rvalid_o), .rready(1),
  //   .awburst(2'b00), .awsize(3'b000), .awlen(8'b00000000), .awid(4'b0000),
  //   .awaddr(awaddr), .awvalid(sram_awvalid), .awready_o(),
  //   .wlast(1'b0),
  //   .wdata(wdata), .wstrb(lsu_wstrb), .wvalid(sram_wvalid), .wready_o(sram_wready_o),
  //   .bid(),
  //   .bresp_o(sram_bresp_o), .bvalid_o(sram_bvalid_o), .bready(1)
  // );

  always @(posedge clk)
    begin
      `Assert(io_master_rresp, 2'b00);
      `Assert(io_master_bresp, 2'b00);
      if (io_master_awvalid || io_master_arvalid)
        begin
          npc_difftest_mem_diff();
          if (
            (io_master_awaddr >= 'h10000000 && io_master_awaddr <= 'h10000005) ||
            (io_master_araddr >= 'h10000001 && io_master_araddr <= 'h10000005) ||
            (io_master_awaddr >= 'h10001000 && io_master_awaddr <= 'h10001fff) ||
            (io_master_araddr >= 'h10001000 && io_master_araddr <= 'h10001fff) ||
            // (io_master_awaddr >= 'h30000000 && io_master_awaddr <= 'h40000000) ||
            (0)
          )
            begin
              npc_difftest_skip_ref();
            end
        end
    end

  // wire [DATA_W-1:0] uart_rdata_o;
  // wire [1:0] uart_rresp_o, uart_bresp_o;
  // wire uart_arready_o, uart_rvalid_o, uart_awready_o, uart_wready_o, uart_bvalid_o;
  // ysyx_UART #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) uart(
  //             .clk(clk),
  //             .arburst(2'b00), .arsize(3'b000), .arlen(8'b00000000), .arid(4'b0000),
  //             .araddr(0), .arvalid(0), .arready_o(uart_arready_o),
  //             .rid(), .rlast_o(),
  //             .rdata_o(uart_rdata_o), .rresp_o(uart_rresp_o), .rvalid_o(uart_rvalid_o), .rready(0),
  //             .awburst(2'b00), .awsize(3'b000), .awlen(8'b00000000), .awid(4'b0000),
  //             .awaddr(awaddr), .awvalid(sram_awvalid), .awready_o(uart_awready_o),
  //             .wlast(1'b0),
  //             .wdata(wdata), .wstrb(lsu_wstrb), .wvalid(uart_wvalid), .wready_o(uart_wready_o),
  //             .bid(),
  //             .bresp_o(uart_bresp_o), .bvalid_o(uart_bvalid_o), .bready(1)
  //           );

  wire clint_arvalid = (lsu_arvalid & clint_en);
  wire clint_arready_o;
  wire [DATA_W-1:0] clint_rdata_o;
  wire [1:0] clint_rresp_o, clint_bresp_o;
  wire clint_rvalid_o;
  wire clint_awready_o, clint_wready_o, clint_bvalid_o;
  ysyx_CLINT #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) clint(
               .clk(clk), .rst(rst),
               .arburst(2'b00), .arsize(3'b000), .arlen(8'b00000000), .arid(4'b0000),
               .araddr(sram_araddr), .arvalid(clint_arvalid), .arready_o(clint_arready_o),
               .rid(), .rlast_o(),
               .rdata_o(clint_rdata_o), .rresp_o(clint_rresp_o), .rvalid_o(clint_rvalid_o), .rready(1),
               .awburst(2'b00), .awsize(3'b000), .awlen(8'b00000000), .awid(4'b0000),
               .awaddr(0), .awvalid(0), .awready_o(clint_awready_o),
               .wlast(1'b0),
               .wdata(0), .wstrb(0), .wvalid(0), .wready_o(clint_wready_o),
               .bid(),
               .bresp_o(clint_bresp_o), .bvalid_o(clint_bvalid_o), .bready(0)
             );
endmodule
