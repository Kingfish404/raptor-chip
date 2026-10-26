`include "rapt.svh"

module tb_alu_cpop;
  logic [63:0] source;
  logic word;
  wire [31:0] result32;
  wire [63:0] result64;
  int checks = 0;
  logic [63:0] rng = 64'hb680_da7e_39ac_4d13;

  rapt_ieu_alu #(
      .XLEN(32)
  ) dut32 (
      .s1(source[31:0]),
      .s2(32'b0),
      .op(`RAPT_ALU_CPOP),
      .word,
      .out_r(result32)
  );
  rapt_ieu_alu #(
      .XLEN(64)
  ) dut64 (
      .s1(source),
      .s2(64'b0),
      .op(`RAPT_ALU_CPOP),
      .word,
      .out_r(result64)
  );

  task automatic check(input logic [63:0] value);
    source = value;
    for (int w = 0; w < 2; w++) begin
      word = 1'(w);
      #1;
      assert (result32 === 32'($countones(value[31:0])))
      else $fatal(1, "CPOP32 value=%h word=%b result=%h", value, word, result32);
      assert (result64 === 64'($countones(word ? {32'b0, value[31:0]} : value)))
      else $fatal(1, "CPOP64 value=%h word=%b result=%h", value, word, result64);
      checks++;
    end
  endtask

  initial begin
    check('0);
    check('1);
    check(64'hffff_ffff_0000_0000);
    check(64'h0000_0000_ffff_ffff);
    for (int bit_idx = 0; bit_idx < 64; bit_idx++) begin
      check(64'b1 << bit_idx);
      check(~(64'b1 << bit_idx));
      // Every population count, including 32/64 and the W boundary.
      check(~64'b0 >> bit_idx);
    end
    for (int trial = 0; trial < 10000; trial++) begin
      rng ^= rng << 13;
      rng ^= rng >> 7;
      rng ^= rng << 17;
      check(rng);
    end
    $display("PASS: CPOP RV32/RV64, both word modes, %0d paired checks", checks);
    $finish;
  end
endmodule
