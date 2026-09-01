`include "rapt.svh"

module rapt_fpu_convert_widen (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [63:0] operand,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  logic s1_valid_q, s2_valid_q;
  logic s1_sign_q;
  logic [7:0] s1_exponent_q;
  logic [22:0] s1_fraction_q;
  logic [5:0] s1_leading_one_q;
  logic [63:0] result_q;
  logic [4:0] flags_q;

  logic [31:0] source_c;
  logic sign_c;
  logic [7:0] exponent_c;
  logic [22:0] fraction_c;
  logic [5:0] leading_one_c;
  logic leading_found_c;
  integer leading_scan_index_c;

  logic [63:0] stage2_result_c;
  logic [4:0] stage2_flags_c;
  logic [51:0] double_fraction_c;

  always_comb begin
    source_c = operand[63:32] == '1 ? operand[31:0] : 32'h7fc0_0000;
    sign_c = source_c[31];
    exponent_c = source_c[30:23];
    fraction_c = source_c[22:0];
    leading_one_c = '0;
    leading_found_c = 1'b0;
    for (
        leading_scan_index_c = 22;
        leading_scan_index_c >= 0;
        leading_scan_index_c = leading_scan_index_c - 1
    ) begin
      if (!leading_found_c && fraction_c[leading_scan_index_c]) begin
        leading_one_c = 6'(leading_scan_index_c + 1);
        leading_found_c = 1'b1;
      end
    end
  end

  always_comb begin
    stage2_result_c = '0;
    stage2_flags_c = '0;
    double_fraction_c = '0;

    if (s1_exponent_q == 8'hff) begin
      stage2_result_c[63] = s1_sign_q;
      stage2_result_c[62:52] = '1;
      if (s1_fraction_q == '0) begin
        stage2_result_c[51:0] = '0;
      end else begin
        stage2_result_c[63] = 1'b0;
        stage2_result_c[51] = 1'b1;
        stage2_flags_c[4] = !s1_fraction_q[22];
      end
    end else if (s1_exponent_q == '0) begin
      if (s1_fraction_q == '0) begin
        stage2_result_c[63] = s1_sign_q;
      end else begin
        double_fraction_c = ({29'b0, s1_fraction_q}
            - (52'(1) << (s1_leading_one_q - 1)))
            << (53 - s1_leading_one_q);
        stage2_result_c[63] = s1_sign_q;
        stage2_result_c[62:52] = {5'b0, s1_leading_one_q} + 11'd873;
        stage2_result_c[51:0] = double_fraction_c;
      end
    end else begin
      stage2_result_c[63] = s1_sign_q;
      stage2_result_c[62:52] = {3'b0, s1_exponent_q} + 11'd896;
      stage2_result_c[51:0] = {s1_fraction_q, 29'b0};
    end
  end

  assign ready = !(s1_valid_q || s2_valid_q);
  assign result = result_q;
  assign flags = flags_q;
  assign result_valid = s2_valid_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      s1_valid_q <= 1'b0;
      s2_valid_q <= 1'b0;
      result_q <= '0;
      flags_q <= '0;
    end else begin
      s2_valid_q <= s1_valid_q;
      s1_valid_q <= valid && ready;
      if (valid && ready) begin
        s1_sign_q <= sign_c;
        s1_exponent_q <= exponent_c;
        s1_fraction_q <= fraction_c;
        s1_leading_one_q <= leading_one_c;
      end
      if (s1_valid_q) begin
        result_q <= stage2_result_c;
        flags_q <= stage2_flags_c;
      end
    end
  end
endmodule
