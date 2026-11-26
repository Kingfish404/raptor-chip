// Formal equivalence and stall-stability contract for rapt_l2_data_array.
// Tracks one symbolic (set, way, chunk) word against the bank priority order
// (SinkC > SourceC > SinkD > buffered line write > SourceD-write > read) and
// proves source_c_read_data stability across arbitrary downstream stalls.
module formal_l2_data_array #(
    parameter int SetBits = 2
) (
    input logic clock,
    input logic reset,
    input logic [SetBits-1:0] watched_set,
    input logic [2:0] watched_way,
    input logic [2:0] watched_chunk,
    input logic read_valid,
    input logic read_all_chunks,
    input logic [SetBits-1:0] read_set,
    input logic [2:0] read_way,
    input logic [2:0] read_chunk,
    input logic source_c_read_valid,
    input logic [SetBits-1:0] source_c_read_set,
    input logic [2:0] source_c_read_way,
    input logic [2:0] source_c_read_chunk,
    input logic sink_d_write_valid,
    input logic [SetBits-1:0] sink_d_write_set,
    input logic [2:0] sink_d_write_way,
    input logic [2:0] sink_d_write_chunk,
    input logic [63:0] sink_d_write_data,
    input logic [7:0] sink_d_write_mask,
    input logic write_line_valid,
    input logic [SetBits-1:0] write_line_set,
    input logic [2:0] write_line_way,
    input logic [511:0] write_line_data,
    input logic priority_write_valid,
    input logic [SetBits-1:0] priority_write_set,
    input logic [2:0] priority_write_way,
    input logic [2:0] priority_write_chunk,
    input logic [63:0] priority_write_data,
    input logic [7:0] priority_write_mask,
    input logic write_word_valid,
    input logic [SetBits-1:0] write_word_set,
    input logic [2:0] write_word_way,
    input logic [2:0] write_word_chunk,
    input logic [63:0] write_word_data,
    input logic [7:0] write_word_mask
);
  logic read_ready, read_result_valid;
  logic [511:0] read_line_data;
  logic source_c_read_ready, source_c_result_valid;
  logic [63:0] source_c_read_data;
  logic sink_d_write_ready, write_line_busy, write_word_ready;

  rapt_l2_data_array #(
      .SetBits(SetBits)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock,
      .reset,
      .read_valid,
      .read_all_chunks,
      .read_ready,
      .read_set,
      .read_way,
      .read_chunk,
      .read_result_valid,
      .read_line_data,
      .source_c_read_valid,
      .source_c_read_ready,
      .source_c_read_set,
      .source_c_read_way,
      .source_c_read_chunk,
      .source_c_result_valid,
      .source_c_read_data,
      .sink_d_write_valid,
      .sink_d_write_ready,
      .sink_d_write_set,
      .sink_d_write_way,
      .sink_d_write_chunk,
      .sink_d_write_data,
      .sink_d_write_mask,
      .write_line_valid,
      .write_line_busy,
      .write_line_set,
      .write_line_way,
      .write_line_data,
      .priority_write_valid,
      .priority_write_set,
      .priority_write_way,
      .priority_write_chunk,
      .priority_write_data,
      .priority_write_mask,
      .write_word_valid,
      .write_word_ready,
      .write_word_set,
      .write_word_way,
      .write_word_chunk,
      .write_word_data,
      .write_word_mask
  );

  function automatic logic [63:0] merge_bytes(input logic [63:0] old_word,
                                              input logic [63:0] new_word, input logic [7:0] mask);
    logic [63:0] out;
    out = old_word;
    for (int i = 0; i < 8; i++) begin
      if (mask[i]) out[i*8+:8] = new_word[i*8+:8];
    end
    return out;
  endfunction

  logic past_valid = 1'b0;
  logic [SetBits-1:0] watched_set_q;
  logic [2:0] watched_way_q, watched_chunk_q;
  logic [63:0] expected_word;
  logic [7:0] known_bytes;

  // Shadow of buffered line-write state to track exact chunk acceptance.
  logic sh_line_active;
  logic [SetBits-1:0] sh_line_set;
  logic [2:0] sh_line_way;
  logic [2:0] sh_line_chunk;
  logic [511:0] sh_line_data;

  // Shadow for source_c result and stall-hold check.
  logic sc_ever_valid;
  logic sc_watched_q;
  logic [63:0] sc_expected_q;
  logic [7:0] sc_known_q;
  logic [63:0] sc_prev_data;

  // Shadow for scalar and full-line reads.
  logic rd_full_pending;
  logic [SetBits-1:0] rd_full_set_q;
  logic [2:0] rd_full_way_q;
  logic [63:0] rd_full_first_expected_q;
  logic [7:0] rd_full_first_known_q;
  logic rd_watched_q;
  logic [63:0] rd_expected_q;
  logic [7:0] rd_known_q;

  // Track source_c stall duration for cover.
  logic [2:0] sc_stall_cycles;
  logic sc_other_bank_write_during_stall;

  wire sc_fire = source_c_read_valid && source_c_read_ready;
  wire sd_fire = sink_d_write_valid && sink_d_write_ready;
  wire ww_fire = write_word_valid && write_word_ready;
  wire [2:0] cur_line_chunk = sh_line_active ? sh_line_chunk : 3'd0;
  wire cur_line_issue = write_line_valid || sh_line_active;
  wire cur_line_fire = cur_line_issue
      && !(priority_write_valid && priority_write_chunk[1:0] == cur_line_chunk[1:0])
      && !(source_c_read_valid && source_c_read_chunk[1:0] == cur_line_chunk[1:0])
      && !(sink_d_write_valid && sink_d_write_chunk[1:0] == cur_line_chunk[1:0]);
  wire [SetBits-1:0] cur_line_set = sh_line_active ? sh_line_set : write_line_set;
  wire [2:0] cur_line_way = sh_line_active ? sh_line_way : write_line_way;
  wire [63:0] cur_line_word = sh_line_active
      ? sh_line_data[int'(sh_line_chunk)*64+:64] : write_line_data[63:0];

  wire prio_hits_watched = priority_write_valid && priority_write_set == watched_set
      && priority_write_way == watched_way && priority_write_chunk == watched_chunk;
  wire sd_hits_watched = sd_fire && sink_d_write_set == watched_set
      && sink_d_write_way == watched_way && sink_d_write_chunk == watched_chunk;
  wire line_hits_watched = cur_line_fire && cur_line_set == watched_set
      && cur_line_way == watched_way && cur_line_chunk == watched_chunk;
  wire ww_hits_watched = ww_fire && write_word_set == watched_set
      && write_word_way == watched_way && write_word_chunk == watched_chunk;

  wire rd_no_conflict = !(read_all_chunks && cur_line_issue)
      && !(cur_line_issue && cur_line_chunk[1:0] == read_chunk[1:0])
      && !(sink_d_write_valid && (read_all_chunks
                                  || sink_d_write_chunk[1:0] == read_chunk[1:0]))
      && !(source_c_read_valid && (read_all_chunks
                                   || source_c_read_chunk[1:0] == read_chunk[1:0]))
      && !(priority_write_valid && (read_all_chunks
                                    || priority_write_chunk[1:0] == read_chunk[1:0]))
      && !(write_word_valid && (read_all_chunks
                                || write_word_chunk[1:0] == read_chunk[1:0]));
  wire rd_scalar_fire = read_valid && !read_all_chunks && !rd_full_pending && read_ready;
  wire rd_full_start = read_valid && read_all_chunks && !rd_full_pending && rd_no_conflict;
  wire rd_full_finish = read_valid && read_all_chunks && rd_full_pending && read_ready;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      // Caller contract: never overlap a new line install while busy.
      assume (!(write_line_busy && write_line_valid));
      // Caller contract: keep full-line read target stable across its two rows.
      if (rd_full_pending && read_valid) begin
        assume (read_all_chunks);
        assume (read_set == rd_full_set_q);
        assume (read_way == rd_full_way_q);
      end
    end
  end

  always_ff @(posedge clock) begin
    if (past_valid) begin
      assume (watched_set == watched_set_q);
      assume (watched_way == watched_way_q);
      assume (watched_chunk == watched_chunk_q);
    end
    watched_set_q <= watched_set;
    watched_way_q <= watched_way;
    watched_chunk_q <= watched_chunk;
    past_valid <= 1'b1;

    if (reset) begin
      expected_word <= '0;
      known_bytes <= '0;
      sh_line_active <= 1'b0;
      sh_line_set <= '0;
      sh_line_way <= '0;
      sh_line_chunk <= '0;
      sh_line_data <= '0;
      sc_ever_valid <= 1'b0;
      sc_watched_q <= 1'b0;
      sc_expected_q <= '0;
      sc_known_q <= '0;
      sc_prev_data <= '0;
      rd_full_pending <= 1'b0;
      rd_full_set_q <= '0;
      rd_full_way_q <= '0;
      rd_full_first_expected_q <= '0;
      rd_full_first_known_q <= '0;
      rd_watched_q <= 1'b0;
      rd_expected_q <= '0;
      rd_known_q <= '0;
      sc_stall_cycles <= '0;
      sc_other_bank_write_during_stall <= 1'b0;
    end else begin
      // Exact priority and busy checks.
      busy_matches : assert (write_line_busy == sh_line_active);
      sc_ready_spec :
      assert (source_c_read_ready == !(priority_write_valid
          && priority_write_chunk[1:0] == source_c_read_chunk[1:0]));
      sd_ready_spec :
      assert (sink_d_write_ready == (!(priority_write_valid
          && priority_write_chunk[1:0] == sink_d_write_chunk[1:0])
          && !(source_c_read_valid
               && source_c_read_chunk[1:0] == sink_d_write_chunk[1:0])));
      // Mutual exclusion: at most one writer can hit the watched word per edge.
      one_writer_watched :
      assert (
          (int'(prio_hits_watched) + int'(sd_hits_watched)
           + int'(line_hits_watched) + int'(ww_hits_watched)) <= 1
      );

      // Update golden word for watched coordinates.
      if (prio_hits_watched) begin
        expected_word <= merge_bytes(expected_word, priority_write_data, priority_write_mask);
        known_bytes <= known_bytes | priority_write_mask;
      end else if (sd_hits_watched) begin
        expected_word <= merge_bytes(expected_word, sink_d_write_data, sink_d_write_mask);
        known_bytes <= known_bytes | sink_d_write_mask;
      end else if (line_hits_watched) begin
        expected_word <= cur_line_word;
        known_bytes <= 8'hff;
      end else if (ww_hits_watched) begin
        expected_word <= merge_bytes(expected_word, write_word_data, write_word_mask);
        known_bytes <= known_bytes | write_word_mask;
      end

      // Update shadow line-write FSM.
      if (write_line_valid) begin
        sh_line_set <= write_line_set;
        sh_line_way <= write_line_way;
        sh_line_data <= write_line_data;
        sh_line_active <= 1'b1;
        sh_line_chunk <= cur_line_fire ? 3'd1 : 3'd0;
      end else if (sh_line_active) begin
        if (cur_line_fire) begin
          if (sh_line_chunk == 3'd7) sh_line_active <= 1'b0;
          else sh_line_chunk <= sh_line_chunk + 1'b1;
        end
      end

      // Check SourceC read exactness and hold stability across stalls.
      if (sc_ever_valid && !source_c_result_valid) begin
        sc_data_held_on_stall : assert (source_c_read_data == sc_prev_data);
      end
      if (source_c_result_valid && sc_watched_q) begin
        for (int b = 0; b < 8; b++) begin
          if (sc_known_q[b]) begin
            sc_read_matches : assert (source_c_read_data[b*8+:8] == sc_expected_q[b*8+:8]);
          end
        end
      end
      if (sc_ever_valid && sc_watched_q && !source_c_result_valid) begin
        for (int b = 0; b < 8; b++) begin
          if (sc_known_q[b]) begin
            sc_held_matches : assert (source_c_read_data[b*8+:8] == sc_expected_q[b*8+:8]);
          end
        end
      end
      if (source_c_result_valid) begin
        sc_ever_valid <= 1'b1;
        sc_prev_data <= source_c_read_data;
      end
      if (sc_fire) begin
        sc_watched_q <= source_c_read_set == watched_set
            && source_c_read_way == watched_way
            && source_c_read_chunk == watched_chunk;
        sc_expected_q <= expected_word;
        sc_known_q <= known_bytes;
        sc_stall_cycles <= '0;
        sc_other_bank_write_during_stall <= 1'b0;
      end else if (sc_ever_valid) begin
        if (sc_stall_cycles != 3'd7) sc_stall_cycles <= sc_stall_cycles + 1'b1;
        if (priority_write_valid || sd_fire || cur_line_fire || ww_fire)
          sc_other_bank_write_during_stall <= 1'b1;
      end

      // Check scalar and full-line read exactness.
      if (read_result_valid && rd_watched_q) begin
        for (int b = 0; b < 8; b++) begin
          if (rd_known_q[b]) begin
            rd_data_matches :
            assert (read_line_data[int'(watched_chunk)*64+b*8+:8] == rd_expected_q[b*8+:8]);
          end
        end
      end
      if (!read_valid) rd_full_pending <= 1'b0;
      else if (rd_full_start) begin
        rd_full_pending <= 1'b1;
        rd_full_set_q <= read_set;
        rd_full_way_q <= read_way;
        rd_full_first_expected_q <= expected_word;
        rd_full_first_known_q <= known_bytes;
      end else if (rd_full_finish) begin
        rd_full_pending <= 1'b0;
      end

      if (rd_scalar_fire) begin
        rd_watched_q <= read_set == watched_set && read_way == watched_way
            && read_chunk == watched_chunk;
        rd_expected_q <= expected_word;
        rd_known_q <= known_bytes;
      end else if (rd_full_finish) begin
        rd_watched_q <= read_set == watched_set && read_way == watched_way;
        if (!watched_chunk[2]) begin
          rd_expected_q <= rd_full_first_expected_q;
          rd_known_q <= rd_full_first_known_q;
        end else begin
          rd_expected_q <= expected_word;
          rd_known_q <= known_bytes;
        end
      end else begin
        rd_watched_q <= 1'b0;
      end

      // Meaningful cover scenarios.
      cov_sc_stall_with_write :
      cover (
          sc_ever_valid && sc_watched_q && &sc_known_q && !source_c_result_valid
          && sc_stall_cycles >= 3'd3 && sc_other_bank_write_during_stall
      );
      cov_full_line_read_hi :
      cover (read_result_valid && rd_watched_q && watched_chunk[2] && &rd_known_q);
      cov_full_line_read_lo :
      cover (read_result_valid && rd_watched_q && !watched_chunk[2] && &rd_known_q);
      cov_line_install_finish : cover (sh_line_active && cur_line_fire && sh_line_chunk == 3'd7);
    end
  end
endmodule
