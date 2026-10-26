module tb_vector_memory_rtl #(
    parameter int XLEN = 64
);
  logic clock;
  always #5 clock = ~clock;

  logic reset = 1;
  logic cmd_valid = 0, cmd_ready;
  logic [31:0] cmd_insn;
  logic [XLEN-1:0] cmd_vtype, cmd_vl, cmd_base, cmd_stride;
  logic [6:0] cmd_vstart;
  logic done_valid, done_ready = 0, done_trap, done_update, done_fof;
  logic [XLEN-1:0] done_cause, done_tval, done_vl;
  logic [6:0] done_vstart;
  logic vr_valid, vr_ready, vr_write, vr_rsp_valid, vr_rsp_ready;
  logic [8:0] vr_addr;
  logic [1:0] vr_size;
  logic [63:0] vr_wdata, vr_rdata;
  logic mem_valid, mem_ready, mem_write, mem_probe;
  logic [XLEN-1:0] mem_addr;
  logic [1:0] mem_size;
  logic [63:0] mem_wdata, mem_rdata;
  logic [9:0] mem_tag, mem_rsp_tag;
  logic [7:0] mem_index, mem_rsp_index;
  logic [2:0] mem_field, mem_rsp_field;
  logic mem_rsp_valid, mem_rsp_ready, mem_rsp_probe, response_dropped;
  logic mem_fault;
  logic [XLEN-1:0] mem_cause, mem_tval;
  logic [7:0] vector_storage[0:511];
  logic [7:0] memory_storage[0:511];
  logic [7:0] seed;
  logic [3:0] cmd_index_pattern;
  string vectors;
  int input_file, parsed, cycles, index_bytes, offset_value, position;
  int vector_requests, memory_requests;
  int vector_request_baseline, memory_request_baseline;

  assign vr_ready = 1;
  assign mem_ready = 1;
  rapt_vpu_memory #(
      .XLEN(XLEN),
      .VLEN(128),
      .ELEN(64)
  ) dut (
      .clock,
      .reset,
      .cmd_valid,
      .cmd_ready,
      .cmd_insn,
      .cmd_tag('0),
      .cmd_base,
      .cmd_stride,
      .cmd_vtype,
      .cmd_vl,
      .cmd_vstart,
      .done_valid,
      .done_ready,
      .done_trap,
      .done_update,
      .done_fof,
      .done_cause,
      .done_tval,
      .done_vl,
      .done_vstart,
      .vr_valid,
      .vr_ready,
      .vr_write,
      .vr_addr,
      .vr_size,
      .vr_wdata,
      .vr_rsp_valid,
      .vr_rsp_ready,
      .vr_rdata,
      .mem_valid,
      .mem_ready,
      .mem_write,
      .mem_probe,
      .mem_addr,
      .mem_size,
      .mem_wdata,
      .mem_tag,
      .mem_index,
      .mem_field,
      .mem_rsp_valid,
      .mem_rsp_ready,
      .mem_rsp_tag,
      .mem_rsp_index,
      .mem_rsp_field,
      .mem_rsp_probe,
      .mem_rdata,
      .mem_fault,
      .mem_non_idempotent(1'b0),
      .mem_cause,
      .mem_tval,
      .response_dropped
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      vector_requests <= 0;
      memory_requests <= 0;
      vr_rsp_valid <= 0;
      vr_rdata <= 0;
      mem_rsp_valid <= 0;
      mem_rdata <= 0;
      mem_rsp_tag <= 0;
      mem_rsp_index <= 0;
      mem_rsp_field <= 0;
      mem_rsp_probe <= 0;
      mem_fault <= 0;
      mem_cause <= 0;
      mem_tval <= 0;
    end else begin
      vr_rsp_valid <= vr_valid && vr_ready;
      mem_rsp_valid <= mem_valid && mem_ready;
      if (vr_rsp_valid && !vr_rsp_ready) $fatal(1, "Unaccepted vector response");
      if (mem_rsp_valid && !mem_rsp_ready) $fatal(1, "Unaccepted memory response");
      if (response_dropped) $fatal(1, "Dropped memory response");
      if (vr_valid && vr_ready) begin
        vector_requests <= vector_requests + 1;
        vr_rdata <= '0;
        for (int byte_index = 0; byte_index < 8; byte_index++) begin
          if (byte_index < (1 << vr_size)) begin
            if (vr_write) vector_storage[int'(vr_addr)+byte_index] <= vr_wdata[byte_index*8+:8];
            else vr_rdata[byte_index*8+:8] <= vector_storage[int'(vr_addr)+byte_index];
          end
        end
      end
      if (mem_valid && mem_ready) begin
        memory_requests <= memory_requests + 1;
        mem_rsp_tag <= mem_tag;
        mem_rsp_index <= mem_index;
        mem_rsp_field <= mem_field;
        mem_rsp_probe <= mem_probe;
        mem_fault <= mem_addr + (XLEN'(1) << mem_size) > XLEN'(512);
        mem_cause <= mem_write ? XLEN'(7) : XLEN'(5);
        mem_tval <= mem_addr;
        if (mem_addr + (XLEN'(1) << mem_size) <= XLEN'(512)) begin
          for (int byte_index = 0; byte_index < 8; byte_index++) begin
            if (byte_index < (1 << mem_size)) begin
              if (mem_write && !mem_probe)
                memory_storage[int'(mem_addr)+byte_index] <= mem_wdata[byte_index*8+:8];
              else mem_rdata[byte_index*8+:8] <= memory_storage[int'(mem_addr)+byte_index];
            end
          end
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
      parsed = $fscanf(
          input_file,
          "%h %h %h %h %h %h %h %h\n",
          cmd_insn,
          cmd_vtype,
          cmd_vl,
          cmd_vstart,
          cmd_base,
          cmd_stride,
          seed,
          cmd_index_pattern
      );
      if (parsed == 8) begin
        vector_request_baseline = vector_requests;
        memory_request_baseline = memory_requests;
        for (int byte_index = 0; byte_index < 512; byte_index++) begin
          vector_storage[byte_index] = 8'(byte_index * 29 + (byte_index / 16) * 37
                                            + int'(seed) * 13);
          memory_storage[byte_index] = 8'(byte_index * 13 + (byte_index / 16) * 19
                                            + int'(seed) * 7);
        end
        if (cmd_index_pattern != 0) begin
          case (cmd_insn[14:12])
            3'b000: index_bytes = 1;
            3'b101: index_bytes = 2;
            3'b110: index_bytes = 4;
            3'b111: index_bytes = 8;
            default: index_bytes = 1;
          endcase
          for (int element_index = 0; element_index < 16; element_index++) begin
            case (cmd_index_pattern)
              1: offset_value = ((element_index * 3 + int'(seed)) % 8) * 8;
              2: offset_value = element_index * 4;
              4: offset_value = 3 + element_index * 4;
              default: offset_value = element_index * 3;
            endcase
            for (int byte_index = 0; byte_index < index_bytes; byte_index++) begin
              position = int'(cmd_insn[24:20]) * 16 + element_index * index_bytes + byte_index;
              if (position < 512) vector_storage[position] = 8'(offset_value >> (byte_index * 8));
            end
          end
        end
        @(negedge clock);
        if (!cmd_ready) $fatal(1, "Memory command not ready");
        cmd_valid = 1;
        @(negedge clock);
        cmd_valid = 0;
        cycles = 0;
        while (!done_valid && cycles < 5000) begin
          @(negedge clock);
          cycles++;
        end
        if (!done_valid) $fatal(1, "Memory command timed out");
        $write("VECTOR_MEMORY_RESULT %0d %0d %0d %h %h %h %h %0d %0d ", done_trap, done_update,
               done_fof, done_cause, done_tval, done_vl, done_vstart,
               vector_requests - vector_request_baseline,
               memory_requests - memory_request_baseline);
        for (int byte_index = 0; byte_index < 512; byte_index++)
        $write("%02x", vector_storage[byte_index]);
        $write(" ");
        for (int byte_index = 0; byte_index < 512; byte_index++)
        $write("%02x", memory_storage[byte_index]);
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
