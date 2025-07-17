`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_lsu_l1d #(
    parameter bit [`YSYX_L1D_LEN:0] L1D_LEN = `YSYX_L1D_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_SIZE = 2 ** `YSYX_L1D_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input flush_pipe,
    input invalid_l1d,

    // read
    input logic [XLEN-1:0] raddr,
    input logic rvalid,
    input [4:0] ralu,
    output logic [XLEN-1:0] lsu_rdata,
    output logic lsu_rready,

    // write
    input logic [XLEN-1:0] waddr,
    input logic wvalid,
    input logic [XLEN-1:0] wdata,
    input logic [4:0] walu,

    // to bus
    lsu_bus_if.master lsu_bus,

    input reset
);
  typedef enum logic [1:0] {
    IF_A = 0,
    IF_L = 1,
    IF_V = 2
  } state_load_t;

  state_load_t state_load;

  logic [XLEN-1:0] l1d[L1D_SIZE];
  logic [L1D_SIZE-1:0] l1d_valid;
  logic [32-L1D_LEN-2-1:0] l1d_tag[L1D_SIZE];
  logic [7:0] rstrb;

  logic [32-L1D_LEN-2-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic l1d_cache_hit;
  logic [XLEN-1:0] l1d_data;
  logic cacheable;
  logic cacheable_w;

  logic [32-L1D_LEN-2-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic l1d_cache_hit_w;

  logic l1d_update;
  logic [XLEN-1:0] l1d_data_u;
  logic l1d_valid_u;
  logic [32-L1D_LEN-2-1:0] l1d_tag_u;
  logic [L1D_LEN-1:0] l1d_idx;

  assign rstrb = (
           ({8{ralu == `YSYX_ALU_LB__}} & 8'h1) |
           ({8{ralu == `YSYX_ALU_LBU_}} & 8'h1) |
           ({8{ralu == `YSYX_ALU_LH__}} & 8'h3) |
           ({8{ralu == `YSYX_ALU_LHU_}} & 8'h3) |
           ({8{ralu == `YSYX_ALU_LW__}} & 8'hf)
         );

  assign addr_tag = raddr[XLEN-1:L1D_LEN+2];
  assign addr_idx = raddr[L1D_LEN+2-1:0+2];
  assign l1d_cache_hit = (l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  assign l1d_data = l1d[addr_idx];

  assign lsu_rready = (state_load == IF_V);

  assign waddr_tag = waddr[XLEN-1:L1D_LEN+2];
  assign waddr_idx = waddr[L1D_LEN+2-1:0+2];
  assign l1d_cache_hit_w = (l1d_valid[waddr_idx] == 1'b1) && (l1d_tag[waddr_idx] == waddr_tag);

  assign cacheable = ((0)  //
      || (raddr >= 'h20000000 && raddr < 'h20400000)  // mrom
      || (raddr >= 'h30000000 && raddr < 'h40000000)  // flash
      || (raddr >= 'h80000000 && raddr < 'h88000000)  // psram
      || (raddr >= 'ha0000000 && raddr < 'hc0000000)  // sdram
      );
  assign cacheable_w = ((0)  //
      || (waddr >= 'h20000000 && waddr < 'h20400000)  // mrom
      || (waddr >= 'h30000000 && waddr < 'h40000000)  // flash
      || (waddr >= 'h80000000 && waddr < 'h88000000)  // psram
      || (waddr >= 'ha0000000 && waddr < 'hc0000000)  // sdram
      );

  assign lsu_bus.arvalid = rvalid && state_load == IF_L;
  assign lsu_bus.araddr = raddr;
  assign lsu_bus.rstrb = rstrb;

  always @(posedge clock) begin
    if (reset) begin
      state_load <= IF_A;
      l1d_valid  <= 0;
      l1d_update <= 0;
    end else begin
      unique case (state_load)
        IF_A: begin
          if (flush_pipe) begin
          end else if (rvalid) begin
            if (l1d_cache_hit) begin
              state_load <= IF_V;
              lsu_rdata  <= l1d_data;
            end else begin
              state_load <= IF_L;
            end
          end
        end
        IF_L: begin
          if (flush_pipe) begin
            state_load <= IF_A;
          end else if (rvalid && lsu_bus.rvalid) begin
            state_load <= IF_V;
            lsu_rdata  <= lsu_bus.rdata;
          end
        end
        IF_V: begin
          state_load <= IF_A;
        end
        default: begin
          state_load <= IF_A;
        end
      endcase

      if (wvalid && cacheable_w) begin
        if (walu == `YSYX_SW_WSTRB) begin
          l1d_update <= 1'b1;
          l1d_data_u <= wdata;
          l1d_valid_u <= 1'b1;
          l1d_tag_u <= waddr_tag;
          l1d_idx <= waddr_idx;
        end else begin
          if (l1d_cache_hit_w) begin
            // invalid cache
            l1d_update <= 1'b1;
            l1d_valid_u <= 0;
            l1d_idx <= waddr_idx;
          end
        end
      end else if (state_load == IF_L) begin
        if (rvalid && lsu_bus.rvalid) begin
          if (cacheable) begin
            l1d_update <= 1'b1;
            l1d_data_u <= lsu_bus.rdata;
            l1d_valid_u <= 1'b1;
            l1d_tag_u <= addr_tag;
            l1d_idx <= addr_idx;
          end
        end
      end

      if (invalid_l1d) begin
        l1d_valid <= 0;
      end else if (l1d_update) begin
        l1d[l1d_idx] <= l1d_data_u;
        l1d_tag[l1d_idx] <= l1d_tag_u;
        l1d_valid[l1d_idx] <= l1d_valid_u;
        l1d_update <= 0;
      end
    end
  end
endmodule
