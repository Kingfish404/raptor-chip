module tb_vector_rtl #(
    parameter int XLEN = 64
);
  logic [XLEN-1:0] requested_vtype, avl, current_vtype, current_vl;
  logic avl_max, keep_vl;
  logic [XLEN-1:0] next_vtype, next_vl, vlmax;
  logic vill;
  string vectors;
  int input_file;
  int parsed;

  rapt_vpu_vtype #(
      .XLEN(XLEN),
      .VLEN(128),
      .ELEN(64)
  ) dut (
      .*
  );

  initial begin
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "Missing vectors path");
    input_file = $fopen(vectors, "r");
    if (input_file == 0) $fatal(1, "Cannot open vector inputs");
    while (!$feof(
        input_file
    )) begin
      parsed = $fscanf(
          input_file,
          "%h %h %h %h %h %h\n",
          requested_vtype,
          avl,
          current_vtype,
          current_vl,
          avl_max,
          keep_vl
      );
      if (parsed == 6) begin
        #1;
        $display("VTYPE_RESULT %h %h %h %d", next_vtype, next_vl, vlmax, vill);
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule
