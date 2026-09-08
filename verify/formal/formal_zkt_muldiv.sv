`include "rapt.svh"

// Timing noninterference at the shared fast MUL/iterative DIV port.
// DIV is not required by Zkt; here its operands also vary to check the
// current implementation's interference with later MUL transactions.
module formal_zkt_muldiv (
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
  wire is_div = in_op == `RAPT_ALU_DIV___ || in_op == `RAPT_ALU_DIVU__
      || in_op == `RAPT_ALU_REM___ || in_op == `RAPT_ALU_REMU__;
  wire is_mul = in_op == `RAPT_ALU_MUL___ || in_op == `RAPT_ALU_MULH__
      || in_op == `RAPT_ALU_MULHSU || in_op == `RAPT_ALU_MULHU_;
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
  // Reachability monitor only; it does not constrain either DUT.
  reg [2:0] phase = 0;
  reg div_was_word;
  reg [7:0] mul_tag;
  always @(posedge clock) begin
    past_valid <= 1;
    if (!past_valid) assume (reset);
    if (in_valid) begin
      assume (is_mul || is_div);
      if (X == 32) assume (!in_word);
      if (in_word && is_mul) assume (in_op == `RAPT_ALU_MUL___);
    end
    if (past_valid) begin
      // Inductive lemmas for long-lived divider state. These are assertions
      // proved from reset, not assumptions equating the two secret operands.
      assert (left_dut.div_active == right_dut.div_active);
      if (left_dut.div_active) begin
        assert (left_dut.div_counter == right_dut.div_counter);
        assert (left_dut.div_tag == right_dut.div_tag);
      end
      assert (left_dut.m1_v == right_dut.m1_v);
      if (left_dut.m1_v) assert (left_dut.m1_tag == right_dut.m1_tag);
      assert (left_dut.m2_v == right_dut.m2_v);
      if (left_dut.m2_v) assert (left_dut.m2_tag == right_dut.m2_tag);
      assert (left_dut.div_out_valid == right_dut.div_out_valid);
      if (left_dut.div_out_valid) assert (left_dut.div_out_tag == right_dut.div_out_tag);
      assert (ready0 == ready1);
      assert (valid0 == valid1);
      if (valid0) assert (tag0 == tag1);
      cover (!ready0 && in_valid && is_mul);
      cover (!ready0 && flush);
      cover (phase == 5 && valid0 && tag0 == mul_tag && !div_was_word);
      if (X == 64) cover (phase == 5 && valid0 && tag0 == mul_tag && div_was_word);
    end
    if (reset || flush) phase <= 0;
    else
      case (phase)
        0:
        if (in_valid && ready0 && is_div && a0 != a1 && b0 != b1) begin
          phase <= 1;
          div_was_word <= in_word;
        end
        1: if (!ready0) phase <= 2;
        2: if (ready0 && valid0) phase <= 3;
        3: if (in_valid && ready0 && is_mul) begin
        phase <= 4;
        mul_tag <= in_tag;
      end
        4: phase <= 5;
        5: phase <= 0;
        default: phase <= 0;
      endcase
  end
endmodule
