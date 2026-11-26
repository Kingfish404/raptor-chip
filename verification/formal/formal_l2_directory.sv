// Formal full-array equivalence contract for rapt_l2_directory.
// Compares reset wipe, single-port write-queue bypass, read lookups,
// scan reads, and clear_set ordering against a golden directory model.
module formal_l2_directory #(
    parameter int SetBits = 2,
    parameter int Ways = 4,
    parameter int TagBits = 4,
    parameter int ClientBits = 1,
    parameter int WayBits = (Ways <= 1) ? 1 : $clog2(Ways),
    parameter int EntryBits = TagBits + ClientBits + 3
) (
    input logic clock,
    input logic reset,
    input logic read_valid,
    input logic [SetBits-1:0] read_set,
    input logic [TagBits-1:0] read_tag,
    input logic scan_valid,
    input logic [SetBits-1:0] scan_set,
    input logic clear_valid,
    input logic [SetBits-1:0] clear_set,
    input logic write_valid,
    input logic [SetBits-1:0] write_set,
    input logic [WayBits-1:0] write_way,
    input logic [TagBits-1:0] write_tag,
    input logic [ClientBits-1:0] write_clients,
    input logic [1:0] write_state,
    input logic write_dirty
);
  localparam int NSets = 1 << SetBits;
  localparam logic [1:0] Invalid = 2'b00;

  logic ready, read_ready, result_valid, result_hit;
  logic [WayBits-1:0] result_way;
  logic [TagBits-1:0] result_tag;
  logic [ClientBits-1:0] result_clients;
  logic [1:0] result_state;
  logic result_dirty;
  logic scan_ready, scan_result_valid;
  logic [Ways*EntryBits-1:0] scan_entries;
  logic clear_ready, write_ready;

  rapt_l2_directory #(
      .SetBits(SetBits),
      .Ways(Ways),
      .TagBits(TagBits),
      .ClientBits(ClientBits)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock,
      .reset,
      .ready,
      .read_valid,
      .read_ready,
      .read_set,
      .read_tag,
      .result_valid,
      .result_hit,
      .result_way,
      .result_tag,
      .result_clients,
      .result_state,
      .result_dirty,
      .scan_valid,
      .scan_ready,
      .scan_set,
      .scan_result_valid,
      .scan_entries,
      .clear_valid,
      .clear_ready,
      .clear_set,
      .write_valid,
      .write_ready,
      .write_set,
      .write_way,
      .write_tag,
      .write_clients,
      .write_state,
      .write_dirty
  );

  logic past_valid = 1'b0;
  logic [EntryBits-1:0] ref_dir[NSets][Ways];
  logic [SetBits:0] reset_cycles;

  // Expected read result registered at read_fire.
  logic exp_read_valid;
  logic exp_read_hit;
  logic [WayBits-1:0] exp_read_hit_way;
  logic [EntryBits-1:0] exp_read_set_entries[Ways];
  logic [TagBits-1:0] exp_read_tag_q;

  // Expected scan result registered at scan_fire.
  logic exp_scan_valid;
  logic [EntryBits-1:0] exp_scan_entries[Ways];

  wire read_fire = read_valid && read_ready;
  wire scan_fire = scan_valid && scan_ready;
  wire clear_fire = clear_valid && clear_ready;
  wire write_fire = write_valid && write_ready;

  // Post-write architectural view seen by a same-edge read/scan.
  logic [EntryBits-1:0] eff_read_entries[Ways];
  logic [EntryBits-1:0] eff_scan_entries[Ways];
  logic dup_valid_tag_write;
  always_comb begin
    dup_valid_tag_write = 1'b0;
    for (int w = 0; w < Ways; w++) begin
      if (write_state != Invalid && w != int'(write_way)
          && ref_dir[write_set][w][TagBits+ClientBits+1:TagBits+ClientBits] != Invalid
          && ref_dir[write_set][w][TagBits-1:0] == write_tag) begin
        dup_valid_tag_write = 1'b1;
      end
      eff_read_entries[w] = (write_fire && write_set == read_set && WayBits'(w) == write_way)
          ? {write_dirty, write_state, write_clients, write_tag}
          : ref_dir[read_set][w];
      eff_scan_entries[w] = (write_fire && write_set == scan_set && WayBits'(w) == write_way)
          ? {write_dirty, write_state, write_clients, write_tag}
          : ref_dir[scan_set][w];
    end
  end

  logic next_read_hit;
  logic [WayBits-1:0] next_read_hit_way;
  always_comb begin
    next_read_hit = 1'b0;
    next_read_hit_way = '0;
    for (int w = 0; w < Ways; w++) begin
      if (eff_read_entries[w][TagBits+ClientBits+1:TagBits+ClientBits] != Invalid
          && eff_read_entries[w][TagBits-1:0] == read_tag) begin
        next_read_hit = 1'b1;
        next_read_hit_way = WayBits'(w);
      end
    end
  end

  always_comb begin
    if (!past_valid) assume (reset);
    // Caller contract: never install a duplicate valid tag in another way.
    if (!reset && write_valid) assume (!dup_valid_tag_write);
  end

  always_ff @(posedge clock) begin
    past_valid <= 1'b1;
    if (reset) begin
      reset_cycles <= '0;
      exp_read_valid <= 1'b0;
      exp_read_hit <= 1'b0;
      exp_read_hit_way <= '0;
      exp_read_tag_q <= '0;
      exp_scan_valid <= 1'b0;
      for (int s = 0; s < NSets; s++) begin
        for (int w = 0; w < Ways; w++) ref_dir[s][w] <= '0;
      end
    end else begin
      if (!ready) begin
        reset_cycles <= reset_cycles + 1'b1;
        no_ops_during_wipe : assert (!read_ready && !scan_ready && !clear_ready && !write_ready);
      end else begin
        wipe_took_exact_sets : assert (reset_cycles == (SetBits + 1)'(NSets));
      end

      // Mutual exclusion: clear cannot execute alongside read, scan, or write.
      clear_excl : assert (!(clear_fire && (read_fire || scan_fire || write_fire)));
      scan_read_excl : assert (!(scan_fire && read_fire));

      // Verify read result against golden directory.
      read_valid_match : assert (result_valid == exp_read_valid);
      if (result_valid) begin
        read_hit_match : assert (result_hit == exp_read_hit);
        if (exp_read_hit) begin
          read_hit_way_match : assert (result_way == exp_read_hit_way);
          read_hit_entry_match :
          assert (
              {result_dirty, result_state, result_clients, result_tag}
              == exp_read_set_entries[exp_read_hit_way]
          );
        end else begin
          read_miss_entry_match :
          assert (
              {result_dirty, result_state, result_clients, result_tag}
              == exp_read_set_entries[result_way]
          );
        end
      end

      // Verify scan result against golden directory across all ways.
      scan_valid_match : assert (scan_result_valid == exp_scan_valid);
      if (scan_result_valid) begin
        for (int w = 0; w < Ways; w++) begin
          scan_entry_match : assert (scan_entries[w*EntryBits+:EntryBits] == exp_scan_entries[w]);
        end
      end

      // Update golden model.
      if (clear_fire) begin
        for (int w = 0; w < Ways; w++) ref_dir[clear_set][w] <= '0;
      end
      if (write_fire) begin
        ref_dir[write_set][write_way] <= {write_dirty, write_state, write_clients, write_tag};
      end

      exp_read_valid <= read_fire;
      if (read_fire) begin
        exp_read_hit <= next_read_hit;
        exp_read_hit_way <= next_read_hit_way;
        exp_read_tag_q <= read_tag;
        for (int w = 0; w < Ways; w++) exp_read_set_entries[w] <= eff_read_entries[w];
      end

      exp_scan_valid <= scan_fire;
      if (scan_fire) begin
        for (int w = 0; w < Ways; w++) exp_scan_entries[w] <= eff_scan_entries[w];
      end

      // Cover bypass, invalidate-reuse, scan-bypass, and clear-after-write.
      cov_same_cycle_bypass_hit :
      cover (
          read_fire && write_fire && write_set == read_set && write_state != Invalid
          && write_tag == read_tag
      );
      cov_inval_reuse :
      cover (
          read_fire && write_fire && write_set == read_set && write_state == Invalid
          && write_tag == read_tag
      );
      cov_scan_after_write : cover (scan_fire && write_fire && write_set == scan_set);
      cov_clear_after_write : cover (clear_fire);
    end
  end
endmodule
