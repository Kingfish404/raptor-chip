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
