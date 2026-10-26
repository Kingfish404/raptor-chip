module tb_vector_mask_ops_rtl;
  logic [31:0] insn;
  logic [7:0] vtype;
  logic [6:0] vstart;
  logic is_integer, mask_prefix, iota, element_index, compress;
  logic src_vector, uses_vs2, mask_result, mask_logic, gather, gather16;
  logic slide, widen, wide_a, narrow, extend, illegal, geometry_legal;
  logic legal_operation, legal_restart, legal_prefix;
  logic [1:0] extend_shift;
  string vectors;
  int input_file;
  int parsed;

  assign legal_operation = is_integer && !illegal && geometry_legal
      && (mask_prefix || iota || element_index || compress);
  assign legal_restart = !(mask_prefix || iota || compress) || vstart == 0;
  assign legal_prefix = !mask_prefix || (insn[11:7] != insn[24:20]
      && (insn[25] || insn[11:7] != 0));

  rapt_vpu_decode u_decode (
      .insn,
      .is_integer,
      .mask_prefix,
      .iota,
      .element_index,
      .compress,
      .src_vector,
      .uses_vs2,
      .mask_result,
      .mask_logic,
      .gather,
      .gather16,
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
      parsed = $fscanf(input_file, "%h %h %h\n", insn, vtype, vstart);
      if (parsed == 3) begin
        #1;
        $display("VECTOR_MASK_OPS_LEGAL %0d", legal_operation && legal_restart && legal_prefix);
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule
