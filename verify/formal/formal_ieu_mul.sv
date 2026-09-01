`include "rapt.svh"

module formal_ieu_mul #(
    parameter bit [7:0] XLEN = `RAPT_XLEN
) (
    input clock,

    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_valid,
    output reg [XLEN-1:0] out_r,
    output reg out_valid,

    input reset
);
  rapt_ieu_mul mul (
      .clock,
      .reset,
      .flush(1'b0),
      .in_a,
      .in_b,
      .in_op,
      .in_word(1'b0),
      .in_tag(1'b0),
      .in_valid,
      .in_ready(),
      .out_r,
      .out_tag(),
      .out_valid
  );

`ifdef FORMAL
  logic ref_valid_q, ref_valid_qq;
  logic [XLEN-1:0] ref_result_q, ref_result_qq;
  logic [2*XLEN-1:0] mul_ss, mul_su, mul_uu;
  logic past_valid = 1'b0;

  always_ff @(posedge clock) past_valid <= 1'b1;

  always_comb begin
    mul_ss = {{XLEN{in_a[XLEN-1]}}, in_a} * {{XLEN{in_b[XLEN-1]}}, in_b};
    mul_su = {{XLEN{in_a[XLEN-1]}}, in_a} * {{XLEN{1'b0}}, in_b};
    mul_uu = {{XLEN{1'b0}}, in_a} * {{XLEN{1'b0}}, in_b};

    if (!past_valid) assume (reset);
    if (in_valid) begin
      assume(in_op == `RAPT_ALU_MUL___ || in_op == `RAPT_ALU_MULH__
             || in_op == `RAPT_ALU_MULHSU || in_op == `RAPT_ALU_MULHU_);
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      ref_valid_q   <= 1'b0;
      ref_valid_qq  <= 1'b0;
      ref_result_q  <= '0;
      ref_result_qq <= '0;
    end else begin
      ref_valid_q   <= in_valid;
      ref_valid_qq  <= ref_valid_q;
      ref_result_qq <= ref_result_q;
      unique case (in_op)
        `RAPT_ALU_MUL___: ref_result_q <= mul_uu[XLEN-1:0];
        `RAPT_ALU_MULH__: ref_result_q <= mul_ss[2*XLEN-1:XLEN];
        `RAPT_ALU_MULHSU: ref_result_q <= mul_su[2*XLEN-1:XLEN];
        `RAPT_ALU_MULHU_: ref_result_q <= mul_uu[2*XLEN-1:XLEN];
        default: ref_result_q <= '0;
      endcase
    end
  end

  always_comb begin
    if (!reset) begin
      valid_assert: assert (out_valid == ref_valid_qq);
      if (out_valid) result_assert: assert (out_r == ref_result_qq);
    end
  end
`endif  // FORMAL
endmodule
