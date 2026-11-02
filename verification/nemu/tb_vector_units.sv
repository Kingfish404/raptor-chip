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

module tb_vector_reduce_rtl #(
    parameter int XLEN = 64
);
  logic clock;
  always #5 clock = ~clock;

  logic reset = 1;
  logic cmd_valid = 0;
  logic cmd_ready;
  logic [31:0] cmd_insn;
  logic [XLEN-1:0] cmd_vtype, cmd_vl;
  logic [6:0] cmd_vstart;
  logic done_valid, done_ready = 0, done_trap;
  logic vr_valid, vr_ready, vr_write, vr_rsp_valid, vr_rsp_ready;
  logic [8:0] vr_addr;
  logic [1:0] vr_size;
  logic [63:0] vr_wdata, vr_rdata;
  logic [7:0] storage[0:511];
  logic [7:0] seed;
  string vectors;
  int input_file;
  int parsed;
  int cycles;

  assign vr_ready = 1;
  rapt_vpu_reduce #(
      .XLEN(XLEN),
      .VLEN(128),
      .ELEN(64)
  ) dut (
      .clock,
      .reset,
      .cmd_valid,
      .cmd_ready,
      .cmd_insn,
      .cmd_vtype,
      .cmd_vl,
      .cmd_vstart,
      .done_valid,
      .done_ready,
      .done_trap,
      .vr_valid,
      .vr_ready,
      .vr_write,
      .vr_addr,
      .vr_size,
      .vr_wdata,
      .vr_rsp_valid,
      .vr_rsp_ready,
      .vr_rdata
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      vr_rsp_valid <= 0;
      vr_rdata <= 0;
    end else begin
      vr_rsp_valid <= vr_valid && vr_ready;
      if (vr_rsp_valid && !vr_rsp_ready) $fatal(1, "Unaccepted vector response");
    end
    if (!reset && vr_valid && vr_ready) begin
      if (!vr_write) vr_rdata <= 0;
      for (int byte_index = 0; byte_index < 8; byte_index++) begin
        if (byte_index < (1 << vr_size)) begin
          if (vr_write) storage[int'(vr_addr)+byte_index] <= vr_wdata[byte_index*8+:8];
          else vr_rdata[byte_index*8+:8] <= storage[int'(vr_addr)+byte_index];
        end
      end
    end
  end

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
      parsed =
          $fscanf(input_file, "%h %h %h %h %h\n", cmd_insn, cmd_vtype, cmd_vl, cmd_vstart, seed);
      if (parsed == 5) begin
        for (int byte_index = 0; byte_index < 512; byte_index++)
        storage[byte_index] = 8'(byte_index * 29 + (byte_index / 16) * 37 + int'(seed) * 13);
        @(negedge clock);
        if (!cmd_ready) $fatal(1, "Reduction command not ready");
        cmd_valid = 1;
        @(negedge clock);
        cmd_valid = 0;
        cycles = 0;
        while (!done_valid && cycles < 3000) begin
          @(negedge clock);
          cycles++;
        end
        if (!done_valid) $fatal(1, "Reduction command timed out");
        $write("VECTOR_REDUCE_RESULT %0d ", done_trap);
        for (int byte_index = 0; byte_index < 512; byte_index++)
        $write("%02x", storage[byte_index]);
        $write("\n");
        done_ready = 1;
        @(negedge clock);
        done_ready = 0;
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule

module tb_vector_mask_scan_rtl #(
    parameter int XLEN = 64
);
  logic clock;
  always #5 clock = ~clock;

  logic reset = 1;
  logic cmd_valid = 0;
  logic cmd_ready;
  logic cmd_first, cmd_masked, cmd_vill;
  logic [4:0] cmd_src;
  logic [XLEN-1:0] cmd_vl;
  logic [6:0] cmd_vstart;
  logic done_valid, done_ready = 0, done_trap;
  logic [XLEN-1:0] done_value;
  logic vr_valid, vr_ready, vr_rsp_valid, vr_rsp_ready;
  logic [8:0] vr_addr;
  logic [7:0] vr_rdata;
  logic [7:0] storage[0:511];
  logic [7:0] seed;
  string vectors;
  int input_file;
  int parsed;
  int cycles;

  assign vr_ready = 1;
  rapt_vpu_mask_scan #(
      .XLEN(XLEN),
      .VLEN(128)
  ) dut (
      .clock,
      .reset,
      .cmd_valid,
      .cmd_ready,
      .cmd_first,
      .cmd_masked,
      .cmd_vill,
      .cmd_src,
      .cmd_vl,
      .cmd_vstart,
      .done_valid,
      .done_ready,
      .done_trap,
      .done_value,
      .vr_valid,
      .vr_ready,
      .vr_addr,
      .vr_rsp_valid,
      .vr_rsp_ready,
      .vr_rdata
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      vr_rsp_valid <= 0;
      vr_rdata <= 0;
    end else begin
      vr_rsp_valid <= vr_valid && vr_ready;
      if (vr_rsp_valid && !vr_rsp_ready) $fatal(1, "Unaccepted mask response");
      if (vr_valid && vr_ready) vr_rdata <= storage[int'(vr_addr)];
    end
  end

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
      parsed = $fscanf(
          input_file,
          "%h %h %h %h %h %h %h\n",
          cmd_first,
          cmd_masked,
          cmd_vill,
          cmd_src,
          cmd_vl,
          cmd_vstart,
          seed
      );
      if (parsed == 7) begin
        for (int byte_index = 0; byte_index < 512; byte_index++)
        storage[byte_index] = 8'(byte_index * 29 + (byte_index / 16) * 37 + int'(seed) * 13);
        @(negedge clock);
        if (!cmd_ready) $fatal(1, "Mask scan command not ready");
        cmd_valid = 1;
        @(negedge clock);
        cmd_valid = 0;
        cycles = 0;
        while (!done_valid && cycles < 3000) begin
          @(negedge clock);
          cycles++;
        end
        if (!done_valid) $fatal(1, "Mask scan command timed out");
        $display("VECTOR_MASK_SCAN_RESULT %0d %h", done_trap, done_value);
        done_ready = 1;
        @(negedge clock);
        done_ready = 0;
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule

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

module tb_vector_move_rtl #(
    parameter int XLEN = 64
);
  logic clock;
  always #5 clock = ~clock;

  logic reset = 1;
  logic cmd_valid = 0;
  logic cmd_ready;
  logic [31:0] cmd_insn;
  logic [1:0] cmd_sew;
  logic cmd_vill;
  logic [6:0] cmd_vstart;
  logic done_valid, done_ready = 0, done_trap;
  logic vr_valid, vr_ready, vr_write, vr_rsp_valid, vr_rsp_ready;
  logic [8:0] vr_addr;
  logic [1:0] vr_size;
  logic [63:0] vr_wdata, vr_rdata;
  logic [7:0] storage[0:511];
  logic [XLEN-1:0] vtype;
  logic [7:0] seed;
  string vectors;
  int input_file;
  int parsed;
  logic [6:0] start_index;
  int cycles;

  assign vr_ready = 1;
  rapt_vpu_move #(
      .VLEN(128)
  ) dut (
      .clock,
      .reset,
      .cmd_valid,
      .cmd_ready,
      .cmd_insn,
      .cmd_sew,
      .cmd_vill,
      .cmd_vstart,
      .done_valid,
      .done_ready,
      .done_trap,
      .vr_valid,
      .vr_ready,
      .vr_write,
      .vr_addr,
      .vr_size,
      .vr_wdata,
      .vr_rsp_valid,
      .vr_rsp_ready,
      .vr_rdata
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      vr_rsp_valid <= 0;
      vr_rdata <= 0;
    end else begin
      vr_rsp_valid <= vr_valid && vr_ready;
      if (vr_rsp_valid && !vr_rsp_ready) $fatal(1, "Unaccepted vector response");
    end
    if (!reset && vr_valid && vr_ready) begin
      for (int byte_index = 0; byte_index < 8; byte_index++) begin
        if (byte_index < (1 << vr_size)) begin
          if (vr_write) storage[int'(vr_addr)+byte_index] <= vr_wdata[byte_index*8+:8];
          else vr_rdata[byte_index*8+:8] <= storage[int'(vr_addr)+byte_index];
        end
      end
    end
  end

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
      parsed = $fscanf(input_file, "%h %h %h %h\n", cmd_insn, vtype, start_index, seed);
      if (parsed == 4) begin
        for (int byte_index = 0; byte_index < 512; byte_index++)
        storage[byte_index] = 8'(byte_index * 29 + (byte_index / 16) * 37 + int'(seed) * 13);
        cmd_sew = vtype[4:3];
        cmd_vill = vtype[XLEN-1];
        cmd_vstart = start_index;
        @(negedge clock);
        if (!cmd_ready) $fatal(1, "Move command not ready");
        cmd_valid = 1;
        @(negedge clock);
        cmd_valid = 0;
        cycles = 0;
        while (!done_valid && cycles < 3000) begin
          @(negedge clock);
          cycles++;
        end
        if (!done_valid) $fatal(1, "Move command timed out");
        $write("VECTOR_MOVE_RESULT %0d ", done_trap);
        for (int byte_index = 0; byte_index < 512; byte_index++)
        $write("%02x", storage[byte_index]);
        $write("\n");
        done_ready = 1;
        @(negedge clock);
        done_ready = 0;
      end else if (!$feof(input_file)) begin
        $fatal(1, "Malformed vector input");
      end
    end
    $fclose(input_file);
    $finish;
  end
endmodule
