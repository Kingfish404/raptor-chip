module tb_vector_muldiv_rtl;
  logic clock;
  always #5 clock = ~clock;

  logic reset = 1;
  logic req_valid = 0;
  logic req_ready;
  logic [2:0] op;
  logic [1:0] sew;
  logic [63:0] a, b;
  logic rsp_valid, rsp_ready = 0;
  logic [63:0] result;
  logic [127:0] full_product;
  string vectors;
  int input_file;
  int parsed;
  int cycles;

  rapt_vpu_muldiv dut (
      .clock,
      .reset,
      .req_valid,
      .req_ready,
      .op,
      .sew,
      .a,
      .b,
      .rsp_valid,
      .rsp_ready,
      .result,
      .full_product
  );

  initial begin
    clock = 0;
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "Missing vectors path");
    input_file = $fopen(vectors, "r");
    if (input_file == 0) $fatal(1, "Cannot open vector inputs");
    repeat (2) @(negedge clock);
    reset = 0;
    while (!$feof(
        input_file
    )) begin
      parsed = $fscanf(input_file, "%h %h %h %h\n", op, sew, a, b);
      if (parsed == 4) begin
        @(negedge clock);
        if (!req_ready) $fatal(1, "Multiply/divide request not ready");
        req_valid = 1;
        @(negedge clock);
        req_valid = 0;
        cycles = 0;
        while (!rsp_valid && cycles < 100) begin
          @(negedge clock);
          cycles++;
        end
        if (!rsp_valid) $fatal(1, "Multiply/divide request timed out");
        $display("VECTOR_MULDIV_RESULT %h %h", result, full_product);
        rsp_ready = 1;
        @(negedge clock);
        rsp_ready = 0;
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule
