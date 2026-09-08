`include "rapt.svh"

// Relational timing check: identical public instruction/control streams,
// independent unconstrained operand data. Results are intentionally unequal.
// Scope: default RAPT_M_FAST multiply port, not the issue/retire fabric.
module formal_zkt_mul (
    input clock,
    reset,
    flush,
    in_valid,
    input [4:0] in_op,
    input in_word,
    input [7:0] in_tag,
    input [`RAPT_XLEN-1:0] a0,
    b0,
    a1,
    b1
);
  localparam int X = `RAPT_XLEN;
  wire ready0, ready1, valid0, valid1;
  wire [7:0] tag0, tag1;
  rapt_ieu_mul #(
      .XLEN(X),
      .TAG_W(8)
  ) left_dut (
      .clock,
      .reset,
      .flush,
      .in_valid,
      .in_op,
      .in_word,
      .in_tag,
      .in_a(a0),
      .in_b(b0),
      .in_ready(ready0),
      .out_valid(valid0),
      .out_tag(tag0),
      .out_r()
  );
  rapt_ieu_mul #(
      .XLEN(X),
      .TAG_W(8)
  ) right_dut (
      .clock,
      .reset,
      .flush,
      .in_valid,
      .in_op,
      .in_word,
      .in_tag,
      .in_a(a1),
      .in_b(b1),
      .in_ready(ready1),
      .out_valid(valid1),
      .out_tag(tag1),
      .out_r()
  );
  reg past_valid = 0;
  reg expected1, expected2;
  reg [7:0] expected_tag1, expected_tag2;
  reg [4:0] expected_op1, expected_op2;
  reg expected_word1, expected_word2;
  always @(posedge clock) begin
    past_valid <= 1;
    if (!past_valid) assume (reset);
    if (in_valid) begin
      assume (in_op == `RAPT_ALU_MUL___ || in_op ==
      `RAPT_ALU_MULH__
      || in_op == `RAPT_ALU_MULHSU || in_op == `RAPT_ALU_MULHU_);
      if (X == 32) assume (!in_word);
      if (in_word) assume (in_op == `RAPT_ALU_MUL___);
    end
    if (reset || flush) begin
      expected1 <= 0;
      expected2 <= 0;
    end else begin
      expected1 <= in_valid;
      expected2 <= expected1;
      expected_tag1 <= in_tag;
      expected_tag2 <= expected_tag1;
      expected_op1 <= in_op;
      expected_op2 <= expected_op1;
      expected_word1 <= in_word;
      expected_word2 <= expected_word1;
    end
    if (past_valid) begin
      assert (ready0 && ready1);
      assert (valid0 == valid1);
      assert (valid0 == expected2);
      if (valid0) begin
        assert (tag0 == tag1);
        assert (tag0 == expected_tag2);
      end
      cover (valid0 && in_valid && a0 != a1 && b0 != b1);
      cover (valid0 && flush);
      cover (valid0 && expected_word2);
      cover (valid0 && expected_op2 == `RAPT_ALU_MUL___ && !expected_word2);
      cover (valid0 && expected_op2 == `RAPT_ALU_MULH__);
      cover (valid0 && expected_op2 == `RAPT_ALU_MULHSU);
      cover (valid0 && expected_op2 == `RAPT_ALU_MULHU_);
    end
  end
endmodule
