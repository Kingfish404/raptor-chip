`include "ysyx.svh"
`include "ysyx_soc.svh"

module ysyx_ifu_l1i (
    input clock,

    input [DATA_W-1:0] pc_ifu,
    input ifu_rvalid,
    input [DATA_W-1:0] ifu_rdata,
    input invalid_l1i,

    output [DATA_W-1:0] ifu_araddr_o,
    output ifu_arvalid_o,
    output ifu_required_o,

    output [DATA_W-1:0] inst_o,
    output l1i_valid,
    output l1i_ready,

    input reset
);
  parameter bit [7:0] DATA_W = 32;
  parameter bit [7:0] L1I_LINE_LEN = 1;
  parameter bit [7:0] L1I_LINE_SIZE = 2 ** L1I_LINE_LEN;
  parameter bit [7:0] L1I_LEN = 2;
  parameter bit [7:0] L1I_SIZE = 2 ** L1I_LEN;

  assign l1i_valid = l1i_cache_hit;
  assign l1i_ready = (l1i_state == 'b000);

  reg [32-1:0] l1i[L1I_SIZE][L1I_LINE_SIZE];
  reg [L1I_SIZE-1:0] l1ic_valid = 0;
  reg [32-L1I_LEN-L1I_LINE_LEN-2-1:0] l1i_tag[L1I_SIZE][L1I_LINE_SIZE];
  reg [2:0] l1i_state = 0;

  wire [32-L1I_LEN-L1I_LINE_LEN-2-1:0] addr_tag = pc_ifu[DATA_W-1:L1I_LEN+L1I_LINE_LEN+2];
  wire [L1I_LEN-1:0] addr_idx = pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  wire [L1I_LINE_LEN-1:0] addr_offset = pc_ifu[L1I_LINE_LEN+2-1:2];

  assign ifu_araddr_o = (l1i_state == 'b00 | l1i_state == 'b01) ? (pc_ifu & ~'h4) : (pc_ifu | 'h4);
  assign ifu_arvalid_o = ifu_sdram_arburst ?
    !l1i_cache_hit & (l1i_state == 'b000 | l1i_state == 'b001) :
    !l1i_cache_hit & (l1i_state != 'b010 & l1i_state != 'b100);
  assign ifu_required_o = (l1i_state != 'b000);

  wire l1i_cache_hit = (
         (l1i_state == 'b000 | l1i_state == 'b100) &
         l1ic_valid[addr_idx] == 1'b1) & (l1i_tag[addr_idx][addr_offset] == addr_tag);
  wire ifu_sdram_arburst = `YSYX_I_SDRAM_ARBURST & (pc_ifu >= 'ha0000000) & (pc_ifu <= 'hc0000000);

  assign inst_o = l1i[addr_idx][addr_offset];

  always @(posedge clock) begin
    if (reset) begin
      l1i_state  <= 'b000;
      l1ic_valid <= 0;
    end else begin
      case (l1i_state)
        'b000: begin
          if (invalid_l1i) begin
            l1ic_valid <= 0;
          end
          if (ifu_arvalid_o) begin
            l1i_state <= 'b001;
          end
        end
        'b001:
        if (ifu_rvalid & !l1i_cache_hit) begin
          if (ifu_sdram_arburst) begin
            l1i_state <= 'b011;
          end else begin
            l1i_state <= 'b010;
          end
          l1i[addr_idx][0] <= ifu_rdata;
          l1i_tag[addr_idx][0] <= addr_tag;
        end
        'b010: begin
          l1i_state <= 'b011;
        end
        'b011: begin
          if (ifu_rvalid) begin
            l1i_state <= 'b100;
            l1i[addr_idx][1] <= ifu_rdata;
            l1i_tag[addr_idx][1] <= addr_tag;
            l1ic_valid[addr_idx] <= 1'b1;
          end
        end
        'b100: begin
          l1i_state <= 'b000;
        end
        default begin
          l1i_state <= 'b000;
        end
      endcase
    end
  end
endmodule
