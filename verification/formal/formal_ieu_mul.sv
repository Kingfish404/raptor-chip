// Select a harness explicitly so unused hierarchical monitors are not elaborated.
`ifndef RAPT_FORMAL_MUL_DATAPATH
`ifndef RAPT_FORMAL_MUL_TRANSPORT
// ---- formal_ieu_mul ----
`include "rapt.svh"

module formal_ieu_mul #(
    parameter bit [7:0] XLEN = `RAPT_XLEN
) (
    input clock,

    input [XLEN-1:0] in_a,
    input [XLEN-1:0] in_b,
    input [4:0] in_op,
    input in_valid,
    input in_word,
    output reg [XLEN-1:0] out_r,
    output reg out_valid,

    input reset
);
  rapt_ieu_mul mul (
      .clock,
      .reset,
      .flush(1'b0),
      .cancel_tags('0),
      .in_a,
      .in_b,
      .in_op,
      .in_word,
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
  logic [4:0] ref_op_q, ref_op_qq;
  logic ref_word_q, ref_word_qq;
  logic [2*XLEN-1:0] mul_ss, mul_su, mul_uu;
  logic past_valid = 1'b0;

  always_ff @(posedge clock) past_valid <= 1'b1;

  always_comb begin
    mul_ss = {{XLEN{in_a[XLEN-1]}}, in_a} * {{XLEN{in_b[XLEN-1]}}, in_b};
    mul_su = {{XLEN{in_a[XLEN-1]}}, in_a} * {{XLEN{1'b0}}, in_b};
    mul_uu = {{XLEN{1'b0}}, in_a} * {{XLEN{1'b0}}, in_b};

    if (!past_valid) assume (reset);
    if (in_valid) begin
      assume (in_op == `RAPT_ALU_MUL___ || in_op ==
      `RAPT_ALU_MULH__
      || in_op == `RAPT_ALU_MULHSU || in_op == `RAPT_ALU_MULHU_);
      if (XLEN == 32) assume (!in_word);
      if (in_word) assume (in_op == `RAPT_ALU_MUL___);
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      ref_valid_q   <= 1'b0;
      ref_valid_qq  <= 1'b0;
      ref_result_q  <= '0;
      ref_result_qq <= '0;
      ref_op_q <= '0;
      ref_op_qq <= '0;
      ref_word_q <= 1'b0;
      ref_word_qq <= 1'b0;
    end else begin
      ref_valid_q   <= in_valid;
      ref_valid_qq  <= ref_valid_q;
      ref_result_qq <= ref_result_q;
      ref_op_q <= in_op;
      ref_op_qq <= ref_op_q;
      ref_word_q <= in_word;
      ref_word_qq <= ref_word_q;
      unique case (in_op)
        `RAPT_ALU_MUL___: begin
          if (XLEN > 32 && in_word) ref_result_q <= XLEN'($signed(mul_uu[31:0]));
          else ref_result_q <= mul_uu[XLEN-1:0];
        end
        `RAPT_ALU_MULH__: ref_result_q <= mul_ss[2*XLEN-1:XLEN];
        `RAPT_ALU_MULHSU: ref_result_q <= mul_su[2*XLEN-1:XLEN];
        `RAPT_ALU_MULHU_: ref_result_q <= mul_uu[2*XLEN-1:XLEN];
        default: ref_result_q <= '0;
      endcase
    end
  end

  // Reset plus two pipeline edges puts the first result in frame 3.
  // Keep these covers with the arithmetic checks so a shallow PASS is visible.
  always @(posedge clock) begin
    if (!reset) begin
      cov_mul : cover (out_valid && ref_op_qq == `RAPT_ALU_MUL___ && !ref_word_qq);
      cov_mulh : cover (out_valid && ref_op_qq == `RAPT_ALU_MULH__);
      cov_mulhsu : cover (out_valid && ref_op_qq == `RAPT_ALU_MULHSU);
      cov_mulhu : cover (out_valid && ref_op_qq == `RAPT_ALU_MULHU_);
      if (XLEN > 32) cov_mulw : cover (out_valid && ref_word_qq);
    end
  end

  always_comb begin
    if (!reset) begin
      valid_assert : assert (out_valid == ref_valid_qq);
      if (out_valid) result_assert : assert (out_r == ref_result_qq);
    end
  end
`endif  // FORMAL
endmodule
`endif
`endif

`ifdef RAPT_FORMAL_MUL_DATAPATH
// ---- formal_mul_datapath ----
`include "rapt.svh"
module formal_mul_datapath #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int Operation = 0,
    parameter bit Word = 0,
    parameter bit UseDsp = 0
) (
    input logic clock,
    reset,
    valid,
    word,
    input logic [4:0] opcode,
    input logic [XLEN-1:0] a,
    b,
    output logic mismatch,
    output logic [4:0] selected_op
);
  assign selected_op = Operation == 0 ? `RAPT_ALU_MUL___ :
      Operation == 1 ? `RAPT_ALU_MULH__ :
      Operation == 2 ? `RAPT_ALU_MULHSU : `RAPT_ALU_MULHU_;
  rapt_ieu_mul #(
      .XLEN(XLEN),
      .UseDsp(UseDsp)
  ) dut (
      .clock,
      .reset,
      .flush(1'b0),
      .cancel_tags('0),
      .in_a(a),
      .in_b(b),
      .in_op(opcode),
      .in_word(word),
      .in_tag(1'b0),
      .in_valid(valid),
      .in_ready(),
      .out_r(),
      .out_tag(),
      .out_valid()
  );
  logic [2*XLEN-1:0] reference_product;
  logic [XLEN-1:0] reference;
  always_comb begin
    case (Operation)
      1: reference_product = $signed(a) * $signed(b);
      2: reference_product = $signed({a[XLEN-1],a}) * $signed({1'b0,b});
      default: reference_product = a * b;
    endcase
    if (Operation == 0) begin
      reference = reference_product[XLEN-1:0];
      if (Word && XLEN == 64) reference = XLEN'($signed(reference_product[31:0]));
    end else reference = reference_product[2*XLEN-1:XLEN];
  end
  assign mismatch = dut.mul_r_comb != reference;
endmodule
`endif

`ifdef RAPT_FORMAL_MUL_TRANSPORT
// ---- formal_mul_transport ----
`include "rapt.svh"
module formal_mul_transport #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int TagBits = 3,
    parameter bit UseDsp = 0
) (
    input logic clock,
    reset,
    flush,
    valid,
    word,
    input logic [1:0] operation,
    input logic [XLEN-1:0] a,
    b,
    input logic [TagBits-1:0] tag,
    input logic [(1<<TagBits)-1:0] cancel,
    output logic correct,
    output logic [8:0] witnessed
);
  logic [4:0] opcode;
  always_comb begin
    case (operation)
      0: opcode = `RAPT_ALU_MUL___;
      1: opcode = `RAPT_ALU_MULH__;
      2: opcode = `RAPT_ALU_MULHSU;
      3: opcode = `RAPT_ALU_MULHU_;
    endcase
    if (valid) begin
      if (XLEN == 32) assume (!word);
      if (word) assume (operation == 0);
    end
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
  logic seen_reset = 0;
  logic ref_v1, ref_v2, word1, word2;
  logic [XLEN-1:0] a1, b1, result2;
  logic [4:0] op1;
  logic [1:0] operation1, operation2;
  logic [TagBits-1:0] tag1, tag2;
  wire accept = valid && !cancel[tag];
  wire expected_valid = ref_v2 && !cancel[tag2];
  always_ff @(posedge clock) begin
    result2 <= dut.mul_r_comb;
    if (reset || flush) begin
      ref_v1 <= 0;
      ref_v2 <= 0;
    end else begin
      ref_v1 <= accept;
      ref_v2 <= ref_v1 && !cancel[tag1];
    end
    if (accept) begin
      a1 <= a;
      b1 <= b;
      op1 <= opcode;
      word1 <= word;
      operation1 <= operation;
      tag1 <= tag;
    end
    if (ref_v1 && !cancel[tag1]) begin
      tag2 <= tag1;
      operation2 <= operation1;
      word2 <= word1;
    end
    if (reset) begin
      seen_reset <= 1;
      witnessed <= 0;
    end else if (seen_reset) begin
      if (out_valid) witnessed[operation2] <= 1;
      if (out_valid && word2) witnessed[4] <= 1;
      if (flush && (ref_v1 || ref_v2)) witnessed[5] <= 1;
      if (ref_v1 && cancel[tag1]) witnessed[6] <= 1;
      if (ref_v2 && cancel[tag2]) witnessed[7] <= 1;
      if (out_valid && accept && tag != out_tag) witnessed[8] <= 1;
    end
  end
  always_comb begin
    correct = 1;
    if (seen_reset) begin
      correct &= ready && !dut.div_active && !dut.div_out_valid;
      correct &= dut.m1_v == ref_v1 && dut.m2_v == ref_v2;
      if (ref_v1)
        correct &= {dut.m1_s1,dut.m1_s2,dut.m1_op,dut.m1_word,dut.m1_tag}
          == {a1,b1,op1,word1,tag1};
      correct &= out_valid == expected_valid;
      if (out_valid) correct &= out_r == result2 && out_tag == tag2;
    end
  end
endmodule
`endif
