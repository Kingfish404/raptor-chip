`include "ysyx.svh"
`include "ysyx_soc.svh"

module ysyx_ifu_l1i #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LINE_LEN = `YSYX_L1I_LINE_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LINE_SIZE = 2 ** L1I_LINE_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LEN = `YSYX_L1I_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_SIZE = 2 ** L1I_LEN
) (
    input clock,

    input [XLEN-1:0] pc_ifu,
    output [32-1:0] out_inst,
    output out_valid,

    input invalid_l1i,

    input bus_ifu_ready,
    output [XLEN-1:0] out_ifu_araddr,
    output out_ifu_arvalid,
    input [XLEN-1:0] ifu_rdata,
    input ifu_rvalid,

    input reset
);
  typedef enum logic [2:0] {
    IDLE = 3'b000,
    RD_0 = 3'b001,
    WAIT = 3'b010,
    RD_1 = 3'b011,
    WB_0 = 3'b100,
    NULL = 3'b111
  } l1i_state_t;
  logic is_c;
  logic [15:0] inst_lo, inst_hi;
  logic [XLEN-1:0] pc_ifu_next;
  logic [XLEN-1:0] l1i_addr;
  logic [32-1:0] l1i[L1I_SIZE][L1I_LINE_SIZE];
  logic [L1I_SIZE-1:0] l1i_valid;
  logic [32-{{2'b0}, L1I_LEN+L1I_LINE_LEN}-2-1:0] l1i_tag[L1I_SIZE][L1I_LINE_SIZE];
  l1i_state_t l1i_state;

  logic [32-{{2'b0}, L1I_LEN+L1I_LINE_LEN}-2-1:0] addr_tag;
  logic [L1I_LEN-1:0] addr_idx;
  logic [L1I_LINE_LEN-1:0] addr_offset;

  logic [32-{{2'b0}, L1I_LEN+L1I_LINE_LEN}-2-1:0] addr_tag_next;
  logic [L1I_LEN-1:0] addr_idx_next;
  logic [L1I_LINE_LEN-1:0] addr_offset_next;

  logic [32-{{2'b0}, L1I_LEN+L1I_LINE_LEN}-2-1:0] tag_fetch;
  logic [L1I_LEN-1:0] idx_fetch;
  logic [L1I_LINE_LEN-1:0] offset_fetch;

  logic hit, hit_next;
  logic ifu_sdram_arburst;
  logic wait_invalid;
  logic [XLEN-1:0] reverse_pc_ifu;

  assign pc_ifu_next = pc_ifu + 2;

  assign addr_tag = pc_ifu[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign addr_idx = pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  assign addr_offset = pc_ifu[L1I_LINE_LEN+2-1:2];

  assign addr_tag_next = pc_ifu_next[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign addr_idx_next = pc_ifu_next[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  assign addr_offset_next = pc_ifu_next[L1I_LINE_LEN+2-1:2];

  assign tag_fetch = l1i_addr[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign offset_fetch = l1i_addr[L1I_LINE_LEN+2-1:2];
  assign idx_fetch = l1i_addr[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];

  assign out_ifu_araddr = (l1i_state == IDLE || l1i_state == RD_0)
    ? (l1i_addr & ~'h4)
    : (l1i_addr | 'h4);
  assign out_ifu_arvalid = (ifu_sdram_arburst
    ? (l1i_state == RD_0)
    : (l1i_state != IDLE && l1i_state != WAIT && l1i_state != WB_0));

  assign hit = !invalid_l1i && !wait_invalid
    && (l1i_valid[addr_idx] == 1'b1)
    && (l1i_tag[addr_idx][addr_offset] == addr_tag);
  assign hit_next = !invalid_l1i && !wait_invalid
    && (l1i_valid[addr_idx_next] == 1'b1)
    && (l1i_tag[addr_idx_next][addr_offset_next] == addr_tag_next);
  assign ifu_sdram_arburst = (`YSYX_I_SDRAM_ARBURST)
    && (l1i_addr >= 'ha0000000)
    && (l1i_addr <= 'hc0000000);

  assign inst_lo = (pc_ifu[1]
    ? l1i[addr_idx][addr_offset][31:16]
    : l1i[addr_idx][addr_offset][15:0]);
  assign inst_hi = (pc_ifu[1]
    ? l1i[addr_idx_next][addr_offset_next][15:0]
    : l1i[addr_idx][addr_offset][31:16]);
  assign is_c = !(inst_lo[1:0] == 2'b11);
  assign out_inst = {{inst_hi}, {inst_lo}};
  assign out_valid = ((hit && (hit_next || is_c) && !wait_invalid));

  always @(posedge clock) begin
    if (reset) begin
      l1i_state <= IDLE;
    end else begin
      unique case (l1i_state)
        IDLE: begin
          if (!invalid_l1i) begin
            if (!hit) begin
              l1i_addr  <= pc_ifu;
              l1i_state <= RD_0;
            end else if (!hit_next) begin
              l1i_addr  <= pc_ifu_next;
              l1i_state <= RD_0;
            end
          end
        end
        RD_0:
        if (ifu_rvalid) begin
          if (ifu_sdram_arburst) begin
            l1i_state <= RD_1;
          end else begin
            l1i_state <= WAIT;
          end
        end
        WAIT: begin
          l1i_state <= RD_1;
        end
        RD_1: begin
          if (ifu_rvalid) begin
            l1i_state <= WB_0;
          end
        end
        WB_0: begin
          l1i_state <= IDLE;
        end
        default begin
          l1i_state <= IDLE;
        end
      endcase
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      l1i_valid <= 0;
    end else begin
      if (invalid_l1i) begin
        if (l1i_state != IDLE) begin
          wait_invalid <= 1;
        end else begin
          l1i_valid <= 0;
          l1i_state <= IDLE;
        end
      end else if (l1i_state == WB_0) begin
        if (wait_invalid) begin
          l1i_valid <= 0;
          wait_invalid <= 0;
        end
      end
      if (ifu_rvalid) begin
        l1i[idx_fetch][l1i_state==RD_0?0 : 1] <= ifu_rdata;
        l1i_tag[idx_fetch][l1i_state==RD_0?0 : 1] <= tag_fetch;
        if (l1i_state == RD_1) begin
          l1i_valid[idx_fetch] <= 1'b1;
        end
      end
    end
  end
endmodule
