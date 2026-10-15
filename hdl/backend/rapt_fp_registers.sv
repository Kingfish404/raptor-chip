`include "rapt.svh"

// Implicit physical-register renaming: each live ROB owner has one FLEN=64
// result slot. The speculative map names that owner, while the architectural
// bank changes only at retirement. Allocation records only source tags (zero
// names the architectural bank); a producer's retirement retags its waiting
// consumers to zero. Values are resolved once, on the dispatch lane, from the
// architectural bank, the producer's result slot or this cycle's accepted
// completion, so WAW/WAR chains need no serialization barrier or free list.
// A precise flush keeps committed values and drops the map.
module rapt_fp_registers #(
    parameter type UopT = rapt_pkg::uop_t,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter int Entries = rapt_pkg::CoreConfig.rob_entries,
    parameter int AllocateWidth = rapt_pkg::DispatchWidth,
    parameter int ReadPorts = AllocateWidth,
    parameter int CommitWidth = rapt_pkg::CommitWidth,
    parameter int CompletionPorts = rapt_pkg::CompletionPorts,
    parameter int IndexBits = rapt_pkg::index_bits(Entries),
    parameter int TagBits = IndexBits + 1,
    parameter int GenerationBits = rapt_pkg::CoreConfig.rob_generation_bits,
    parameter bit CompactSourceOperands = 1'b0,
    parameter int OperandEntries = rapt_pkg::CoreConfig.operand_spill_entries,
    parameter int OperandBits = rapt_pkg::index_bits(OperandEntries),
    // Completion ports that may carry fp_wen; each gets one result-file bank.
    parameter logic [31:0] WritePorts = '1
) (
    input logic clock,
    reset,
    flush,
    input logic allocate_valid[AllocateWidth],
    input UopT allocate_uop[AllocateWidth],
    input logic [IndexBits-1:0] allocate_index[AllocateWidth],
    input logic [GenerationBits-1:0] allocate_generation[AllocateWidth],
    // Unresolved source tags: zero reads the architectural bank at dispatch.
    output logic [2:0][TagBits-1:0] allocate_tag[AllocateWidth],
    input logic [IndexBits-1:0] read_index[ReadPorts],
    output logic [2:0][TagBits-1:0] read_tag[ReadPorts],
    // Dispatch-lane value resolution. A returned zero tag means the value is
    // complete; otherwise the destination queue waits for that producer.
    input UopT resolve_uop[ReadPorts],
    input logic [2:0][TagBits-1:0] resolve_tag[ReadPorts],
    output logic [2:0][63:0] resolve_value[ReadPorts],
    output logic [2:0][TagBits-1:0] resolve_ready_tag[ReadPorts],
    input CompletionT completion[CompletionPorts],
    input logic commit_valid[CommitWidth],
    input logic [IndexBits-1:0] commit_index[CommitWidth],
    // Optional physical source slots shared with the ROU operand spill bank.
    // ROB result ownership and the architectural register bank stay ROB-indexed.
    input logic [OperandBits-1:0] operand_allocate_index[AllocateWidth] = '{default: '0},
    input logic operand_release_valid[ReadPorts] = '{default: '0},
    input logic [OperandBits-1:0] operand_release_index[ReadPorts] = '{default: '0},
    input logic operand_read_valid[ReadPorts] = '{default: '0},
    input logic [OperandBits-1:0] operand_read_index[ReadPorts] = '{default: '0}
);
  logic [63:0] architectural[32];
  logic [2:0][63:0] architectural_read[ReadPorts];
  logic [TagBits-1:0] map_q[32], map_next[32];
  logic [63:0] result_q[Entries];
  // Result-file reads: one per resolved source and one per retiring lane.
  logic [63:0] result_resolve[ReadPorts][3];
  logic [63:0] result_commit[CommitWidth];
  logic [Entries-1:0] result_ready, destination_valid, owner_live;
  logic [4:0] destination[Entries];
  logic [GenerationBits-1:0] owner_generation[Entries];
  logic [CompletionPorts-1:0] wake_valid;

  for (genvar p = 0; p < CompletionPorts; p++) begin : g_wake
    wire [IndexBits-1:0] owner = completion[p].dest;
    assign wake_valid[p] = WritePorts[p] && completion[p].valid && completion[p].fp_wen
        && !completion[p].trap && int'(completion[p].dest) < Entries && owner_live[owner]
        && destination_valid[owner] && owner_generation[owner] == completion[p].generation;
  end

  function automatic logic hit(input logic [TagBits-1:0] tag);
    logic found;
    found = 1'b0;
    for (int p = 0; p < CompletionPorts; p++)
    found |= wake_valid[p] && tag == TagBits'(completion[p].dest) + TagBits'(1);
    return tag != '0 && found;
  endfunction
  function automatic logic [63:0] value(input logic [TagBits-1:0] tag, input logic [63:0] fallback);
    logic [63:0] result;
    result = fallback;
    for (int p = 0; p < CompletionPorts; p++)
    if (wake_valid[p] && tag == TagBits'(completion[p].dest) + TagBits'(1))
      result = completion[p].fp_result;
    return result;
  endfunction
  // A retiring producer's consumers read the architectural bank afterwards:
  // no older-than-consumer writer of that register can retire before them.
  function automatic logic retiring(input logic [TagBits-1:0] tag);
    logic found;
    found = 1'b0;
    for (int c = 0; c < CommitWidth; c++)
    found |= commit_valid[c] && TagBits'(commit_index[c]) + TagBits'(1) == tag;
    return tag != '0 && found;
  endfunction
  logic allocate_writer[AllocateWidth];
  // Stored source tags. The architectural bank is written on the retiring
  // edge, so only the stored copy (read next cycle or later) is retagged.
  logic [2:0][TagBits-1:0] stored_tag[AllocateWidth];
  for (genvar s = 0; s < AllocateWidth; s++) begin : g_stored_tag
    for (genvar operand = 0; operand < 3; operand++) begin : g_operand
      assign stored_tag[s][operand] = retiring(
          allocate_tag[s][operand]
      ) ? '0 : allocate_tag[s][operand];
    end
  end
  function automatic logic allocating(input logic [IndexBits-1:0] owner);
    logic found;
    found = 1'b0;
    for (int a = 0; a < AllocateWidth; a++)
    found |= allocate_valid[a] && allocate_writer[a] && allocate_index[a] == owner;
    return found;
  endfunction
  function automatic logic [4:0] source_register(input UopT uop, input int operand);
    case (operand)
      0: return uop.execute.fp.rs1;
      1: return uop.execute.fp.rs2;
      default: return uop.execute.fp.rs3;
    endcase
  endfunction
  for (genvar s = 0; s < AllocateWidth; s++) begin : g_allocate_operands
    wire [2:0] sources = rapt_pkg::fp_sources(
        allocate_uop[s].execute.fp.valid, allocate_uop[s].execute.fp.op, allocate_uop[s].inst
    );
    assign allocate_writer[s] = rapt_pkg::fp_writes_register(
        allocate_uop[s].execute.fp.valid, allocate_uop[s].execute.fp.op, allocate_uop[s].inst
    ) && !allocate_uop[s].trap;
    for (genvar operand = 0; operand < 3; operand++) begin : g_source
      logic [4:0] reg_index;
      logic [TagBits-1:0] tag;
      always_comb begin
        reg_index = source_register(allocate_uop[s], operand);
        tag = map_q[reg_index];
        allocate_tag[s][operand] = '0;
        if (sources[operand]) begin
          allocate_tag[s][operand] = tag;
          // Program-order fold within one allocation group, including f0.
          for (int older = 0; older < s; older++) begin
            if (allocate_valid[older] && allocate_writer[older]
                && allocate_uop[older].execute.fp.rd == reg_index) begin
              allocate_tag[s][operand] = TagBits'(allocate_index[older]) + TagBits'(1);
            end
          end
        end
      end
    end
  end

  always_comb begin
    for (int r = 0; r < 32; r++) begin
      map_next[r] = map_q[r];
      for (int c = 0; c < CommitWidth; c++)
      if (commit_valid[c] && destination_valid[commit_index[c]]
            && destination[commit_index[c]] == 5'(r)
            && map_q[r] == TagBits'(commit_index[c]) + TagBits'(1))
        map_next[r] = '0;
      for (int s = 0; s < AllocateWidth; s++)
      if (allocate_valid[s] && allocate_writer[s] && allocate_uop[s].execute.fp.rd == 5'(r))
        map_next[r] = TagBits'(allocate_index[s]) + TagBits'(1);
      if (flush) map_next[r] = '0;
    end
  end

  // The speculative map is independent of the committed data bank.
  for (genvar r = 0; r < 32; r++) begin : g_map
    always_ff @(posedge clock) begin
      if (reset) map_q[r] <= '0;
      else map_q[r] <= map_next[r];
    end
  end

  if (`RAPT_FPGA_LUTRAM) begin : g_arch_lutram
    // One physical write port per commit lane. The small last-writer table
    // selects the youngest same-group commit, including f0. A reset-valid
    // bit supplies zero without resetting the RAM payload. Retirement on
    // a redirect edge remains architectural, so flush never gates writes.
    localparam int LaneBits = CommitWidth > 1 ? $clog2(CommitWidth) : 1;
    logic [31:0] valid_q;
    logic [LaneBits-1:0] lane_q[32];
    logic write_valid[CommitWidth];
    logic [4:0] write_index[CommitWidth];
    logic [63:0] write_value[CommitWidth];
    logic [63:0] bank_read[ReadPorts][3][CommitWidth];
`ifndef SYNTHESIS
    logic [63:0] debug_word[32][CommitWidth];
`endif
    for (genvar c = 0; c < CommitWidth; c++) begin : g_write_lane
      assign write_valid[c] = commit_valid[c] && destination_valid[commit_index[c]];
      assign write_index[c] = destination[commit_index[c]];
      assign write_value[c] = result_commit[c];
      for (genvar s = 0; s < ReadPorts; s++) begin : g_read_copy
        for (genvar operand = 0; operand < 3; operand++) begin : g_operand
          (* ram_style = "distributed" *) logic [63:0] words[32];
          always_ff @(posedge clock)
            if (!reset && write_valid[c])
              words[write_index[c]] <= write_value[c];
          assign bank_read[s][operand][c] = words[source_register(resolve_uop[s], operand)];
          // Preserve the existing internal verification view. It has no
          // functional consumers in this branch and is pruned in synthesis.
`ifndef SYNTHESIS
          if (s == 0 && operand == 0) begin : g_debug_view
            for (genvar r = 0; r < 32; r++) assign debug_word[r][c] = words[r];
          end
`endif
        end
      end
    end
    for (genvar r = 0; r < 32; r++) begin : g_last_writer
      always_ff @(posedge clock) begin
        if (reset) valid_q[r] <= 1'b0;
        else begin
          for (int c = 0; c < CommitWidth; c++)
          if (write_valid[c] && write_index[c] == 5'(r)) begin
            valid_q[r] <= 1'b1;
            lane_q[r] <= LaneBits'(c);
          end
        end
      end
`ifndef SYNTHESIS
      assign architectural[r] = valid_q[r] ? debug_word[r][lane_q[r]] : '0;
`endif
    end
    for (genvar s = 0; s < ReadPorts; s++) begin : g_resolve_read
      for (genvar operand = 0; operand < 3; operand++) begin : g_operand
        wire [4:0] reg_index = source_register(resolve_uop[s], operand);
        assign architectural_read[s][operand] = valid_q[reg_index]
            ? bank_read[s][operand][lane_q[reg_index]] : '0;
      end
    end
  end else begin : g_arch_flops
    // Keep the original flop implementation for non-FPGA configurations.
    for (genvar r = 0; r < 32; r++) begin : g_word
      always_ff @(posedge clock) begin
        if (reset) architectural[r] <= '0;
        else begin
          for (int c = 0; c < CommitWidth; c++)
          if (commit_valid[c] && destination_valid[commit_index[c]]
                && destination[commit_index[c]] == 5'(r))
            architectural[r] <= result_commit[c];
        end
      end
    end
    for (genvar s = 0; s < ReadPorts; s++) begin : g_resolve_read
      for (genvar operand = 0; operand < 3; operand++) begin : g_operand
        assign architectural_read[s][operand] = architectural[source_register(
            resolve_uop[s], operand
        )];
      end
    end
  end
  for (genvar e = 0; e < Entries; e++) begin : g_owner
    always_ff @(posedge clock) begin
      if (reset || flush) begin
        owner_live[e] <= 1'b0;
        result_ready[e] <= 1'b0;
        destination_valid[e] <= 1'b0;
      end else begin
        for (int c = 0; c < CommitWidth; c++)
        if (commit_valid[c] && commit_index[c] == IndexBits'(e)) owner_live[e] <= 1'b0;
        for (int p = 0; p < CompletionPorts; p++)
        if (wake_valid[p] && completion[p].dest == IndexBits'(e)) result_ready[e] <= 1'b1;
        for (int s = 0; s < AllocateWidth; s++)
        if (allocate_valid[s] && allocate_index[s] == IndexBits'(e)) begin
          owner_live[e] <= 1'b1;
          owner_generation[e] <= allocate_generation[s];
          destination_valid[e] <= allocate_writer[s];
          destination[e] <= allocate_uop[s].execute.fp.rd;
          result_ready[e] <= 1'b0;
        end
      end
    end
  end
  if (`RAPT_FPGA_LUTRAM) begin : g_result_lutram
    // One distributed-RAM bank per FP writer port and one copy per read; a
    // live-value table names the bank holding each owner's result.
    localparam int PortBits = CompletionPorts > 1 ? $clog2(CompletionPorts) : 1;
    localparam int Reads = ReadPorts * 3 + CommitWidth;
    logic [PortBits-1:0] lvt[Entries];
    logic [IndexBits-1:0] read_addr[Reads];
    logic [63:0] bank_read[Reads][CompletionPorts];
    logic [63:0] read_data[Reads];
    for (genvar p = 0; p < CompletionPorts; p++) begin : g_port
      if (WritePorts[p]) begin : g_bank
        for (genvar r = 0; r < Reads; r++) begin : g_copy
          (* ram_style = "distributed" *) logic [63:0] words[Entries];
          always_ff @(posedge clock)
            if (!(reset || flush) && wake_valid[p])
              words[completion[p].dest] <= completion[p].fp_result;
          assign bank_read[r][p] = words[read_addr[r]];
        end
      end else begin : g_no_bank
        for (genvar r = 0; r < Reads; r++) begin : g_zero
          assign bank_read[r][p] = '0;
        end
      end
    end
    // The highest writer wins, matching the flop file's port order.
    for (genvar e = 0; e < Entries; e++) begin : g_lvt
      always_ff @(posedge clock) begin
        if (!(reset || flush)) begin
          for (int p = 0; p < CompletionPorts; p++)
          if (WritePorts[p] && wake_valid[p] && completion[p].dest == IndexBits'(e))
            lvt[e] <= PortBits'(p);
        end
      end
    end
    for (genvar s = 0; s < ReadPorts; s++) begin : g_resolve_addr
      for (genvar operand = 0; operand < 3; operand++) begin : g_operand
        assign read_addr[s*3+operand] = IndexBits'(resolve_tag[s][operand] - TagBits'(1));
        assign result_resolve[s][operand] = read_data[s*3+operand];
      end
    end
    for (genvar c = 0; c < CommitWidth; c++) begin : g_commit_addr
      assign read_addr[ReadPorts*3+c] = commit_index[c];
      assign result_commit[c] = read_data[ReadPorts*3+c];
    end
    for (genvar r = 0; r < Reads; r++) begin : g_read
      assign read_data[r] = bank_read[r][lvt[read_addr[r]]];
    end
`ifndef SYNTHESIS
    // Owner-indexed view for module checks.
    for (genvar e = 0; e < Entries; e++) begin : g_view
      logic [63:0] port_word[CompletionPorts];
      for (genvar p = 0; p < CompletionPorts; p++) begin : g_port_word
        if (WritePorts[p]) begin : g_bank_word
          assign port_word[p] = g_port[p].g_bank.g_copy[0].words[e];
        end else begin : g_zero_word
          assign port_word[p] = '0;
        end
      end
      assign result_q[e] = port_word[lvt[e]];
    end
`endif
  end else begin : g_result_flops
    for (genvar e = 0; e < Entries; e++) begin : g_entry
      always_ff @(posedge clock) begin
        if (!(reset || flush)) begin
          for (int p = 0; p < CompletionPorts; p++)
          if (wake_valid[p] && completion[p].dest == IndexBits'(e))
            result_q[e] <= completion[p].fp_result;
        end
      end
    end
    for (genvar s = 0; s < ReadPorts; s++) begin : g_resolve_read
      for (genvar operand = 0; operand < 3; operand++) begin : g_operand
        assign result_resolve[s][operand] = result_q[IndexBits'(resolve_tag[s][operand] - TagBits'(1))];
      end
    end
    for (genvar c = 0; c < CommitWidth; c++) begin : g_commit_read
      assign result_commit[c] = result_q[commit_index[c]];
    end
  end
  // Each source slot holds only its producer tag. Retirement and completion
  // never move data into it; only the retiring producer clears the tag.
  if (CompactSourceOperands) begin : g_compact_sources
    // A source tag is only read while its consumer waits in ROB_DP. Give it
    // the same physical lifetime as integer operands and immutable fields.
    typedef logic [2:0][TagBits-1:0] source_payload_t;
    source_payload_t allocate_payload[AllocateWidth], read_payload[ReadPorts];
    source_payload_t update_payload[OperandEntries], entry_payload[OperandEntries];
    logic allocate_ready[AllocateWidth];
    logic [OperandBits-1:0] source_allocate_index[AllocateWidth];
    logic read_valid[ReadPorts];
    logic update_valid[OperandEntries], entry_valid[OperandEntries];
    for (genvar a = 0; a < AllocateWidth; a++) begin : g_allocate
      assign allocate_payload[a] = stored_tag[a];
      `RAPT_SVA_IMPLY(clock, reset || flush, FP_SOURCE_SPILL_ALLOCATION_MATCH, allocate_valid[a],
                      allocate_ready[a] && source_allocate_index[a] == operand_allocate_index[a])
    end
    for (genvar e = 0; e < OperandEntries; e++) begin : g_entry
      always_comb begin
        update_payload[e] = entry_payload[e];
        update_valid[e] = 1'b0;
        for (int operand = 0; operand < 3; operand++) begin
          if (entry_valid[e] && retiring(entry_payload[e][operand])) begin
            update_valid[e] = 1'b1;
            update_payload[e][operand] = '0;
          end
        end
      end
    end
    rapt_operand_spill #(
        .PayloadT(source_payload_t),
        .Entries(OperandEntries),
        .AllocateWidth(AllocateWidth),
        .ReleaseWidth(ReadPorts),
        .ReadPorts(ReadPorts),
        .IndexBits(OperandBits)
    ) storage (
        .clock,
        .reset,
        .flush,
        .allocate_valid,
        .allocate_payload,
        .allocate_ready,
        .allocate_index(source_allocate_index),
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
    for (genvar p = 0; p < ReadPorts; p++) begin : g_read
      // A producer retiring on this edge still owns its result slot now.
      assign read_tag[p] = read_payload[p];
      `RAPT_SVA_IMPLY(clock, reset || flush, FP_SOURCE_SPILL_READ_LIVE, operand_read_valid[p],
                      read_valid[p])
    end
  end else begin : g_rob_sources
    logic [2:0][TagBits-1:0] source_tag[Entries];
    for (genvar e = 0; e < Entries; e++) begin : g_owner
      always_ff @(posedge clock) begin
        if (!(reset || flush)) begin
          for (int operand = 0; operand < 3; operand++)
          if (owner_live[e] && retiring(source_tag[e][operand])) source_tag[e][operand] <= '0;
          for (int s = 0; s < AllocateWidth; s++)
          if (allocate_valid[s] && allocate_index[s] == IndexBits'(e))
            source_tag[e] <= stored_tag[s];
        end
      end
    end
    for (genvar p = 0; p < ReadPorts; p++) begin : g_read
      assign read_tag[p] = source_tag[read_index[p]];
    end
  end
  // Dispatch-lane resolution: architectural bank for a zero tag, else this
  // cycle's accepted completion or the producer's completed result slot.
  for (genvar p = 0; p < ReadPorts; p++) begin : g_resolve
    wire [2:0] sources = rapt_pkg::fp_sources(
        resolve_uop[p].execute.fp.valid, resolve_uop[p].execute.fp.op, resolve_uop[p].inst
    );
    for (genvar operand = 0; operand < 3; operand++) begin : g_operand
      wire [TagBits-1:0] tag = resolve_tag[p][operand];
      wire [IndexBits-1:0] producer = IndexBits'(tag - TagBits'(1));
      always_comb begin
        resolve_value[p][operand] = '0;
        resolve_ready_tag[p][operand] = '0;
        if (tag == '0) begin
          if (sources[operand]) resolve_value[p][operand] = architectural_read[p][operand];
        end else begin
          // A same-group producer allocated on this edge is never ready; its
          // slot may still carry the retired previous owner's result.
          resolve_value[p][operand] = value(tag, result_resolve[p][operand]);
          if (!(owner_live[producer] && (result_ready[producer] || hit(tag))))
            resolve_ready_tag[p][operand] = tag;
        end
      end
      `RAPT_SVA_IMPLY(clock, reset || flush, FP_RESOLVE_PRODUCER_LIVE, tag != '0,
                      owner_live[producer] && destination_valid[producer] || allocating(producer))
    end
  end
  for (genvar c = 0; c < CommitWidth; c++) begin : g_commit_contract
    `RAPT_SVA_IMPLY(clock, reset, FP_COMMIT_HAS_RESULT,
                    commit_valid[c] && destination_valid[commit_index[c]],
                    owner_live[commit_index[c]] && result_ready[commit_index[c]])
  end
endmodule
