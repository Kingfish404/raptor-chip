`include "rapt_sva.svh"
// Already-authorized FP reduction over an exclusive element VRF port.
// All source/mask reads precede the sole destination write, including when
// vd overlaps vs1, vs2 or v0. Tail bytes are preserved. External numeric and
// VRF services must reset/drain with the engine before reuse.
module rapt_vpu_fp_reduce_engine #(
    parameter int XLEN=64,
    VLEN=128,
    ELEN=64,
    parameter bit CacheMask=1,
    parameter int AddrBits=$clog2(32*VLEN/8),
    IndexBits=$clog2(VLEN)+1
) (
    input logic clock,
    reset,
    cmd_valid,
    output logic cmd_ready,
    input logic [31:0] cmd_insn,
    input logic [XLEN-1:0] cmd_vtype,
    cmd_vl,
    input logic [$clog2(VLEN)-1:0] cmd_vstart,
    input logic [2:0] cmd_frm,
    input logic cmd_enabled,
    output logic done_valid,
    input logic done_ready,
    output logic done_trap,
    output logic [4:0] done_flags,
    output logic vr_valid,
    input logic vr_ready,
    output logic vr_write,
    output logic [AddrBits-1:0] vr_addr,
    output logic [1:0] vr_size,
    output logic [63:0] vr_wdata,
    input logic vr_rsp_valid,
    output logic vr_rsp_ready,
    input logic [63:0] vr_rdata,
    output logic service_req_valid,
    input logic service_req_ready,
    output logic [1:0] service_op,
    output logic service_double,
    output logic [2:0] service_rm,
    output logic [63:0] service_a,
    service_b,
    input logic service_rsp_valid,
    output logic service_rsp_ready,
    input logic [63:0] service_result,
    input logic [4:0] service_flags,
    input logic service_illegal
);
  typedef enum logic [3:0] {
    IDLE,
    CHECK,
    SEED_REQ,
    SEED_RSP,
    START,
    NEXT,
    MASK_REQ,
    MASK_RSP,
    DATA_REQ,
    DATA_RSP,
    FEED,
    WRITE_REQ,
    WRITE_RSP,
    DONE
  } state_t;
  state_t state;
  logic [31:0] insn_q;
  logic [XLEN-1:0] type_q, vl_q, vlmax;
  logic [$clog2(VLEN)-1:0] start_q;
  logic [2:0] frm_q;
  logic enabled_q, type_illegal, decode_legal, source_double, widen;
  logic [1:0] operation, input_size, output_size;
  logic [IndexBits-1:0] index_q;
  logic [63:0] seed_q, data_q, result_q, stream_result;
  logic mask_cached;
  logic [7:0] mask_byte;
  logic active_q, stream_ready, element_ready, stream_valid, stream_illegal, stream_write;
  logic [4:0] stream_flags;
  int unsigned group_size;
  logic geometry_legal;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] unused_type, unused_vl;
  logic unused_recognized, unused_ordered;
  /* verilator lint_on UNUSEDSIGNAL */
  rapt_vpu_vtype #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN)
  ) u_type (
      .requested_vtype(type_q),
      .avl(vl_q),
      .avl_max(1'b0),
      .keep_vl(1'b0),
      .current_vtype(type_q),
      .current_vl(vl_q),
      .next_vtype(unused_type),
      .next_vl(unused_vl),
      .vlmax(vlmax),
      .vill(type_illegal)
  );
  rapt_vpu_fp_reduce_decode #(
      .ELEN(ELEN)
  ) u_decode (
      .insn(insn_q),
      .sew(type_q[5:3]),
      .frm(frm_q),
      .enabled(enabled_q),
      .vill(type_illegal),
      .recognized(unused_recognized),
      .legal(decode_legal),
      .operation(operation),
      .source_double(source_double),
      .widen(widen),
      .ordered_sum(unused_ordered)
  );
  assign input_size = type_q[4:3];
  assign output_size = input_size + 2'(widen);
  always_comb begin
    group_size = !type_q[2] ? (1 << type_q[1:0]) : 1;
    geometry_legal = !type_illegal && vl_q <= vlmax && start_q == 0
        && (int'(insn_q[24:20]) & (group_size-1)) == 0
        && int'(insn_q[24:20])+group_size <= 32;
  end
  rapt_vpu_fp_reduce_control #(
      .ELEN(ELEN),
      .CountBits(IndexBits)
  ) u_stream (
      .clock(clock),
      .reset(reset),
      .req_valid(state == START),
      .req_ready(stream_ready),
      .op(operation),
      .source_double(source_double),
      .widen(widen),
      .rm(frm_q),
      .count(IndexBits'(vl_q)),
      .seed(seed_q),
      .element_valid(state == FEED),
      .element_active(active_q),
      .element_ready(element_ready),
      .element(data_q),
      .rsp_valid(stream_valid),
      .rsp_ready(state == NEXT),
      .result(stream_result),
      .flags(stream_flags),
      .illegal(stream_illegal),
      .write_result(stream_write),
      .service_req_valid(service_req_valid),
      .service_req_ready(service_req_ready),
      .service_op(service_op),
      .service_double(service_double),
      .service_rm(service_rm),
      .service_a(service_a),
      .service_b(service_b),
      .service_rsp_valid(service_rsp_valid),
      .service_rsp_ready(service_rsp_ready),
      .service_result(service_result),
      .service_flags(service_flags),
      .service_illegal(service_illegal)
  );
  assign cmd_ready = !reset && state == IDLE;
  assign done_valid = !reset && state == DONE;
  assign vr_valid = !reset && (state == SEED_REQ || state == MASK_REQ || state == DATA_REQ || state == WRITE_REQ);
  assign vr_write = state == WRITE_REQ;
  assign vr_wdata = result_q;
  assign vr_rsp_ready = !reset && (state == SEED_RSP || state == MASK_RSP || state == DATA_RSP || state == WRITE_RSP);
  always_comb begin
    vr_size = output_size;
    vr_addr = AddrBits'(int'(insn_q[11:7])*(VLEN/8));
    if (state == SEED_REQ) vr_addr = AddrBits'(int'(insn_q[19:15]) * (VLEN / 8));
    else if (state == MASK_REQ) begin
      vr_size = 0;
      vr_addr = AddrBits'(index_q >> 3);
    end else if (state == DATA_REQ) begin
      vr_size = input_size;
      vr_addr = AddrBits'(int'(insn_q[24:20])*(VLEN/8)+(int'(index_q) << input_size));
    end
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      insn_q <= 0;
      type_q <= 0;
      vl_q <= 0;
      start_q <= 0;
      frm_q <= 0;
      enabled_q <= 0;
      index_q <= 0;
      seed_q <= 0;
      data_q <= 0;
      mask_cached <= 0;
      mask_byte <= 0;
      result_q <= 0;
      active_q <= 0;
      done_trap <= 0;
      done_flags <= 0;
    end else
      case (state)
        IDLE:
        if (cmd_valid && cmd_ready) begin
          insn_q <= cmd_insn;
          type_q <= cmd_vtype;
          vl_q <= cmd_vl;
          start_q <= cmd_vstart;
          frm_q <= cmd_frm;
          enabled_q <= cmd_enabled;
          mask_cached <= 0;
          index_q <= 0;
          done_trap <= 0;
          done_flags <= 0;
          state <= CHECK;
        end
        CHECK:
        if (!decode_legal || !geometry_legal) begin
          done_trap <= 1;
          state <= DONE;
        end else state <= vl_q == 0 ? DONE : SEED_REQ;
        SEED_REQ: if (vr_ready) state <= SEED_RSP;
        SEED_RSP: if (vr_rsp_valid) begin seed_q <= vr_rdata; state <= START; end
        START: if (stream_ready) state <= NEXT;
        NEXT: if (stream_valid) begin
        done_trap <= stream_illegal; done_flags <= stream_flags; result_q <= stream_result;
        state <= stream_write && !stream_illegal ? WRITE_REQ : DONE;
      end else if (element_ready) begin
        if (insn_q[25]) state <= DATA_REQ;
        else if (CacheMask && mask_cached) begin
          active_q <= mask_byte[index_q[2:0]];
          state <= mask_byte[index_q[2:0]] ? DATA_REQ : FEED;
        end else state <= MASK_REQ;
      end
        MASK_REQ: if (vr_ready) state <= MASK_RSP;
        MASK_RSP: if (vr_rsp_valid) begin
        mask_byte <= vr_rdata[7:0]; mask_cached <= CacheMask;
        active_q <= vr_rdata[{3'b0,index_q[2:0]}];
        state <= vr_rdata[{3'b0,index_q[2:0]}] ? DATA_REQ : FEED;
      end
        DATA_REQ: if (vr_ready) state <= DATA_RSP;
        DATA_RSP: if (vr_rsp_valid) begin data_q <= vr_rdata; active_q <= 1; state <= FEED; end
        FEED: if (element_ready) begin
        // The stream advances exactly one element; the next byte is fetched
        // after every eight entries. No VRF writes occur before final result.
        if (index_q[2:0] == 7) mask_cached <= 0;
        index_q <= index_q+1'b1; state <= NEXT;
      end
        WRITE_REQ: if (vr_ready) state <= WRITE_RSP;
        WRITE_RSP: if (vr_rsp_valid) state <= DONE;
        DONE: if (done_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_FP_REDUCE_VR_HOLD, vr_valid && !vr_ready, vr_valid && $stable
                 ({vr_addr, vr_size, vr_write, vr_wdata}))
  `RAPT_SVA_NEXT(clock, reset, VPU_FP_REDUCE_ENGINE_DONE_HOLD, done_valid && !done_ready,
                 done_valid && $stable({done_trap, done_flags}))
  `RAPT_SVA_IMPLY(clock, reset, VPU_FP_REDUCE_ENGINE_WRITE_LAST, vr_valid && vr_write,
                  XLEN'(index_q) == vl_q && vl_q != 0 && !done_trap)
endmodule
