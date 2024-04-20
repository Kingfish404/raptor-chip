`include "ysyx_macro.v"

module ysyx_IFU (
    input clk, rst,

    input prev_valid, next_ready,
    output valid_o, ready_o,

    // for bus
    output [DATA_W-1:0] ifu_araddr_o,
    output ifu_arvalid_o,
    input [DATA_W-1:0] ifu_rdata,
    input ifu_rvalid,

    input [ADDR_W-1:0] pc, npc,
    output [DATA_W-1:0] inst_o,
    output reg [DATA_W-1:0] pc_o
  );
  parameter ADDR_W = 32;
  parameter DATA_W = 32;

  reg [DATA_W-1:0] inst_ifu = 0;
  reg state, valid;
  reg pvalid;
  reg [32-1:0] l1_icache[256-1:0];
  reg [24-1:0] l1_icache_tag[256-1:0];
  reg [256-1:0] l1_icache_valid = 0;

  wire arvalid;
  wire [24-1:0] addr_tag = ifu_araddr_o[ADDR_W-1:8];
  wire [8-1:0] addr_idx = ifu_araddr_o[7:0];
  wire l1_cache_miss = (
         l1_icache_valid[addr_idx] == 0) & (l1_icache_tag[addr_idx] != addr_tag);

  assign ready_o = !valid_o;

  assign arvalid = pvalid;

  assign ifu_araddr_o = prev_valid ? npc : pc;
  assign ifu_arvalid_o = arvalid & l1_cache_miss;
  // assign inst_o = ifu_rvalid ? ifu_rdata : inst_ifu;
  assign inst_o = ifu_rvalid ? ifu_rdata : l1_icache[addr_idx];
  assign valid_o = ifu_rvalid | valid;

  `ysyx_BUS_FSM();
  always @(posedge clk)
    begin
      if (rst)
        begin
          valid <= 0;
          pvalid <= 1;
          inst_ifu <= 0;
        end
      else
        begin
          pc_o <= pc;
          if (ifu_rvalid)
            begin
              inst_ifu <= ifu_rdata;
              l1_icache[addr_idx] <= ifu_rdata;
              l1_icache_tag[addr_idx] <= addr_tag;
              l1_icache_valid[addr_idx] <= 1;
            end
          if (state == `ysyx_IDLE)
            begin
              if (prev_valid)
                begin
                  pvalid <= prev_valid;
                end
              if (ifu_rvalid)
                begin
                  valid <= 1;
                end
            end
          else if (state == `ysyx_WAIT_READY)
            begin
              if (next_ready == 1)
                begin
                  pvalid <= 0;
                  valid <= 0;
                end
            end
        end
    end
endmodule // ysyx_IFU
