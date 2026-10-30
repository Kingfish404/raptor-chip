`include "rapt.svh"

// The independent flop payload is the pre-banking reference. Every occupied
// physical word must agree, strengthening the public FIFO equivalence proof.
module formal_stream_queue #(
    parameter int Depth = 8,
    parameter int InWidth = 4,
    parameter int OutWidth = 4,
    parameter int ItemBits = 8,
    parameter bit ReclaimSameCycle = 0
) (
    input logic clock,
    reset,
    flush,
    input logic [ItemBits-1:0] in_data[InWidth],
    input logic [rapt_pkg::index_bits(ItemBits)-1:0] observed_bit,
    input logic in_valid[InWidth],
    input logic out_ready[OutWidth]
);
  typedef logic [ItemBits-1:0] ItemT;
  localparam int PtrBits = rapt_pkg::index_bits(Depth);
  localparam int Lanes = InWidth > OutWidth ? InWidth : OutWidth;
  localparam int Banks = Depth % Lanes == 0 ? Lanes : 2 ** $clog2(Lanes);
  localparam bit BankPayload = Depth > 1 && Depth % Banks == 0;
  localparam bit BlockPayload = `RAPT_FPGA_STREAM_BRAM && !ReclaimSameCycle
      && InWidth == OutWidth && InWidth >= 4 && Depth >= 2 * InWidth
      && (Depth & (Depth - 1)) == 0 && (InWidth & (InWidth - 1)) == 0;
  ItemT out_data[OutWidth], reference_data[OutWidth];
  logic in_ready[InWidth], out_valid[OutWidth];
  logic reference_ready[InWidth], reference_valid[OutWidth];
  logic [$clog2(Depth+1)-1:0] occupancy, reference_occupancy;
  rapt_stream_queue #(
      .ItemT(ItemT),
      .Depth(Depth),
      .InWidth(InWidth),
      .OutWidth(OutWidth),
      .ReclaimSameCycle(ReclaimSameCycle)
  ) dut (
      .*
  );
  stream_queue_shadow #(
      .ItemT(ItemT),
      .Depth(Depth),
      .InWidth(InWidth),
      .OutWidth(OutWidth),
      .ReclaimSameCycle(ReclaimSameCycle)
  ) reference (
      .clock,
      .reset,
      .flush,
      .in_data,
      .in_valid,
      .in_ready(reference_ready),
      .out_data(reference_data),
      .out_valid(reference_valid),
      .out_ready,
      .occupancy(reference_occupancy)
  );
  logic past_valid = 0;
  logic [Depth-1:0] known = '0;
  logic seen_full = 0, seen_push = 0, seen_wrap = 0, seen_flush = 0;
  logic [PtrBits-1:0] previous_tail;
  always_ff @(posedge clock) begin
    if (!past_valid) assume (reset);
    // A stable, universally quantified bit proves transport for the whole word
    // without asking the solver to repeat the same data-independent argument.
    assume (int'(observed_bit) < ItemBits);
    if (past_valid) assume (observed_bit == $past(observed_bit));
    past_valid <= 1;
    previous_tail <= reference.tail;
    if (reset || flush) known <= '0;
    else begin
      for (int s = 0; s < InWidth; s++) begin
        if (s < reference.push_count) known[reference.push_index[s]] <= 1;
      end
    end
    if (reset) begin
      seen_full <= 0;
      seen_push <= 0;
      seen_wrap <= 0;
      seen_flush <= 0;
    end else begin
      if (int'(reference_occupancy) == Depth) seen_full <= 1;
      if (reference.push_count != 0) seen_push <= 1;
      if (reference.tail < previous_tail && seen_push) seen_wrap <= 1;
      if (flush && seen_push) seen_flush <= 1;
    end
    if (past_valid) begin
      same_occupancy : assert (occupancy == reference_occupancy);
      same_head : assert (dut.head == reference.head);
      same_tail : assert (dut.tail == reference.tail);
      capacity : assert (int'(reference_occupancy) <= Depth);
      pointer_range : assert (int'(reference.head) < Depth && int'(reference.tail) < Depth);
      pointer_occupancy :
      assert (reference.tail == PtrBits'(
          (int'(reference.head) + int'(reference_occupancy)) % Depth
      ));
    end
    full_and_stalled :
    cover (past_valid && seen_full && reference.pop_count == 0 && !reset && !flush);
    if (ReclaimSameCycle || Depth > 1)
      simultaneous_transfer :
      cover (past_valid && reference.push_count != 0 && reference.pop_count != 0 && !reset && !flush);
    if (Depth > 1)
      wrap_after_full :
      cover (past_valid && seen_full && seen_wrap && reference.pop_count != 0 && !reset && !flush);
    flush_after_data :
    cover (past_valid && seen_flush && reference_occupancy == 0 && !reset && !flush);
  end
  for (genvar s = 0; s < InWidth; s++) begin : g_input
    always_ff @(posedge clock) if (past_valid) assert (in_ready[s] == reference_ready[s]);
  end
  for (genvar s = 0; s < OutWidth; s++) begin : g_output
    always_ff @(posedge clock) begin
      if (past_valid) begin
        assert (out_valid[s] == reference_valid[s]);
        if (reference_valid[s])
          assert (out_data[s][observed_bit] == reference_data[s][observed_bit]);
      end
      all_output_lanes :
      cover (past_valid && reference_valid[s] && out_ready[s] && !reset && !flush);
    end
  end
  if (BlockPayload) begin : g_prefetch
    localparam int BankBits = $clog2(InWidth);
    for (genvar b = 0; b < InWidth; b++) begin : g_bank
      wire [BankBits-1:0] slot = BankBits'(b) - BankBits'(reference.head);
      wire [PtrBits-1:0] index = reference.head + PtrBits'(slot);
      wire [ItemBits-1:0] data = dut.g_block_payload.bank_data[b];
      // Prove the prefetched row even outside the occupied prefix. This is a
      // lemma, not an assumption about RAM contents or pipeline progress.
      always_ff @(posedge clock) begin
        if (past_valid && known[index])
          assert (data[observed_bit] == reference.g_flop_payload.storage[index][observed_bit]);
      end
    end
  end
  for (genvar e = 0; e < Depth; e++) begin : g_word
    wire [ItemBits-1:0] actual;
    if (BlockPayload) begin : g_block
      assign actual = dut.g_block_payload.g_bank[e%InWidth].words[e/InWidth];
    end else if (BankPayload) begin : g_banked
      assign actual = dut.g_banked_payload.g_bank[e%Banks].words[e/Banks];
    end else begin : g_flop
      assign actual = dut.g_flop_payload.storage[e];
    end
    always_ff @(posedge clock) begin
      if (known[e])
        stored_word :
        assert (actual[observed_bit] == reference.g_flop_payload.storage[e][observed_bit]);
    end
  end
  for (genvar age = 0; age < Depth; age++) begin : g_occupied
    wire [PtrBits-1:0] index = PtrBits'((int'(reference.head) + age) % Depth);
    always_ff @(posedge clock) begin
      if (past_valid && age < int'(reference_occupancy)) assert (known[index]);
    end
  end
endmodule
