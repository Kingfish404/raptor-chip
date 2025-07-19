`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_ifu #(
    parameter bit [$clog2(`YSYX_PHT_SIZE):0] PHT_SIZE = `YSYX_PHT_SIZE,
    parameter bit [$clog2(`YSYX_BTB_SIZE):0] BTB_SIZE = `YSYX_BTB_SIZE,
    parameter bit [$clog2(`YSYX_RSB_SIZE):0] RSB_SIZE = `YSYX_RSB_SIZE,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input flush_pipe,
    input fence_time,
    input fence_i,

    wbu_pipe_if.in wbu_bcast,

    ifu_idu_if.master ifu_idu,
    ifu_bus_if.master ifu_bus,

    input  prev_valid,
    input  next_ready,
    output out_valid,

    input reset
);
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] bpu_npc;
  logic ifu_sys_hazard;

  logic [2:0] bpu_pht[PHT_SIZE];
  logic [XLEN-1:0] bpu_btb[BTB_SIZE];
  logic [BTB_SIZE-1:0] bpu_btb_v;
  logic [XLEN-1:0] bpu_rsb[RSB_SIZE];
  logic [RSB_SIZE-1:0] bpu_rsb_v;
  logic [$clog2(RSB_SIZE)-1:0] bpu_rsb_idx;

  logic [$clog2(PHT_SIZE)-1:0] pht_rpc_idx, pht_idx;
  logic [$clog2(BTB_SIZE)-1:0] rpc_idx, btb_idx;

  logic ifu_hazard;
  logic [6:0] opcode;
  logic is_c, is_cjr, is_cjalr;
  logic is_b, is_jalr, is_jal, is_call, is_ret;
  logic is_sys;
  logic valid;

  logic invalid_l1i;
  logic l1i_valid;
  logic [XLEN-1:0] l1_inst;
  logic [XLEN-1:0] imm_b;
  logic [XLEN-1:0] imm_j;

  logic [XLEN-1:0] npc;
  logic [XLEN-1:0] rpc;
  logic jen;
  logic ben;
  logic sys_retire;

  assign rpc = wbu_bcast.pc;
  assign npc = wbu_bcast.npc;
  assign jen = wbu_bcast.jen;
  assign ben = wbu_bcast.ben;
  assign sys_retire = wbu_bcast.sys_retire;

  assign ifu_hazard = ifu_sys_hazard;
  assign opcode = is_c ? {2'b0, {l1_inst[15:13]}, {l1_inst[1:0]}} : l1_inst[6:0];
  // pre decode
  assign is_c = !(l1_inst[1:0] == 2'b11);
  assign is_cjr = (l1_inst[15:12] == 'b1000 && l1_inst[6:0] == 'b0000010);
  assign is_cjalr = (l1_inst[15:12] == 'b1001 && l1_inst[6:0] == 'b0000010);
  assign is_jalr = (opcode == `YSYX_OP_JALR__);

  assign is_b = (opcode == `YSYX_OP_B_TYPE_)
    || (opcode == `YSYX_OP_C_BEQZ)
    || (opcode == `YSYX_OP_C_BNEZ);
  assign is_jal = (opcode == `YSYX_OP_JAL___)
    || (opcode == `YSYX_OP_C_J___)
    || (opcode == `YSYX_OP_C_JAL_);
  assign is_call = ((is_jal && (l1_inst[12-1:0] != 'h06f))
    || (is_jalr && (l1_inst[12-1:0] != 'h067))
    || (is_cjalr)
    );
  assign is_ret = (l1_inst == 'h00008067) || (is_c && (l1_inst[15:0] == 'h8082));
  assign is_sys = (opcode == `YSYX_OP_SYSTEM) || (opcode == `YSYX_OP_FENCE_);

  assign valid = (l1i_valid && !ifu_hazard) && !flush_pipe;
  assign out_valid = valid;
  assign imm_b = (is_c)
    ? {
    {XLEN - 9{l1_inst[12]}},
    {l1_inst[12:12]},
    {l1_inst[6:6]},
    {l1_inst[5:5]},
    {l1_inst[2:2]},
    {l1_inst[11:11]},
    {l1_inst[10:10]},
    {l1_inst[4:4]},
    {l1_inst[3:3]},
    {1'b0}}
    :{{XLEN - 13{l1_inst[31]}}, {l1_inst[31:31]}, {l1_inst[7:7]}, l1_inst[30:25], l1_inst[11:8], 1'b0};
  assign imm_j = (is_c)
    ? {
    {XLEN - 12{l1_inst[12]}},
    {l1_inst[12:12]},
    {l1_inst[8:8]},
    {l1_inst[10:9]},
    {l1_inst[6:6]},
    {l1_inst[7:7]},
    {l1_inst[2:2]},
    {l1_inst[11:11]},
    {l1_inst[5:3]},
    {1'b0}}
    : {{XLEN - 21{l1_inst[31]}}, {l1_inst[31:31]}, l1_inst[19:12], l1_inst[20], l1_inst[30:21], 1'b0};

  // bpu
  assign bpu_npc = (is_ret) && bpu_rsb_v[bpu_rsb_idx-1]
    ? bpu_rsb[bpu_rsb_idx-1]
    : (is_jalr || is_cjalr || is_cjr) && bpu_btb_v[btb_idx]
      ? bpu_btb[btb_idx]
      : is_b && (bpu_pht[pht_idx][2:2])
        ? pc_ifu + imm_b
        :  (is_jal)
          ? pc_ifu + imm_j
          : pc_ifu + (is_c ? 'h2 : 'h4);
  assign pht_rpc_idx = rpc[$clog2(PHT_SIZE)-1+1:1];
  assign pht_idx = pc_ifu[$clog2(PHT_SIZE)-1+1:1];
  assign rpc_idx = rpc[$clog2(BTB_SIZE)-1+1:1];
  assign btb_idx = pc_ifu[$clog2(BTB_SIZE)-1+1:1];

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
        if (jen && flush_pipe) begin
          bpu_btb[rpc_idx]   <= npc;
          bpu_btb_v[rpc_idx] <= 1;
        end
        if (ben) begin
          if ((npc == rpc + 4) || (npc == rpc + 2)) begin
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
  assign ifu_idu.pc = pc_ifu;
  assign ifu_idu.pnpc = bpu_npc;
  assign ifu_idu.inst = l1_inst;

  assign ifu_idu.valid = valid;

  always @(posedge clock) begin
    if (reset) begin
      pc_ifu <= `YSYX_PC_INIT;
      ifu_sys_hazard <= 0;
    end else begin
      if (flush_pipe) begin
        pc_ifu <= npc;
        ifu_sys_hazard <= 0;
      end else begin
        if (prev_valid && sys_retire) begin
          ifu_sys_hazard <= 0;
          pc_ifu <= npc;
        end
        if (next_ready && valid) begin
          pc_ifu <= bpu_npc;
          if (is_call) begin
            bpu_rsb[bpu_rsb_idx] <= pc_ifu + (is_c ? 'h2 : 'h4);
            bpu_rsb_v[bpu_rsb_idx] <= 1;
            bpu_rsb_idx <= (bpu_rsb_idx + 1);
          end else if (is_ret) begin
            if (bpu_rsb_v[bpu_rsb_idx-1]) begin
              bpu_rsb_v[bpu_rsb_idx-1] <= 0;
              bpu_rsb_idx <= (bpu_rsb_idx - 1);
            end
          end
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
      .out_valid(l1i_valid),

      .invalid_l1i(fence_i),

      // <=> bus
      .bus_ifu_ready(ifu_bus.bus_ready),
      .out_ifu_araddr(ifu_bus.araddr),
      .out_ifu_arvalid(ifu_bus.arvalid),
      .ifu_rdata(ifu_bus.rdata),
      .ifu_rvalid(ifu_bus.rready),

      .reset(reset)
  );
endmodule
