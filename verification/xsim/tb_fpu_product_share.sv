`include "rapt.svh"
`include "rapt_fp_ops.svh"

// Standalone wrappers retain private product resources. Compare their complete
// pipelines against the shared endpoint on every cycle, not just final values.
module fpu_product_share_check #(
    parameter bit Double = 0
) (
    input logic clock,
    output logic done
);
  logic reset = 1, flush = 0, valid = 0, is_fma = 0, ready;
  logic [5:0] op = 0;
  logic [63:0] operand_a = 0, operand_b = 0, operand_c = 0, result;
  logic [2:0] rounding_mode = 0;
  logic [4:0] flags;
  logic result_valid, mul_ready, fma_ready, mul_result_valid, fma_result_valid;
  logic [63:0] mul_result, fma_result;
  logic [4:0] mul_flags, fma_flags;
  logic reference_ready;
  int accepted_mul = 0, accepted_fma = 0, completed = 0, killed = 0;
  logic [7:0] expected_valid = '0, expected_fma = '0;
  logic [63:0] expected_result[8];
  logic [4:0] expected_flags[8];
  logic [31:0] rng = 32'h71648293;
  assign reference_ready = mul_ready && fma_ready;
  rapt_fpu_mul_fma #(.TARGET_DOUBLE(Double)) dut (.*);
  rapt_fpu_mul #(
      .TARGET_DOUBLE(Double)
  ) reference_mul (
      .clock,
      .reset,
      .flush,
      .valid(valid && reference_ready && !is_fma),
      .ready(mul_ready),
      .operand_a,
      .operand_b,
      .rounding_mode,
      .result(mul_result),
      .flags(mul_flags),
      .result_valid(mul_result_valid)
  );
  rapt_fpu_fma #(
      .TARGET_DOUBLE(Double)
  ) reference_fma (
      .clock,
      .reset,
      .flush,
      .valid(valid && reference_ready && is_fma),
      .ready(fma_ready),
      .op,
      .operand_a,
      .operand_b,
      .operand_c,
      .rounding_mode,
      .result(fma_result),
      .flags(fma_flags),
      .result_valid(fma_result_valid)
  );
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic logic [63:0] operand();
    logic [63:0] value;
    value = {random_word(), random_word()};
    case (random_word() % 12)
      0: value = 0;
      1: value = Double ? 64'h8000000000000000 : 64'h80000000;
      2: value = 1;
      3: value = Double ? 64'h000fffffffffffff : 64'h007fffff;
      4: value = Double ? 64'h0010000000000000 : 64'h00800000;
      5: value = Double ? 64'h7ff0000000000000 : 64'h7f800000;
      6: value = Double ? 64'hfff0000000000000 : 64'hff800000;
      7: value = Double ? 64'h7ff0000000000001 : 64'h7f800001;
      8: value = Double ? 64'h7ff8000000000000 : 64'h7fc00000;
      9: value = Double ? 64'h7fefffffffffffff : 64'h7f7fffff;
      default: ;
    endcase
    if (!Double && random_word() % 8 != 0) value[63:32] = '1;
    return value;
  endfunction
  task automatic sample ();
    bit take;
    take = valid && ready && !reset && !flush;
    @(posedge clock);
    if (reset || flush) begin
      killed += $countones(expected_valid[6:0]);
      expected_valid = '0;
      expected_fma = '0;
    end else begin
      for (int stage = 7; stage > 0; stage--) begin
        expected_result[stage] = expected_result[stage-1];
        expected_flags[stage] = expected_flags[stage-1];
      end
      expected_valid = {expected_valid[6:0], take};
      expected_fma = {expected_fma[6:0], is_fma};
      if (take) begin
        if (is_fma) accepted_fma++;
        else accepted_mul++;
      end
    end
    #1;
    assert (ready == reference_ready)
    else $fatal(1, "streaming endpoint stopped accepting operands");
    assert (mul_result_valid == (expected_valid[3] && !expected_fma[3]))
    else $fatal(1, "private MUL latency/owner changed");
    assert (fma_result_valid == (expected_valid[7] && expected_fma[7]))
    else $fatal(1, "private FMA latency/owner changed");
    if (mul_result_valid) begin
      expected_result[3] = mul_result;
      expected_flags[3] = mul_flags;
    end
    if (fma_result_valid) begin
      expected_result[7] = fma_result;
      expected_flags[7] = fma_flags;
    end
    assert (result_valid == expected_valid[7])
    else $fatal(1, "mixed product stream did not preserve eight-stage latency");
    if (result_valid) begin
      assert (result == expected_result[7] && flags == expected_flags[7])
      else $fatal(1, "shared product changed arithmetic or flags Double=%0d", Double);
      completed++;
    end
  endtask
  initial begin
    done = 0;
    repeat (3) begin
      @(negedge clock);
      sample ();
    end
    for (int cycle = 0; cycle < 20000; cycle++) begin
      @(negedge clock);
      reset = cycle % 251 == 250;
      flush = random_word() % 37 == 0;
      valid = random_word() % 5 != 0;
      is_fma = 1'(random_word());
      op = 6'(51 + int'(Double) + 2 * (random_word() % 4));
      rounding_mode = 3'(random_word() % 5);
      // Change inputs even while busy to expose incorrect product ownership.
      operand_a = operand();
      operand_b = operand();
      operand_c = operand();
      #1;
      sample ();
    end
    repeat (10) begin
      @(negedge clock);
      reset = 0;
      flush = 0;
      valid = 0;
      #1;
      sample ();
    end
    assert (accepted_mul > 1000 && accepted_fma > 1000 && killed > 50)
    else $fatal(1, "insufficient shared-product coverage");
    assert (accepted_mul + accepted_fma == completed + killed)
    else $fatal(1, "lost or duplicate product owner");
    $display("PASS: shared product Double=%0d mul=%0d fma=%0d completed=%0d killed=%0d", Double,
             accepted_mul, accepted_fma, completed, killed);
    done = 1;
  end
endmodule

module tb_fpu_product_share;
  logic clock = 0;
  logic done_s, done_d;
  always #5 clock = ~clock;
  fpu_product_share_check #(
      .Double(0)
  ) single_check (
      .clock,
      .done(done_s)
  );
  fpu_product_share_check #(
      .Double(1)
  ) double_check (
      .clock,
      .done(done_d)
  );
  initial begin
    wait (done_s && done_d);
    $display("PASS: shared/private FP product cycle and flags comparison");
    $finish;
  end
  initial begin
    #300000;
    $fatal(1, "shared product timeout");
  end
endmodule
