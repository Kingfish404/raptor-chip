module tb_vector_gather_rtl;
  logic [31:0] insn;
  logic [7:0] vtype;
  logic is_integer, gather, gather16, src_vector, uses_vs2;
  logic mask_result, mask_logic, iota, compress, slide;
  logic widen, wide_a, narrow, extend, illegal, geometry_legal;
  logic [1:0] extend_shift;
  string vectors;
  int input_file;
  int parsed;

  rapt_vpu_decode u_decode (
      .insn,
      .is_integer,
      .gather,
      .gather16,
      .src_vector,
      .uses_vs2,
      .mask_result,
      .mask_logic,
      .iota,
      .compress,
      .slide,
      .widen,
      .wide_a,
      .narrow,
      .extend,
      .extend_shift,
      .illegal
  );
  rapt_vpu_geometry u_geometry (
      .vtype,
      .vd(insn[11:7]),
      .vs2(insn[24:20]),
      .vs1(insn[19:15]),
      .uses_vs2,
      .src_vector,
      .masked(!insn[25]),
      .mask_result,
      .mask_logic,
      .mask_source(iota),
      .compress,
      .slide_up(slide && !insn[26]),
      .gather,
      .gather16,
      .widen,
      .wide_a,
      .narrow,
      .extend,
      .extend_shift,
      .legal(geometry_legal)
  );

  initial begin
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "Missing vectors path");
    input_file = $fopen(vectors, "r");
    if (input_file == 0) $fatal(1, "Cannot open vector inputs");
    while (!$feof(
        input_file
    )) begin
      parsed = $fscanf(input_file, "%h %h\n", insn, vtype);
      if (parsed == 2) begin
        #1;
        $display("VECTOR_GATHER_LEGAL %0d", is_integer && gather && !illegal && geometry_legal);
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule
