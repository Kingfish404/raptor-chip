`include "rapt.svh"

module rapt_fpu_double_to_int_w (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [63:0] operand,
    input  logic        unsigned_result,
    input  logic        int64_target,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  rapt_fpu_single_to_int_w #(
      .SOURCE_DOUBLE(1'b1)
  ) u_fpu_to_int (
      .clock,
      .reset,
      .flush,
      .valid,
      .ready,
      .operand,
      .unsigned_result,
      .int64_target,
      .rounding_mode,
      .result,
      .flags,
      .result_valid
  );
endmodule
