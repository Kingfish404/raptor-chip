`include "ysyx.svh"
`include "ysyx_soc.svh"

module ysyx_ifu (
    input clock,

    // for bus
    output [DATA_W-1:0] ifu_araddr_o,
    output ifu_arvalid_o,
    output ifu_required_o,
    input [DATA_W-1:0] ifu_rdata,
    input ifu_rvalid,

    input  [DATA_W-1:0] npc,
    output [DATA_W-1:0] inst_o,
    output [DATA_W-1:0] pc_o,

    input [DATA_W-1:0] pc,
    input pc_change,
    input pc_retire,
    input load_retire,

    output speculation_o,
    output bad_speculation_o,
    output good_speculation_o,

    input  prev_valid,
    input  next_ready,
    output valid_o,
    output ready_o,

    input reset
);
  parameter bit [7:0] DATA_W = 32;

  reg [DATA_W-1:0] pc_ifu;
  reg ifu_lsu_hazard = 0, ifu_branch_hazard = 0;

  reg [DATA_W-1:0] btb;
  reg [DATA_W-1:0] ifu_speculation, ifu_npc_speculation;
  reg btb_valid, speculation, bad_speculation, ifu_b_speculation;

  wire ifu_hazard = ifu_lsu_hazard | ifu_branch_hazard;
  wire [6:0] opcode = inst_o[6:0];
  wire is_branch = (
    (opcode == `YSYX_OP_JAL) | (opcode == `YSYX_OP_JALR) |
    (opcode == `YSYX_OP_B_TYPE) |
    (0)
  );
  wire is_load = (opcode == `YSYX_OP_IL_TYPE);
  wire is_store = (opcode == `YSYX_OP_S_TYPE);
  wire is_fencei = (inst_o == `YSYX_INST_FENCE_I);  // fence.i is system instruction
  wire is_sys = (opcode == `YSYX_OP_SYSTEM);

  assign valid_o = (l1i_valid & !ifu_hazard) &
   !bad_speculation & !(speculation & (is_load | is_store));
  assign ready_o = !valid_o;

  // Branch Prediction
  assign speculation_o = speculation;
  assign good_speculation_o = good_speculation;
  assign bad_speculation_o = bad_speculation | bad_speculationing;
  wire good_speculationing = (
    (pc_change & npc == ifu_speculation) |
    (pc_retire & pc + 4 == ifu_speculation));
  wire bad_speculationing = (speculation & (
    (pc_change & npc != ifu_speculation) |
    (pc_retire & !pc_change & pc + 4 != ifu_speculation)));
  reg good_speculation;
  reg bad_speculation_pc_change;

  assign pc_o = pc_ifu;
  always @(posedge clock) begin
    if (reset) begin
      pc_ifu <= `YSYX_PC_INIT;
      speculation <= 0;
      ifu_lsu_hazard <= 0;
      ifu_branch_hazard <= 0;
    end else begin
      if (speculation) begin
        if (good_speculationing) begin
          good_speculation <= 1;
          speculation <= 0;
          ifu_b_speculation <= 0;
        end
        if ((bad_speculationing)) begin
          bad_speculation <= 1;
          speculation <= 0;
          bad_speculation_pc_change <= pc_change;
        end
      end
      if (bad_speculation & next_ready & l1i_ready) begin
        bad_speculation <= 0;
        ifu_lsu_hazard <= 0;
        ifu_branch_hazard <= 0;
        ifu_b_speculation <= 0;
        bad_speculation_pc_change <= 0;
        pc_ifu <= (ifu_b_speculation & !bad_speculation_pc_change) ? ifu_npc_speculation : npc;
      end else if (good_speculation) begin
        good_speculation <= 0;
      end
      if (!speculation) begin
        if (ifu_branch_hazard & (pc_change | pc_retire) & l1i_ready) begin
          ifu_branch_hazard <= 0;
          pc_ifu <= pc_change ? npc : pc_ifu + 4;
        end
        if (ifu_lsu_hazard & load_retire & l1i_ready) begin
          ifu_lsu_hazard <= 0;
          pc_ifu <= pc_ifu + 4;
        end
      end
      if (pc_change) begin
        btb <= npc;
        btb_valid <= 1;
      end
      if (!bad_speculation_o & next_ready == 1 & valid_o) begin
        if (!is_branch & !is_load & !is_sys) begin
          pc_ifu <= pc_ifu + 4;
        end else begin
          if (is_branch) begin
            if (btb_valid & 1 & !speculation) begin
              pc_ifu <= btb;
              ifu_speculation <= btb;
              ifu_npc_speculation <= pc_ifu + 4;
              speculation <= 1;
              if (opcode == `YSYX_OP_B_TYPE) begin
                ifu_b_speculation <= 1;
              end
            end else begin
              ifu_branch_hazard <= 1;
            end
          end
          if (is_load) begin
            ifu_lsu_hazard <= 1;
          end
          if (is_sys) begin
            ifu_branch_hazard <= 1;
          end
        end
      end
    end
  end

  wire invalid_l1i = valid_o & next_ready & is_fencei;
  wire l1i_valid;
  wire l1i_ready;

  ysyx_ifu_l1i l1i_cache (
      .clock(clock),

      .pc_ifu(pc_ifu),
      .ifu_rvalid(ifu_rvalid),
      .ifu_rdata(ifu_rdata),
      .invalid_l1i(invalid_l1i),

      .ifu_araddr_o  (ifu_araddr_o),
      .ifu_arvalid_o (ifu_arvalid_o),
      .ifu_required_o(ifu_required_o),

      .inst_o(inst_o),
      .l1i_valid(l1i_valid),
      .l1i_ready(l1i_ready),

      .reset(reset)
  );
endmodule  // ysyx_IFU
