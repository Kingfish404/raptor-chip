`include "rapt_sva.svh"

// Whole-register copy engine. The owner authorizes exclusive VRF access.
// Legal aligned equal-sized groups are either identical or disjoint. VL/LMUL
// do not set transfer length; SEW converts vstart into a byte offset. VILL traps.
module rapt_vpu_move #(
    parameter int VLEN=128,
    parameter int AddrBits=$clog2(32*VLEN/8),
    OffsetBits=$clog2(VLEN)+4
) (
    input logic clock,
    reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [31:0] cmd_insn,
    input logic [1:0] cmd_sew,
    input logic cmd_vill,
    input logic [$clog2(VLEN)-1:0] cmd_vstart,
    output logic done_valid,
    input logic done_ready,
    output logic done_trap,
    output logic vr_valid,
    input logic vr_ready,
    output logic vr_write,
    output logic [AddrBits-1:0] vr_addr,
    output logic [1:0] vr_size,
    output logic [63:0] vr_wdata,
    input logic vr_rsp_valid,
    output logic vr_rsp_ready,
    input logic [63:0] vr_rdata
);
  typedef enum logic [2:0] {
    IDLE,
    CHECK,
    READ_REQ,
    READ_RSP,
    WRITE_REQ,
    WRITE_RSP,
    DONE
  } state_t;
  state_t state;
  logic [31:0] insn_q;
  logic [1:0] sew_q;
  logic [OffsetBits-1:0] offset_q, limit;
  logic [63:0] data_q;
  logic legal, vill_q;
  logic [4:0] count_mask;
  assign count_mask = insn_q[19:15];
  assign limit = (OffsetBits'(count_mask)+1'b1)*OffsetBits'(VLEN/8);
  assign legal = !vill_q && insn_q[6:0] == 7'h57 && insn_q[14:12] == 3 && insn_q[31:25] == 7'b1001111
      && (count_mask == 0 || count_mask == 1 || count_mask == 3 || count_mask == 7)
      && (insn_q[24:20] & count_mask) == 0 && (insn_q[11:7] & count_mask) == 0;
  assign cmd_ready = !reset && state == IDLE;
  assign done_valid = !reset && state == DONE;
  assign vr_valid = !reset && (state == READ_REQ || state == WRITE_REQ);
  assign vr_write = state == WRITE_REQ;
  assign vr_size = sew_q;
  assign vr_addr = AddrBits'((vr_write ? int'(insn_q[11:7]) : int'(insn_q[24:20]))*(VLEN/8)+int'(offset_q));
  assign vr_wdata = data_q;
  assign vr_rsp_ready = state == READ_RSP || state == WRITE_RSP;
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      vill_q <= 0;
      insn_q <= 0;
      sew_q <= 0;
      offset_q <= 0;
      data_q <= 0;
      done_trap <= 0;
    end else
      case (state)
        IDLE:
        if (cmd_valid && cmd_ready) begin
          insn_q <= cmd_insn;
          sew_q <= cmd_sew;
          vill_q <= cmd_vill;
          offset_q <= OffsetBits'(cmd_vstart) << cmd_sew;
          done_trap <= 0;
          state <= CHECK;
        end
        CHECK:
        if (!legal) begin
          done_trap <= 1;
          state <= DONE;
        end else if (offset_q >= limit || insn_q[11:7] == insn_q[24:20]) state <= DONE;
        else state <= READ_REQ;
        READ_REQ: if (vr_valid && vr_ready) state <= READ_RSP;
        READ_RSP: if (vr_rsp_valid && vr_rsp_ready) begin data_q <= vr_rdata; state <= WRITE_REQ; end
        WRITE_REQ: if (vr_valid && vr_ready) state <= WRITE_RSP;
        WRITE_RSP: if (vr_rsp_valid && vr_rsp_ready) begin
        offset_q <= offset_q+(OffsetBits'(1) << sew_q);
        state <= offset_q+(OffsetBits'(1) << sew_q) >= limit ? DONE : READ_REQ;
      end
        DONE: if (done_valid && done_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_MOVE_REQUEST_HOLD, vr_valid && !vr_ready, vr_valid && $stable
                 ({vr_addr, vr_size, vr_write, vr_wdata}))
  `RAPT_SVA_NEXT(clock, reset, VPU_MOVE_DONE_HOLD, done_valid && !done_ready, done_valid && $stable
                 (done_trap))
  `RAPT_SVA_IMPLY(clock, reset, VPU_MOVE_ACCESS_LEGAL, vr_valid, legal && offset_q < limit)
endmodule
