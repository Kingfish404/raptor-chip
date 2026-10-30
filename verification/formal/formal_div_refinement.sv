`include "rapt.svh"

// A canonical, MSB-first unsigned divider: consume input bits, compare the
// appended remainder, and shift the quotient. The production divider instead
// carries a lookahead bit in its remainder and places quotient bits by index.
// Their state correspondence is asserted, including normalization and W forms.
module formal_div_refinement #(
    parameter int XLEN = 32,
    parameter int TagBits = 2,
    parameter bit UseDsp = 0,
    parameter bit AllowMultiply = 0
) (
    input logic clock,
    reset,
    flush,
    valid,
    word,
    input logic [1+AllowMultiply:0] operation,
    input logic [XLEN-1:0] a,
    b,
    input logic [TagBits-1:0] tag,
    input logic [(1<<TagBits)-1:0] cancel,
    output logic correct,
    output logic [(AllowMultiply ? 18 : 10)-1:0] witnessed
);
  logic [9:0] div_witnessed;
  assign witnessed[9:0] = div_witnessed;

  localparam int CountBits = $clog2(XLEN + 1);
  typedef logic [CountBits-1:0] count_t;
  logic [4:0] opcode;
  wire is_multiply;
  if (AllowMultiply) assign is_multiply = operation[2];
  else assign is_multiply = 1'b0;
  always_comb begin
    case (operation[1:0])
      0: opcode = `RAPT_ALU_DIV___;
      1: opcode = `RAPT_ALU_DIVU__;
      2: opcode = `RAPT_ALU_REM___;
      3: opcode = `RAPT_ALU_REMU__;
    endcase
    if (is_multiply) begin
      case (operation[1:0])
        0: opcode = `RAPT_ALU_MUL___;
        1: opcode = `RAPT_ALU_MULH__;
        2: opcode = `RAPT_ALU_MULHSU;
        3: opcode = `RAPT_ALU_MULHU_;
      endcase
      if (valid && word) assume (operation[1:0] == 0);
    end
    if (valid && XLEN == 32) assume (!word);
  end
  logic ready, out_valid;
  logic [XLEN-1:0] out_r;
  logic [TagBits-1:0] out_tag;
  rapt_ieu_mul #(
      .XLEN(XLEN),
      .TAG_W(TagBits),
      .UseDsp(UseDsp)
  ) dut (
      .clock,
      .reset,
      .flush,
      .cancel_tags(cancel),
      .in_a(a),
      .in_b(b),
      .in_op(opcode),
      .in_word(word),
      .in_tag(tag),
      .in_valid(valid),
      .in_ready(ready),
      .out_r,
      .out_tag,
      .out_valid
  );

  function automatic logic [XLEN-1:0] narrow_operand(input logic [XLEN-1:0] value,
                                                     input logic is_word, is_signed);
    if (is_word && XLEN == 64) begin
      if (is_signed) return XLEN'($signed(value[31:0]));
      return XLEN'(value[31:0]);
    end
    return value;
  endfunction

  function automatic count_t significant_bits(input logic [XLEN-1:0] value);
    significant_bits = '0;
    for (int bit_index = 0; bit_index < XLEN; bit_index++) begin
      if (value[bit_index]) significant_bits = count_t'(bit_index + 1);
    end
  endfunction

  wire signed_operation = !operation[0];
  wire [XLEN-1:0] operand_a = narrow_operand(a, word, signed_operation);
  wire [XLEN-1:0] operand_b = narrow_operand(b, word, signed_operation);
  wire negative_a = signed_operation && operand_a[XLEN-1];
  wire negative_b = signed_operation && operand_b[XLEN-1];
  wire [XLEN-1:0] magnitude_a = negative_a ? -operand_a : operand_a;
  wire [XLEN-1:0] magnitude_b = negative_b ? -operand_b : operand_b;

  logic seen_reset = 0;
  logic busy, normalizing, emission;
  logic [TagBits-1:0] owner, result_tag;
  logic [XLEN-1:0] dividend, divisor, quotient, remainder, prefix;
  logic [XLEN-1:0] original_a, original_b, result_value;
  logic held_word, sign_a, sign_b;
  logic [1:0] held_operation;
  logic [4:0] held_opcode;
  logic [4:0] expected_opcode;
  always_comb begin
    case (held_operation)
      0: expected_opcode = `RAPT_ALU_DIV___;
      1: expected_opcode = `RAPT_ALU_DIVU__;
      2: expected_opcode = `RAPT_ALU_REM___;
      3: expected_opcode = `RAPT_ALU_REMU__;
    endcase
  end
  count_t remaining;
  count_t age;
  wire [CountBits-1:0] remaining_cycles = (remaining + 1) >> 1;
  wire [CountBits-1:0] total_cycles = (significant_bits(dividend) + 1) >> 1;
  wire accepted = valid && !busy && !cancel[tag] && !is_multiply;
  wire accepted_multiply = valid && !busy && !cancel[tag] && is_multiply;

  // Arithmetic at this single combinational interface is proved separately
  // for every operand/opcode/W selector. In mixed mode the runner replaces
  // it with one free value, used by both the DUT and this transport monitor.
  logic mul_v1, mul_v2;
  logic [TagBits-1:0] mul_tag1, mul_tag2;
  logic [XLEN-1:0] mul_a1, mul_b1, mul_result2;
  logic [4:0] mul_opcode1;
  logic mul_word1;
  wire visible_divide = emission && !cancel[result_tag];
  wire visible_multiply = mul_v2 && !cancel[mul_tag2];
  always_ff @(posedge clock) begin
    mul_result2 <= dut.mul_r_comb;
    mul_v1 <= accepted_multiply;
    mul_v2 <= mul_v1 && !cancel[mul_tag1];
    if (accepted_multiply) begin
      mul_a1 <= a;
      mul_b1 <= b;
      mul_opcode1 <= opcode;
      mul_word1 <= word;
      mul_tag1 <= tag;
    end
    if (mul_v1 && !cancel[mul_tag1]) mul_tag2 <= mul_tag1;
    if (reset || flush) begin
      mul_v1 <= 0;
      mul_v2 <= 0;
    end
  end

  // One canonical step consumes a dividend bit before deciding the next bit
  // of the quotient. Extra width makes every carry explicit.
  logic [XLEN:0] appended1, appended2;
  logic [XLEN:0] residue1, residue2, wide_q1, wide_q2, wide_prefix1, wide_prefix2;
  logic [XLEN-1:0] remainder1, remainder2, quotient1, quotient2;
  logic [XLEN-1:0] prefix1, prefix2;
  logic bit1, bit2, take1, take2;
  always_comb begin
    bit1 = remaining != 0 ? dividend[remaining-1] : 1'b0;
    bit2 = remaining > 1 ? dividend[remaining-2] : 1'b0;
    appended1 = {remainder, bit1};
    take1 = appended1 >= {1'b0, divisor};
    residue1 = take1 ? appended1 - {1'b0, divisor} : appended1;
    remainder1 = residue1[XLEN-1:0];
    wide_q1 = {quotient, take1};
    quotient1 = wide_q1[XLEN-1:0];
    wide_prefix1 = {prefix, bit1};
    prefix1 = wide_prefix1[XLEN-1:0];
    appended2 = {remainder1, bit2};
    take2 = appended2 >= {1'b0, divisor};
    residue2 = take2 ? appended2 - {1'b0, divisor} : appended2;
    remainder2 = residue2[XLEN-1:0];
    wide_q2 = {quotient1, take2};
    quotient2 = wide_q2[XLEN-1:0];
    wide_prefix2 = {prefix1, bit2};
    prefix2 = wide_prefix2[XLEN-1:0];
  end

  logic [XLEN-1:0] corrected_q, corrected_r, expected_result;
  always_comb begin
    corrected_q = sign_a != sign_b ? -quotient : quotient;
    corrected_r = sign_a ? -remainder : remainder;
    if (held_operation[1]) begin
      expected_result = divisor == 0 ? original_a : corrected_r;
    end else begin
      expected_result = divisor == 0 ? '1 : corrected_q;
    end
    if (held_word && XLEN == 64) expected_result = XLEN'($signed(expected_result[31:0]));
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      seen_reset <= 1;
      div_witnessed[9:0] <= '0;
    end else if (seen_reset) begin
      if (out_valid) begin
        div_witnessed[held_operation] <= 1;
        if (held_word) div_witnessed[4] <= 1;
        if (original_b == 0) div_witnessed[5] <= 1;
        if (sign_a && sign_b) div_witnessed[6] <= 1;
        if (dividend[XLEN-1] && divisor == 1) div_witnessed[9] <= 1;
      end
      if (busy && cancel[owner]) div_witnessed[7] <= 1;
      if (busy && flush) div_witnessed[8] <= 1;
    end
    emission <= 0;
    if (busy) age <= age + 1;
    if (accepted) begin
      busy <= 1;
      normalizing <= 1;
      owner <= tag;
      dividend <= magnitude_a;
      divisor <= magnitude_b;
      quotient <= 0;
      remainder <= 0;
      prefix <= 0;
      original_a <= operand_a;
      original_b <= operand_b;
      sign_a <= negative_a;
      sign_b <= negative_b;
      held_operation <= operation[1:0];
      held_opcode <= opcode;
      held_word <= word;
      remaining <= significant_bits(magnitude_a);
      age <= 0;
    end else if (busy && cancel[owner]) begin
      busy <= 0;
      normalizing <= 0;
    end else if (busy && normalizing) begin
      normalizing <= 0;
    end else if (busy && remaining != 0) begin
      quotient <= remaining > 1 ? quotient2 : quotient1;
      remainder <= remaining > 1 ? remainder2 : remainder1;
      prefix <= remaining > 1 ? prefix2 : prefix1;
      remaining <= remaining > 1 ? remaining - 2 : remaining - 1;
    end else if (busy) begin
      busy <= 0;
      emission <= 1;
      result_value <= expected_result;
      result_tag <= owner;
    end
    if (reset || flush) begin
      busy <= 0;
      normalizing <= 0;
      emission <= 0;
      age <= 0;
    end
  end

  if (AllowMultiply) begin : g_mixed_covers
    logic [7:0] mixed_witnessed;
    assign witnessed[17:10] = mixed_witnessed;
    logic saw_divide_result;
    logic saw_cancelled_divide;
    logic [TagBits-1:0] cancelled_tag;
    logic reuse1, reuse2;
    logic [2:0] sequence_phase;
    always_ff @(posedge clock) begin
      reuse1 <= accepted_multiply && saw_cancelled_divide && tag == cancelled_tag;
      reuse2 <= reuse1 && mul_v1 && !cancel[mul_tag1];
      if (busy && cancel[owner]) begin
        saw_cancelled_divide <= 1;
        cancelled_tag <= owner;
      end
      if (visible_divide) saw_divide_result <= 1;
      if (seen_reset) begin
        if (visible_multiply && busy) mixed_witnessed[0] <= 1;
        if (visible_divide && accepted_multiply) mixed_witnessed[1] <= 1;
        if (busy && valid && is_multiply && !cancel[tag]) mixed_witnessed[2] <= 1;
        if (sequence_phase == 3 && visible_divide) mixed_witnessed[3] <= 1;
        if (saw_divide_result && visible_multiply) mixed_witnessed[4] <= 1;
        if (visible_multiply && reuse2) mixed_witnessed[5] <= 1;
        if (visible_multiply && busy && cancel[owner] && mul_tag2 != owner) mixed_witnessed[6] <= 1;
        if (flush && busy && (mul_v1 || mul_v2)) mixed_witnessed[7] <= 1;
      end
      case (sequence_phase)
        0: if (accepted_multiply) sequence_phase <= 1;
        1: if (accepted) sequence_phase <= 2;
        2: if (visible_multiply) sequence_phase <= 3;
        3: if (visible_divide) sequence_phase <= 0;
        default: sequence_phase <= 0;
      endcase
      if (reset || flush) begin
        saw_divide_result <= 0;
        saw_cancelled_divide <= 0;
        sequence_phase <= 0;
        reuse1 <= 0;
        reuse2 <= 0;
      end
      if (reset) mixed_witnessed <= '0;
    end
  end

  logic [XLEN:0] lookahead;
  always_comb begin
    lookahead = {remainder, 1'b0} | (XLEN+1)'(bit1);
    correct = 1;
    if (seen_reset) begin
      correct &= !(busy && emission);
      correct &= dut.div_active == busy && ready == !busy;
      correct &= dut.m1_v == mul_v1 && dut.m2_v == mul_v2;
      if (mul_v1) begin
        correct &= {dut.m1_s1, dut.m1_s2, dut.m1_op, dut.m1_word, dut.m1_tag}
            == {mul_a1, mul_b1, mul_opcode1, mul_word1, mul_tag1};
      end
      if (mul_v2) correct &= dut.m2_tag == mul_tag2;
      // The normalization edge drains an older multiply before division can
      // emit, including zero-dividend shortcuts and cancellation recovery.
      correct &= !(busy && mul_v1);
      if (busy && !normalizing) correct &= !mul_v2;
      if (emission) correct &= !mul_v1 && !mul_v2;
      correct &= !(visible_divide && visible_multiply);
      correct &= dut.div_out_valid == emission;
      if (emission) correct &= dut.div_out_r == result_value && dut.div_out_tag == result_tag;
      correct &= out_valid == (visible_divide || visible_multiply);
      if (visible_divide) correct &= out_r == result_value && out_tag == result_tag;
      if (visible_multiply) correct &= out_r == mul_result2 && out_tag == mul_tag2;
      if (busy) begin
        correct &= dut.div_norm == normalizing;
        correct &= dut.div_tag == owner && dut.div_word == held_word;
        correct &= dut.div_s1 == original_a && dut.div_s2 == original_b;
        correct &= dut.div_op == held_opcode;
        correct &= dut.div_sign == {original_a[XLEN-1], original_b[XLEN-1]};
        correct &= dut.div_divisor == divisor;
        correct &= held_opcode == expected_opcode;
        correct &= sign_a == (!held_operation[0] && original_a[XLEN-1]);
        correct &= sign_b == (!held_operation[0] && original_b[XLEN-1]);
        correct &= dividend == (sign_a ? -original_a : original_a);
        correct &= divisor == (sign_b ? -original_b : original_b);
        if (held_word && XLEN == 64) begin
          correct &= original_a == narrow_operand(original_a, 1'b1, !held_operation[0]);
          correct &= original_b == narrow_operand(original_b, 1'b1, !held_operation[0]);
        end
        correct &= remaining <= XLEN;
        correct &= int'(age) + int'(remaining_cycles) + int'(normalizing) == int'(total_cycles) + 1;
        correct &= age <= XLEN / 2 + 1;
        correct &= prefix == (dividend >> remaining);
        correct &= remainder <= prefix;
        correct &= (quotient >> (XLEN - remaining)) == 0;
        if (divisor != 0) correct &= remainder < divisor;
        if (divisor == 1) correct &= quotient == prefix && remainder == 0;
        if (normalizing) begin
          correct &= dut.div_counter == ((held_word && XLEN == 64) ? 32 : 0);
          correct &= dut.div_quotient == 0 && dut.div_remainder == 0;
          correct &= dut.div_dividend_shifted
              == ((held_word && XLEN == 64) ? dividend << 32 : dividend);
          correct &= quotient == 0 && remainder == 0 && prefix == 0;
          correct &= remaining == significant_bits(dividend);
        end else begin
          if (remaining != 0) begin
            correct &= !residue1[XLEN] && !wide_q1[XLEN] && !wide_prefix1[XLEN];
          end
          if (remaining > 1) begin
            correct &= !residue2[XLEN] && !wide_q2[XLEN] && !wide_prefix2[XLEN];
          end
          correct &= dut.div_counter == XLEN - remaining;
          correct &= dut.div_remainder == lookahead;
          correct &= dut.div_quotient == quotient << remaining;
          correct &= dut.div_dividend_shifted == dividend << (XLEN + 1 - remaining);
        end
      end
    end
  end
endmodule
