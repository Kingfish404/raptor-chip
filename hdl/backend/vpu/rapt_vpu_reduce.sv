`include "rapt_sva.svh"

// Authorized, sequential integer reduction over an exclusive element VRF port.
// Seed and destination are scalars in one register regardless of LMUL. No
// destination write occurs until all source/mask reads have completed, permitting
// arbitrary destination/source overlap, including v0. Nonzero vstart is illegal.
module rapt_vpu_reduce #(
    parameter int XLEN=64,
    VLEN=128,
    ELEN=64,
    parameter int AddrBits=$clog2(32*VLEN/8),
    IndexBits=$clog2(VLEN)+1
) (
    input logic clock,
    reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [31:0] cmd_insn,
    input logic [XLEN-1:0] cmd_vtype,
    cmd_vl,
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
  logic [63:0] acc_q, operand, next_acc;
  logic [1:0] input_size, output_size;
  logic wide, legal;
  logic [5:0] alu_op;
  int signed lm;
  int unsigned group_size;
  assign wide = insn_q[14:12] == 0;
  assign input_size = type_q[4:3];
  assign output_size = input_size+2'(wide);
  always_comb begin
    lm = int'($signed(type_q[2:0]));
    group_size = lm > 0 ? 1 << lm : 1;
    legal = insn_q[6:0] == 7'h57 && start_q == 0 && !(|type_q[XLEN-1:8])
        && lm >= -$clog2(ELEN/8) && lm <= 3 && (8 << type_q[5:3]) <= ELEN
        && (lm >= 0 || (8 << type_q[5:3]) <= (ELEN >> (-lm)))
        && (int'(insn_q[24:20]) & (group_size-1)) == 0 && vl_q <= XLEN'(VLEN)
        && ((insn_q[14:12] == 2 && insn_q[31:29] == 0)
          || (wide && insn_q[31:27] == 5'b11000 && (16 << type_q[5:3]) <= ELEN));
    alu_op = 0;
    if (!wide)
      case (insn_q[28:26])
        1: alu_op = 6'h09;
        2: alu_op = 6'h0a;
        3: alu_op = 6'h0b;
        4,5,6,7: alu_op = {3'b000,insn_q[28:26]};
        default: ;
      endcase
    operand = vr_rdata;
    if (wide && insn_q[26])
      operand = 64'($signed(vr_rdata << (64 - (8 << input_size))) >>> (64 - (8 << input_size)));
  end
  rapt_vpu_alu u_accumulate (
      .funct6(alu_op),
      .sew(output_size),
      .a(acc_q),
      .b(operand),
      .mask_bit(1'b0),
      .mask_logic(1'b0),
      .result(next_acc)
  );
  assign cmd_ready = !reset && state == IDLE;
  assign done_valid = !reset && state == DONE;
  assign vr_valid = !reset && (state == SEED_REQ || state == MASK_REQ || state == DATA_REQ || state == WRITE_REQ);
  assign vr_write = state == WRITE_REQ;
  assign vr_wdata = acc_q;
  assign vr_rsp_ready = state == SEED_RSP || state == MASK_RSP || state == DATA_RSP || state == WRITE_RSP;
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
      index_q <= 0;
      acc_q <= 0;
      done_trap <= 0;
    end else
      case (state)
        IDLE:
        if (cmd_valid && cmd_ready) begin
          insn_q <= cmd_insn;
          type_q <= cmd_vtype;
          vl_q <= cmd_vl;
          start_q <= cmd_vstart;
          index_q <= 0;
          acc_q <= 0;
          done_trap <= 0;
          state <= CHECK;
        end
        CHECK:
        if (!legal) begin
          done_trap <= 1;
          state <= DONE;
        end else state <= vl_q == 0 ? DONE : SEED_REQ;
        SEED_REQ: if (vr_valid && vr_ready) state <= SEED_RSP;
        SEED_RSP: if (vr_rsp_valid && vr_rsp_ready) begin acc_q <= vr_rdata; state <= NEXT; end
        NEXT: if (XLEN'(index_q) >= vl_q) state <= WRITE_REQ;
            else state <= insn_q[25] ? DATA_REQ : MASK_REQ;
        MASK_REQ: if (vr_valid && vr_ready) state <= MASK_RSP;
        MASK_RSP: if (vr_rsp_valid && vr_rsp_ready) begin
        if (vr_rdata[{3'b0,index_q[2:0]}]) state <= DATA_REQ;
        else begin index_q <= index_q+1'b1; state <= NEXT; end
      end
        DATA_REQ: if (vr_valid && vr_ready) state <= DATA_RSP;
        DATA_RSP: if (vr_rsp_valid && vr_rsp_ready) begin
        acc_q <= next_acc; index_q <= index_q+1'b1; state <= NEXT;
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
                  XLEN'(index_q) == vl_q && vl_q != 0)
endmodule
