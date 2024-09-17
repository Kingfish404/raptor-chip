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

    input [DATA_W-1:0] pc,
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

  // IFU State Registers
  reg [DATA_W-1:0] pc_ifu;
  reg [DATA_W-1:0] btb, ifu_speculation, ifu_npc_speculation, ifu_npc_bad_speculation;
  reg speculation, bad_speculation, ifu_b_speculation;
  reg ifu_hazard = 0, ifu_lsu_hazard = 0, ifu_branch_hazard = 0;
  reg good_speculation;
  reg bad_speculation_pc_change;

  // Wires for interactions between modules
  wire [DATA_W-1:0] l1i_inst;
  wire l1i_valid, l1i_ready, l1i_cache_hit;
  wire bpu_speculation, bpu_bad_speculation;

  // Instantiate the L1I Cache module
  l1i_cache #(
      .ADDR_W(ADDR_W),
      .DATA_W(DATA_W)
  ) l1i_cache_inst (
      .clk(clk),
      .rst(rst),
      .pc_ifu(pc_ifu),
      .ifu_rdata(ifu_rdata),
      .ifu_rvalid(ifu_rvalid),
      .ifu_arvalid_o(ifu_arvalid_o),
      .ifu_araddr_o(ifu_araddr_o),
      .ifu_required_o(ifu_required_o),
      .l1i_inst(l1i_inst),
      .l1i_valid(l1i_valid),
      .l1i_ready(l1i_ready),
      .l1i_cache_hit(l1i_cache_hit)
  );

  // Instantiate the Branch Prediction Unit (BPU) module
  bpu #(
      .ADDR_W(ADDR_W),
      .DATA_W(DATA_W)
  ) bpu_inst (
      .clk(clk),
      .rst(rst),
      .pc_ifu(pc_ifu),
      .npc(npc),
      .pc(pc),
      .pc_change(pc_change),
      .pc_retire(pc_retire),
      .btb(btb),
      .speculation_o(speculation_o),
      .bad_speculation_o(bad_speculation_o),
      .good_speculation_o(good_speculation_o),
      .speculation(bpu_speculation),
      .bad_speculation(bpu_bad_speculation),
      .ifu_speculation(ifu_speculation),
      .ifu_npc_speculation(ifu_npc_speculation),
      .ifu_npc_bad_speculation(ifu_npc_bad_speculation)
  );

  // PC update and control logic
  assign pc_o = pc_ifu;
  assign inst_o = (l1i_cache_hit && !ifu_hazard) ? l1i_inst : ifu_rdata;
  assign valid_o = l1i_valid && !ifu_hazard && !bad_speculation && !(speculation && (is_load | is_store));
  assign ready_o = !valid_o;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      pc_ifu <= `YSYX_PC_INIT;
      speculation <= 0;
      bad_speculation <= 0;
      ifu_hazard <= 0;
    end else begin
      if (bad_speculation_o && next_ready && l1i_ready) begin
        if (bpu_speculation && !bad_speculation_pc_change) begin
          pc_ifu <= ifu_npc_speculation;
        end else begin
          pc_ifu <= npc;
        end
      end else if (good_speculation_o) begin
        speculation <= 0;
      end
      if (bpu_speculation && (pc_change || pc_retire)) begin
        good_speculation <= 1;
        speculation <= 0;
      end
    end
  end

endmodule

module l1i_cache #(
    parameter bit [7:0] ADDR_W = 32,
    parameter bit [7:0] DATA_W = 32
) (
    input clk,
    input rst,
    input [DATA_W-1:0] pc_ifu,
    input [DATA_W-1:0] ifu_rdata,
    input ifu_rvalid,

    output ifu_arvalid_o,
    output [DATA_W-1:0] ifu_araddr_o,
    output ifu_required_o,

    output [DATA_W-1:0] l1i_inst,
    output l1i_valid,
    output l1i_ready,
    output l1i_cache_hit
);
  parameter bit [7:0] L1I_LINE_LEN = 1;
  parameter bit [7:0] L1I_LINE_SIZE = 2 ** L1I_LINE_LEN;
  parameter bit [7:0] L1I_LEN = 2;
  parameter bit [7:0] L1I_SIZE = 2 ** L1I_LEN;

  // Cache storage and state
  reg [DATA_W-1:0] l1i[L1I_SIZE][L1I_LINE_SIZE];
  reg [L1I_SIZE-1:0] l1i_valid_reg;
  reg [32-L1I_LEN-L1I_LINE_LEN-2-1:0] l1i_tag[L1I_SIZE][L1I_LINE_SIZE];
  reg [2:0] l1i_state;

  wire [32-L1I_LEN-L1I_LINE_LEN-2-1:0] addr_tag = pc_ifu[ADDR_W-1:L1I_LEN+L1I_LINE_LEN+2];
  wire [L1I_LEN-1:0] addr_idx = pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  wire [L1I_LINE_LEN-1:0] addr_offset = pc_ifu[L1I_LINE_LEN+2-1:2];

  assign l1i_cache_hit = (l1i_valid_reg[addr_idx] && l1i_tag[addr_idx][addr_offset] == addr_tag);
  assign l1i_inst = l1i[addr_idx][addr_offset];
  assign l1i_valid = l1i_cache_hit;
  assign l1i_ready = (l1i_state == 'b100);

  // SDRAM access and state machine
  assign ifu_araddr_o = (l1i_state == 'b00 || l1i_state == 'b01) ? (pc_ifu & ~'h4) : (pc_ifu | 'h4);
  assign ifu_arvalid_o = !l1i_cache_hit && (l1i_state != 'b010 && l1i_state != 'b100);
  assign ifu_required_o = (l1i_state != 'b000);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      l1i_state <= 'b000;
      l1i_valid_reg <= 0;
    end else begin
      case (l1i_state)
        'b000:   if (ifu_arvalid_o) l1i_state <= 'b001;
        'b001:
        if (ifu_rvalid) begin
          l1i[addr_idx][0] <= ifu_rdata;
          l1i_tag[addr_idx][0] <= addr_tag;
          l1i_state <= 'b011;
        end
        'b011:
        if (ifu_rvalid) begin
          l1i[addr_idx][1] <= ifu_rdata;
          l1i_tag[addr_idx][1] <= addr_tag;
          l1i_valid_reg[addr_idx] <= 1'b1;
          l1i_state <= 'b100;
        end
        'b100:   l1i_state <= 'b000;
        default: l1i_state <= 'b000;
      endcase
    end
  end

endmodule

module bpu #(
    parameter bit [7:0] ADDR_W = 32,
    parameter bit [7:0] DATA_W = 32
) (
    input clk,
    input rst,
    input [DATA_W-1:0] pc_ifu,
    input [ADDR_W-1:0] npc,
    input [DATA_W-1:0] pc,
    input pc_change,
    input pc_retire,

    input [DATA_W-1:0] btb,

    output speculation_o,
    output bad_speculation_o,
    output good_speculation_o,

    output reg speculation,
    output reg bad_speculation,
    output reg [DATA_W-1:0] ifu_speculation,
    output reg [DATA_W-1:0] ifu_npc_speculation,
    output reg [DATA_W-1:0] ifu_npc_bad_speculation
);

  reg [DATA_W-1:0] btb_buffer;  // Store the branch target buffer value
  reg btb_valid;  // Branch target buffer valid flag
  reg ifu_b_speculation;  // Branch speculation flag
  reg good_speculation;
  reg bad_speculation_pc_change;  // To track if bad speculation is due to PC change

  // Signals for determining whether it's a branch instruction
  wire [6:0] opcode_o = pc_ifu[6:0]; // Extract opcode from instruction (assuming it starts at bit 0)
  wire is_branch = (
    (opcode_o == `YSYX_OP_JAL) | (opcode_o == `YSYX_OP_JALR) |
    (opcode_o == `YSYX_OP_B_TYPE) | (opcode_o == `YSYX_OP_SYSTEM)
  );

  assign speculation_o = speculation;
  assign good_speculation_o = good_speculation;
  assign bad_speculation_o = bad_speculation | bad_speculationing;

  // Bad speculation logic
  wire bad_speculationing = (speculation && (
    (pc_change && npc != ifu_speculation) || 
    (pc_retire && (pc + 4) != ifu_speculation)
  ));

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      speculation <= 0;
      bad_speculation <= 0;
      good_speculation <= 0;
      ifu_b_speculation <= 0;
      bad_speculation_pc_change <= 0;
      ifu_npc_bad_speculation <= 0;
    end else begin
      if (bad_speculationing) begin
        bad_speculation <= 1;
        speculation <= 0;
        bad_speculation_pc_change <= pc_change;
      end else if (good_speculation) begin
        good_speculation <= 0;
        speculation <= 0;
      end

      // If speculation was successful and retire occurred with matching PC, mark as good speculation
      if (speculation && ((pc_change && npc == ifu_speculation) || 
          (pc_retire && (pc + 4) == ifu_speculation))) begin
        good_speculation <= 1;
        speculation <= 0;
      end

      // On bad speculation, update PC with correct next PC or the mispredicted target
      if (bad_speculation && !bad_speculation_pc_change) begin
        ifu_npc_bad_speculation <= npc;
      end
    end
  end

  // Branch prediction logic
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      btb_valid <= 0;
      ifu_b_speculation <= 0;
    end else begin
      if (is_branch && btb_valid && !speculation) begin
        speculation <= 1;
        ifu_speculation <= btb;
        ifu_npc_speculation <= pc_ifu + 4;
        if (opcode_o == `YSYX_OP_B_TYPE) begin
          ifu_b_speculation <= 1;  // Set if it's a conditional branch
        end
      end else if (pc_change) begin
        // Update BTB with new branch target on PC change
        btb_buffer <= npc;
        btb_valid  <= 1;
      end else if (pc_retire) begin
        // On retire, update PC to next sequential instruction (PC + 4)
        if (!is_branch) begin
          btb_valid <= 0;
        end
      end
    end
  end
endmodule
