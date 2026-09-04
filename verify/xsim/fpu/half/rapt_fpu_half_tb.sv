module rapt_fpu_half_tb (
    input logic clock,
    input logic reset
);
  logic flush;
  logic widen_valid, widen_ready, widen_double, widen_result_valid;
  logic [63:0] widen_operand, widen_result;
  logic [4:0] widen_flags;
  logic narrow_valid, narrow_ready, narrow_double, narrow_result_valid;
  logic [63:0] narrow_operand, narrow_result;
  logic [2:0] narrow_rm;
  logic [4:0] narrow_flags;

  rapt_fpu_half_to_fp widen (
      .clock, .reset, .flush,
      .valid(widen_valid), .ready(widen_ready), .operand(widen_operand),
      .target_double(widen_double), .result(widen_result),
      .flags(widen_flags), .result_valid(widen_result_valid)
  );
  rapt_fpu_fp_to_half narrow (
      .clock, .reset, .flush,
      .valid(narrow_valid), .ready(narrow_ready), .operand(narrow_operand),
      .source_double(narrow_double), .rounding_mode(narrow_rm),
      .result(narrow_result), .flags(narrow_flags),
      .result_valid(narrow_result_valid)
  );

  task automatic check(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      $fatal(1);
    end
  endtask

  task automatic test_widen(
      input logic [63:0] operand,
      input logic target_double,
      input logic [63:0] expected,
      input logic [4:0] expected_flags
  );
    while (!widen_ready) @(posedge clock);
    widen_operand = operand;
    widen_double = target_double;
    widen_valid = 1'b1;
    @(posedge clock);
    widen_valid = 1'b0;
    while (!widen_result_valid) @(posedge clock);
    check(widen_result === expected, "half widening result mismatch");
    check(widen_flags === expected_flags, "half widening flags mismatch");
    @(posedge clock);
  endtask

  task automatic test_narrow(
      input logic [63:0] operand,
      input logic source_double,
      input logic [2:0] rm,
      input logic [15:0] expected,
      input logic [4:0] expected_flags
  );
    while (!narrow_ready) @(posedge clock);
    narrow_operand = operand;
    narrow_double = source_double;
    narrow_rm = rm;
    narrow_valid = 1'b1;
    @(posedge clock);
    narrow_valid = 1'b0;
    while (!narrow_result_valid) @(posedge clock);
    check(narrow_result === {48'hffff_ffff_ffff, expected},
          "half narrowing result/NaN-box mismatch");
    check(narrow_flags === expected_flags, "half narrowing flags mismatch");
    @(posedge clock);
  endtask

  initial begin
    flush = 1'b0;
    widen_valid = 1'b0;
    narrow_valid = 1'b0;
    widen_operand = '0;
    narrow_operand = '0;
    widen_double = 1'b0;
    narrow_double = 1'b0;
    narrow_rm = 3'b000;
    wait (!reset);
    @(posedge clock);

    test_widen(64'hffff_ffff_ffff_0000, 1'b0, 64'hffff_ffff_0000_0000, 0);
    test_widen(64'hffff_ffff_ffff_8000, 1'b0, 64'hffff_ffff_8000_0000, 0);
    test_widen(64'hffff_ffff_ffff_3c00, 1'b0, 64'hffff_ffff_3f80_0000, 0);
    test_widen(64'hffff_ffff_ffff_c000, 1'b0, 64'hffff_ffff_c000_0000, 0);
    test_widen(64'hffff_ffff_ffff_0001, 1'b0, 64'hffff_ffff_3380_0000, 0);
    test_widen(64'hffff_ffff_ffff_0400, 1'b0, 64'hffff_ffff_3880_0000, 0);
    test_widen(64'hffff_ffff_ffff_7c00, 1'b0, 64'hffff_ffff_7f80_0000, 0);
    test_widen(64'hffff_ffff_ffff_7d00, 1'b0, 64'hffff_ffff_7fc0_0000, 5'b10000);
    test_widen(64'h0000_ffff_ffff_3c00, 1'b0, 64'hffff_ffff_7fc0_0000, 0);
    test_widen(64'hffff_ffff_ffff_3c00, 1'b1, 64'h3ff0_0000_0000_0000, 0);
    test_widen(64'hffff_ffff_ffff_0001, 1'b1, 64'h3e70_0000_0000_0000, 0);

    test_narrow(64'hffff_ffff_3f80_0000, 1'b0, 3'b000, 16'h3c00, 0);
    test_narrow(64'hffff_ffff_c000_0000, 1'b0, 3'b000, 16'hc000, 0);
    test_narrow(64'hffff_ffff_3880_0000, 1'b0, 3'b000, 16'h0400, 0);
    test_narrow(64'hffff_ffff_3380_0000, 1'b0, 3'b000, 16'h0001, 0);
    test_narrow(64'hffff_ffff_477f_e000, 1'b0, 3'b000, 16'h7bff, 0);
    test_narrow(64'hffff_ffff_4780_0000, 1'b0, 3'b000, 16'h7c00, 5'b00101);
    test_narrow(64'hffff_ffff_3f80_1000, 1'b0, 3'b000, 16'h3c00, 5'b00001);
    test_narrow(64'hffff_ffff_3f80_1000, 1'b0, 3'b100, 16'h3c01, 5'b00001);
    test_narrow(64'hffff_ffff_3300_0000, 1'b0, 3'b000, 16'h0000, 5'b00011);
    test_narrow(64'hffff_ffff_3300_0000, 1'b0, 3'b100, 16'h0001, 5'b00011);
    test_narrow(64'h3ff0_0000_0000_0000, 1'b1, 3'b000, 16'h3c00, 0);
    test_narrow(64'h7ff0_0000_0000_0000, 1'b1, 3'b000, 16'h7c00, 0);
    test_narrow(64'h7ff0_0000_0000_0001, 1'b1, 3'b000, 16'h7e00, 5'b10000);
    test_narrow(64'h0000_0000_3f80_0000, 1'b0, 3'b000, 16'h7e00, 0);

    $display("PASS: Zfhmin binary16 conversions and NaN boxing");
    $finish;
  end
endmodule
