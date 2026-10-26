module formal_alu_equivalence (
    input logic [5:0] funct6,
    input logic [1:0] sew,
    input logic [63:0] a,
    b,
    input logic mask_bit,
    mask_logic,
    output logic correct
);
  logic [63:0] baseline, optimized;
  rapt_vpu_alu_baseline u_before (
      .funct6,
      .sew,
      .a,
      .b,
      .mask_bit,
      .mask_logic,
      .result(baseline)
  );
  rapt_vpu_alu u_after (
      .funct6,
      .sew,
      .a,
      .b,
      .mask_bit,
      .mask_logic,
      .result(optimized)
  );
  assign correct = baseline == optimized;
endmodule
