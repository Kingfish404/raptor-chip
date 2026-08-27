`include "rapt.svh"

module misc_tb;
  logic [5:0] op;
  logic [63:0] operand_a, operand_b;
  logic [63:0] compare_result, sgnj_result;
  logic [4:0] compare_flags;
  logic is_double;
  logic [9:0] classify_result;
  integer failures = 0;

  rapt_fpu_compare compare_i (.*,.result(compare_result),.flags(compare_flags));
  rapt_fpu_sgnj sgnj_i (.*,.result(sgnj_result));
  rapt_fpu_classify classify_i (
      .is_double, .operand(operand_a), .result(classify_result));

  task automatic check_class(
      input logic double_precision,
      input logic [63:0] value,
      input logic [9:0] expected
  );
    is_double = double_precision;
    operand_a = value;
    #1;
    if (classify_result !== expected) begin
      $display("CLASS FAIL double=%0d value=%h got=%h expected=%h",
               double_precision, value, classify_result, expected);
      failures++;
    end
  endtask

  task automatic check_compare(
      input logic [5:0] operation,
      input logic [63:0] a,
      input logic [63:0] b,
      input logic [63:0] expected_result,
      input logic [4:0] expected_flags
  );
    op = operation;
    operand_a = a;
    operand_b = b;
    #1;
    if (compare_result !== expected_result || compare_flags !== expected_flags) begin
      $display("COMPARE FAIL op=%0d a=%h b=%h got=%h/%h expected=%h/%h",
               operation, a, b, compare_result, compare_flags,
               expected_result, expected_flags);
      failures++;
    end
  endtask

  task automatic check_sgnj(
      input logic [5:0] operation,
      input logic [63:0] a,
      input logic [63:0] b,
      input logic [63:0] expected
  );
    op = operation;
    operand_a = a;
    operand_b = b;
    #1;
    if (sgnj_result !== expected) begin
      $display("SGNJ FAIL op=%0d a=%h b=%h got=%h expected=%h",
               operation, a, b, sgnj_result, expected);
      failures++;
    end
  endtask

  initial begin
    check_class(0, 64'hffff_ffff_ff80_0000, 10'b0000000001);
    check_class(0, 64'hffff_ffff_bf80_0000, 10'b0000000010);
    check_class(0, 64'hffff_ffff_8000_0001, 10'b0000000100);
    check_class(0, 64'hffff_ffff_8000_0000, 10'b0000001000);
    check_class(0, 64'hffff_ffff_0000_0000, 10'b0000010000);
    check_class(0, 64'hffff_ffff_0000_0001, 10'b0000100000);
    check_class(0, 64'hffff_ffff_3f80_0000, 10'b0001000000);
    check_class(0, 64'hffff_ffff_7f80_0000, 10'b0010000000);
    check_class(0, 64'hffff_ffff_7f80_0001, 10'b0100000000);
    check_class(0, 64'hffff_ffff_7fc0_0000, 10'b1000000000);
    check_class(0, 64'h0000_0000_3f80_0000, 10'b1000000000);

    check_class(1, 64'hfff0_0000_0000_0000, 10'b0000000001);
    check_class(1, 64'hbff0_0000_0000_0000, 10'b0000000010);
    check_class(1, 64'h8000_0000_0000_0001, 10'b0000000100);
    check_class(1, 64'h8000_0000_0000_0000, 10'b0000001000);
    check_class(1, 64'h0000_0000_0000_0000, 10'b0000010000);
    check_class(1, 64'h0000_0000_0000_0001, 10'b0000100000);
    check_class(1, 64'h3ff0_0000_0000_0000, 10'b0001000000);
    check_class(1, 64'h7ff0_0000_0000_0000, 10'b0010000000);
    check_class(1, 64'h7ff0_0000_0000_0001, 10'b0100000000);
    check_class(1, 64'h7ff8_0000_0000_0000, 10'b1000000000);

    check_compare(`RAPT_FP_OP_FEQ_S, 64'hffff_ffff_0000_0000,
                  64'hffff_ffff_8000_0000, 64'd1, 5'd0);
    check_compare(`RAPT_FP_OP_FLT_S, 64'hffff_ffff_bf80_0000,
                  64'hffff_ffff_0000_0001, 64'd1, 5'd0);
    check_compare(`RAPT_FP_OP_FEQ_S, 64'hffff_ffff_7fc0_0000,
                  64'hffff_ffff_3f80_0000, 64'd0, 5'd0);
    check_compare(`RAPT_FP_OP_FEQ_S, 64'hffff_ffff_7f80_0001,
                  64'hffff_ffff_3f80_0000, 64'd0, 5'h10);
    check_compare(`RAPT_FP_OP_FLT_S, 64'hffff_ffff_7fc0_0000,
                  64'hffff_ffff_3f80_0000, 64'd0, 5'h10);
    check_compare(`RAPT_FP_OP_FMIN_S, 64'hffff_ffff_7fc0_0000,
                  64'hffff_ffff_3f80_0000, 64'hffff_ffff_3f80_0000, 5'd0);
    check_compare(`RAPT_FP_OP_FMAX_S, 64'hffff_ffff_8000_0000,
                  64'hffff_ffff_0000_0000, 64'hffff_ffff_0000_0000, 5'd0);
    check_compare(`RAPT_FP_OP_FMIN_D, 64'h7ff8_0000_0000_0000,
                  64'h7ff8_0000_0000_0001, 64'h7ff8_0000_0000_0000, 5'd0);
    check_compare(`RAPT_FP_OP_FLE_D, 64'hbff0_0000_0000_0000,
                  64'hbff0_0000_0000_0000, 64'd1, 5'd0);

    check_sgnj(`RAPT_FP_OP_FSGNJ_S, 64'hffff_ffff_3f80_0000,
               64'hffff_ffff_8000_0000, 64'hffff_ffff_bf80_0000);
    check_sgnj(`RAPT_FP_OP_FSGNJN_S, 64'hffff_ffff_bf80_0000,
               64'hffff_ffff_8000_0000, 64'hffff_ffff_3f80_0000);
    check_sgnj(`RAPT_FP_OP_FSGNJX_S, 64'hffff_ffff_bf80_0000,
               64'hffff_ffff_8000_0000, 64'hffff_ffff_3f80_0000);
    check_sgnj(`RAPT_FP_OP_FSGNJ_S, 64'h0000_0000_3f80_0000,
               64'hffff_ffff_8000_0000, 64'hffff_ffff_ffc0_0000);
    check_sgnj(`RAPT_FP_OP_FSGNJ_D, 64'h3ff0_0000_0000_0000,
               64'h8000_0000_0000_0000, 64'hbff0_0000_0000_0000);
    check_sgnj(`RAPT_FP_OP_FSGNJN_D, 64'hbff0_0000_0000_0000,
               64'h8000_0000_0000_0000, 64'h3ff0_0000_0000_0000);
    check_sgnj(`RAPT_FP_OP_FSGNJX_D, 64'hbff0_0000_0000_0000,
               64'h8000_0000_0000_0000, 64'h3ff0_0000_0000_0000);

    if (failures != 0)
      $fatal(1, "FPU misc failures=%0d", failures);
    $display("FPU-MISC PASS");
    $finish;
  end
endmodule
