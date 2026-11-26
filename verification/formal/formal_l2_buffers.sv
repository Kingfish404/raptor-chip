// Formal verification harnesses for rapt_l2_put_buffer, rapt_l2_release_buffer,
// and rapt_l2_secondary_buffer: exact FIFO ordering, linked-list pool
// conservation, simultaneous push/pop on 1-element lists, and leak freedom.
module formal_l2_put_buffer #(
    parameter int Xlen = 32,
    parameter int NumLists = 4,
    parameter int NumBeats = 6,
    parameter int ListBits = $clog2(NumLists)
) (
    input logic clock,
    input logic reset,
    input logic [ListBits-1:0] watched_list,
    input logic push_valid,
    input logic [ListBits-1:0] push_list,
    input logic [Xlen-1:0] push_data,
    input logic [Xlen/8-1:0] push_mask,
    input logic push_last,
    input logic pop_valid,
    input logic [ListBits-1:0] pop_list
);
  localparam int BeatW = Xlen + Xlen / 8 + 1;

  logic push_ready;
  logic [Xlen-1:0] pop_data;
  logic [Xlen/8-1:0] pop_mask;
  logic pop_last;
  logic [NumLists-1:0] list_valid;

  rapt_l2_put_buffer #(
      .Xlen(Xlen),
      .NumLists(NumLists),
      .NumBeats(NumBeats)
  ) dut (
      .clock,
      .reset,
      .push_valid,
      .push_ready,
      .push_list,
      .push_data,
      .push_mask,
      .push_last,
      .pop_valid,
      .pop_list,
      .pop_data,
      .pop_mask,
      .pop_last,
      .list_valid
  );

  logic past_valid = 1'b0;
  logic [ListBits-1:0] watched_list_q;
  logic [BeatW-1:0] q_mem[NumBeats];
  logic [$clog2(NumBeats+1)-1:0] q_cnt, total_cnt;
  logic [$clog2(NumBeats+1)-1:0] list_cnt[NumLists];

  wire push_fire = push_valid && push_ready;
  wire watch_push = push_fire && push_list == watched_list;
  wire watch_pop = pop_valid && pop_list == watched_list;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      assume (!push_valid || int'(push_list) < NumLists);
      assume (!pop_valid || (int'(pop_list) < NumLists && list_valid[pop_list]));
      assume (int'(watched_list) < NumLists);
    end
  end

  always_ff @(posedge clock) begin
    if (past_valid) assume (watched_list == watched_list_q);
    watched_list_q <= watched_list;
    past_valid <= 1'b1;

    if (reset) begin
      q_cnt <= '0;
      total_cnt <= '0;
      for (int i = 0; i < NumLists; i++) list_cnt[i] <= '0;
    end else begin
      // Global occupancy and non-flowing ready contract.
      ready_exact : assert (push_ready == (int'(total_cnt) < NumBeats));
      watched_valid_exact : assert (list_valid[watched_list] == (q_cnt != 0));
      for (int i = 0; i < NumLists; i++) begin
        all_valid_exact : assert (list_valid[i] == (list_cnt[i] != 0));
      end

      // Exact FIFO head check for watched_list.
      if (watch_pop) begin
        pop_matches_fifo : assert ({pop_data, pop_mask, pop_last} == q_mem[0]);
      end

      // Update global and per-list counts.
      total_cnt <= total_cnt + (push_fire ? 1'b1 : 1'b0) - (pop_valid ? 1'b1 : 1'b0);
      for (int i = 0; i < NumLists; i++) begin
        list_cnt[i] <= list_cnt[i]
            + ((push_fire && push_list == ListBits'(i)) ? 1'b1 : 1'b0)
            - ((pop_valid && pop_list == ListBits'(i)) ? 1'b1 : 1'b0);
      end

      // Update watched_list shadow FIFO.
      if (watch_pop && watch_push) begin
        for (int i = 0; i < NumBeats - 1; i++) q_mem[i] <= q_mem[i+1];
        q_mem[q_cnt-1] <= {push_data, push_mask, push_last};
      end else if (watch_pop) begin
        for (int i = 0; i < NumBeats - 1; i++) q_mem[i] <= q_mem[i+1];
        q_cnt <= q_cnt - 1'b1;
      end else if (watch_push) begin
        q_mem[q_cnt] <= {push_data, push_mask, push_last};
        q_cnt <= q_cnt + 1'b1;
      end

      cov_full_pool : cover (int'(total_cnt) == NumBeats && !push_ready);
      cov_same_list_single_push_pop : cover (watch_pop && watch_push && q_cnt == 1);
      cov_same_list_multi_push_pop : cover (watch_pop && watch_push && q_cnt >= 2);
      cov_drain_to_empty : cover (pop_valid && total_cnt == 1);
    end
  end
endmodule

module formal_l2_release_buffer #(
    parameter int Xlen = 32,
    parameter int LineBytes = 16,
    parameter int LineWords = LineBytes / (Xlen / 8),
    parameter int WordBits = $clog2(LineWords)
) (
    input logic clock,
    input logic reset,
    input logic push_valid,
    input logic [Xlen-1:0] push_addr,
    input logic [Xlen-1:0] push_data,
    input logic push_has_data,
    input logic push_mask,
    input logic push_last,
    input logic head_pop,
    input logic [WordBits-1:0] head_word
);
  localparam int OffsetBits = $clog2(LineBytes);

  logic push_ready, busy_o, head_valid, head_complete, head_has_data;
  logic [Xlen-1:0] head_addr, head_data;
  logic head_word_valid, head_mask;

  rapt_l2_release_buffer #(
      .Xlen(Xlen),
      .LineBytes(LineBytes)
  ) dut (
      .clock,
      .reset,
      .push_valid,
      .push_ready,
      .push_addr,
      .push_data,
      .push_has_data,
      .push_mask,
      .push_last,
      .busy_o,
      .head_valid,
      .head_complete,
      .head_pop,
      .head_addr,
      .head_has_data,
      .head_word,
      .head_word_valid,
      .head_data,
      .head_mask
  );

  logic past_valid = 1'b0;
  logic [1:0] sh_occ, sh_comp;
  logic sh_wlist, sh_rlist, sh_recv;
  logic [WordBits-1:0] sh_wword;
  logic [Xlen-1:OffsetBits] sh_addr[2];
  logic sh_has_data[2];
  logic [LineWords-1:0] sh_wvalid[2];
  logic [Xlen-1:0] sh_data[2][LineWords];
  logic sh_mask[2][LineWords];

  wire push_fire = push_valid && push_ready;
  wire bypass = push_fire && !sh_recv && sh_wlist == sh_rlist && !sh_occ[sh_rlist];

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      // Caller contract matching rapt_l2_release_buffer assertions.
      assume (!(head_pop && !head_complete));
      if (push_valid) begin
        if (sh_recv) begin
          assume (push_addr[Xlen-1:OffsetBits] == sh_addr[sh_wlist]);
          assume (push_has_data == sh_has_data[sh_wlist]);
        end
        if (push_has_data)
          assume (push_last == (sh_recv && &sh_wword));
          else assume (!sh_recv && push_last && !push_mask);
      end
    end
  end

  always_ff @(posedge clock) begin
    past_valid <= 1'b1;
    if (reset) begin
      sh_occ <= '0;
      sh_comp <= '0;
      sh_wlist <= 1'b0;
      sh_rlist <= 1'b0;
      sh_recv <= 1'b0;
      sh_wword <= '0;
      for (int l = 0; l < 2; l++) sh_wvalid[l] <= '0;
    end else begin
      busy_exact : assert (busy_o == |sh_occ);
      head_valid_exact : assert (head_valid == (sh_occ[sh_rlist] || bypass));
      head_complete_exact : assert (head_complete == sh_comp[sh_rlist]);
      if (head_valid) begin
        head_addr_exact :
        assert (head_addr == {
            bypass ? push_addr[Xlen-1:OffsetBits] : sh_addr[sh_rlist], {OffsetBits{1'b0}}
        });
        head_has_data_exact :
        assert (head_has_data == (bypass ? push_has_data : sh_has_data[sh_rlist]));
        head_wvalid_exact :
        assert (head_word_valid == (
            (bypass && head_word == '0 && push_has_data)
            || sh_wvalid[sh_rlist][head_word]
        ) || (bypass && head_word == '0 && !push_has_data));
        if (head_word_valid && head_has_data) begin
          head_data_exact :
          assert (head_data == (bypass ? push_data : sh_data[sh_rlist][head_word]));
          head_mask_exact :
          assert (head_mask == (bypass ? push_mask : sh_mask[sh_rlist][head_word]));
        end
      end

      if (push_fire) begin
        if (!sh_recv) begin
          sh_addr[sh_wlist] <= push_addr[Xlen-1:OffsetBits];
          sh_has_data[sh_wlist] <= push_has_data;
          sh_occ[sh_wlist] <= 1'b1;
          sh_wword <= WordBits'(1);
          sh_wvalid[sh_wlist] <= push_has_data ? {{(LineWords - 1) {1'b0}}, 1'b1} : '0;
        end else begin
          sh_wword <= sh_wword + 1'b1;
          if (push_has_data) sh_wvalid[sh_wlist][sh_wword] <= 1'b1;
        end
        if (push_has_data) begin
          sh_data[sh_wlist][sh_recv ? sh_wword : '0] <= push_data;
          sh_mask[sh_wlist][sh_recv ? sh_wword : '0] <= push_mask;
        end
        if (push_last) begin
          sh_comp[sh_wlist] <= 1'b1;
          sh_recv <= 1'b0;
          sh_wlist <= ~sh_wlist;
        end else sh_recv <= 1'b1;
      end
      if (head_pop && head_valid) begin
        sh_occ[sh_rlist] <= 1'b0;
        sh_comp[sh_rlist] <= 1'b0;
        sh_wvalid[sh_rlist] <= '0;
        sh_rlist <= ~sh_rlist;
      end

      cov_two_lines_full : cover (sh_occ == 2'b11 && sh_comp == 2'b11);
      cov_bypass : cover (bypass && push_has_data);
      cov_simultaneous_pop_push : cover (head_pop && push_fire && sh_occ == 2'b01);
      cov_dataless_release : cover (push_fire && !push_has_data);
    end
  end
endmodule

module formal_l2_secondary_buffer #(
    parameter int NumMshrs = 3,
    parameter int NumEntries = 6,
    parameter int DataBits = 8,
    parameter int NumQueues = 3 * NumMshrs,
    parameter int QueueBits = $clog2(NumQueues)
) (
    input logic clock,
    input logic reset,
    input logic [QueueBits-1:0] watched_queue,
    input logic push_valid,
    input logic [QueueBits-1:0] push_index,
    input logic [DataBits-1:0] push_data,
    input logic pop_valid,
    input logic [QueueBits-1:0] pop_index
);
  logic push_ready;
  logic [DataBits-1:0] pop_data;
  logic [NumQueues-1:0] queue_valid;

  rapt_l2_secondary_buffer #(
      .NumMshrs(NumMshrs),
      .NumEntries(NumEntries),
      .DataBits(DataBits)
  ) dut (
      .clock,
      .reset,
      .push_valid,
      .push_ready,
      .push_index,
      .push_data,
      .pop_valid,
      .pop_index,
      .pop_data,
      .queue_valid
  );

  logic past_valid = 1'b0;
  logic [QueueBits-1:0] watched_queue_q;
  logic [DataBits-1:0] q_mem[NumEntries];
  logic [$clog2(NumEntries+1)-1:0] q_cnt, total_cnt;
  logic [$clog2(NumEntries+1)-1:0] per_q_cnt[NumQueues];

  wire push_fire = push_valid && push_ready;
  wire watch_push = push_fire && push_index == watched_queue;
  wire watch_pop = pop_valid && pop_index == watched_queue;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      assume (int'(watched_queue) < NumQueues);
      assume (!push_valid || int'(push_index) < NumQueues);
      assume (!pop_valid || (int'(pop_index) < NumQueues && queue_valid[pop_index]));
    end
  end

  always_ff @(posedge clock) begin
    if (past_valid) assume (watched_queue == watched_queue_q);
    watched_queue_q <= watched_queue;
    past_valid <= 1'b1;

    if (reset) begin
      q_cnt <= '0;
      total_cnt <= '0;
      for (int i = 0; i < NumQueues; i++) per_q_cnt[i] <= '0;
    end else begin
      ready_exact : assert (push_ready == (int'(total_cnt) < NumEntries));
      for (int i = 0; i < NumQueues; i++) begin
        valid_exact : assert (queue_valid[i] == (per_q_cnt[i] != 0));
      end
      if (watch_pop) begin
        pop_matches_fifo : assert (pop_data == q_mem[0]);
      end

      total_cnt <= total_cnt + (push_fire ? 1'b1 : 1'b0) - (pop_valid ? 1'b1 : 1'b0);
      for (int i = 0; i < NumQueues; i++) begin
        per_q_cnt[i] <= per_q_cnt[i]
            + ((push_fire && push_index == QueueBits'(i)) ? 1'b1 : 1'b0)
            - ((pop_valid && pop_index == QueueBits'(i)) ? 1'b1 : 1'b0);
      end

      if (watch_pop && watch_push) begin
        for (int i = 0; i < NumEntries - 1; i++) q_mem[i] <= q_mem[i+1];
        q_mem[q_cnt-1] <= push_data;
      end else if (watch_pop) begin
        for (int i = 0; i < NumEntries - 1; i++) q_mem[i] <= q_mem[i+1];
        q_cnt <= q_cnt - 1'b1;
      end else if (watch_push) begin
        q_mem[q_cnt] <= push_data;
        q_cnt <= q_cnt + 1'b1;
      end

      cov_single_push_pop : cover (watch_pop && watch_push && q_cnt == 1);
      cov_full : cover (int'(total_cnt) == NumEntries);
    end
  end
endmodule
