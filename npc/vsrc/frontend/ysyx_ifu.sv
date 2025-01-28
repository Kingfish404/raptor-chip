`include "ysyx.svh"
`include "ysyx_soc.svh"

module ysyx_ifu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input load_retire,

    input [XLEN-1:0] npc,
    input pc_change,
    input pc_retire,

    output [XLEN-1:0] out_inst,
    output [XLEN-1:0] out_pc,
    output [XLEN-1:0] out_pnpc,

    input flush_pipeline,

    // for bus
    input bus_ifu_ready,
    output [XLEN-1:0] out_ifu_araddr,
    output out_ifu_arvalid,
    output out_ifu_lock,
    input [XLEN-1:0] ifu_rdata,
    input ifu_rvalid,

    input  prev_valid,
    input  next_ready,
    output out_valid,
    output out_ready,

    input reset
);
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] pnpc_ifu;
  logic ifu_lsu_hazard = 0, ifu_branch_hazard = 0;

  logic [XLEN-1:0] btb, btb_jal;
  logic speculation, ifu_b_speculation;

  logic ifu_hazard;
  logic [6:0] opcode;
  logic is_jalr, is_jal, is_b_type, is_branch, is_load, is_store, is_fencei, is_sys;
  logic valid;

  logic invalid_l1i;
  logic l1i_valid;
  logic l1i_ready;
  logic [XLEN-1:0] l1_inst;

  assign ifu_hazard = ifu_lsu_hazard || ifu_branch_hazard;
  assign out_inst = l1i_valid ? l1_inst : 'h0;
  assign opcode = out_inst[6:0];
  // pre decode
  assign is_jalr = (opcode == `YSYX_OP_JALR__);
  assign is_jal = (opcode == `YSYX_OP_JAL___);
  assign is_b_type = (opcode == `YSYX_OP_B_TYPE_);
  assign is_branch = (is_jal || is_jalr || is_b_type);
  assign is_load = (opcode == `YSYX_OP_IL_TYPE);
  assign is_store = (opcode == `YSYX_OP_S_TYPE_);
  assign is_fencei = (out_inst == `YSYX_INST_FENCE_I);  // fence.i is system instruction
  assign is_sys = (opcode == `YSYX_OP_SYSTEM);

  assign valid =(l1i_valid && !ifu_hazard) && !flush_pipeline &&
          !(speculation && (is_load || is_store));
  assign out_valid = valid;
  assign out_ready = !valid;

  // BTFN (Backward Taken, Forward Not-taken), jalr is always not taken
  assign pnpc_ifu = ((is_b_type && (btb < pc_ifu)) ? btb :
   (is_jal && (btb_jal < pc_ifu)) ? btb_jal : ((is_load) ? pc_ifu + 4 :pc_ifu));
  assign out_pc = pc_ifu;
  assign out_pnpc = pnpc_ifu;
  always @(posedge clock) begin
    if (reset) begin
      btb <= `YSYX_PC_INIT;
      btb_jal <= `YSYX_PC_INIT;
      pc_ifu <= `YSYX_PC_INIT;
      speculation <= 0;
      ifu_lsu_hazard <= 0;
      ifu_branch_hazard <= 0;
    end else begin
      if (flush_pipeline) begin
        speculation <= 0;
        pc_ifu <= npc;
        ifu_lsu_hazard <= 0;
        ifu_branch_hazard <= 0;
        ifu_b_speculation <= 0;
        if (ifu_b_speculation) begin
          btb <= npc;
        end else begin
          btb_jal <= npc;
        end
      end else if (prev_valid && pc_retire) begin
        speculation <= 0;
        ifu_branch_hazard <= 0;
        if (ifu_branch_hazard) begin
          pc_ifu <= npc;
        end
      end else if (ifu_lsu_hazard && load_retire && l1i_ready) begin
        ifu_lsu_hazard <= 0;
        pc_ifu <= pc_ifu + 4;
      end
      if (next_ready && valid) begin
        if (!is_branch && !is_load && !is_sys) begin
          pc_ifu <= pc_ifu + 4;
        end else begin
          if (is_branch) begin
            if (!speculation) begin
              pc_ifu <= pnpc_ifu;
              if (is_b_type && (btb < pc_ifu)) begin
                speculation <= 1;
                ifu_b_speculation <= 1;
              end else if (is_jal && (btb_jal < pc_ifu)) begin
                speculation <= 1;
              end else begin
                ifu_branch_hazard <= 1;
              end
            end else begin
              ifu_branch_hazard <= 1;
            end
          end else if (is_load) begin
            ifu_lsu_hazard <= 1;
          end else if (is_sys) begin
            ifu_branch_hazard <= 1;
          end
        end
      end
    end
  end

  assign invalid_l1i = valid && next_ready && is_fencei;

  ysyx_ifu_l1i l1i_cache (
      .clock(clock),

      .pc_ifu(pc_ifu),
      .out_inst(l1_inst),
      .l1i_valid(l1i_valid),
      .l1i_ready(l1i_ready),
      .invalid_l1i(invalid_l1i),
      .flush_pipeline(flush_pipeline),

      // <=> bus
      .bus_ifu_ready(bus_ifu_ready),
      .out_ifu_lock(out_ifu_lock),
      .out_ifu_araddr(out_ifu_araddr),
      .out_ifu_arvalid(out_ifu_arvalid),
      .ifu_rdata(ifu_rdata),
      .ifu_rvalid(ifu_rvalid),

      .reset(reset)
  );
endmodule
