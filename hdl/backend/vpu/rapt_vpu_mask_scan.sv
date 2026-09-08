`include "rapt_sva.svh"

// Read-only mask scan, independent of vector element width and scalar ROB.
// Caller owns exclusive VRF access and has validated the raw instruction.
// One source byte (and at most one predicate byte) is fetched per eight bits.
module rapt_vpu_mask_scan #(
    parameter int XLEN=64,
    VLEN=128,
    parameter int AddrBits=$clog2(32*VLEN/8),
    IndexBits=$clog2(VLEN)+1
) (
    input logic clock,
    reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic cmd_first,
    cmd_masked,
    cmd_vill,
    input logic [4:0] cmd_src,
    input logic [XLEN-1:0] cmd_vl,
    input logic [$clog2(VLEN)-1:0] cmd_vstart,
    output logic done_valid,
    input logic done_ready,
    output logic done_trap,
    output logic [XLEN-1:0] done_value,
    output logic vr_valid,
    input logic vr_ready,
    output logic [AddrBits-1:0] vr_addr,
    input logic vr_rsp_valid,
    output logic vr_rsp_ready,
    input logic [7:0] vr_rdata
);
  typedef enum logic [2:0] {
    IDLE,
    CHECK,
    SOURCE_REQ,
    SOURCE_RSP,
    MASK_REQ,
    MASK_RSP,
    FOLD,
    DONE
  } state_t;
  state_t state;
  logic first_q, masked_q, bad_q;
  logic [4:0] src_q;
  logic [XLEN-1:0] vl_q;
  logic [IndexBits-1:0] index_q;
  logic [7:0] source_q, mask_q;
  logic [3:0] count;
  logic found;
  logic [2:0] first_bit;
  always_comb begin
    count = 0;
    found = 0;
    first_bit = 0;
    for (int b = 0; b < 8; b++) begin
      if (source_q[b] && mask_q[b] && XLEN'(index_q) + XLEN'(b) < vl_q) begin
        count = count + 1'b1;
        if (!found) first_bit = 3'(b);
        found = 1;
      end
    end
  end
  assign cmd_ready = !reset && state == IDLE;
  assign done_valid = !reset && state == DONE;
  assign vr_valid = !reset && (state == SOURCE_REQ || state == MASK_REQ);
  assign vr_addr = AddrBits'((state == MASK_REQ ? 0 : int'(src_q)*(VLEN/8))+(int'(index_q) >> 3));
  assign vr_rsp_ready = state == SOURCE_RSP || state == MASK_RSP;
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      first_q <= 0;
      masked_q <= 0;
      bad_q <= 0;
      src_q <= 0;
      vl_q <= 0;
      index_q <= 0;
      source_q <= 0;
      mask_q <= 0;
      done_value <= 0;
      done_trap <= 0;
    end else
      case (state)
        IDLE:
        if (cmd_valid && cmd_ready) begin
          first_q <= cmd_first;
          masked_q <= cmd_masked;
          src_q <= cmd_src;
          vl_q <= cmd_vl;
          bad_q <= cmd_vill || cmd_vstart != 0 || cmd_vl > XLEN'(VLEN);
          index_q <= 0;
          done_trap <= 0;
          done_value <= cmd_first ? '1 : '0;
          state <= CHECK;
        end
        CHECK:
        if (bad_q) begin
          done_trap <= 1;
          state <= DONE;
        end else state <= vl_q == 0 ? DONE : SOURCE_REQ;
        SOURCE_REQ: if (vr_valid && vr_ready) state <= SOURCE_RSP;
        SOURCE_RSP: if (vr_rsp_valid && vr_rsp_ready) begin
        source_q <= vr_rdata;
        // When vs2=v0, predicate AND source equals source without another read.
        mask_q <= '1;
        state <= masked_q && src_q != 0 ? MASK_REQ : FOLD;
      end
        MASK_REQ: if (vr_valid && vr_ready) state <= MASK_RSP;
        MASK_RSP: if (vr_rsp_valid && vr_rsp_ready) begin mask_q <= vr_rdata; state <= FOLD; end
        FOLD: begin
        if (first_q && found) begin
          done_value <= XLEN'(index_q)+XLEN'(first_bit); state <= DONE;
        end else begin
          if (!first_q) done_value <= done_value+XLEN'(count);
          index_q <= index_q+IndexBits'(8);
          state <= XLEN'(index_q)+XLEN'(8) >= vl_q ? DONE : SOURCE_REQ;
        end
      end
        DONE: if (done_valid && done_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_SCAN_REQUEST_HOLD, vr_valid && !vr_ready, vr_valid && $stable
                 (vr_addr))
  `RAPT_SVA_NEXT(clock, reset, VPU_SCAN_DONE_HOLD, done_valid && !done_ready, done_valid && $stable
                 ({done_trap, done_value}))
  `RAPT_SVA_IMPLY(clock, reset, VPU_SCAN_REQUEST_RANGE, vr_valid, !bad_q && XLEN'(index_q) < vl_q)
endmodule
