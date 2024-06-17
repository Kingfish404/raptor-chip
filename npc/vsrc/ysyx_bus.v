`include "ysyx_macro.v"
`include "ysyx_macro_dpi_c.v"

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

  // typedef enum [2:0] {if_a, if_d, ls_a, ls_d_r, ls_d_w} state_t;
  //                   000,  001,  010,    011,    100,
  parameter if_a = 3'b000, if_d = 3'b001, ls_a = 3'b010, ls_d_r = 3'b011, ls_d_w = 3'b100;

  reg [2:0] state;
  reg first = 1;
  reg write_valid = 0;
  always @(posedge clk)
    begin
      if (rst)
        begin
          state <= if_a;
          first <= 1;
        end
      else
        begin
          // $display("state: %d, arready: %d",
          //          state, io_master_arready,);
          case (state)
            if_a:
              begin
                if (first)
                  begin
                    state <= if_d;
                    first <= 0;
                  end
                if (ifu_arvalid & io_master_arready)
                  begin
                    state <= if_d;
                  end
                if (lsu_arvalid | lsu_awvalid)
                  begin
                    state <= ls_a;
                  end
              end
            if_d:
              begin
                if (lsu_arvalid | lsu_awvalid)
                  begin
                    state <= ls_a;
                  end
                else
                  if (io_master_rvalid)
                    begin
                      state <= if_a;
                    end
              end
            ls_a:
              begin
                if (io_master_awvalid & io_master_awready)
                  begin
                    state <= ls_d_w;
                    write_valid <= 1;
                  end
                else if (io_master_arvalid & io_master_arready)
                  begin
                    state <= ls_d_r;
                  end
                else if (clint_en)
                  begin
                    state <= if_a;
                  end
              end
            ls_d_r:
              begin
                if (io_master_rvalid)
                  begin
                    state <= if_a;
                  end
              end
            ls_d_w:
              begin
                if (io_master_wready)
                  begin
                    write_valid <= 0;
                  end
                if (io_master_bvalid)
                  begin
                    state <= if_a;
                  end
              end
            default:
              state <= if_a;
          endcase
        end
    end

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

  // lsu write
  assign lsu_wready_o = io_master_bvalid;

  // io lsu read
  assign io_master_arsize = (
           ({3{lsu_rstrb == 8'h1}} & 3'b000) |
           ({3{lsu_rstrb == 8'h3}} & 3'b001) |
           ({3{lsu_rstrb == 8'hf}} & 3'b010) |
           (3'b000)
         );
  assign io_master_araddr = sram_araddr;
  assign io_master_arvalid = !rst & (
           ((state == if_a) & ifu_arvalid) |
           //  ((state == ls_a) & lsu_arvalid & !clint_en)
           // ((state == ls_a || state == ls_d_r) & lsu_arvalid & !clint_en) // for old soc
           ((state == ls_a) & lsu_arvalid & !clint_en) // for new soc
         );
  assign arready_o = io_master_arready & io_master_bvalid;

  wire [DATA_W-1:0] io_rdata = (io_master_araddr[2:2] == 1) ?
       io_master_rdata[63:32]:
       io_master_rdata[31:00];
  wire [1:0] araddr_lo = io_master_araddr[1:0];
  assign rdata_o = io_rdata;
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
  assign io_master_awaddr = lsu_awaddr;
  assign io_master_awvalid = (state == ls_a) & (lsu_wvalid);

  assign io_master_wlast = ((state == ls_d_w) & write_valid);
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
  assign io_master_wvalid = (
           //  (state == ls_d_w ) & (lsu_wvalid)
           // (state == ls_a || state == ls_d_w) & (lsu_wvalid) // for old soc
           (((state == ls_d_w) & write_valid)) & (lsu_wvalid) // for new soc
         );

  assign io_master_bready = 1;

  always @(posedge clk)
    begin
      `ysyx_Assert(io_master_rresp, 2'b00);
      `ysyx_Assert(io_master_bresp, 2'b00);
      if (io_master_awvalid)
        begin
          `ysyx_DPI_C_npc_difftest_mem_diff
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
                `ysyx_DPI_C_npc_difftest_skip_ref
                  // $display("DIFFTEST: skip ref at aw: %h", io_master_awaddr);
                end
            end
          if (io_master_arvalid)
            begin
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
                  `ysyx_DPI_C_npc_difftest_skip_ref
                    // $display("DIFFTEST: skip ref at ar: %h", io_master_araddr);
                  end
              end
          end

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

// Core Local INTerrupt controller
module ysyx_CLINT(
    input clk, rst,

    input [1:0] arburst,
    input [2:0] arsize,
    input [7:0] arlen,
    input [3:0] arid,
    input [ADDR_W-1:0] araddr,
    input arvalid,
    output reg arready_o,

    output reg [3:0] rid,
    output reg rlast_o,
    output reg [DATA_W-1:0] rdata_o,
    output reg [1:0] rresp_o,
    output reg rvalid_o,
    input rready,

    input [1:0] awburst,
    input [2:0] awsize,
    input [7:0] awlen,
    input [3:0] awid,
    input [ADDR_W-1:0] awaddr,
    input awvalid,
    output reg awready_o,

    input wlast,
    input [DATA_W-1:0] wdata,
    input [7:0] wstrb,
    input wvalid,
    output reg wready_o,

    output reg [3:0] bid,
    output reg [1:0] bresp_o,
    output reg bvalid_o,
    input bready
  );
  parameter ADDR_W = 32, DATA_W = 32;

  reg [63:0] mtime;
  reg [19:0] lfsr;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk )
    begin
      lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]};
    end
  always @(posedge clk)
    begin
      if (rst)
        begin
          mtime <= 0;
          lfsr <= 101;
        end
      else
        begin
          mtime <= mtime + 1;
        end
      rdata_o <= 0;
      rvalid_o <= 0;
      wready_o <= 0;
      if (arvalid & !rvalid_o & rready)
        begin
          if (ifsr_ready)
            begin
              case (araddr)
                unique `ysyx_BUS_RTC_ADDR:
                  rdata_o <= mtime[31:0];
                `ysyx_BUS_RTC_ADDR_UP:
                  rdata_o <= mtime[63:32];
              endcase
              `ysyx_DPI_C_npc_difftest_skip_ref
                rvalid_o <= 1;
            end
        end
      if (wvalid & !wready_o & bready)
        begin
          if (ifsr_ready)
            begin
              wready_o <= 1;
            end
        end
    end
endmodule //ysyx_CLINT
