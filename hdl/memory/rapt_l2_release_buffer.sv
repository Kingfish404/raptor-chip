// Two in-flight L1D release lists share BOOM's lowest-free beat pool.
// RV64 has 16 shared beats and RV32 has 32. Keep beats until ReleaseAck so
// a failed nested refill can replay the same ReleaseData without a new C.
module rapt_l2_release_buffer #(
    parameter int Xlen = 64,
    parameter int LineBytes = 64,
    parameter int LineWords = LineBytes / (Xlen / 8),
    parameter int WordBits = $clog2(LineWords),
    parameter int PoolBeats = 2 * LineWords,
    parameter int EntryBits = $clog2(PoolBeats)
) (
    input logic clock,
    input logic reset,
    input logic push_valid,
    output logic push_ready,
    input logic [Xlen-1:0] push_addr,
    input logic [Xlen-1:0] push_data,
    input logic push_has_data,
    input logic push_mask,
    input logic push_last,
    output logic busy_o,
    output logic head_valid,
    output logic head_complete,
    input logic head_pop,
    output logic [Xlen-1:0] head_addr,
    output logic head_has_data,
    input logic [WordBits-1:0] head_word,
    output logic head_word_valid,
    output logic [Xlen-1:0] head_data,
    output logic head_mask
);
  localparam int OffsetBits = $clog2(LineBytes);
  logic [1:0] occupied, complete;
  logic write_list, read_list, receiving;
  logic [WordBits-1:0] write_word;
  // Release requests identify whole cache lines; byte-offset bits are fixed.
  logic [Xlen-1:OffsetBits] addr[2];
  logic has_data[2];
  logic [Xlen-1:0] data[PoolBeats];
  logic mask[PoolBeats];
  logic [EntryBits-1:0] entry_index[2][LineWords];
  logic [PoolBeats-1:0] used, used_clear;
  logic [EntryBits-1:0] free_index;
  logic free_found, data_push;
  logic [LineWords-1:0] word_valid[2];
  logic push_fire;
  logic first_beat_bypass;

  if (!(Xlen inside {32, 64}) || LineBytes < Xlen / 8
      || (LineBytes & (LineBytes - 1)) != 0 || LineWords < 2
      || (LineWords & (LineWords - 1)) != 0)
    $error("invalid L2 release buffer geometry");

  if (PoolBeats != 2 * LineWords) $error("L2 Release pool must hold two full lines");

  // ListBuffer chooses the lowest free entry from pre-edge occupancy. A
  // pop on this edge cannot make a full pool ready combinationally.
  always_comb begin
    free_found = 1'b0;
    free_index = '0;
    for (int entry = PoolBeats - 1; entry >= 0; entry--) begin
      if (!used[entry]) begin
        free_found = 1'b1;
        free_index = EntryBits'(entry);
      end
    end
    used_clear = '0;
    for (int word = 0; word < LineWords; word++) begin
      if (head_pop && head_valid && word_valid[read_list][word])
        used_clear[entry_index[read_list][word]] = 1'b1;
    end
  end

  assign push_ready = (receiving || !occupied[write_list])
      && (!push_valid || !push_has_data || free_found);
  assign push_fire = push_valid && push_ready;
  assign data_push = push_fire && push_has_data;
  assign first_beat_bypass = push_fire && !receiving && write_list == read_list
      && !occupied[read_list];
  assign busy_o = |occupied;
  // SinkC presents a Release request on its first C beat. Keep the data
  // beats independently valid so the consumer can start the directory
  // lookup immediately and then wait for each not-yet-arrived word.
  assign head_valid = occupied[read_list] || first_beat_bypass;
  assign head_complete = complete[read_list];
  assign head_addr = {first_beat_bypass ? push_addr[Xlen-1:OffsetBits] : addr[read_list],
                      {OffsetBits{1'b0}}};
  assign head_has_data = first_beat_bypass ? push_has_data : has_data[read_list];
  assign head_word_valid = first_beat_bypass && head_word == '0 || word_valid[read_list][head_word];
  assign head_data = first_beat_bypass ? push_data : data[entry_index[read_list][head_word]];
  assign head_mask = first_beat_bypass ? push_mask : mask[entry_index[read_list][head_word]];

  always_ff @(posedge clock) begin
    if (reset) begin
      occupied   <= '0;
      complete   <= '0;
      write_list <= 1'b0;
      read_list  <= 1'b0;
      receiving  <= 1'b0;
      write_word <= '0;
      used <= '0;
      for (int list = 0; list < 2; list++) word_valid[list] <= '0;
    end else begin
      used <= (used & ~used_clear) | (data_push ? (PoolBeats'(1) << free_index) : '0);
      if (push_fire) begin
        if (!receiving) begin
          addr[write_list] <= push_addr[Xlen-1:OffsetBits];
          has_data[write_list] <= push_has_data;
          occupied[write_list] <= 1'b1;
          write_word <= WordBits'(1);
          word_valid[write_list] <= push_has_data
              ? {{(LineWords - 1) {1'b0}}, 1'b1} : '0;
        end else begin
          write_word <= write_word + 1'b1;
          if (push_has_data) word_valid[write_list][write_word] <= 1'b1;
        end
        if (push_has_data) begin
          data[free_index] <= push_data;
          mask[free_index] <= push_mask;
          entry_index[write_list][receiving ? write_word : '0] <= free_index;
        end
        if (push_last) begin
          complete[write_list] <= 1'b1;
          receiving <= 1'b0;
          write_list <= ~write_list;
        end else receiving <= 1'b1;
      end
      if (head_pop && head_valid) begin
        occupied[read_list] <= 1'b0;
        complete[read_list] <= 1'b0;
        word_valid[read_list] <= '0;
        read_list <= ~read_list;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset) begin
      assert (!(head_pop && !head_complete));
      if (push_fire) begin
        assert (!receiving || push_addr[Xlen-1:OffsetBits] == addr[write_list]);
        assert (!receiving || push_has_data == has_data[write_list]);
        assert (!push_has_data || push_last == (receiving && &write_word));
        assert (push_has_data || (!receiving && push_last && !push_mask));
      end
    end
  end
`endif
endmodule
