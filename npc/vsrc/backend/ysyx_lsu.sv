`include "ysyx.svh"

module ysyx_lsu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_LEN = `YSYX_L1D_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_SIZE = 2 ** L1D_LEN
) (
    input clock,

    input fence_time,

    // from exu
    input [XLEN-1:0] raddr,
    input [XLEN-1:0] waddr,
    input [4:0] ralu,
    input [4:0] walu,
    input ren,
    input wen,
    input [XLEN-1:0] wdata,
    // to exu
    output [XLEN-1:0] out_rdata,
    output out_rvalid,
    output out_wready,

    // to bus load
    output [XLEN-1:0] out_lsu_araddr,
    output out_lsu_arvalid,
    output [7:0] out_lsu_rstrb,
    // from bus load
    input [XLEN-1:0] bus_rdata,
    input lsu_rvalid,

    // to bus store
    output [XLEN-1:0] out_lsu_awaddr,
    output out_lsu_awvalid,
    output [XLEN-1:0] out_lsu_wdata,
    output [7:0] out_lsu_wstrb,
    output out_lsu_wvalid,
    // from bus store
    input logic lsu_wready,

    input reset
);
  typedef enum logic [1:0] {
    IF_A = 0,
    IF_L = 1,
    IF_V = 2
  } state_load_t;

  typedef enum logic [1:0] {
    LS_S_V = 0,
    LS_S_R = 1
  } state_store_t;

  state_load_t  state_load;
  state_store_t state_store;

  logic [XLEN-1:0] rdata, rdata_unalign;
  logic [7:0] wstrb, rstrb;
  logic arvalid;

  logic [32-1:0] l1d[L1D_SIZE], lsu_rdata;
  logic [L1D_SIZE-1:0] l1d_valid;
  logic [32-L1D_LEN-2-1:0] l1d_tag[L1D_SIZE];

  logic [32-L1D_LEN-2-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic l1d_cache_hit;
  logic uncacheable;

  logic [32-L1D_LEN-2-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic l1d_cache_hit_w;
  logic raddr_valid;

  assign raddr_valid = (  //
      (raddr >= 'h02000048 && raddr < 'h02000050) ||  // clint
      (raddr >= 'h0f000000 && raddr < 'h0f002000) ||  // sram
      (raddr >= 'h10000000 && raddr < 'h10001000) ||  // uart/ns16550
      (raddr >= 'h10010000 && raddr < 'h10011900) ||  // liteuart0/csr
      (raddr >= 'h20000000 && raddr < 'h20400000) ||  // mrom
      (raddr >= 'h30000000 && raddr < 'h40000000) ||  // flash
      (raddr >= 'h80000000 && raddr < 'h88000000) ||  // psram
      (raddr >= 'ha0000000 && raddr < 'hc0000000) ||  // sdram
      (0));

  assign out_lsu_araddr = raddr;
  assign out_lsu_arvalid = arvalid;
  assign arvalid = ren && raddr_valid && state_load == IF_L;
  assign out_lsu_rstrb = rstrb;

  assign rdata_unalign = lsu_rdata;
  assign out_rvalid = state_load == IF_V;

  assign out_lsu_awaddr = waddr;
  assign out_lsu_awvalid = wen && state_store == LS_S_V;

  assign out_lsu_wdata = wdata;
  assign out_lsu_wstrb = wstrb;
  assign out_lsu_wvalid = wen && state_store == LS_S_V;

  assign out_wready = state_store == LS_S_R;

  assign l1d_cache_hit = (l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  assign addr_tag = raddr[XLEN-1:L1D_LEN+2];
  assign addr_idx = raddr[L1D_LEN+2-1:0+2];
  assign uncacheable = (
         (raddr >= 'h02000048 && raddr < 'h02000050) ||
         (raddr >= 'h0c000000 && raddr < 'h0d000000) ||
         (raddr >= 'h10000000 && raddr < 'h10020000) ||
         (raddr >= 'ha0000000 && raddr < 'hb0000000) ||
         (0)
       );

  assign waddr_tag = waddr[XLEN-1:L1D_LEN+2];
  assign waddr_idx = waddr[L1D_LEN+2-1:0+2];
  assign l1d_cache_hit_w = (l1d_valid[waddr_idx] == 1'b1) && (l1d_tag[waddr_idx] == waddr_tag);

  // load/store unit
  // assign wstrb = (
  //          ({8{ralu == `YSYX_ALU_SB}} & 8'h1) |
  //          ({8{ralu == `YSYX_ALU_SH}} & 8'h3) |
  //          ({8{ralu == `YSYX_ALU_SW}} & 8'hf)
  //        );
  assign wstrb = {{4{1'b0}}, {walu[3:0]}};
  assign rstrb = (
           ({8{ralu == `YSYX_ALU_LB__}} & 8'h1) |
           ({8{ralu == `YSYX_ALU_LBU_}} & 8'h1) |
           ({8{ralu == `YSYX_ALU_LH__}} & 8'h3) |
           ({8{ralu == `YSYX_ALU_LHU_}} & 8'h3) |
           ({8{ralu == `YSYX_ALU_LW__}} & 8'hf)
         );

  assign rdata = (
           ({XLEN{raddr[1:0] == 2'b00}} & rdata_unalign) |
           ({XLEN{raddr[1:0] == 2'b01}} & {{8'b0}, {rdata_unalign[31:8]}}) |
           ({XLEN{raddr[1:0] == 2'b10}} & {{16'b0}, {rdata_unalign[31:16]}}) |
           ({XLEN{raddr[1:0] == 2'b11}} & {{24'b0}, {rdata_unalign[31:24]}}) |
           (0)
         );
  assign out_rdata = (
           ({XLEN{ralu == `YSYX_ALU_LB__}} & (rdata[7] ? rdata | 'hffffff00 : rdata & 'hff)) |
           ({XLEN{ralu == `YSYX_ALU_LBU_}} & rdata & 'hff) |
           ({XLEN{ralu == `YSYX_ALU_LH__}} &
              (rdata[15] ? rdata | 'hffff0000 : rdata & 'hffff)) |
           ({XLEN{ralu == `YSYX_ALU_LHU_}} & rdata & 'hffff) |
           ({XLEN{ralu == `YSYX_ALU_LW__}} & rdata)
         );
  always @(posedge clock) begin
    if (reset) begin
      l1d_valid   <= 0;
      state_load  <= IF_A;
      state_store <= LS_S_V;
    end else begin
      unique case (state_load)
        IF_A: begin
          if (fence_time) begin
            l1d_valid <= 0;
          end
          if (ren) begin
            if (l1d_cache_hit) begin
              state_load <= IF_V;
              lsu_rdata  <= l1d[addr_idx];
            end else begin
              state_load <= IF_L;
            end
          end
        end
        IF_L: begin
          if (ren && lsu_rvalid) begin
            lsu_rdata  <= bus_rdata;
            state_load <= IF_V;
            if (!uncacheable) begin
              l1d[addr_idx] <= bus_rdata;
              l1d_tag[addr_idx] <= addr_tag;
              l1d_valid[addr_idx] <= 1'b1;
            end
          end
        end
        IF_V: begin
          state_load <= IF_A;
        end
        default: begin
          state_load <= IF_A;
        end
      endcase

      unique case (state_store)
        LS_S_V: begin
          if (wen) begin
            if (l1d_cache_hit_w) begin
              l1d_valid[waddr_idx] <= 1'b0;
            end
            if (lsu_wready) begin
              state_store <= LS_S_R;
            end
          end
        end
        LS_S_R: begin
          state_store <= LS_S_V;
        end
        default: begin
          state_store <= LS_S_V;
        end
      endcase
    end
  end
endmodule
