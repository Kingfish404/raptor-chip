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

    input [ADDR_W-1:0] pc,
    output [DATA_W-1:0] inst_o,
    output [DATA_W-1:0] pc_o
  );
  parameter integer ADDR_W = 32;
  parameter integer DATA_W = 32;

  reg state, valid;
  reg pvalid;

  assign ready_o = !valid_o;
  assign arvalid = pvalid;

  parameter integer L1I_LINE_SIZE = 2 * 4 * 8;
  parameter integer L1I_LINE_LEN = 0;
  parameter integer L1I_SIZE = 8;
  parameter integer L1I_LEN = 3;
  reg [L1I_LINE_SIZE-1:0] l1i[L1I_SIZE];
  reg [L1I_SIZE-1:0] l1i_valid = 0;
  reg [32-L1I_LEN-2-1:0] l1i_tag[L1I_SIZE];

  wire arvalid;
  wire [32-L1I_LEN-2-1:0] addr_tag = ifu_araddr_o[ADDR_W-1:L1I_LEN+L1I_LINE_LEN+2];
  wire [L1I_LEN-1:0] addr_idx = ifu_araddr_o[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  wire [L1I_LINE_LEN-1:0]addr_offset = ifu_araddr_o[L1I_LINE_LEN+2-1:2];
  wire l1i_cache_hit = (
         (pvalid) & 1 &
         l1i_valid[addr_idx] == 1'b1) & (l1i_tag[addr_idx] == addr_tag);

  assign ifu_araddr_o = pc;
  assign ifu_arvalid_o = arvalid & !l1i_cache_hit;

  // with l1i cache
  assign inst_o = (ifu_rvalid) ? ifu_rdata : l1i[addr_idx];
  assign valid_o = ifu_rvalid | valid | l1i_cache_hit;

  `ysyx_BUS_FSM()
  assign pc_o = pc;
  always @(posedge clk)
    begin
      if (rst)
        begin
          valid <= 0;
          pvalid <= 1;
        end
      else
        begin
          if (ifu_rvalid)
            begin
              l1i[addr_idx] <= ifu_rdata;
              l1i_tag[addr_idx] <= addr_tag;
              l1i_valid[addr_idx] <= 1'b1;
              if (ifu_rdata == 'h0000100f) begin
                l1i_valid <= 0;
              end
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
