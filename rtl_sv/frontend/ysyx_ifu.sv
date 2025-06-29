`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_ifu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [$clog2(`YSYX_PHT_SIZE):0] PHT_SIZE = `YSYX_PHT_SIZE,
    parameter bit [$clog2(`YSYX_BTB_SIZE):0] BTB_SIZE = `YSYX_BTB_SIZE
) (
    input clock,

    wbu_pipe_if.in wbu_if,

    output [XLEN-1:0] out_inst,
    output [XLEN-1:0] out_pc,
    output [XLEN-1:0] out_pnpc,

    input flush_pipeline,
    input fence_time,

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
  logic [XLEN-1:0] bpu_npc;
  logic ifu_sys_hazard;

  logic [2:0] bpu_pht[PHT_SIZE];
  logic [XLEN-1:0] bpu_btb[BTB_SIZE];
  logic [BTB_SIZE-1:0] bpu_btb_v;
  logic [$clog2(PHT_SIZE)-1:0] pht_rpc_idx, pht_idx;
  logic [$clog2(BTB_SIZE)-1:0] rpc_idx, btb_idx;

  logic ifu_hazard;
  logic [6:0] opcode;
  logic is_jalr, is_jal, is_b;
  logic is_sys;
  logic valid;

  logic invalid_l1i;
  logic l1i_valid;
  logic l1i_ready;
  logic [XLEN-1:0] l1_inst;
  logic [XLEN-1:0] imm_b;
  logic [XLEN-1:0] imm_j;

  logic [XLEN-1:0] npc;
  logic [XLEN-1:0] rpc;
  logic jen;
  logic ben;
  logic sys_retire;

  assign npc = wbu_if.npc;
  assign rpc = wbu_if.rpc;
  assign jen = wbu_if.jen;
  assign ben = wbu_if.ben;
  assign sys_retire = wbu_if.sys_retire;

  assign ifu_hazard = ifu_sys_hazard;
  assign out_inst = l1_inst;
  assign opcode = out_inst[6:0];
  // pre decode
  assign is_jalr = (opcode == `YSYX_OP_JALR__);
  assign is_b = (opcode == `YSYX_OP_B_TYPE_);
  assign is_jal = (opcode == `YSYX_OP_JAL___);
  assign is_sys = (opcode == `YSYX_OP_SYSTEM) || (opcode == `YSYX_OP_FENCE_);

  assign valid = (l1i_valid && !ifu_hazard) && !flush_pipeline;
  assign out_valid = valid;
  assign out_ready = !valid;
  assign imm_b = {
    {XLEN - 13{l1_inst[31]}}, {l1_inst[31:31]}, {l1_inst[7:7]}, l1_inst[30:25], l1_inst[11:8], 1'b0
  };
  assign imm_j = {
    {XLEN - 21{l1_inst[31]}}, {l1_inst[31:31]}, l1_inst[19:12], l1_inst[20], l1_inst[30:21], 1'b0
  };

  // bpu
  assign bpu_npc = is_jalr && bpu_btb_v[btb_idx]
    ? bpu_btb[btb_idx]
    : is_b && (bpu_pht[pht_idx][2:2])
      ? pc_ifu + imm_b
      :  (is_jal)
        ? pc_ifu + imm_j
        : pc_ifu + 4;
  assign pht_rpc_idx = rpc[$clog2(PHT_SIZE)-1+2:2];
  assign pht_idx = pc_ifu[$clog2(PHT_SIZE)-1+2:2];
  assign rpc_idx = rpc[$clog2(BTB_SIZE)-1+2:2];
  assign btb_idx = pc_ifu[$clog2(BTB_SIZE)-1+2:2];

  always @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < PHT_SIZE; i++) begin
        bpu_pht[i] <= 0;
      end
      bpu_btb_v <= 0;
    end else begin
      if (fence_time) begin
        for (int i = 0; i < PHT_SIZE; i++) begin
          bpu_pht[i] <= 0;
        end
        bpu_btb_v <= 0;
      end else begin
        if (jen) begin
          bpu_btb[rpc_idx]   <= npc;
          bpu_btb_v[rpc_idx] <= 1;
        end
        if (ben) begin
          if (npc == rpc + 4) begin
            if (bpu_pht[pht_rpc_idx] != 'b000) begin
              bpu_pht[pht_rpc_idx] <= bpu_pht[pht_rpc_idx] - 1;
            end else begin
            end
          end else begin
            if (bpu_pht[pht_rpc_idx] != 'b111) begin
              bpu_pht[pht_rpc_idx] <= bpu_pht[pht_rpc_idx] + 1;
            end else begin
            end
          end
        end
      end
    end
  end

  // ifu
  assign out_pc   = pc_ifu;
  assign out_pnpc = bpu_npc;
  always @(posedge clock) begin
    if (reset) begin
      pc_ifu <= `YSYX_PC_INIT;
      ifu_sys_hazard <= 0;
    end else begin
      if (flush_pipeline) begin
        pc_ifu <= npc;
        ifu_sys_hazard <= 0;
      end else begin
        if (prev_valid && sys_retire) begin
          ifu_sys_hazard <= 0;
          pc_ifu <= npc;
        end
        if (next_ready && valid) begin
          pc_ifu <= bpu_npc;
          if (is_sys) begin
            ifu_sys_hazard <= 1;
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
