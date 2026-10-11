`include "rapt.svh"

// Public-port check of the committed bank, independent of its storage layout.
module tb_fp_arch_bank;
  import rapt_pkg::*;
  localparam int Entries = 8;
  localparam int Bits = 3;
  localparam int Width = 4;
  localparam int GenBits = CoreConfig.rob_generation_bits;
  logic clock = 0, reset = 1, flush = 0;
  logic allocate_valid[Width], commit_valid[Width];
  uop_t allocate_uop[Width];
  logic [Bits-1:0] allocate_index[Width], commit_index[Width], read_index[Width];
  logic [GenBits-1:0] allocate_generation[Width];
  logic [2:0][63:0] allocate_value[Width], read_value[Width];
  logic [2:0][Bits:0] allocate_tag[Width], read_tag[Width];
  completion_t completion[Width];
  logic [63:0] expected[32];
  logic [63:0] data[Width];
  int dest[Width];
  bit writes[Width];
  logic [31:0] rng = 32'h7b85169d;
  int observations = 0;

  rapt_fp_registers #(
      .Entries(Entries),
      .AllocateWidth(Width),
      .ReadPorts(Width),
      .CommitWidth(Width),
      .CompletionPorts(Width)
  ) dut (
      .operand_allocate_index('{default: '0}),
      .operand_release_valid('{default: '0}),
      .operand_release_index('{default: '0}),
      .operand_read_valid('{default: '0}),
      .operand_read_index('{default: '0}),
      .*
  );

  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  task automatic tick;
    #2;
    clock = 1;
    #2;
    clock = 0;
    #1;
  endtask

  task automatic clear_inputs;
    for (int s = 0; s < Width; s++) begin
      allocate_valid[s] = 0;
      allocate_uop[s] = '0;
      allocate_index[s] = Bits'(s);
      allocate_generation[s] = GenBits'(1);
      commit_valid[s] = 0;
      commit_index[s] = Bits'(s);
      completion[s] = '0;
      read_index[s] = Bits'(s);
    end
  endtask

  task automatic check_bank;
    clear_inputs();
    // Every one of the twelve asynchronous read ports observes every word.
    for (int r = 0; r < 32; r++) begin
      for (int s = 0; s < Width; s++) begin
        allocate_uop[s].execute.fp.valid = 1;
        allocate_uop[s].execute.fp.op = `RAPT_FP_OP_FMADD_D;
        allocate_uop[s].execute.fp.rs1 = 5'(r + s * 3);
        allocate_uop[s].execute.fp.rs2 = 5'(r + s * 3 + 7);
        allocate_uop[s].execute.fp.rs3 = 5'(r + s * 3 + 14);
      end
      #1;
      for (int s = 0; s < Width; s++) begin
        for (int operand = 0; operand < 3; operand++) begin
          if (allocate_tag[s][operand] !== '0
              || allocate_value[s][operand] !== expected[(r+s*3+operand*7)%32])
            $fatal(
                1,
                "committed bank mismatch lane=%0d operand=%0d f%0d got=%h expected=%h",
                s,
                operand,
                (r + s * 3 + operand * 7) % 32,
                allocate_value[s][operand],
                expected[(r+s*3+operand*7)%32]
            );
          observations++;
        end
      end
    end
    clear_inputs();
  endtask

  initial begin
    clear_inputs();
    for (int r = 0; r < 32; r++) expected[r] = 0;
    tick();
    reset = 0;
    check_bank();
    for (int round = 0; round < 160; round++) begin
      clear_inputs();
      for (int s = 0; s < Width; s++) begin
        // Initial sweep writes all words from each lane; subsequent rounds
        // include four-way aliases, partial aliases, and arbitrary addresses.
        if (round < 32) dest[s] = (round + s * 8) % 32;
        else if (round % 4 == 0) dest[s] = (round / 4) % 32;
        else if (round % 4 == 1) dest[s] = (round + s % 2) % 32;
        else dest[s] = int'(random_word() & 31);
        data[s] = {random_word(), random_word()};
        writes[s] = round < 32 || (round + s) % 11 != 0;
        allocate_valid[s] = 1;
        allocate_uop[s].execute.fp.valid = 1;
        allocate_uop[s].execute.fp.op = `RAPT_FP_OP_FADD_D;
        allocate_uop[s].execute.fp.rd = 5'(dest[s]);
        allocate_uop[s].trap = !writes[s];
      end
      tick();
      clear_inputs();
      for (int s = 0; s < Width; s++) begin
        completion[s].valid = writes[s];
        completion[s].fp_wen = 1;
        completion[s].dest = ROBIndexBits'(s);
        completion[s].generation = GenBits'(1);
        completion[s].fp_result = data[s];
      end
      tick();
      clear_inputs();
      // Commit prefixes, retirement on redirect, and reset on retirement.
      for (int s = 0; s < Width; s++) commit_valid[s] = round < 32 || s < round % 5;
      flush = round % 3 == 0;
      reset = round == 79 || round == 127;
      if (reset) begin
        for (int r = 0; r < 32; r++) expected[r] = 0;
      end else begin
        for (int s = 0; s < Width; s++)
        if (commit_valid[s] && writes[s]) expected[dest[s]] = data[s];
      end
      tick();
      clear_inputs();
      reset = 0;
      // Discard any uncommitted suffix before observing architectural values.
      if (!flush) begin
        flush = 1;
        tick();
      end
      flush = 0;
      check_bank();
    end
    $display(
        "PASS: four-lane FP architectural bank, all 32 words and 12 ports, observations=%0d XLEN=%0d",
        observations, `RAPT_XLEN);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "FP architectural bank test timeout");
  end
endmodule
