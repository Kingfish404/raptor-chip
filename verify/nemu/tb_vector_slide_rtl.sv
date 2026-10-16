module tb_vector_slide_rtl #(
    parameter int XLEN = 64
);
  logic cmd_up, cmd_single, cmd_masked;
  logic [1:0] cmd_sew;
  logic [2:0] cmd_lmul;
  logic [4:0] cmd_src, cmd_dst;
  logic [7:0] cmd_vl, cmd_vstart, index, maximum;
  logic [XLEN-1:0] cmd_offset;
  logic [63:0] cmd_scalar;
  logic [7:0] cmd_seed;
  logic mask_active, write_element, read_source, scalar_select;
  logic [7:0] source_index;
  logic [7:0] storage[0:511];
  logic [1023:0] result;
  string vectors;
  int input_file;
  int parsed;
  int group;
  int byte_count;
  int source_address;
  int destination_address;

  rapt_vpu_slide #(
      .XLEN(XLEN),
      .VLEN(128)
  ) dut (
      .up(cmd_up),
      .single(cmd_single),
      .mask_active,
      .index,
      .vl(cmd_vl),
      .vlmax(maximum),
      .vstart(cmd_vstart),
      .offset(cmd_offset),
      .write_element,
      .read_source,
      .scalar_select,
      .source_index
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
          "%h %h %h %h %h %h %h %h %h %h %h %h\n",
          cmd_up,
          cmd_single,
          cmd_masked,
          cmd_sew,
          cmd_lmul,
          cmd_src,
          cmd_dst,
          cmd_vl,
          cmd_vstart,
          cmd_offset,
          cmd_scalar,
          cmd_seed
      );
      if (parsed == 12) begin
        group = 1 << cmd_lmul;
        byte_count = 1 << cmd_sew;
        maximum = 8'((128 >> (cmd_sew + 3)) << cmd_lmul);
        for (int byte_index = 0; byte_index < 512; byte_index++)
        storage[byte_index] = 8'(byte_index * 29 + (byte_index / 16) * 37 + int'(cmd_seed) * 13);
        for (int element = 0; element < int'(maximum); element++) begin
          index = 8'(element);
          mask_active = !cmd_masked || storage[element / 8][element % 8];
          #1;
          if (write_element) begin
            destination_address = int'(cmd_dst) * 16 + element * byte_count;
            source_address = int'(cmd_src) * 16 + int'(source_index) * byte_count;
            for (int byte_index = 0; byte_index < byte_count; byte_index++) begin
              storage[destination_address+byte_index] = read_source
                  ? storage[source_address+byte_index]
                  : scalar_select ? 8'(cmd_scalar >> (8 * byte_index)) : 0;
            end
          end
        end
        result = 0;
        for (int byte_index = 0; byte_index < group * 16; byte_index++)
        result[byte_index*8+:8] = storage[int'(cmd_dst)*16+byte_index];
        $display("VECTOR_SLIDE_RESULT %h", result);
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule
