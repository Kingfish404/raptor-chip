// Formal verification harnesses for the four L2 phase controllers:
// rapt_l2_bypass_ctrl, rapt_l2_evict_ctrl, rapt_l2_hit_ctrl, rapt_l2_refill_ctrl.
module formal_l2_bypass_ctrl #(
    parameter int XLEN = 32,
    parameter int ID_W = 4
) (
    input logic clock,
    input logic reset,
    input logic valid_i,
    input logic start_ar_i,
    input logic wait_done_i,
    input logic ar_done_i,
    input logic r_last_fire_i,
    input logic done_ready_i,
    input logic request_valid_i,
    input logic request_issue_i,
    input logic [XLEN-1:0] request_addr_i,
    input logic [ID_W-1:0] request_id_i,
    input logic [7:0] request_len_i,
    input logic [2:0] request_size_i,
    input logic [1:0] request_burst_i,
    input logic [3:0] request_cache_i,
    input logic arready_i
);
  logic ready_o, done_valid_o, arvalid_o;
  logic [1:0] phase_o;
  logic [XLEN-1:0] araddr_o;
  logic [ID_W-1:0] arid_o;
  logic [7:0] arlen_o;
  logic [2:0] arsize_o;
  logic [1:0] arburst_o;
  logic [3:0] arcache_o;

  rapt_l2_bypass_ctrl #(
      .XLEN(XLEN),
      .ID_W(ID_W)
  ) dut (
      .*
  );

  logic past_valid = 1'b0;
  logic ar_stall_q;
  logic [XLEN-1:0] ar_addr_q;
  logic [ID_W-1:0] ar_id_q;
  logic [7:0] ar_len_q;
  logic [2:0] ar_size_q;
  logic [1:0] ar_burst_q;
  logic [3:0] ar_cache_q;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      // Caller contract: do not overwrite an active stalled AR register.
      if (arvalid_o && !arready_i) begin
        assume (!request_valid_i);
        assume (!request_issue_i);
      end
    end
  end

  always_ff @(posedge clock) begin
    past_valid <= 1'b1;
    if (reset) begin
      ar_stall_q <= 1'b0;
    end else begin
      if (ar_stall_q) begin
        ar_stable_valid : assert (arvalid_o);
        ar_stable_addr : assert (araddr_o == ar_addr_q);
        ar_stable_id : assert (arid_o == ar_id_q);
        ar_stable_len : assert (arlen_o == ar_len_q);
        ar_stable_size : assert (arsize_o == ar_size_q);
        ar_stable_burst : assert (arburst_o == ar_burst_q);
        ar_stable_cache : assert (arcache_o == ar_cache_q);
      end
      ar_stall_q <= arvalid_o && !arready_i;
      if (arvalid_o) begin
        ar_addr_q <= araddr_o;
        ar_id_q <= arid_o;
        ar_len_q <= arlen_o;
        ar_size_q <= arsize_o;
        ar_burst_q <= arburst_o;
        ar_cache_q <= arcache_o;
      end
      ready_spec : assert (ready_o == !valid_i);
      done_spec : assert (done_valid_o == (valid_i && phase_o == 2'd2 && r_last_fire_i));
      phase_legal : assert (phase_o <= 2'd2);

      cov_wait_to_done : cover (done_valid_o && done_ready_i);
      cov_ar_stall_then_fire : cover (ar_stall_q && arvalid_o && arready_i);
    end
  end
endmodule

module formal_l2_evict_ctrl #(
    parameter int LINE_LEN = 2,
    parameter int WAY_BITS = 2,
    parameter int TAG_BITS = 6
) (
    input logic clock,
    input logic reset,
    input logic valid_i,
    input logic aw_fire_i,
    input logic read_ready_i,
    input logic w_fire_i,
    input logic b_fire_i,
    input logic done_ready_i,
    input logic capture_valid_i,
    input logic capture_way_only_i,
    input logic [WAY_BITS-1:0] capture_way_i,
    input logic [TAG_BITS-1:0] capture_tag_i,
    input logic [1:0] capture_state_i,
    input logic capture_dirty_i,
    input logic capture_clients_i,
    input logic probe_release_i,
    input logic nested_release_i,
    input logic nested_dirty_i,
    input logic [1:0] nested_state_i
);
  localparam int LineWords = 1 << LINE_LEN;

  logic ready_o, done_valid_o, victim_dirty_o, victim_clients_o;
  logic [1:0] phase_o, victim_state_o;
  logic [LINE_LEN-1:0] word_o;
  logic [WAY_BITS-1:0] victim_way_o;
  logic [TAG_BITS-1:0] victim_tag_o;

  rapt_l2_evict_ctrl #(
      .LINE_LEN(LINE_LEN),
      .WAY_BITS(WAY_BITS),
      .TAG_BITS(TAG_BITS)
  ) dut (
      .*
  );

  logic past_valid = 1'b0;
  logic [LINE_LEN:0] beats_sent;
  logic saw_aw, saw_b;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      // Caller asserts aw/w/b fires only in matching phases.
      assume (!aw_fire_i || (valid_i && phase_o == 2'd0));
      assume (!w_fire_i || (valid_i && phase_o == 2'd2));
      assume (!b_fire_i || (valid_i && phase_o == 2'd3));
    end
  end

  always_ff @(posedge clock) begin
    past_valid <= 1'b1;
    if (reset || !valid_i) begin
      beats_sent <= '0;
      saw_aw <= 1'b0;
      saw_b <= 1'b0;
    end else begin
      // Inductive invariants linking DUT phase/word to shadow beat count.
      if (phase_o == 2'd0) inv_aw : assert (!saw_aw && beats_sent == '0 && word_o == '0);
      if (phase_o == 2'd1 || phase_o == 2'd2)
        inv_rw : assert (saw_aw && beats_sent == {1'b0, word_o});
      if (phase_o == 2'd3) inv_b : assert (saw_aw && int'(beats_sent) == LineWords);
      if (aw_fire_i) saw_aw <= 1'b1;
      if (w_fire_i) begin
        beat_after_aw : assert (saw_aw);
        word_matches_cnt : assert (word_o == beats_sent[LINE_LEN-1:0]);
        beats_sent <= beats_sent + 1'b1;
      end
      if (done_valid_o) begin
        all_beats_before_b : assert (int'(beats_sent) == LineWords);
        saw_b <= 1'b1;
      end
      if (done_valid_o && done_ready_i) begin
        beats_sent <= '0;
        saw_aw <= 1'b0;
      end
      cov_full_evict : cover (done_valid_o && done_ready_i);
      cov_probe_sets_dirty : cover (probe_release_i && !capture_valid_i && !nested_release_i);
    end
  end
endmodule

module formal_l2_hit_ctrl #(
    parameter int XLEN = 32,
    parameter int LINE_LEN = 2,
    parameter int ID_W = 4
) (
    input logic clock,
    input logic reset,
    input logic valid_i,
    input logic start_install_i,
    input logic boom_i,
    input logic lookup_blocked_i,
    input logic hit_i,
    input logic probe_needed_i,
    input logic probe_done_i,
    input logic probe_commit_i,
    input logic data_recheck_i,
    input logic data_advance_i,
    input logic more_beats_i,
    input logic install_ready_i,
    input logic capture_addr_valid_i,
    input logic [XLEN-1:0] capture_addr_i,
    input logic capture_word_valid_i,
    input logic [LINE_LEN-1:0] capture_word_i,
    input logic capture_len_valid_i,
    input logic [7:0] capture_len_i,
    input logic beat_advance_i,
    input logic error_advance_i,
    input logic [XLEN-1:0] next_addr_i,
    input logic [LINE_LEN-1:0] next_word_i,
    input logic response_write_i,
    input logic [XLEN-1:0] response_data_i,
    input logic [ID_W-1:0] response_id_i,
    input logic [1:0] response_code_i,
    input logic response_last_i,
    input logic response_secondary_write_i,
    input logic response_secondary_i,
    input logic response_ready_i
);
  logic ready_o, response_valid_o, response_last_o, response_secondary_o;
  logic [2:0] phase_o;
  logic [XLEN-1:0] addr_o, response_data_o;
  logic [LINE_LEN-1:0] word_o;
  logic [7:0] len_o;
  logic [ID_W-1:0] response_id_o;
  logic [1:0] response_code_o;

  rapt_l2_hit_ctrl #(
      .XLEN(XLEN),
      .LINE_LEN(LINE_LEN),
      .ID_W(ID_W)
  ) dut (
      .*
  );

  logic past_valid = 1'b0;
  logic rsp_stall_q;
  logic [XLEN-1:0] rsp_data_q;
  logic [ID_W-1:0] rsp_id_q;
  logic [1:0] rsp_code_q;
  logic rsp_last_q;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      // Caller contract: never write a new response while output is stalled.
      if (response_valid_o && !response_ready_i) assume (!response_write_i);
    end
  end

  always_ff @(posedge clock) begin
    past_valid <= 1'b1;
    if (reset) begin
      rsp_stall_q <= 1'b0;
    end else begin
      // AXI R stability on the response register.
      if (rsp_stall_q) begin
        rsp_valid_stable : assert (response_valid_o);
        rsp_data_stable : assert (response_data_o == rsp_data_q);
        rsp_id_stable : assert (response_id_o == rsp_id_q);
        rsp_code_stable : assert (response_code_o == rsp_code_q);
        rsp_last_stable : assert (response_last_o == rsp_last_q);
      end
      rsp_stall_q <= response_valid_o && !response_ready_i;
      if (response_valid_o) begin
        rsp_data_q <= response_data_o;
        rsp_id_q <= response_id_o;
        rsp_code_q <= response_code_o;
        rsp_last_q <= response_last_o;
      end
      phase_legal : assert (phase_o <= 3'd4);
      cov_probe_cycle : cover (valid_i && phase_o == 3'd3 && probe_commit_i);
      cov_rsp_stall : cover (rsp_stall_q && response_valid_o && response_ready_i);
    end
  end
endmodule
