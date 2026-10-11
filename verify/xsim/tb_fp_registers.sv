`include "rapt.svh"
module tb_fp_registers;
  import rapt_pkg::*;
  localparam int Entries = 8;
  localparam int Bits = 3;
  localparam int GenBits = CoreConfig.rob_generation_bits;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  logic allocate_valid[2], commit_valid[2];
  uop_t allocate_uop[2];
  logic [Bits-1:0] allocate_index[2], commit_index[2], read_index[2];
  logic [GenBits-1:0] allocate_generation[2];
  logic [2:0][63:0] allocate_value[2], read_value[2];
  logic [2:0][Bits:0] allocate_tag[2], read_tag[2];
  completion_t completion[2];
  rapt_fp_registers #(
`ifdef RAPT_TEST_COMPACT_FP
      .CompactSourceOperands(1'b1),
      .OperandEntries(Entries),
`endif
      .Entries(Entries),
      .AllocateWidth(2),
      .ReadPorts(2),
      .CommitWidth(2),
      .CompletionPorts(2)
  ) dut (
`ifndef RAPT_TEST_COMPACT_FP
      .operand_allocate_index('{default: '0}),
      .operand_release_valid('{default: '0}),
      .operand_release_index('{default: '0}),
      .operand_read_valid('{default: '0}),
      .operand_read_index('{default: '0}),
`endif
      .*
  );
`ifdef RAPT_TEST_COMPACT_FP
  // Independent spill allocator models ROU slot ownership. The ROB-owner map
  // intentionally differs from slot indices (the seed repeatedly uses owner 7).
  logic source_allocate_ready[2];
  logic [Bits-1:0] operand_allocate_index[2], operand_read_index[2];
  logic operand_release_valid[2], operand_read_valid[2];
  logic [Bits-1:0] operand_release_index[2], owner_slot[Entries];
  logic allocate_payload[2], read_payload[2], read_valid[2];
  logic update_valid[Entries], update_payload[Entries];
  logic entry_valid[Entries], entry_payload[Entries];
  for (genvar p = 0; p < 2; p++) begin : g_source_lifecycle
    assign allocate_payload[p] = 1'b0;
    assign operand_release_valid[p] = commit_valid[p];
    assign operand_release_index[p] = owner_slot[commit_index[p]];
    assign operand_read_index[p] = owner_slot[read_index[p]];
    // This fixture reads payload only at explicit task checks; idle read ports
    // may name an owner that has already retired.
    assign operand_read_valid[p] = 1'b0;
    always_ff @(posedge clock) begin
      if (!(reset || flush) && allocate_valid[p]) begin
        assert (source_allocate_ready[p])
        else $fatal(1, "reference FP spill full");
        owner_slot[allocate_index[p]] <= operand_allocate_index[p];
      end
    end
  end
  for (genvar e = 0; e < Entries; e++) begin : g_no_update
    assign update_valid[e] = 1'b0;
    assign update_payload[e] = 1'b0;
  end
  rapt_operand_spill #(
      .PayloadT(logic),
      .Entries(Entries),
      .AllocateWidth(2),
      .ReleaseWidth(2),
      .ReadPorts(2),
      .IndexBits(Bits)
  ) reference_slots (
      .clock,
      .reset,
      .flush,
      .allocate_valid,
      .allocate_payload,
      .allocate_ready(source_allocate_ready),
      .allocate_index(operand_allocate_index),
      .release_valid(operand_release_valid),
      .release_index(operand_release_index),
      .read_index(operand_read_index),
      .read_valid,
      .read_payload,
      .update_valid,
      .update_payload,
      .entry_valid,
      .entry_payload
  );
`endif

  task automatic tick;
    @(posedge clock);
    #1;
    @(negedge clock);
  endtask
  task automatic clear_inputs;
    for (int p = 0; p < 2; p++) begin
      allocate_valid[p] = 0;
      allocate_uop[p] = '0;
      allocate_index[p] = '0;
      allocate_generation[p] = '0;
      commit_valid[p] = 0;
      commit_index[p] = '0;
      completion[p] = '0;
      read_index[p] = '0;
    end
  endtask
  task automatic writer(input int lane, owner, rd, generation = 1);
    allocate_valid[lane] = 1;
    allocate_index[lane] = Bits'(owner);
    allocate_generation[lane] = GenBits'(generation);
    allocate_uop[lane] = '0;
    allocate_uop[lane].execute.fp.valid = 1;
    allocate_uop[lane].execute.fp.op = `RAPT_FP_OP_FADD_D;
    allocate_uop[lane].execute.fp.rd = 5'(rd);
    allocate_uop[lane].execute.fp.rs1 = 1;
    allocate_uop[lane].execute.fp.rs2 = 2;
  endtask
  task automatic finish_owner(input int port, owner, input logic [63:0] data,
                              input int generation = 1);
    completion[port] = '0;
    completion[port].valid = 1;
    completion[port].fp_wen = 1;
    completion[port].dest = ROBIndexBits'(owner);
    completion[port].generation = GenBits'(generation);
    completion[port].fp_result = data;
  endtask
  task automatic retire(input int lane, owner);
    commit_valid[lane] = 1;
    commit_index[lane] = Bits'(owner);
  endtask
  task automatic seed(input int reg_index, input logic [63:0] data);
    clear_inputs();
    writer(0, 7, reg_index);
    tick();
    clear_inputs();
    finish_owner(0, 7, data);
    tick();
    clear_inputs();
    retire(0, 7);
    tick();
    clear_inputs();
  endtask
  task automatic read_arch(input int reg_index, input logic [63:0] expected);
    allocate_uop[0] = '0;
    allocate_uop[0].execute.fp.valid = 1;
    allocate_uop[0].execute.fp.op = `RAPT_FP_OP_FCLASS_D;
    allocate_uop[0].execute.fp.rs1 = 5'(reg_index);
    #1;
    if (allocate_tag[0][0] != 0 || allocate_value[0][0] != expected)
      $fatal(
          1,
          "f%0d read tag=%0d value=%h expected=%h",
          reg_index,
          allocate_tag[0][0],
          allocate_value[0][0],
          expected
      );
  endtask
  initial begin
    clear_inputs();
    repeat (3) tick();
    reset = 0;
    seed(0, 64'h0123456789abcdef);
    seed(1, 64'hfedcba9876543210);
    seed(2, 64'hffffffff3f800000);
    read_arch(0, 64'h0123456789abcdef);

    clear_inputs();
    writer(0, 0, 0);
    writer(1, 1, 1);
    allocate_uop[1].execute.fp.op = `RAPT_FP_OP_FMADD_D;
    allocate_uop[1].execute.fp.rs1 = 0;
    allocate_uop[1].execute.fp.rs2 = 2;
    allocate_uop[1].execute.fp.rs3 = 1;
    #1;
    if (allocate_tag[1][0] != 1 || allocate_tag[1][2] != 0
        || allocate_value[1][2] != 64'hfedcba9876543210)
      $fatal(1, "same-group RAW or FMA third-source WAR capture failed");
    tick();
    clear_inputs();
    writer(0, 2, 0);
    tick();
    clear_inputs();
    finish_owner(0, 2, 64'hbbbbbbbbbbbbbbbb);
    tick();
    clear_inputs();
    read_arch(0, 64'hbbbbbbbbbbbbbbbb);
    read_index[0] = 1;
    #1;
    if (read_tag[0][0] != 1) $fatal(1, "younger WAW completion woke an older dependency");
    finish_owner(0, 0, 64'haaaaaaaaaaaaaaaa);
    #1;
    if (read_tag[0][0] != 0 || read_value[0][0] != 64'haaaaaaaaaaaaaaaa)
      $fatal(1, "dispatch/completion bypass lost the old renamed producer");
    tick();
    clear_inputs();
    retire(0, 0);
    tick();
    clear_inputs();
    read_arch(0, 64'hbbbbbbbbbbbbbbbb);
    if (dut.architectural[0] != 64'haaaaaaaaaaaaaaaa)
      $fatal(1, "speculative WAW escaped in-order architectural commit");
    finish_owner(0, 1, 64'hcccccccccccccccc);
    tick();
    clear_inputs();
    retire(0, 1);
    retire(1, 2);
    tick();
    clear_inputs();
    read_arch(0, 64'hbbbbbbbbbbbbbbbb);
    read_arch(1, 64'hcccccccccccccccc);

    clear_inputs();
    writer(0, 3, 3);
    writer(1, 4, 3);
    tick();
    clear_inputs();
    finish_owner(0, 3, 64'h1111111111111111);
    finish_owner(1, 4, 64'h2222222222222222);
    tick();
    clear_inputs();
    retire(0, 3);
    retire(1, 4);
    tick();
    clear_inputs();
    read_arch(3, 64'h2222222222222222);

    writer(0, 3, 4, 2);
    writer(1, 4, 4, 2);
    tick();
    clear_inputs();
    finish_owner(0, 3, 64'h3333333333333333, 2);
    finish_owner(1, 4, 64'h4444444444444444, 2);
    tick();
    clear_inputs();
    retire(0, 3);
    flush = 1;
    tick();
    flush = 0;
    clear_inputs();
    read_arch(4, 64'h3333333333333333);

    writer(0, 0, 5, 9);
    tick();
    clear_inputs();
    finish_owner(0, 0, 64'hbadbadbadbadbad0, 8);
    tick();
    clear_inputs();
    allocate_uop[0].execute.fp.valid = 1;
    allocate_uop[0].execute.fp.op = `RAPT_FP_OP_FCLASS_D;
    allocate_uop[0].execute.fp.rs1 = 5;
    #1;
    if (allocate_tag[0][0] != 1) $fatal(1, "stale generation completed a reused owner");
    finish_owner(0, 0, 64'h5555555555555555, 9);
    tick();
    clear_inputs();
    retire(0, 0);
    tick();
    clear_inputs();
    read_arch(5, 64'h5555555555555555);
    $display("PASS: FP renaming f0, RAW/WAR/WAW, third source, commit prefix, flush and reuse");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "FP register test timeout");
  end
endmodule
