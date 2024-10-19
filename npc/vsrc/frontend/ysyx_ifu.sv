`include "ysyx.svh"
`include "ysyx_soc.svh"

module ysyx_ifu (
    input clock,

    // for bus
    output [XLEN-1:0] out_ifu_araddr,
    output out_ifu_arvalid,
    output out_ifu_required,
    input [XLEN-1:0] ifu_rdata,
    input ifu_rvalid,

    input  [XLEN-1:0] npc,
    output [XLEN-1:0] out_inst,
    output [XLEN-1:0] out_pc,

    input pc_change,
    input pc_retire,
    input load_retire,

    output out_flush_pipeline,

    input  prev_valid,
    input  next_ready,
    output out_valid,
    output out_ready,

    input reset
);
  parameter bit [7:0] XLEN = 32;

  reg [XLEN-1:0] pc_ifu;
  reg ifu_lsu_hazard = 0, ifu_branch_hazard = 0;

  reg [XLEN-1:0] btb;
  reg [XLEN-1:0] ifu_speculation, ifu_npc_speculation;
  reg speculation, bad_speculation, ifu_b_speculation;

  wire ifu_hazard = ifu_lsu_hazard | ifu_branch_hazard;
  wire [6:0] opcode = out_inst[6:0];
  wire is_branch = (
    (opcode == `YSYX_OP_JAL) | (opcode == `YSYX_OP_JALR) |
    (opcode == `YSYX_OP_B_TYPE) | (0)
  );
  wire is_load = (opcode == `YSYX_OP_IL_TYPE);
  wire is_store = (opcode == `YSYX_OP_S_TYPE);
  wire is_fencei = (out_inst == `YSYX_INST_FENCE_I);  // fence.i is system instruction
  wire is_sys = (opcode == `YSYX_OP_SYSTEM);
  wire valid;

  assign valid =(l1i_valid & !ifu_hazard) &
   !bad_speculation & !(speculation & (is_load | is_store));
  assign out_valid = valid;
  assign out_ready = !valid;

  // Branch Prediction
  assign out_flush_pipeline = bad_speculation | bad_speculationing;
  wire good_speculationing = ((pc_change | pc_retire) & npc == ifu_speculation);
  wire bad_speculationing = ((speculation) & ((pc_change | pc_retire) & npc != ifu_speculation));
  reg  bad_speculation_pc_change;

  assign out_pc = pc_ifu;
  always @(posedge clock) begin
    if (reset) begin
      btb <= `YSYX_PC_INIT;
      pc_ifu <= `YSYX_PC_INIT;
      speculation <= 0;
      ifu_lsu_hazard <= 0;
      ifu_branch_hazard <= 0;
    end else begin
      if (prev_valid) begin
        if (speculation) begin
          if (good_speculationing) begin
            speculation <= 0;
            ifu_b_speculation <= 0;
          end
          if ((bad_speculationing)) begin
            bad_speculation <= 1;
            speculation <= 0;
            bad_speculation_pc_change <= pc_change;
          end
        end
      end
      if (pc_change) begin
        btb <= npc;
      end
      if (bad_speculation & next_ready & l1i_ready) begin
        bad_speculation <= 0;
        ifu_lsu_hazard <= 0;
        ifu_branch_hazard <= 0;
        ifu_b_speculation <= 0;
        bad_speculation_pc_change <= 0;
        pc_ifu <= (ifu_b_speculation & !bad_speculation_pc_change) ? ifu_npc_speculation : npc;
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
      if (!(bad_speculation | bad_speculationing) & next_ready == 1 & valid) begin
        if (!is_branch & !is_load & !is_sys) begin
          pc_ifu <= pc_ifu + 4;
        end else begin
          if (is_branch) begin
            if (!speculation) begin
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

  wire invalid_l1i = valid & next_ready & is_fencei;
  wire l1i_valid;
  wire l1i_ready;

  ysyx_ifu_l1i l1i_cache (
      .clock(clock),

      .pc_ifu(pc_ifu),
      .ifu_rvalid(ifu_rvalid),
      .ifu_rdata(ifu_rdata),
      .invalid_l1i(invalid_l1i),

      .out_ifu_araddr  (out_ifu_araddr),
      .out_ifu_arvalid (out_ifu_arvalid),
      .out_ifu_required(out_ifu_required),

      .out_inst (out_inst),
      .l1i_valid(l1i_valid),
      .l1i_ready(l1i_ready),

      .reset(reset)
  );
endmodule  // ysyx_IFU
