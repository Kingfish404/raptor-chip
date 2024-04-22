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

  assign ready_o = !valid_o;
  assign arvalid = pvalid;

  parameter L1I_SIZE = 16;
  parameter L1I_LEN = 4;
  reg [32-1:0] l1i[L1I_SIZE-1:0];
  reg [L1I_SIZE-1:0] l1i_valid = 0;
  reg [32-L1I_LEN-2-1:0] l1i_tag[L1I_SIZE-1:0];

  wire arvalid;
  wire [32-L1I_LEN-2-1:0] addr_tag = ifu_araddr_o[ADDR_W-1:L1I_LEN+2];
  wire [L1I_LEN-1:0] addr_idx = ifu_araddr_o[L1I_LEN+2-1:0+2];
  wire l1i_cache_hit = (
         (pvalid) &
         l1i_valid[addr_idx] == 1'b1) & (l1i_tag[addr_idx] == addr_tag);

  assign ifu_araddr_o = prev_valid ? npc : pc;
  assign ifu_arvalid_o = arvalid & !l1i_cache_hit;
  // without l1i cache
  // assign inst_o = ifu_rvalid ? ifu_rdata : inst_ifu;
  // assign valid_o = ifu_rvalid | valid;

  // with l1i cache
  assign inst_o = (ifu_rvalid) ? ifu_rdata : l1i[addr_idx];
  assign valid_o = ifu_rvalid | valid | l1i_cache_hit;

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
              l1i[addr_idx] <= ifu_rdata;
              l1i_tag[addr_idx] <= addr_tag;
              l1i_valid[addr_idx] <= 1'b1;
            end
          if (state == `ysyx_IDLE)
            begin
              if (prev_valid)
                begin
                  pvalid <= prev_valid;
                end
              if (ifu_rvalid | (l1i_cache_hit))
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
