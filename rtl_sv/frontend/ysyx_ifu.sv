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

    cmu_bcast_if.in cmu_bcast,

    ifu_bpu_if.out ifu_bpu,
    ifu_l1i_if.master ifu_l1i,
    ifu_idu_if.master ifu_idu,

    input reset
);
  typedef enum logic [1:0] {
    IDLE  = 'b00,
    VALID = 'b01,
    STALL = 'b10
  } state_ifu_t;

  state_ifu_t state_ifu;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] seqpc;
  logic [XLEN-1:0] nextpc;

  logic ifu_hazard;
  logic pre_is_c;
  logic is_c;
  logic [6:0] opcode;
  logic is_sys;
  logic is_atomic;
  logic recv_ready;
  logic valid;

  logic [XLEN-1:0] inst;
  logic trap;
  logic [XLEN-1:0] cause;

  // debug signals
  logic [XLEN-1:0] pc_stride;
  logic [XLEN-1:0] pred_stride;

  assign ifu_hazard = state_ifu == STALL;
  assign pre_is_c = !(ifu_l1i.inst[1:0] == 2'b11);
  assign is_c = !(inst[1:0] == 2'b11);
  assign opcode = is_c ? {2'b0, {inst[15:13]}, {inst[1:0]}} : inst[6:0];
  assign is_sys = (opcode == `YSYX_OP_SYSTEM) || (opcode == `YSYX_OP_FENCE_);
  assign is_atomic = (opcode == `YSYX_OP_AMO___);

  assign valid = state_ifu == VALID;

  assign ifu_bpu.pc = pc_ifu;

  assign ifu_l1i.pc = pc_ifu;
  assign ifu_l1i.invalid = cmu_bcast.fence_i;

  assign ifu_idu.inst = inst;
  assign ifu_idu.pc = pc;
  assign ifu_idu.pnpc = pc_ifu;

  assign ifu_idu.trap = trap;
  assign ifu_idu.cause = cause;

  assign ifu_idu.valid = valid;

  assign seqpc = pc_ifu + (pre_is_c ? 'h2 : 'h4);
  assign nextpc = (cmu_bcast.flush_pipe ? cmu_bcast.cpc : ifu_bpu.taken ? ifu_bpu.npc : seqpc);

  assign recv_ready = (ifu_l1i.valid && (ifu_idu.ready || (state_ifu == IDLE)));

  assign pc_stride = pc_ifu - pc;
  assign pred_stride = nextpc - pc_ifu;

  always @(posedge clock) begin
    if (reset) begin
      pc_ifu <= `YSYX_PC_INIT;
      trap   <= 0;
    end else begin
      unique case (state_ifu)
        IDLE: begin
          if (cmu_bcast.flush_pipe) begin
            state_ifu <= IDLE;
          end else if (ifu_l1i.valid) begin
            state_ifu <= VALID;
          end
        end
        VALID: begin
          if (cmu_bcast.flush_pipe) begin
            state_ifu <= IDLE;
          end else if (ifu_idu.ready) begin
            if (is_sys || is_atomic || trap) begin
              state_ifu <= STALL;
            end else
            if (ifu_l1i.valid) begin
            end else begin
              state_ifu <= IDLE;
            end
          end
        end
        STALL: begin
          if (cmu_bcast.flush_pipe) begin
            state_ifu <= IDLE;
            trap <= 0;
          end
        end
        default: begin
          state_ifu <= IDLE;
        end
      endcase
      if (recv_ready || cmu_bcast.flush_pipe) begin
        pc_ifu <= nextpc;
      end
      if (recv_ready) begin
        inst <= ifu_l1i.inst;
        trap <= ifu_l1i.trap;
        cause <= ifu_l1i.cause;
        pc <= pc_ifu;
      end
    end
  end

endmodule
