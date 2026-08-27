module rapt_fpu_convert_tb (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    input  logic        narrow,
    input  logic [63:0] operand,
    input  logic [2:0]  rounding_mode,
    output logic        ready,
    output logic [63:0] dut_result,
    output logic [4:0]  dut_flags,
    output logic        dut_valid
);
  logic widen_ready, narrow_ready;
  logic [63:0] widen_result, narrow_result;
  logic [4:0] widen_flags, narrow_flags;
  logic widen_valid, narrow_valid;

  rapt_fpu_convert_widen dut_widen (
      .clock(clock), .reset(reset), .flush(flush),
      .valid(valid && !narrow), .ready(widen_ready),
      .operand(operand), .result(widen_result), .flags(widen_flags),
      .result_valid(widen_valid));

  rapt_fpu_convert_narrow dut_narrow (
      .clock(clock), .reset(reset), .flush(flush),
      .valid(valid && narrow), .ready(narrow_ready),
      .operand(operand), .rounding_mode(rounding_mode),
      .result(narrow_result), .flags(narrow_flags),
      .result_valid(narrow_valid));

  assign ready = narrow ? narrow_ready : widen_ready;
  assign dut_result = narrow ? narrow_result : widen_result;
  assign dut_flags = narrow ? narrow_flags : widen_flags;
  assign dut_valid = narrow ? narrow_valid : widen_valid;
endmodule
