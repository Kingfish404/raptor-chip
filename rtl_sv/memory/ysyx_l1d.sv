`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_l1d #(
    parameter bit [`YSYX_L1D_LEN:0] L1D_LEN = `YSYX_L1D_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_SIZE = 2 ** `YSYX_L1D_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    wbu_pipe_if.in wbu_bcast,

    lsu_l1d_if.slave  lsu_l1d,
    l1d_bus_if.master l1d_bus,

    input reset
);
  typedef enum {
    IF_A = 0,
    IF_L = 1,
    IF_V = 2
  } state_load_t;

  state_load_t state_load;

  logic invalid_l1d;

  logic [XLEN-1:0] l1d_buffer;

  logic [XLEN-1:0] l1d_raddr;
  logic [4:0] l1d_walu;
  logic [32-{{3'b0}, L1D_LEN}-2-1:0] l1d_addr_tag;
  logic [L1D_LEN-1:0] l1d_addr_idx;

  logic [XLEN-1:0] l1d[L1D_SIZE];
  logic [L1D_SIZE-1:0] l1d_valid;
  logic [32-{{3'b0}, L1D_LEN}-2-1:0] l1d_tag[L1D_SIZE];
  logic [7:0] rstrb;

  logic [32-{{3'b0}, L1D_LEN}-2-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic hit;
  logic [XLEN-1:0] l1d_data;
  logic cacheable_r;
  logic cacheable_w;

  logic [32-{{3'b0}, L1D_LEN}-2-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic hit_w;

  logic l1d_update;
  logic [XLEN-1:0] l1d_data_u;
  logic l1d_valid_u;
  logic [32-{{3'b0}, L1D_LEN}-2-1:0] l1d_tag_u;
  logic [L1D_LEN-1:0] l1d_idx;

  assign invalid_l1d = wbu_bcast.fence_time;

  assign rstrb = (
      ({8{l1d_walu == `YSYX_ALU_LB__}} & 8'h1)
    | ({8{l1d_walu == `YSYX_ALU_LBU_}} & 8'h1)
    | ({8{l1d_walu == `YSYX_ALU_LH__}} & 8'h3)
    | ({8{l1d_walu == `YSYX_ALU_LHU_}} & 8'h3)
    | ({8{l1d_walu == `YSYX_ALU_LW__}} & 8'hf)
    );

  assign addr_tag = lsu_l1d.raddr[XLEN-1:L1D_LEN+2];
  assign addr_idx = lsu_l1d.raddr[L1D_LEN+2-1:0+2];

  assign l1d_addr_tag = l1d_raddr[XLEN-1:L1D_LEN+2];
  assign l1d_addr_idx = l1d_raddr[L1D_LEN+2-1:0+2];

  assign hit = (l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  assign l1d_data = l1d[addr_idx];

  assign waddr_tag = lsu_l1d.waddr[XLEN-1:L1D_LEN+2];
  assign waddr_idx = lsu_l1d.waddr[L1D_LEN+2-1:0+2];
  assign hit_w = (l1d_valid[waddr_idx] == 1'b1) && (l1d_tag[waddr_idx] == waddr_tag);

  assign cacheable_r = ((0)  //
      || (l1d_raddr >= 'h20000000 && l1d_raddr < 'h20400000)  // mrom
      || (l1d_raddr >= 'h30000000 && l1d_raddr < 'h40000000)  // flash
      || (l1d_raddr >= 'h80000000 && l1d_raddr < 'h88000000)  // psram
      || (l1d_raddr >= 'ha0000000 && l1d_raddr < 'hc0000000)  // sdram
      );
  assign cacheable_w = ((0)  //
      || (lsu_l1d.waddr >= 'h20000000 && lsu_l1d.waddr < 'h20400000)  // mrom
      || (lsu_l1d.waddr >= 'h30000000 && lsu_l1d.waddr < 'h40000000)  // flash
      || (lsu_l1d.waddr >= 'h80000000 && lsu_l1d.waddr < 'h88000000)  // psram
      || (lsu_l1d.waddr >= 'ha0000000 && lsu_l1d.waddr < 'hc0000000)  // sdram
      );

  assign l1d_bus.arvalid = (state_load == IF_L);
  assign l1d_bus.araddr = cacheable_r ? l1d_raddr & ~'h3 : l1d_raddr;
  assign l1d_bus.rstrb = cacheable_r ? 8'hf : rstrb;

  assign lsu_l1d.rdata = hit ? l1d_data : l1d_bus.rdata;
  assign lsu_l1d.rready = lsu_l1d.rvalid && (hit || (l1d_bus.rvalid) && l1d_raddr == lsu_l1d.raddr);

  always @(posedge clock) begin
    if (reset) begin
      state_load <= IF_A;
      l1d_valid  <= 0;
      l1d_update <= 0;
    end else begin
      unique case (state_load)
        IF_A: begin
          if (wbu_bcast.flush_pipe) begin
          end else if (lsu_l1d.rvalid) begin
            if (!hit) begin
              state_load <= IF_L;
              l1d_raddr  <= lsu_l1d.raddr;
              l1d_walu   <= lsu_l1d.ralu;
            end
          end else begin
            l1d_raddr <= '0;
          end
        end
        IF_L: begin
          if (l1d_bus.rvalid) begin
            state_load <= IF_V;
            l1d_buffer <= l1d_bus.rdata;
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

      if (lsu_l1d.wvalid && l1d_bus.wready && cacheable_w) begin
        if (lsu_l1d.walu == `YSYX_SW_WSTRB) begin
          l1d_update <= 1'b1;
          l1d_data_u <= lsu_l1d.wdata;
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
        if (lsu_l1d.rvalid && l1d_bus.rvalid) begin
          if (cacheable_r) begin
            l1d_update <= 1'b1;
            l1d_data_u <= l1d_bus.rdata;
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
