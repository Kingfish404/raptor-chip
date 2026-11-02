`include "rapt.svh"
`include "rapt_fp_ops.svh"

// The fixed-format endpoints exercise the original precision-specific window.
// Define the reference module externally to compare against frozen older RTL.
`ifndef RAPT_FPU_MULTIFORMAT_REFERENCE
`define RAPT_FPU_MULTIFORMAT_REFERENCE rapt_fpu_mul_fma
`endif
module tb_fpu_multiformat;
  logic clock = 0;
  logic reset = 1, flush = 0, valid = 0, is_fma = 0, target_double = 0;
  logic ready, result_valid;
  logic [5:0] op = 0;
  logic [63:0] operand_a = 0, operand_b = 0, operand_c = 0, result;
  logic [2:0] rounding_mode = 0;
  logic [4:0] flags;
  logic [1:0] reference_ready, reference_valid;
  logic [63:0] reference_result[2];
  logic [4:0] reference_flags[2];
  logic [7:0] expected_valid = '0, expected_double = '0;
  logic [63:0] history_a[8], history_b[8], history_c[8];
  logic [5:0] history_op[8];
  logic [2:0] history_rm[8];
  logic [63:0] counts[2][5][5] = '{default: '0};
  logic [63:0] directed = 0, accepted = 0, completed = 0, killed = 0;
  logic [63:0] rng = 64'hac5317e4682f9bd1;
  integer random_vectors = 200000;
  localparam int Corners = 24;
  always #5 clock = ~clock;

  rapt_fpu_fp_product dut (.*);
  for (genvar fmt = 0; fmt < 2; fmt++) begin : g_reference
    `RAPT_FPU_MULTIFORMAT_REFERENCE #(
        .TARGET_DOUBLE(fmt == 1)
    ) reference_unit (
        .clock,
        .reset,
        .flush,
        .valid(valid && target_double == (fmt == 1)),
        .is_fma,
        .ready(reference_ready[fmt]),
        .op,
        .operand_a,
        .operand_b,
        .operand_c,
        .rounding_mode,
        .result(reference_result[fmt]),
        .flags(reference_flags[fmt]),
        .result_valid(reference_valid[fmt])
    );
  end

  function automatic logic [63:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
  endfunction

  function automatic logic [63:0] corner(input bit fmt, input int index);
    logic [63:0] value;
    case (index)
      0: value = 0;
      1: value = fmt ? 64'h8000000000000000 : 64'h80000000;
      2: value = 1;
      3: value = fmt ? 64'h8000000000000001 : 64'h80000001;
      4: value = fmt ? 64'h000fffffffffffff : 64'h007fffff;
      5: value = fmt ? 64'h800fffffffffffff : 64'h807fffff;
      6: value = fmt ? 64'h0010000000000000 : 64'h00800000;
      7: value = fmt ? 64'h8010000000000000 : 64'h80800000;
      8: value = fmt ? 64'h3ff0000000000000 : 64'h3f800000;
      9: value = fmt ? 64'hbff0000000000000 : 64'hbf800000;
      10: value = fmt ? 64'h3ff0000000000001 : 64'h3f800001;
      11: value = fmt ? 64'h3fefffffffffffff : 64'h3f7fffff;
      12: value = fmt ? 64'h7fefffffffffffff : 64'h7f7fffff;
      13: value = fmt ? 64'hffefffffffffffff : 64'hff7fffff;
      14: value = fmt ? 64'h7ff0000000000000 : 64'h7f800000;
      15: value = fmt ? 64'hfff0000000000000 : 64'hff800000;
      16: value = fmt ? 64'h7ff0000000000001 : 64'h7f800001;
      17: value = fmt ? 64'hfff7ffffffffffff : 64'hffbfffff;
      18: value = fmt ? 64'h7ff8bad012345678 : 64'h7fc12345;
      19: value = fmt ? 64'hfffabcdef1234567 : 64'hffeabcde;
      20: value = fmt ? 64'h001fffffffffffff : 64'h00ffffff;
      21: value = fmt ? 64'h3fe0000000000000 : 64'h3f000000;
      22: value = fmt ? 64'h0020000000000000 : 64'h01000000;
      default: value = fmt ? 64'h3ff8000000000000 : 64'h3fc00000;
    endcase
    if (!fmt) value[63:32] = '1;
    return value;
  endfunction

  function automatic logic [63:0] random_operand(input bit fmt);
    logic [63:0] value;
    value = random_word();
    case (random_word() % 4)
      0: value = corner(fmt, int'(random_word() % Corners));
      1: begin
        if (fmt) value[62:52] = '0;
        else value[30:23] = '0;
      end
      default: ;
    endcase
    if (!fmt && random_word() % 16 != 0) value[63:32] = '1;
    return value;
  endfunction

  // Make the addend almost cancel the product, including deep cancellation.
  task automatic cancellation_operands(input bit fmt, input int variant);
    logic [105:0] exact_product;
    logic [52:0] mant_a, mant_b, mant_c;
    int fraction_bits, bias, exponent_a, exponent_b, exponent_c;
    bit sign_a, sign_b, sign_c;
    fraction_bits = fmt ? 52 : 23;
    bias = fmt ? 1023 : 127;
    exponent_a = int'(random_word() % (fmt ? 901 : 101)) - (fmt ? 450 : 50);
    exponent_b = int'(random_word() % (fmt ? 901 : 101)) - (fmt ? 450 : 50);
    mant_a = (53'b1 << fraction_bits) | (random_word() & ((53'b1 << fraction_bits) - 1));
    mant_b = (53'b1 << fraction_bits) | (random_word() & ((53'b1 << fraction_bits) - 1));
    exact_product = mant_a * mant_b;
    exponent_c = exponent_a + exponent_b;
    if (exact_product[2*fraction_bits+1]) begin
      mant_c = 53'(exact_product >> (fraction_bits + 1));
      exponent_c++;
    end else mant_c = 53'(exact_product >> fraction_bits);
    sign_a = 1'(random_word());
    sign_b = 1'(random_word());
    sign_c = sign_a ^ sign_b ^ (variant == 0 || variant == 3);
    if (fmt) begin
      operand_a = {sign_a, 11'(exponent_a + bias), mant_a[51:0]};
      operand_b = {sign_b, 11'(exponent_b + bias), mant_b[51:0]};
      operand_c = {sign_c, 11'(exponent_c + bias), mant_c[51:0]};
    end else begin
      operand_a = {32'hffff_ffff, sign_a, 8'(exponent_a + bias), mant_a[22:0]};
      operand_b = {32'hffff_ffff, sign_b, 8'(exponent_b + bias), mant_b[22:0]};
      operand_c = {32'hffff_ffff, sign_c, 8'(exponent_c + bias), mant_c[22:0]};
    end
    case (random_word() % 3)
      0: operand_c++;
      1: operand_c--;
      default: ;
    endcase
  endtask

  task automatic sample ();
    bit take;
    int operation_index;
    take = valid && ready && !reset && !flush;
    operation_index = is_fma ? 1 + ((int'(op) - 51) / 2) : 0;
    @(posedge clock);
    if (reset || flush) begin
      killed += 64'($countones(expected_valid[6:0]));
      expected_valid = '0;
    end else begin
      for (int stage = 7; stage > 0; stage--) begin
        history_a[stage] = history_a[stage-1];
        history_b[stage] = history_b[stage-1];
        history_c[stage] = history_c[stage-1];
        history_op[stage] = history_op[stage-1];
        history_rm[stage] = history_rm[stage-1];
      end
      history_a[0] = operand_a;
      history_b[0] = operand_b;
      history_c[0] = operand_c;
      history_op[0] = op;
      history_rm[0] = rounding_mode;
      expected_valid = {expected_valid[6:0], take};
      expected_double = {expected_double[6:0], target_double};
      if (take) begin
        accepted++;
        counts[int'(target_double)][operation_index][int'(rounding_mode)]++;
      end
    end
    #1;
    assert (ready == (&reference_ready))
    else $fatal(1, "format-dependent launch stall");
    assert (result_valid == expected_valid[7] && result_valid == (|reference_valid))
    else $fatal(1, "multi-format latency changed");
    if (result_valid) begin
      assert (reference_valid == (expected_double[7] ? 2'b10 : 2'b01))
      else $fatal(1, "wrong format owner");
      assert (result == reference_result[expected_double[7]]
              && flags == reference_flags[expected_double[7]])
      else begin
        $display("fmt=%0d op=%0d rm=%0d a=%h b=%h c=%h", expected_double[7], history_op[7],
                 history_rm[7], history_a[7], history_b[7], history_c[7]);
        $fatal(1, "got=%h/%h expected=%h/%h", result, flags, reference_result[expected_double[7]],
               reference_flags[expected_double[7]]);
      end
      completed++;
    end
  endtask

  initial begin
    void'($value$plusargs("RANDOM_VECTORS=%d", random_vectors));
    repeat (3) begin
      @(negedge clock);
      sample ();
    end
    reset = 0;
    // Cross all directed operand classes for every operation and rounding mode.
    // Alternate formats each cycle so adjacent owners share no format state.
    for (int rm = 0; rm < 5; rm++)
    for (int operation_index = 0; operation_index < 5; operation_index++)
    for (int a = 0; a < Corners; a++)
    for (int b = 0; b < Corners; b++)
    for (int c = 0; c < (operation_index == 0 ? 1 : Corners); c++)
    for (int fmt = 0; fmt < 2; fmt++) begin
      @(negedge clock);
      valid = 1;
      target_double = 1'(fmt);
      is_fma = operation_index != 0;
      op = 6'(51 + fmt + 2 * (operation_index - 1));
      rounding_mode = 3'(rm);
      operand_a = corner(target_double, a);
      operand_b = corner(target_double, b);
      operand_c = corner(target_double, c);
      #1;
      sample ();
      directed++;
    end
    for (int rm = 0; rm < 5; rm++)
    for (int variant = 0; variant < 4; variant++)
    for (int vector_index = 0; vector_index < 2000; vector_index++)
    for (int fmt = 0; fmt < 2; fmt++) begin
      @(negedge clock);
      target_double = 1'(fmt);
      is_fma = 1;
      op = 6'(51 + fmt + 2 * variant);
      rounding_mode = 3'(rm);
      cancellation_operands(target_double, variant);
      #1;
      sample ();
      directed++;
    end
    for (int cycle = 0; cycle < random_vectors; cycle++) begin
      @(negedge clock);
      reset = cycle % 1009 == 1008;
      flush = random_word() % 127 == 0;
      valid = random_word() % 8 != 0;
      target_double = 1'(random_word());
      is_fma = random_word() % 5 != 0;
      op = 6'(51 + int'(target_double) + 2 * (random_word() % 4));
      rounding_mode = 3'(random_word() % 5);
      operand_a = random_operand(target_double);
      operand_b = random_operand(target_double);
      operand_c = random_operand(target_double);
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
    assert (accepted == completed + killed)
    else $fatal(1, "lost/duplicate format owner");
    for (int fmt = 0; fmt < 2; fmt++)
    for (int operation_index = 0; operation_index < 5; operation_index++)
    for (int rm = 0; rm < 5; rm++) begin
      assert (counts[fmt][operation_index][rm] > 500)
      else $fatal(1, "coverage gap");
      $display("vectors fmt=%0d operation=%0d rm=%0d count=%0d", fmt, operation_index, rm,
               counts[fmt][operation_index][rm]);
    end
    $display("PASS: multi-format directed=%0d accepted=%0d completed=%0d killed=%0d", directed,
             accepted, completed, killed);
    $finish;
  end
endmodule
