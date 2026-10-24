module tb_vector_alu_rtl;
  logic [5:0] funct6;
  logic [1:0] sew;
  logic [63:0] a, b, result;
  logic mask_bit, mask_logic;
  string vectors;
  int input_file;
  int parsed;

  rapt_vpu_alu dut (
      .funct6(funct6),
      .sew(sew),
      .a(a),
      .b(b),
      .mask_bit(mask_bit),
      .mask_logic(mask_logic),
      .result(result)
  );

  initial begin
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "Missing vectors path");
    input_file = $fopen(vectors, "r");
    if (input_file == 0) $fatal(1, "Cannot open vector inputs");
    while (!$feof(
        input_file
    )) begin
      parsed = $fscanf(input_file, "%h %h %h %h %h %h\n", funct6, sew, a, b, mask_bit, mask_logic);
      if (parsed == 6) begin
        #1;
        $display("VECTOR_ALU_RESULT %h", result);
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule
