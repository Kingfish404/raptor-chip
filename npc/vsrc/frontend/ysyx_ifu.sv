`include "ysyx.svh"
`include "ysyx_soc.svh"

module ysyx_ifu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [$clog2(`YSYX_BTB_SIZE):0] BTB_SIZE = `YSYX_BTB_SIZE
) (
    input clock,

    input [XLEN-1:0] npc,
    input [XLEN-1:0] cpc,
    input br_retire,

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

    // for iqu
    input fence_i,

    input  prev_valid,
    input  next_ready,
    output out_valid,
    output out_ready,

    input reset
);
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] pnpc_ifu;
  logic ifu_sys_hazard = 0;

  logic [XLEN-1:0] btb, btb_jal;
  logic [XLEN-1:0] bpu_btb[BTB_SIZE], bpu_btb_jal[BTB_SIZE];
  logic [$clog2(BTB_SIZE)-1:0] cpc_idx, pc_idx;
  logic speculation, ifu_b_speculation;

  logic ifu_hazard;
  logic [6:0] opcode;
  logic is_jalr, is_jal, is_b_type, is_branch;
  logic is_sys;
  logic valid;

  logic invalid_l1i;
  logic l1i_valid;
  logic l1i_ready;
  logic [XLEN-1:0] l1_inst;

  assign ifu_hazard = ifu_sys_hazard;
  assign out_inst = l1i_valid ? l1_inst : 'h0;
  assign opcode = out_inst[6:0];
  // pre decode
  assign is_jalr = (opcode == `YSYX_OP_JALR__);
  assign is_jal = (opcode == `YSYX_OP_JAL___);
  assign is_b_type = (opcode == `YSYX_OP_B_TYPE_);
  assign is_branch = (is_jal || is_jalr || is_b_type);
  assign is_sys = (opcode == `YSYX_OP_SYSTEM);

  assign valid = (l1i_valid && !ifu_hazard) && !flush_pipeline;
  assign out_valid = valid;
  assign out_ready = !valid;

  // BTFN (Backward Taken, Forward Not-taken), jalr is always not taken
  assign pnpc_ifu = ((is_b_type && (btb < pc_ifu)) ? btb :
   (is_jal && (btb_jal < pc_ifu)) ? btb_jal : pc_ifu + 4);
  assign btb = bpu_btb[pc_idx];
  assign btb_jal = bpu_btb_jal[pc_idx];
  assign cpc_idx = cpc[$clog2(BTB_SIZE)-1+2:2];
  assign pc_idx = pc_ifu[$clog2(BTB_SIZE)-1+2:2];

  assign out_pc = pc_ifu;
  assign out_pnpc = pnpc_ifu;
  always @(posedge clock) begin
    if (reset) begin
      pc_ifu <= `YSYX_PC_INIT;
      speculation <= 0;
      ifu_sys_hazard <= 0;
      for (int i = 0; i < BTB_SIZE; i++) begin
        bpu_btb[i[$clog2(BTB_SIZE)-1:0]] <= `YSYX_PC_INIT;
        bpu_btb_jal[i[$clog2(BTB_SIZE)-1:0]] <= `YSYX_PC_INIT;
      end
    end else begin
      if (flush_pipeline) begin
        pc_ifu <= npc;
        ifu_sys_hazard <= 0;
        speculation <= 0;
        ifu_b_speculation <= 0;
        if (ifu_b_speculation) begin
          bpu_btb[cpc_idx] <= npc;
        end else begin
          bpu_btb_jal[cpc_idx] <= npc;
        end
      end else begin
        if (prev_valid && br_retire) begin
          speculation <= 0;
          ifu_b_speculation <= 0;
          ifu_sys_hazard <= 0;
          if (ifu_sys_hazard) begin
            pc_ifu <= npc;
          end
        end
        if (next_ready && valid) begin
          if (!is_branch && !is_sys) begin
            pc_ifu <= pc_ifu + 4;
          end else begin
            if (is_branch) begin
              pc_ifu <= pnpc_ifu;
              if (is_b_type && (btb < pc_ifu)) begin
                speculation <= 1;
                ifu_b_speculation <= 1;
              end else if (is_jal && (btb_jal < pc_ifu)) begin
                speculation <= 1;
              end
            end else if (is_sys) begin
              ifu_sys_hazard <= 1;
            end
          end
        end
      end
    end
  end

  ysyx_ifu_l1i l1i_cache (
      .clock(clock),

      .pc_ifu(pc_ifu),
      .out_inst(l1_inst),
      .l1i_valid(l1i_valid),
      .l1i_ready(l1i_ready),
      .invalid_l1i(fence_i),
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
