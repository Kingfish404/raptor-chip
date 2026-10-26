`include "rapt_sva.svh"
// Raw integer/FP element conversion. Fixed elaboration widths keep arithmetic
// independent of XLEN. Caller validates ISA EEW/EMUL and resolves RTZ vs FRM.
module rapt_vpu_int_fp #(
    parameter bit FloatDouble = 1,
    parameter int IntBits = 32
) (
    input logic clock,
    reset,
    req_valid,
    output logic req_ready,
    input logic to_float,
    unsigned_integer,
    input logic [63:0] operand,
    input logic [2:0] rm,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  typedef enum logic [1:0] {
    IDLE,
    RUN,
    DONE
  } state_t;
  state_t state;
  logic direction_q, unsigned_q, bad_request;
  logic ir, iv, fr, fv;
  logic [63:0] integer_operand, ir_data, fr_data;
  logic [IntBits-1:0] clipped;
  logic [4:0] ir_flags, fr_flags, clipped_flags;
  assign integer_operand = unsigned_integer
      ? {{(64-IntBits){1'b0}},operand[IntBits-1:0]}
      : {{(64-IntBits){operand[IntBits-1]}},operand[IntBits-1:0]};
  assign bad_request = rm > 4;
  assign req_ready = !reset && state == IDLE && (to_float ? ir : fr);
  assign rsp_valid = !reset && state == DONE;
  rapt_fpu_int_to_fp #(
      .TARGET_DOUBLE(FloatDouble),
      .INT64_INPUT(1)
  ) u_to_fp (
      .clock(clock),
      .reset(reset),
      .flush(1'b0),
      .valid(req_valid && req_ready && to_float && !bad_request),
      .ready(ir),
      .operand(integer_operand),
      .unsigned_input(unsigned_integer),
      .rounding_mode(rm),
      .result(ir_data),
      .flags(ir_flags),
      .result_valid(iv)
  );
  rapt_fpu_single_to_int_w #(
      .SOURCE_DOUBLE(FloatDouble)
  ) u_to_int (
      .clock(clock),
      .reset(reset),
      .flush(1'b0),
      .valid(req_valid && req_ready && !to_float && !bad_request),
      .ready(fr),
      .operand(FloatDouble ? operand : {32'hffffffff,operand[31:0]}),
      .unsigned_result(unsigned_integer),
      .int64_target(IntBits == 64),
      .rounding_mode(rm),
      .result(fr_data),
      .flags(fr_flags),
      .result_valid(fv)
  );
  always_comb begin
    clipped = IntBits'(fr_data);
    clipped_flags = fr_flags;
    // The scalar converter already rounded and checked its 32/64-bit range.
    // A narrower invalid result must replace NX with NV, never merely truncate.
    if (IntBits == 16) begin
      if (unsigned_q && fr_data > 64'd65535) begin
        clipped = IntBits'(65535);
        clipped_flags = 5'b10000;
      end else if (!unsigned_q && $signed(fr_data) > 64'sd32767) begin
        clipped = IntBits'(32767);
        clipped_flags = 5'b10000;
      end else if (!unsigned_q && $signed(fr_data) < -64'sd32768) begin
        clipped = IntBits'('h8000);
        clipped_flags = 5'b10000;
      end
    end
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      direction_q <= 0;
      unsigned_q <= 0;
      result <= 0;
      flags <= 0;
      illegal <= 0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          direction_q <= to_float;
          unsigned_q <= unsigned_integer;
          illegal <= bad_request;
          if (bad_request) begin
            result <= 0;
            flags <= 0;
            state <= DONE;
          end else state <= RUN;
        end
        RUN:
        if (direction_q ? iv : fv) begin
          result <= direction_q ? (FloatDouble ? ir_data : {32'b0,ir_data[31:0]})
            : {{(64-IntBits){1'b0}},clipped[IntBits-1:0]};
          flags <= direction_q ? ir_flags : clipped_flags;
          state <= DONE;
        end
        DONE: if (rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_INT_FP_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 ({result, flags, illegal}))
endmodule
