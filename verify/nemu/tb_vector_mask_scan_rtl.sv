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
