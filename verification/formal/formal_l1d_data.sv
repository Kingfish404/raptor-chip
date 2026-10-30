// Architectural-byte history versus the real diagonal SRAM banks. Observer
// coordinates are stable; transactions and initial storage remain arbitrary.
module formal_l1d_data #(
    parameter int Xlen = 32,
    parameter int SetBits = 1,
    parameter int WordBits = 2,
    parameter int Ways = 2,
    parameter int LineWords = 2 ** WordBits,
    parameter int WayBits = Ways > 1 ? $clog2(Ways) : 1,
    parameter int WordBytes = Xlen / 8,
    parameter int ChunkWords = 64 / Xlen,
    parameter int Chunks = LineWords / ChunkWords,
    parameter int Banks = ((Ways + Chunks - 1) / Chunks) * Chunks,
    parameter int GroupWays = Ways < Chunks ? Ways : Chunks,
    parameter int RowBits = $clog2(GroupWays),
    parameter int AddrBits = SetBits + RowBits
) (
    input logic clock,
    reset,
    input logic [SetBits-1:0] read_addr,
    write_addr,
    watched_set,
    input logic [WordBits-1:0] read_word,
    write_word,
    watched_word,
    input logic [WayBits-1:0] read_way,
    write_way,
    watched_way,
    input logic [$clog2(WordBytes)-1:0] watched_byte,
    input logic read_line,
    write_valid,
    write_blocked,
    write_line,
    input logic [Xlen-1:0] write_data,
    input logic [WordBytes-1:0] write_strobe,
    input logic [LineWords-1:0] write_mask,
    input logic [LineWords*Xlen-1:0] write_line_data
);
  wire [SetBits-1:0] read_index;
  wire [WordBits-1:0] read_word_index;
  wire [Banks-1:0] read_bank_valid;
  wire [63:0] read_data[Banks];
  wire read_line_valid;
  wire [LineWords*Xlen-1:0] read_line_data;
  rapt_l1d_data #(
      .Xlen(Xlen),
      .SetBits(SetBits),
      .WordBits(WordBits),
      .Ways(Ways)
  ) dut (
      .*
  );

  // Forward map from architectural way/chunk, independently of the DUT's
  // inverse lane-to-chunk arithmetic and compact-row addressing.
  function automatic int bank_of(input int way, chunk);
    return (way / Chunks) * Chunks + (way + chunk) % Chunks;
  endfunction
  wire [AddrBits-1:0] observed_row = AddrBits'(
      int'(watched_set) * GroupWays + (int'(watched_word) / ChunkWords) % GroupWays);
  wire [2:0] observed_byte_lane = 3'(
      (int'(watched_word) % ChunkWords) * WordBytes + int'(watched_byte));
  wire [7:0] physical_byte[Banks];
  // Per-run include selects behavioral storage or the ideal macro stub.
  `include "formal_l1d_data_observe.svh"
  wire [7:0] actual_byte = physical_byte[bank_of(
      int'(watched_way), int'(watched_word) / ChunkWords)];
  wire [7:0] output_byte = read_data[bank_of(
      int'(watched_way), int'(watched_word) / ChunkWords)][observed_byte_lane*8+:8];

  logic [Banks-1:0] intended_write;
  always_comb begin
    intended_write = '0;
    for (int chunk = 0; chunk < Chunks; chunk++) begin
      for (int word_in_chunk = 0; word_in_chunk < ChunkWords; word_in_chunk++) begin
        if (write_valid && (write_line
            ? write_mask[chunk*ChunkWords+word_in_chunk]
            : int'(write_word) == chunk*ChunkWords+word_in_chunk && |write_strobe))
          intended_write[bank_of(int'(write_way), chunk)] = 1;
      end
    end
  end
  wire selected_byte = write_valid && write_addr == watched_set && write_way == watched_way
      && (write_line ? write_mask[watched_word]
          : write_word == watched_word && write_strobe[watched_byte]);
  wire [7:0] incoming_byte = write_line
      ? write_line_data[int'(watched_word)*Xlen+int'(watched_byte)*8+:8]
      : write_data[int'(watched_byte)*8+:8];
  wire bank_reserved = intended_write[bank_of(
      int'(watched_way), int'(watched_word) / ChunkWords)];
  wire reading_owner = read_addr == watched_set && (read_line
      ? read_way == watched_way
      : int'(read_word) / ChunkWords == int'(watched_word) / ChunkWords);

  logic [7:0] expected_byte, expected_output, previous_output;
  logic known = 0, output_known = 0, read_owned = 0;
  logic past_valid = 0, held_q;
  logic [SetBits-1:0] expected_read_index;
  logic [WordBits-1:0] expected_word_index;
  logic [Banks-1:0] expected_valid;
  logic expected_line_valid;
  logic [WayBits-1:0] previous_read_way;
  logic partial_word_seen = 0, partial_line_seen = 0, full_line_seen = 0;
  logic blocked_seen = 0, reset_write_seen = 0, cross_group_q;
  logic line_conflict;
  always_comb begin
    line_conflict = 0;
    for (int chunk = 0; chunk < Chunks; chunk++)
    line_conflict |= intended_write[bank_of(int'(read_way), chunk)];
  end

  always_ff @(posedge clock) begin
    if (past_valid)
      assume ({watched_set, watched_way, watched_word, watched_byte} == $past(
          {watched_set, watched_way, watched_word, watched_byte}
      ));
    assume (int'(watched_way) < Ways);
    assume (int'(read_way) < Ways && int'(write_way) < Ways);
    past_valid <= 1;
    if (selected_byte && !write_blocked) begin
      expected_byte <= incoming_byte;
      known <= 1;
      if (!write_line && !(&write_strobe)) partial_word_seen <= 1;
      if (write_line && !(&write_mask)) partial_line_seen <= 1;
      if (write_line && &write_mask) full_line_seen <= 1;
      if (reset) reset_write_seen <= 1;
    end
    if (known && selected_byte && write_blocked && incoming_byte != expected_byte)
      blocked_seen <= 1;
    if (!bank_reserved) begin
      expected_output <= expected_byte;
      output_known <= known;
      read_owned <= reading_owner;
    end
    previous_output <= output_byte;
    held_q <= bank_reserved;
    expected_read_index <= read_addr;
    expected_word_index <= read_word;
    expected_valid <= {Banks{!reset}} & ~intended_write;
    expected_line_valid <= !reset && read_line && !line_conflict;
    previous_read_way <= read_way;
    cross_group_q <= read_line && write_valid && !write_blocked && |intended_write
        && int'(read_way) / Chunks != int'(write_way) / Chunks;

    if (known) tracked_storage : assert (actual_byte == expected_byte);
    if (read_owned && output_known) tracked_read : assert (output_byte == expected_output);
    if (past_valid) begin
      read_address_latency : assert (read_index == expected_read_index);
      read_word_latency : assert (read_word_index == expected_word_index);
      bank_availability : assert (read_bank_valid == expected_valid);
      line_availability : assert (read_line_valid == expected_line_valid);
      if (held_q) reserved_output_hold : assert (output_byte == previous_output);
      if (read_line_valid && previous_read_way == watched_way && read_owned && output_known)
        assembled_line :
        assert (read_line_data[int'(watched_word)*Xlen+int'(watched_byte)*8+:8] == expected_output);
    end
    word_partial_read : cover (read_owned && output_known && partial_word_seen && !reset);
    line_partial_read :
    cover (read_owned && output_known && partial_line_seen && read_line_valid && !reset);
    line_full_read :
    cover (read_owned && output_known && full_line_seen && read_line_valid && !reset);
    blocked_write_read : cover (read_owned && output_known && blocked_seen && !reset);
    reset_preserves_written_data : cover (read_owned && output_known && reset_write_seen && !reset);
    held_on_reserved_bank : cover (read_owned && output_known && held_q && !reset);
    if (Ways > Chunks)
      independent_group_read_write :
      cover (read_owned && output_known && read_line_valid && cross_group_q && !reset);
  end
  for (genvar bank = 0; bank < Banks; bank++) begin : g_bank_cover
    always_ff @(posedge clock)
      all_banks :
      cover (read_owned && output_known && bank_of(
          int'(watched_way), int'(watched_word) / ChunkWords
      ) == bank && !reset);
  end
  for (genvar byte_lane = 0; byte_lane < WordBytes; byte_lane++) begin : g_byte_cover
    always_ff @(posedge clock)
      all_byte_lanes :
      cover (read_owned && output_known && int'(watched_byte) == byte_lane && !reset);
  end
  if (ChunkWords == 2) begin : g_half_cover
    for (genvar half = 0; half < 2; half++) begin : g_half
      always_ff @(posedge clock)
        both_rv32_words :
        cover (read_owned && output_known && int'(watched_word) % 2 == half && !reset);
    end
  end
endmodule
