`include "rapt_sva.svh"

// Authorized, sequential integer reduction over an exclusive element VRF port.
// Seed and destination are scalars in one register regardless of LMUL. No
// destination write occurs until all source/mask reads have completed, permitting
// destination/source overlap, including v0 when it is not also the predicate.
// Nonzero vstart is illegal.
module rapt_vpu_reduce #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64,
    parameter int AddrBits = $clog2(32 * VLEN / 8),
    parameter int IndexBits = $clog2(VLEN) + 1
) (
    input logic clock,
    input logic reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [31:0] cmd_insn,
    input logic [XLEN-1:0] cmd_vtype,
    input logic [XLEN-1:0] cmd_vl,
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
  typedef enum logic [3:0] {
    IDLE,
    CHECK,
    SEED_REQ,
    SEED_RSP,
    NEXT,
    MASK_REQ,
    MASK_RSP,
    DATA_REQ,
    DATA_RSP,
    WRITE_REQ,
    WRITE_RSP,
    DONE
  } state_t;
  state_t state;
  logic [31:0] insn_q;
  // Tail/mask policy does not change legality; this engine preserves the tail.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] type_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [XLEN-1:0] vl_q;
  logic [$clog2(VLEN)-1:0] start_q;
  logic [IndexBits-1:0] index_q;
  logic [63:0] acc_q, operand, out_mask, au, bu, raw_acc, next_acc;
  logic signed [63:0] sa, sb;
  logic [64:0] cmp_a, cmp_b;
  logic [1:0] input_size, output_size;
  logic [2:0] red_op;
  logic wide, legal, signed_cmp, a_lt_b;
  int signed lm;
  wire [5:0] mask_bit_idx = {3'b0, index_q[2:0]};
  int unsigned group_size;

  assign wide = insn_q[14:12] == 3'd0;
  assign input_size = type_q[4:3];
  assign output_size = input_size + 2'(wide);

  always_comb begin
    lm = int'($signed(type_q[2:0]));
    group_size = lm > 0 ? (1 << lm) : 1;
    legal = insn_q[6:0] == 7'h57 && start_q == '0 && !(|type_q[XLEN-1:8])
        && lm >= -$clog2(ELEN / 8) && lm <= 3 && (8 << type_q[5:3]) <= ELEN
        && (lm >= 0 || (8 << type_q[5:3]) <= (ELEN >> (-lm)))
        && (int'(insn_q[24:20]) & (group_size - 1)) == 0 && vl_q <= XLEN'(VLEN)
        && ((insn_q[14:12] == 3'd2 && insn_q[31:29] == 3'd0)
          || (wide && insn_q[31:27] == 5'b11000 && (16 << type_q[5:3]) <= ELEN));

    operand = vr_rdata;
    if (wide && insn_q[26]) begin
      case (input_size)
        2'd0: operand = {{56{vr_rdata[7]}}, vr_rdata[7:0]};
        2'd1: operand = {{48{vr_rdata[15]}}, vr_rdata[15:0]};
        2'd2: operand = {{32{vr_rdata[31]}}, vr_rdata[31:0]};
        default: operand = vr_rdata;
      endcase
    end

    case (output_size)
      2'd0: begin
        out_mask = 64'h0000_0000_0000_00ff;
        sa = {{56{acc_q[7]}}, acc_q[7:0]};
        sb = {{56{operand[7]}}, operand[7:0]};
      end
      2'd1: begin
        out_mask = 64'h0000_0000_0000_ffff;
        sa = {{48{acc_q[15]}}, acc_q[15:0]};
        sb = {{48{operand[15]}}, operand[15:0]};
      end
      2'd2: begin
        out_mask = 64'h0000_0000_ffff_ffff;
        sa = {{32{acc_q[31]}}, acc_q[31:0]};
        sb = {{32{operand[31]}}, operand[31:0]};
      end
      default: begin
        out_mask = 64'hffff_ffff_ffff_ffff;
        sa = $signed(acc_q);
        sb = $signed(operand);
      end
    endcase

    au = acc_q & out_mask;
    bu = operand & out_mask;
    red_op = wide ? 3'd0 : insn_q[28:26];
    signed_cmp = red_op[0];
    cmp_a = {signed_cmp && sa[63], signed_cmp ? 64'(sa) : au};
    cmp_b = {signed_cmp && sb[63], signed_cmp ? 64'(sb) : bu};
    a_lt_b = $signed(cmp_a) < $signed(cmp_b);

    case (red_op)
      3'd1: raw_acc = au & bu;
      3'd2: raw_acc = au | bu;
      3'd3: raw_acc = au ^ bu;
      3'd4, 3'd5, 3'd6, 3'd7: raw_acc = (a_lt_b ^ red_op[1]) ? au : bu;
      default: raw_acc = au + bu;
    endcase
    next_acc = raw_acc & out_mask;
  end

  assign cmd_ready = !reset && state == IDLE;
  assign done_valid = !reset && state == DONE;
  assign vr_valid = !reset && (state == SEED_REQ || state == MASK_REQ
      || state == DATA_REQ || state == WRITE_REQ);
  assign vr_write = state == WRITE_REQ;
  assign vr_wdata = acc_q;
  assign vr_rsp_ready = state == SEED_RSP || state == MASK_RSP
      || state == DATA_RSP || state == WRITE_RSP;

  always_comb begin
    vr_size = output_size;
    vr_addr = AddrBits'(int'(insn_q[11:7]) * (VLEN / 8));
    if (state == SEED_REQ) vr_addr = AddrBits'(int'(insn_q[19:15]) * (VLEN / 8));
    else if (state == MASK_REQ) begin
      vr_size = 2'd0;
      vr_addr = AddrBits'(index_q >> 3);
    end else if (state == DATA_REQ) begin
      vr_size = input_size;
      vr_addr = AddrBits'(int'(insn_q[24:20]) * (VLEN / 8) + (int'(index_q) << input_size));
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      insn_q <= 32'd0;
      type_q <= '0;
      vl_q <= '0;
      start_q <= '0;
      index_q <= '0;
      acc_q <= 64'd0;
      done_trap <= 1'b0;
    end else
      case (state)
        IDLE:
        if (cmd_valid && cmd_ready) begin
          insn_q <= cmd_insn;
          type_q <= cmd_vtype;
          vl_q <= cmd_vl;
          start_q <= cmd_vstart;
          index_q <= '0;
          acc_q <= 64'd0;
          done_trap <= 1'b0;
          state <= CHECK;
        end
        CHECK:
        if (!legal) begin
          done_trap <= 1'b1;
          state <= DONE;
        end else state <= vl_q == '0 ? DONE : SEED_REQ;
        SEED_REQ: if (vr_valid && vr_ready) state <= SEED_RSP;
        SEED_RSP:
        if (vr_rsp_valid && vr_rsp_ready) begin
          acc_q <= vr_rdata;
          state <= NEXT;
        end
        NEXT:
        if (XLEN'(index_q) >= vl_q) state <= WRITE_REQ;
        else state <= insn_q[25] ? DATA_REQ : MASK_REQ;
        MASK_REQ: if (vr_valid && vr_ready) state <= MASK_RSP;
        MASK_RSP:
        if (vr_rsp_valid && vr_rsp_ready) begin
          if (vr_rdata[mask_bit_idx]) state <= DATA_REQ;
          else begin
            index_q <= index_q + 1'b1;
            state <= NEXT;
          end
        end
        DATA_REQ: if (vr_valid && vr_ready) state <= DATA_RSP;
        DATA_RSP:
        if (vr_rsp_valid && vr_rsp_ready) begin
          acc_q <= next_acc;
          index_q <= index_q + 1'b1;
          state <= NEXT;
        end
        WRITE_REQ: if (vr_valid && vr_ready) state <= WRITE_RSP;
        WRITE_RSP: if (vr_rsp_valid && vr_rsp_ready) state <= DONE;
        DONE: if (done_valid && done_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_REDUCE_REQUEST_HOLD, vr_valid && !vr_ready, vr_valid && $stable
                 ({vr_addr, vr_size, vr_write, vr_wdata}))
  `RAPT_SVA_NEXT(clock, reset, VPU_REDUCE_DONE_HOLD, done_valid && !done_ready,
                 done_valid && $stable(done_trap))
  `RAPT_SVA_IMPLY(clock, reset, VPU_REDUCE_WRITES_LAST, vr_valid && vr_write,
                  XLEN'(index_q) == vl_q && vl_q != '0)
endmodule
