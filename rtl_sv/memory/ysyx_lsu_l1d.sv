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
    output logic [XLEN-1:0] io_rdata_o,
    output logic io_rready_o,

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

  logic [XLEN-1:0] l1d_buffer;

  logic [XLEN-1:0] l1d_raddr;
  logic [4:0] l1d_walu;
  logic [32-L1D_LEN-2-1:0] l1d_addr_tag;
  logic [L1D_LEN-1:0] l1d_addr_idx;

  logic [XLEN-1:0] l1d[L1D_SIZE];
  logic [L1D_SIZE-1:0] l1d_valid;
  logic [32-L1D_LEN-2-1:0] l1d_tag[L1D_SIZE];
  logic [7:0] rstrb;

  logic [32-L1D_LEN-2-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic hit;
  logic [XLEN-1:0] l1d_data;
  logic cacheable_r;
  logic cacheable_w;

  logic [32-L1D_LEN-2-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic hit_w;

  logic l1d_update;
  logic [XLEN-1:0] l1d_data_u;
  logic l1d_valid_u;
  logic [32-L1D_LEN-2-1:0] l1d_tag_u;
  logic [L1D_LEN-1:0] l1d_idx;

  assign rstrb = (
      ({8{l1d_walu == `YSYX_ALU_LB__}} & 8'h1)
    | ({8{l1d_walu == `YSYX_ALU_LBU_}} & 8'h1)
    | ({8{l1d_walu == `YSYX_ALU_LH__}} & 8'h3)
    | ({8{l1d_walu == `YSYX_ALU_LHU_}} & 8'h3)
    | ({8{l1d_walu == `YSYX_ALU_LW__}} & 8'hf)
    );

  assign addr_tag = raddr[XLEN-1:L1D_LEN+2];
  assign addr_idx = raddr[L1D_LEN+2-1:0+2];

  assign l1d_addr_tag = l1d_raddr[XLEN-1:L1D_LEN+2];
  assign l1d_addr_idx = l1d_raddr[L1D_LEN+2-1:0+2];

  assign hit = (l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  assign l1d_data = l1d[addr_idx];

  assign io_rdata_o = hit ? l1d_data : lsu_bus.rdata;
  assign io_rready_o = rvalid && (hit || (lsu_bus.rvalid) && l1d_raddr == raddr);

  assign waddr_tag = waddr[XLEN-1:L1D_LEN+2];
  assign waddr_idx = waddr[L1D_LEN+2-1:0+2];
  assign hit_w = (l1d_valid[waddr_idx] == 1'b1) && (l1d_tag[waddr_idx] == waddr_tag);

  assign cacheable_r = ((0)  //
      || (l1d_raddr >= 'h20000000 && l1d_raddr < 'h20400000)  // mrom
      || (l1d_raddr >= 'h30000000 && l1d_raddr < 'h40000000)  // flash
      || (l1d_raddr >= 'h80000000 && l1d_raddr < 'h88000000)  // psram
      || (l1d_raddr >= 'ha0000000 && l1d_raddr < 'hc0000000)  // sdram
      );
  assign cacheable_w = ((0)  //
      || (waddr >= 'h20000000 && waddr < 'h20400000)  // mrom
      || (waddr >= 'h30000000 && waddr < 'h40000000)  // flash
      || (waddr >= 'h80000000 && waddr < 'h88000000)  // psram
      || (waddr >= 'ha0000000 && waddr < 'hc0000000)  // sdram
      );

  assign lsu_bus.arvalid = (state_load == IF_L);
  assign lsu_bus.araddr = cacheable_r ? l1d_raddr & ~'h3 : l1d_raddr;
  assign lsu_bus.rstrb = cacheable_r ? 8'hf : rstrb;

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
            if (!hit) begin
              state_load <= IF_L;
              l1d_raddr  <= raddr;
              l1d_walu   <= ralu;
            end
          end else begin
            l1d_raddr <= '0;
          end
        end
        IF_L: begin
          if (lsu_bus.rvalid) begin
            state_load <= IF_V;
            l1d_buffer <= lsu_bus.rdata;
          end
        end
        IF_V: begin
          state_load <= IF_A;
          l1d_raddr  <= '0;
        end
        default: begin
          state_load <= IF_A;
          l1d_raddr  <= '0;
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
          if (hit_w) begin
            // invalid cache
            l1d_update <= 1'b1;
            l1d_valid_u <= 0;
            l1d_idx <= waddr_idx;
          end
        end
      end else if (state_load == IF_L) begin
        if (rvalid && lsu_bus.rvalid) begin
          if (cacheable_r) begin
            l1d_update <= 1'b1;
            l1d_data_u <= lsu_bus.rdata;
            l1d_valid_u <= 1'b1;
            l1d_tag_u <= l1d_addr_tag;
            l1d_idx <= l1d_addr_idx;
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
