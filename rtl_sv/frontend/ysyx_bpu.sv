`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_bpu #(
    parameter int PHT_SIZE = `YSYX_PHT_SIZE,
    parameter int BTB_SIZE = `YSYX_BTB_SIZE,
    parameter int RSB_SIZE = `YSYX_RSB_SIZE,
    parameter int XLEN = `YSYX_XLEN
) (
    input clock,

    wbu_pipe_if.in wbu_bcast,

    ifu_bpu_if.in ifu_bpu,

    input reset
);
  logic [XLEN-1:0] inst;
  logic [XLEN-1:0] imm_b;
  logic [XLEN-1:0] imm_j;

  logic [6:0] opcode;
  logic is_c, is_cjr, is_cjalr;
  logic is_b, is_jalr, is_jal;

  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;

  logic [2:0] bpu_pht[PHT_SIZE];
  logic [XLEN-1:0] bpu_btb[BTB_SIZE];
  logic [BTB_SIZE-1:0] bpu_btb_v;
  logic [XLEN-1:0] bpu_rsb[RSB_SIZE];
  logic [RSB_SIZE-1:0] bpu_rsb_v;
  logic [$clog2(RSB_SIZE)-1:0] bpu_rsb_idx;

  logic [$clog2(PHT_SIZE)-1:0] pht_rpc_idx, pht_idx;
  logic [$clog2(BTB_SIZE)-1:0] rpc_idx, btb_idx;

  assign inst = ifu_bpu.inst;
  assign opcode = is_c ? {2'b0, {inst[15:13]}, {inst[1:0]}} : inst[6:0];
  assign is_c = !(inst[1:0] == 2'b11);
  assign is_cjr = (inst[15:12] == 'b1000 && inst[6:0] == 'b0000010);
  assign is_cjalr = (inst[15:12] == 'b1001 && inst[6:0] == 'b0000010);
  assign is_jalr = (opcode == `YSYX_OP_JALR__);

  assign is_b = (opcode == `YSYX_OP_B_TYPE_)
    || (opcode == `YSYX_OP_C_BEQZ)
    || (opcode == `YSYX_OP_C_BNEZ);
  assign is_jal = (opcode == `YSYX_OP_JAL___)
    || (opcode == `YSYX_OP_C_J___)
    || (opcode == `YSYX_OP_C_JAL_);

  assign imm_b = (is_c)
    ? {
    {XLEN - 9{inst[12]}},
    {inst[12:12]},
    {inst[6:6]},
    {inst[5:5]},
    {inst[2:2]},
    {inst[11:11]},
    {inst[10:10]},
    {inst[4:4]},
    {inst[3:3]},
    {1'b0}}
    : {{XLEN - 13{inst[31]}},
      {inst[31:31]}, {inst[7:7]}, inst[30:25], inst[11:8], 1'b0};
  assign imm_j = (is_c)
    ? {
    {XLEN - 12{inst[12]}},
    {inst[12:12]},
    {inst[8:8]},
    {inst[10:9]},
    {inst[6:6]},
    {inst[7:7]},
    {inst[2:2]},
    {inst[11:11]},
    {inst[5:3]},
    {1'b0}}
    : {{XLEN - 21{inst[31]}},
      {inst[31:31]}, inst[19:12], inst[20], inst[30:21], 1'b0};

  assign pc = ifu_bpu.pc;
  assign npc = (is_jalr || is_cjalr || is_cjr) && bpu_btb_v[btb_idx]
      ? bpu_btb[btb_idx]
      : is_b && (bpu_pht[pht_idx][2:2])
        ? pc + imm_b
        :  (is_jal)
          ? pc + imm_j
          : pc + (is_c ? 'h2 : 'h4);

  assign rpc = wbu_bcast.rpc;
  assign cpc = wbu_bcast.cpc;

  assign pht_idx = pc[$clog2(PHT_SIZE)-1+1:1];
  assign btb_idx = pc[$clog2(BTB_SIZE)-1+1:1];
  assign rpc_idx = rpc[$clog2(BTB_SIZE)-1+1:1];
  assign pht_rpc_idx = rpc[$clog2(PHT_SIZE)-1+1:1];

  assign ifu_bpu.npc = npc;
  assign ifu_bpu.taken = bpu_btb_v[btb_idx];

  always @(posedge clock) begin
    if (reset || wbu_bcast.fence_time) begin
      for (int i = 0; i < PHT_SIZE; i++) begin
        bpu_pht[i] <= 0;
      end
      bpu_btb_v <= 0;
    end else begin
      if (wbu_bcast.jen && wbu_bcast.flush_pipe) begin
        bpu_btb[rpc_idx]   <= cpc;
        bpu_btb_v[rpc_idx] <= 1;
      end
      if (wbu_bcast.ben) begin
        if ((cpc == rpc + 4) || (cpc == rpc + 2)) begin
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

endmodule
