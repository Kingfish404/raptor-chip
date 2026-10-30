`include "rapt.svh"

// Ordered instruction stream, not a queue of indivisible fetch/rename groups.
// Valid inputs and accepted outputs are contiguous prefixes. No fall-through:
// storage decouples producer data from consumer selection. Flush cancels both.
module rapt_stream_queue #(
    parameter type ItemT = logic [31:0],
    parameter int Depth = 8,
    parameter int InWidth = 2,
    parameter int OutWidth = 2,
    parameter bit ReclaimSameCycle = 1'b1
) (
    input logic clock,
    reset,
    flush,
    input ItemT in_data[InWidth],
    input logic in_valid[InWidth],
    output logic in_ready[InWidth],
    output ItemT out_data[OutWidth],
    output logic out_valid[OutWidth],
    input logic out_ready[OutWidth],
    output logic [$clog2(Depth+1)-1:0] occupancy
);
  localparam int PtrBits = rapt_pkg::index_bits(Depth);
  // Registered-capacity boundaries avoid a combinational ready path through
  // the banked RAM prefetch. Equal power-of-two lane counts give each bank at
  // most one read and one write per cycle.
  localparam bit BlockPayload = `RAPT_FPGA_STREAM_BRAM && !ReclaimSameCycle &&
      InWidth == OutWidth && InWidth >= 4 && Depth >= 2 * InWidth &&
      (Depth & (Depth - 1)) == 0 && (InWidth & (InWidth - 1)) == 0;
  localparam int Lanes = InWidth > OutWidth ? InWidth : OutWidth;
  // The bank count must divide Depth: otherwise a group crossing the physical
  // end can access a bank twice. Width three/depth eight uses four banks;
  // width three/depth six uses three. Other geometries retain the flop path.
  localparam int Banks = Depth % Lanes == 0 ? Lanes : 2 ** $clog2(Lanes);
  localparam bit BankPayload = Depth > 1 && Depth % Banks == 0;
  logic [PtrBits-1:0] head, tail;
  int unsigned push_count, pop_count;
  function automatic int unsigned advance(input int unsigned ptr, input int unsigned amount);
    int unsigned sum;
    // Reachable pointers are below Depth and each advance is at most Depth.
    // One subtraction suffices, including non-power-of-two depths.
    sum = ptr + amount;
    return sum >= Depth ? sum - Depth : sum;
  endfunction
  if (!(Depth > 0 && InWidth > 0 && OutWidth > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_stream_queue configuration");
  end
  if (!(Depth >= InWidth && Depth >= OutWidth)) begin : g_invalid_config_1
    $error("Invalid rapt_stream_queue configuration");
  end
  for (genvar s = 0; s < OutWidth; s++) begin : g_read
    assign out_valid[s] = !flush && !reset && int'(occupancy) > s;
  end
  // Transfers are contiguous prefixes; each count is the leading run length.
  logic [OutWidth-1:0] pop_prefix;
  for (genvar s = 0; s < OutWidth; s++) begin : g_pop_prefix
    if (s == 0) begin : g_first
      assign pop_prefix[s] = out_valid[s] && out_ready[s];
    end else begin : g_next
      assign pop_prefix[s] = pop_prefix[s-1] && out_valid[s] && out_ready[s];
    end
  end
  assign pop_count = $countones(pop_prefix);
  // ReclaimSameCycle preserves the normal full-rate queue contract.  Pipeline
  // boundaries that participate in a wider ready/flush feedback path can turn
  // it off so readiness depends only on registered occupancy.
  for (genvar s = 0; s < InWidth; s++) begin : g_ready
    assign in_ready[s] = !flush && !reset
        && s < Depth - int'(occupancy) + (ReclaimSameCycle ? pop_count : 0);
  end
  logic [InWidth-1:0] push_prefix;
  for (genvar s = 0; s < InWidth; s++) begin : g_push_prefix
    if (s == 0) begin : g_first
      assign push_prefix[s] = in_valid[s] && in_ready[s];
    end else begin : g_next
      assign push_prefix[s] = push_prefix[s-1] && in_valid[s] && in_ready[s];
    end
  end
  assign push_count = $countones(push_prefix);
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      head <= '0;
      tail <= '0;
      occupancy <= '0;
    end else begin
      head <= PtrBits'(advance(int'(head), pop_count));
      tail <= PtrBits'(advance(int'(tail), push_count));
      occupancy <= $clog2(Depth + 1)'(int'(occupancy) + push_count - pop_count);
    end
  end
  if (BlockPayload) begin : g_block_payload
    localparam int BlockBanks = InWidth;
    localparam int BankBits = $clog2(BlockBanks);
    localparam int Rows = Depth / BlockBanks;
    localparam int RowBits = $clog2(Rows);
    localparam int ItemBits = $bits(ItemT);
    logic [PtrBits-1:0] next_head;
    logic [ItemBits-1:0] bank_data[BlockBanks];
    // Read the next visible group on this edge so outputs still have the
    // original queue's cycle latency. Forward a same-address enqueue because
    // the block RAM's read-during-write result is vendor dependent.
    assign next_head = (reset || flush) ? '0 : head + PtrBits'(pop_count);
    for (genvar b = 0; b < BlockBanks; b++) begin : g_bank
      (* ram_style = "block" *) logic [ItemBits-1:0] words[Rows];
      logic [BankBits-1:0] read_slot, write_slot;
      logic [PtrBits-1:0] read_index, write_index;
      logic [RowBits-1:0] read_row, write_row;
      logic [ItemBits-1:0] read_q, forward_q;
      logic write_en, forward_q_valid, collision;
      assign read_slot = BankBits'(b) - next_head[BankBits-1:0];
      assign read_index = next_head + PtrBits'(read_slot);
      assign read_row = read_index[PtrBits-1:BankBits];
      assign write_slot = BankBits'(b) - tail[BankBits-1:0];
      assign write_index = tail + PtrBits'(write_slot);
      assign write_row = write_index[PtrBits-1:BankBits];
      assign write_en = !reset && !flush && int'(write_slot) < push_count;
      assign collision = write_en && read_row == write_row;
      always_ff @(posedge clock) begin
        read_q <= words[read_row];
        if (write_en) words[write_row] <= ItemBits'(in_data[write_slot]);
      end
      always_ff @(posedge clock) begin
        if (reset || flush) forward_q_valid <= 1'b0;
        else forward_q_valid <= collision;
        if (collision) forward_q <= ItemBits'(in_data[write_slot]);
      end
      assign bank_data[b] = forward_q_valid ? forward_q : read_q;
    end
    for (genvar s = 0; s < OutWidth; s++) begin : g_output
      assign out_data[s] = ItemT'(bank_data[BankBits'(head[BankBits-1:0]+BankBits'(s))]);
    end
  end else if (BankPayload) begin : g_banked_payload
    localparam int BankBits = rapt_pkg::index_bits(Banks);
    localparam int Rows = Depth / Banks;
    localparam int RowBits = rapt_pkg::index_bits(Rows);
    localparam int ItemBits = $bits(ItemT);
    logic [ItemBits-1:0] bank_data[Banks];
    logic [BankBits-1:0] head_bank, tail_bank;
    logic [RowBits-1:0] head_row, tail_row, next_head_row, next_tail_row;
    assign head_bank = BankBits'(int'(head) % Banks);
    assign tail_bank = BankBits'(int'(tail) % Banks);
    assign head_row = RowBits'(int'(head) / Banks);
    assign tail_row = RowBits'(int'(tail) / Banks);
    assign next_head_row = head_row == RowBits'(Rows - 1) ? '0 : head_row + 1'b1;
    assign next_tail_row = tail_row == RowBits'(Rows - 1) ? '0 : tail_row + 1'b1;
    // Entry e is bank e % Banks, row e / Banks. Rotate lanes before storage
    // so each bank has one indexed writer and one asynchronous read. Neither
    // reset nor flush touches payload; the existing pointers/occupancy hide it.
    for (genvar b = 0; b < Banks; b++) begin : g_bank
      // Keep the stored word integral even when ItemT is a packed struct.
      logic [ItemBits-1:0] words[Rows];
      logic [BankBits-1:0] write_slot;
      logic [RowBits-1:0] read_row, write_row;
      logic write_en;
      if (b == Banks - 1) begin : g_last
        assign write_slot = BankBits'(b) - tail_bank;
        assign read_row = head_row;
        assign write_row = tail_row;
      end else begin : g_wrap
        assign write_slot = tail_bank <= BankBits'(b) ? BankBits'(b) - tail_bank :
            BankBits'(b + Banks) - tail_bank;
        assign read_row = head_bank > BankBits'(b) ? next_head_row : head_row;
        assign write_row = tail_bank > BankBits'(b) ? next_tail_row : tail_row;
      end
      assign write_en = !reset && !flush && int'(write_slot) < push_count;
      always_ff @(posedge clock) begin
        if (write_en) words[write_row] <= ItemBits'(in_data[write_slot]);
      end
      assign bank_data[b] = words[read_row];
    end
    for (genvar s = 0; s < OutWidth; s++) begin : g_output
      logic [BankBits:0] bank_sum;
      logic [BankBits-1:0] bank_index;
      assign bank_sum = {1'b0, head_bank} + (BankBits + 1)'(s);
      assign bank_index = bank_sum >= (BankBits + 1)'(Banks) ?
          BankBits'(bank_sum - (BankBits + 1)'(Banks)) : BankBits'(bank_sum);
      assign out_data[s] = ItemT'(bank_data[bank_index]);
    end
  end else begin : g_flop_payload
    // Each entry owns its storage update. Accepted slots have distinct indices;
    // enqueue replaces a reclaimed entry after its old value is consumed.
    ItemT storage[Depth];
    logic [PtrBits-1:0] push_index[InWidth];
    for (genvar s = 0; s < InWidth; s++) begin : g_write_index
      assign push_index[s] = PtrBits'(advance(int'(tail), s));
    end
    for (genvar s = 0; s < OutWidth; s++) begin : g_read
      assign out_data[s] = storage[advance(int'(head), s)];
    end
    for (genvar e = 0; e < Depth; e++) begin : g_entry
      always_ff @(posedge clock) begin
        if (!reset && !flush) begin
          for (int s = 0; s < InWidth; s++)
          if (s < push_count && push_index[s] == PtrBits'(e)) storage[e] <= in_data[s];
        end
      end
    end
  end
  for (genvar s = 1; s < InWidth; s++) begin : g_input_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, STREAM_INPUT_PREFIX, in_valid[s], in_valid[s-1])
  end
  for (genvar s = 1; s < OutWidth; s++) begin : g_output_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, STREAM_ACCEPT_PREFIX, out_valid[s] && out_ready[s],
                    out_valid[s-1] && out_ready[s-1])
  end
  `RAPT_SVA(clock, reset, STREAM_CAPACITY, int'(occupancy) <= Depth)
  `RAPT_SVA(clock, reset, STREAM_POINTER_RANGE, int'(head) < Depth && int'(tail) < Depth)
endmodule
