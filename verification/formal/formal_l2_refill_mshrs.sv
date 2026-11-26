// Formal contract for rapt_l2_refill_mshrs:
// 1. AXI4 AR channel stability across arbitrary outer_arready stalls.
// 2. Interleaved multi-ID beat capture exactness for a symbolic watched slot/word.
// 3. Sticky non-OKAY response error tracking and critical_ready exactness.
// 4. Reload and retry invariants without losing or corrupting in-flight slots.
module formal_l2_refill_mshrs #(
    parameter int XLEN = 32,
    parameter int ID_W = 4,
    parameter int LineBytes = 16,
    parameter int NumMshrs = 4,
    parameter int MshrBits = $clog2(NumMshrs),
    parameter int LineWords = LineBytes / (XLEN / 8),
    parameter int WordBits = $clog2(LineWords),
    parameter int WrapBits = $clog2(16 * (XLEN / 8))
) (
    input logic clock,
    input logic reset,
    input logic [MshrBits-1:0] watched_slot,
    input logic [WordBits-1:0] watched_word,
    input logic alloc_valid,
    input logic alloc_reload,
    input logic [MshrBits-1:0] alloc_slot,
    input logic retry_valid,
    input logic [MshrBits-1:0] retry_slot,
    input logic [XLEN-1:0] alloc_addr,
    input logic [ID_W-1:0] alloc_inner_id,
    input logic [7:0] alloc_inner_len,
    input logic [2:0] alloc_inner_size,
    input logic [WrapBits-1:0] alloc_inner_wrap_mask,
    input logic [1:0] alloc_inner_burst,
    input logic [3:0] alloc_cache,
    input logic outer_arready,
    input logic outer_rvalid,
    input logic outer_store_ready,
    input logic [ID_W-1:0] outer_rid,
    input logic [XLEN-1:0] outer_rdata,
    input logic [1:0] outer_rresp,
    input logic outer_rlast,
    input logic retire_valid,
    input logic [MshrBits-1:0] retire_slot
);
  logic alloc_ready, outer_arvalid, outer_rready;
  logic [XLEN-1:0] outer_araddr;
  logic [ID_W-1:0] outer_arid;
  logic [7:0] outer_arlen;
  logic [2:0] outer_arsize;
  logic [1:0] outer_arburst;
  logic [3:0] outer_arcache;
  logic [WordBits-1:0] outer_rbeat;
  logic [NumMshrs-1:0] slot_valid, slot_done, slot_critical_ready;
  logic [LineWords-1:0] slot_beat_valid[NumMshrs];
  logic [1:0] slot_resp[NumMshrs];
  logic [LineWords-1:0] retire_beat_valid;
  logic [LineBytes*8-1:0] retire_line;
  logic [1:0] retire_resp;
  logic [XLEN-1:0] retire_addr;
  logic [ID_W-1:0] retire_inner_id;
  logic [7:0] retire_inner_len;
  logic [2:0] retire_inner_size;
  logic [WrapBits-1:0] retire_inner_wrap_mask;
  logic [1:0] retire_inner_burst;
  logic [3:0] retire_cache;

  rapt_l2_refill_mshrs #(
      .XLEN(XLEN),
      .ID_W(ID_W),
      .LineBytes(LineBytes),
      .NumMshrs(NumMshrs)
  ) dut (
      .clock,
      .reset,
      .alloc_valid,
      .alloc_ready,
      .alloc_reload,
      .alloc_slot,
      .retry_valid,
      .retry_slot,
      .alloc_addr,
      .alloc_inner_id,
      .alloc_inner_len,
      .alloc_inner_size,
      .alloc_inner_wrap_mask,
      .alloc_inner_burst,
      .alloc_cache,
      .outer_arvalid,
      .outer_arready,
      .outer_araddr,
      .outer_arid,
      .outer_arlen,
      .outer_arsize,
      .outer_arburst,
      .outer_arcache,
      .outer_rvalid,
      .outer_rready,
      .outer_store_ready,
      .outer_rid,
      .outer_rbeat,
      .outer_rdata,
      .outer_rresp,
      .outer_rlast,
      .slot_valid,
      .slot_done,
      .slot_critical_ready,
      .slot_beat_valid,
      .slot_resp,
      .retire_valid,
      .retire_slot,
      .retire_beat_valid,
      .retire_line,
      .retire_resp,
      .retire_addr,
      .retire_inner_id,
      .retire_inner_len,
      .retire_inner_size,
      .retire_inner_wrap_mask,
      .retire_inner_burst,
      .retire_cache
  );

  logic past_valid = 1'b0;
  logic [MshrBits-1:0] watched_slot_q;
  logic [WordBits-1:0] watched_word_q;

  // AXI AR stability shadow.
  logic ar_stall_q;
  logic [XLEN-1:0] ar_addr_q;
  logic [ID_W-1:0] ar_id_q;
  logic [7:0] ar_len_q;
  logic [2:0] ar_size_q;
  logic [1:0] ar_burst_q;
  logic [3:0] ar_cache_q;

  // Per-slot AR-issued shadow for legal outer R assumptions.
  logic [NumMshrs-1:0] sh_ar_sent;
  logic [WordBits-1:0] sh_beat_cnt[NumMshrs];

  // Watched slot golden tracker.
  logic sh_w_valid, sh_w_done, sh_w_word_valid;
  logic [XLEN-1:0] sh_w_word_data, sh_w_addr;
  logic [ID_W-1:0] sh_w_inner_id;
  logic [WordBits-1:0] sh_w_crit_word;
  logic [1:0] sh_w_resp;
  logic saw_interleaved_r;

  wire ar_fire = outer_arvalid && outer_arready;
  wire r_fire = outer_rvalid && outer_rready;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      assume (int'(watched_slot) < NumMshrs);
      assume (!alloc_valid || (int'(alloc_slot) < NumMshrs && alloc_ready));
      assume (!(alloc_valid && alloc_reload && !(slot_valid[alloc_slot] && slot_done[alloc_slot])));
      assume (!(alloc_valid && retire_valid && alloc_slot == retire_slot));
      assume (!(alloc_valid && retry_valid && alloc_slot == retry_slot));
      assume (!(retire_valid && retry_valid && retire_slot == retry_slot));
      assume (!retry_valid || (int'(retry_slot) < NumMshrs && slot_valid[retry_slot]
                               && slot_done[retry_slot] && slot_resp[retry_slot] != 2'b00));
      assume (!retire_valid || (int'(retire_slot) < NumMshrs && slot_valid[retire_slot]
                                && slot_done[retire_slot]));
      // Legal outer AXI R responses only for issued, unfinished ARs.
      if (outer_rvalid) begin
        assume (int'(outer_rid) < NumMshrs);
        assume (slot_valid[outer_rid] && sh_ar_sent[outer_rid] && !slot_done[outer_rid]);
        assume (outer_rlast == (sh_beat_cnt[outer_rid] == WordBits'(LineWords - 1)));
      end
    end
  end

  always_ff @(posedge clock) begin
    if (past_valid) begin
      assume (watched_slot == watched_slot_q);
      assume (watched_word == watched_word_q);
    end
    watched_slot_q <= watched_slot;
    watched_word_q <= watched_word;
    past_valid <= 1'b1;

    if (reset) begin
      ar_stall_q <= 1'b0;
      sh_ar_sent <= '0;
      for (int s = 0; s < NumMshrs; s++) sh_beat_cnt[s] <= '0;
      sh_w_valid <= 1'b0;
      sh_w_done <= 1'b0;
      sh_w_word_valid <= 1'b0;
      sh_w_word_data <= '0;
      sh_w_addr <= '0;
      sh_w_inner_id <= '0;
      sh_w_crit_word <= '0;
      sh_w_resp <= 2'b00;
      saw_interleaved_r <= 1'b0;
    end else begin
      // 1. AXI4 AR channel stability under stalls.
      if (ar_stall_q) begin
        ar_valid_stable : assert (outer_arvalid);
        ar_addr_stable : assert (outer_araddr == ar_addr_q);
        ar_id_stable : assert (outer_arid == ar_id_q);
        ar_len_stable : assert (outer_arlen == ar_len_q);
        ar_size_stable : assert (outer_arsize == ar_size_q);
        ar_burst_stable : assert (outer_arburst == ar_burst_q);
        ar_cache_stable : assert (outer_arcache == ar_cache_q);
      end
      ar_stall_q <= outer_arvalid && !outer_arready;
      if (outer_arvalid) begin
        ar_addr_q <= outer_araddr;
        ar_id_q <= outer_arid;
        ar_len_q <= outer_arlen;
        ar_size_q <= outer_arsize;
        ar_burst_q <= outer_arburst;
        ar_cache_q <= outer_arcache;
      end

      // 2. Watched slot status, critical_ready, and retire payload exactness.
      w_valid_match : assert (slot_valid[watched_slot] == sh_w_valid);
      w_done_match : assert (slot_done[watched_slot] == sh_w_done);
      w_resp_match : assert (slot_resp[watched_slot] == sh_w_resp);
      w_beat_match : assert (slot_beat_valid[watched_slot][watched_word] == sh_w_word_valid);
      w_crit_match :
      assert (slot_critical_ready[watched_slot] == (
          sh_w_valid && slot_beat_valid[watched_slot][sh_w_crit_word] && sh_w_resp == 2'b00
      ));
      if (retire_slot == watched_slot && sh_w_valid) begin
        w_addr_match : assert (retire_addr == sh_w_addr);
        w_id_match : assert (retire_inner_id == sh_w_inner_id);
        if (sh_w_word_valid) begin
          w_data_match : assert (retire_line[int'(watched_word)*XLEN+:XLEN] == sh_w_word_data);
        end
      end

      // Update AR shadow.
      if (alloc_valid && alloc_ready) begin
        sh_ar_sent[alloc_slot] <= 1'b0;
        sh_beat_cnt[alloc_slot] <= '0;
      end
      if (retry_valid) begin
        sh_ar_sent[retry_slot] <= 1'b0;
        sh_beat_cnt[retry_slot] <= '0;
      end
      if (ar_fire) sh_ar_sent[outer_arid[MshrBits-1:0]] <= 1'b1;
      if (r_fire && !outer_rlast)
        sh_beat_cnt[outer_rid[MshrBits-1:0]] <= sh_beat_cnt[outer_rid[MshrBits-1:0]] + 1'b1;
      if (retire_valid) sh_ar_sent[retire_slot] <= 1'b0;

      // Update watched slot golden state.
      if (alloc_valid && alloc_ready && alloc_slot == watched_slot) begin
        sh_w_valid <= 1'b1;
        sh_w_done <= 1'b0;
        sh_w_word_valid <= 1'b0;
        sh_w_addr <= alloc_addr;
        sh_w_inner_id <= alloc_inner_id;
        sh_w_crit_word <= WordBits'(alloc_addr >> $clog2(XLEN / 8));
        sh_w_resp <= 2'b00;
      end
      if (retry_valid && retry_slot == watched_slot) begin
        sh_w_done <= 1'b0;
        sh_w_word_valid <= 1'b0;
        sh_w_resp <= 2'b00;
      end
      if (r_fire && outer_rid == ID_W'(watched_slot)) begin
        if (sh_beat_cnt[watched_slot] == watched_word) begin
          sh_w_word_valid <= 1'b1;
          sh_w_word_data <= outer_rdata;
        end
        if (outer_rresp != 2'b00) sh_w_resp <= outer_rresp;
        if (outer_rlast) sh_w_done <= 1'b1;
      end
      if (r_fire && outer_rid != ID_W'(watched_slot) && sh_w_valid && sh_ar_sent[watched_slot]
          && !sh_w_done && sh_beat_cnt[watched_slot] != '0) begin
        saw_interleaved_r <= 1'b1;
      end
      if (retire_valid && retire_slot == watched_slot) begin
        sh_w_valid <= 1'b0;
        sh_w_done <= 1'b0;
      end

      cov_ar_stall_with_new_alloc : cover (ar_stall_q && alloc_valid && alloc_ready);
      cov_interleaved_retire :
      cover (
          retire_valid && retire_slot == watched_slot && saw_interleaved_r && sh_w_resp == 2'b00
      );
      cov_retry_after_error : cover (retry_valid && retry_slot == watched_slot);
      cov_reload_in_place : cover (alloc_valid && alloc_reload && alloc_slot == watched_slot);
    end
  end
endmodule
