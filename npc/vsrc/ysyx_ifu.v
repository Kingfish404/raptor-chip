`include "ysyx_macro.vh"
`include "ysyx_macro_soc.vh"

module ysyx_ifu (
    input clk,
    input rst,

    // for bus
    output [DATA_W-1:0] ifu_araddr_o,
    output ifu_arvalid_o,
    output ifu_required_o,
    input [DATA_W-1:0] ifu_rdata,
    input ifu_rvalid,

    input  [ADDR_W-1:0] npc,
    output [DATA_W-1:0] inst_o,
    output [DATA_W-1:0] pc_o,

    input pc_change,
    input pc_retire,

    output speculation_o,
    output bad_speculation_o,
    output good_speculation_o,

    input  prev_valid,
    input  next_ready,
    output valid_o,
    output ready_o
);
  parameter bit [7:0] ADDR_W = 32;
  parameter bit [7:0] DATA_W = 32;

  parameter bit [7:0] L1I_LINE_LEN = 1;
  parameter bit [7:0] L1I_LINE_SIZE = 2 ** L1I_LINE_LEN;
  parameter bit [7:0] L1I_LEN = 2;
  parameter bit [7:0] L1I_SIZE = 2 ** L1I_LEN;

  reg state;

  reg [DATA_W-1:0] pc_ifu;
  reg [32-1:0] l1i[L1I_SIZE][L1I_LINE_SIZE];
  reg [L1I_SIZE-1:0] l1i_valid = 0;
  reg [32-L1I_LEN-L1I_LINE_LEN-2-1:0] l1i_tag[L1I_SIZE];
  reg [2:0] l1i_state = 0;
  reg ifu_hazard = 0, ifu_lsu_hazard = 0, ifu_branch_hazard = 0;

  reg [DATA_W-1:0] btb, ifu_speculation;
  reg btb_valid, speculation;

  wire [32-L1I_LEN-L1I_LINE_LEN-2-1:0] addr_tag = pc_ifu[ADDR_W-1:L1I_LEN+L1I_LINE_LEN+2];
  wire [L1I_LEN-1:0] addr_idx = pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  wire [L1I_LINE_LEN-1:0] addr_offset = pc_ifu[L1I_LINE_LEN+2-1:2];

  wire l1i_cache_hit = (
         1 & (l1i_state == 'b00 | l1i_state == 'b100) &
         l1i_valid[addr_idx] == 1'b1) & (l1i_tag[addr_idx] == addr_tag);
  wire ifu_sdram_arburst = `YSYX_I_SDRAM_ARBURST & (pc_ifu >= 'ha0000000) & (pc_ifu <= 'hc0000000);
  wire [6:0] opcode_o = inst_o[6:0];
  wire is_branch = (
    (opcode_o == `YSYX_OP_JAL) | (opcode_o == `YSYX_OP_JALR) |
    (opcode_o == `YSYX_OP_B_TYPE) | (opcode_o == `YSYX_OP_SYSTEM) |
    (0)
  );
  wire is_load = (opcode_o == `YSYX_OP_IL_TYPE);

  assign ifu_araddr_o = (l1i_state == 'b00 | l1i_state == 'b01) ? (pc_ifu & ~'h4) : (pc_ifu | 'h4);
  assign ifu_arvalid_o = ifu_sdram_arburst ?
    !l1i_cache_hit & (l1i_state == 'b000 | l1i_state == 'b001) :
    !l1i_cache_hit & (l1i_state != 'b010 & l1i_state != 'b100);
  assign ifu_required_o = (l1i_state != 'b000);

  // with l1i cache
  wire ifu_just_load = ((l1i_state == 'b11) & ifu_rvalid);
  assign inst_o = ifu_just_load & pc_ifu[2] == 1'b1 ? ifu_rdata : l1i[addr_idx][addr_offset];
  assign valid_o = ifu_just_load | (l1i_cache_hit & !ifu_hazard);
  assign ready_o = !valid_o;

  // for speculation
  assign speculation_o = speculation;
  assign good_speculation_o = good_speculation;
  assign bad_speculation_o = (
    prev_valid & (pc_change | pc_retire) &
    speculation & (npc != ifu_speculation));
  wire good_speculation = (
    prev_valid & (pc_change | pc_retire) &
    speculation & (npc == ifu_speculation));

  assign pc_o = pc_ifu;
  `YSYX_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      pc_ifu <= `YSYX_PC_INIT;
      btb_valid <= 0;
      speculation <= 0;
    end else begin
      if (valid_o & next_ready & inst_o == `YSYX_INST_FENCE_I) begin
        l1i_valid <= 0;
      end
      if (bad_speculation_o) begin
        speculation <= 0;
        ifu_hazard <= 0;
        ifu_lsu_hazard <= 0;
        ifu_branch_hazard <= 0;
        pc_ifu <= npc;
      end else if (good_speculation) begin
        speculation <= 0;
        ifu_hazard <= 0;
        ifu_lsu_hazard <= 0;
        ifu_branch_hazard <= 0;
      end
      if (state == `YSYX_IDLE) begin
        if (prev_valid) begin
          if (pc_change | pc_retire) begin
            ifu_hazard <= 0;
            ifu_lsu_hazard <= 0;
            ifu_branch_hazard <= 0;
            pc_ifu <= npc;
          end
          if (pc_change) begin
            btb <= npc;
            btb_valid <= 1;
          end
        end
      end else if (state == `YSYX_WAIT_READY) begin
        if (!bad_speculation_o & next_ready == 1 & valid_o) begin
          if (!is_branch & !is_load) begin
            pc_ifu <= pc_ifu + 4;
          end else begin
            if (is_branch) begin
              if (btb_valid & !speculation) begin
                pc_ifu <= btb;
                ifu_speculation <= btb;
                speculation <= 1;
              end else begin
                ifu_hazard <= 1;
                ifu_branch_hazard <= 1;
              end
            end
            if (is_load) begin
              ifu_hazard <= 1;
              ifu_lsu_hazard <= 1;
            end
          end
        end
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      l1i_state <= 'b000;
      l1i_valid <= 0;
    end else begin
      case (l1i_state)
        'b000:
        if (ifu_arvalid_o) begin
          l1i_state <= 'b001;
        end
        'b001:
        if (ifu_rvalid & !l1i_cache_hit) begin
          if (ifu_sdram_arburst) begin
            l1i_state <= 'b011;
          end else begin
            l1i_state <= 'b010;
          end
          l1i[addr_idx][0]  <= ifu_rdata;
          l1i_tag[addr_idx] <= addr_tag;
        end
        'b010: begin
          l1i_state <= 'b011;
        end
        'b011: begin
          if (ifu_rvalid) begin
            l1i_state <= 'b100;
            l1i[addr_idx][1] <= ifu_rdata;
            l1i_tag[addr_idx] <= addr_tag;
            l1i_valid[addr_idx] <= 1'b1;
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
endmodule  // ysyx_IFU
