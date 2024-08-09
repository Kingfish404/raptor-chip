`include "ysyx_macro.v"
`include "ysyx_macro_soc.v"

module ysyx_IFU (
    input clk,
    rst,

    // for bus
    output [DATA_W-1:0] ifu_araddr_o,
    output ifu_arvalid_o,
    input [DATA_W-1:0] ifu_rdata,
    input ifu_rvalid,

    input  [ADDR_W-1:0] npc,
    output [DATA_W-1:0] inst_o,
    output [DATA_W-1:0] pc_o,

    input  pc_valid,
    input  pc_skip,
    input  prev_valid,
    next_ready,
    output valid_o,
    ready_o
);
  parameter integer ADDR_W = 32;
  parameter integer DATA_W = 32;

  reg state;
  reg pvalid;

  assign ready_o = !valid_o;
  assign arvalid = pvalid;

  parameter integer L1I_LINE_SIZE = 2;
  parameter integer L1I_LINE_LEN = 1;
  parameter integer L1I_SIZE = 4;
  parameter integer L1I_LEN = 2;
  reg [DATA_W-1:0] pc_ifu;
  reg [32-1:0] l1i[L1I_SIZE][L1I_LINE_SIZE];
  reg [L1I_SIZE-1:0] l1i_valid = 0;
  reg [32-L1I_LEN-L1I_LINE_LEN-2-1:0] l1i_tag[L1I_SIZE];
  reg [1:0] l1i_state = 0;
  reg branch_stall = 0;

  wire arvalid;

  wire [32-L1I_LEN-L1I_LINE_LEN-2-1:0] addr_tag = pc_ifu[ADDR_W-1:L1I_LEN+L1I_LINE_LEN+2];
  wire [L1I_LEN-1:0] addr_idx = pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  wire [L1I_LINE_LEN-1:0] addr_offset = pc_ifu[L1I_LINE_LEN+2-1:2];

  wire l1i_cache_hit = (
         1 & l1i_state == 'b00 &
         l1i_valid[addr_idx] == 1'b1) & (l1i_tag[addr_idx] == addr_tag);
  wire ifu_sdram_arburst = `ysyx_I_SDRAM_ARBURST & (pc_ifu >= 'ha0000000) & (pc_ifu <= 'hc0000000);
  wire [6:0] opcode_o = inst_o[6:0];
  wire is_branch = (
    (opcode_o == `ysyx_OP_JAL) | (opcode_o == `ysyx_OP_JALR) |
    (opcode_o == `ysyx_OP_B_TYPE) | (opcode_o == `ysyx_OP_SYSTEM) |
    (0)
  );
  wire is_load = (opcode_o == `ysyx_OP_IL_TYPE);

  assign ifu_araddr_o = (l1i_state == 'b00 | l1i_state == 'b01) ? (pc_ifu & ~'h4) : (pc_ifu | 'h4);
  assign ifu_arvalid_o = ifu_sdram_arburst ?
    arvalid & !l1i_cache_hit & (l1i_state == 'b00 | l1i_state == 'b01) :
    arvalid & !l1i_cache_hit & l1i_state != 'b10;

  // with l1i cache
  assign inst_o = l1i[addr_idx][addr_offset];
  assign valid_o = l1i_cache_hit & !branch_stall;

  assign pc_o = pc_ifu;
  `ysyx_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      pvalid <= 1;
      pc_ifu <= `ysyx_PC_INIT;
    end else begin
      if (inst_o == `ysyx_INST_FENCE_I) begin
        l1i_valid <= 0;
      end
      case (l1i_state)
        'b00:
        if (ifu_arvalid_o) begin
          l1i_state <= 'b01;
        end
        'b01:
        if (ifu_rvalid & !l1i_cache_hit) begin
          if (ifu_sdram_arburst) begin
            l1i_state <= 'b11;
          end else begin
            l1i_state <= 'b10;
          end
          l1i[addr_idx][0]  <= ifu_rdata;
          l1i_tag[addr_idx] <= addr_tag;
        end
        'b10: begin
          l1i_state <= 'b11;
        end
        'b11: begin
          if (ifu_rvalid) begin
            l1i_state <= 'b00;
            l1i[addr_idx][1] <= ifu_rdata;
            l1i_tag[addr_idx] <= addr_tag;
            l1i_valid[addr_idx] <= 1'b1;
          end
        end
      endcase
      if (state == `ysyx_IDLE) begin
        if (prev_valid) begin
          pvalid <= prev_valid;
          if (is_branch & pc_valid) begin
            branch_stall <= 0;
            pc_ifu <= npc;
          end else if (is_branch & pc_skip) begin
            branch_stall <= 0;
            pc_ifu <= npc;
          end
          // if (is_branch & pc_valid) begin
          //   branch_stall <= 0;
          //   if (pc_valid) begin
          //     pc_ifu <= npc;
          //   end
          // end
        end
      end else if (state == `ysyx_WAIT_READY) begin
        if (next_ready == 1) begin
          if (valid_o) begin
            if (!is_branch & !is_load) begin
              pc_ifu <= pc_ifu + 4;
              pvalid <= 0;
            end else begin
              branch_stall <= 1;
            end
          end else begin
            pvalid <= 0;
          end
        end
      end
    end
  end
endmodule  // ysyx_IFU
