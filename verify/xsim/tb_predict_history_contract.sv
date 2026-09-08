// ---- tb_predict_history ----
module tb_predict_history;
  logic clock = 0, reset = 1, clear = 0, flush = 0, decode_recover = 0;
  always #5 clock = ~clock;
  logic fetch_valid = 0, fetch_taken = 0, fetch_pc_bit = 0;
  logic decode_valid = 0, decode_taken = 0, decode_pc_bit = 0;
  logic commit_valid = 0, commit_taken = 0, commit_pc_bit = 0;
  wire [2:0] correct;
  formal_predict_history #(
      .GhrBits(1),
      .PhrBits(1)
  ) one (
      .*,
      .correct(correct[0])
  );
  formal_predict_history #(
      .GhrBits(7),
      .PhrBits(3)
  ) odd (
      .*,
      .correct(correct[1])
  );
  formal_predict_history standard (
      .*,
      .correct(correct[2])
  );
  int seed;
  int unsigned rng;
  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rng = 32'(seed);
    repeat (2) @(negedge clock);
    reset = 0;
    // Fill past the longest instantiated history before injecting recovery.
    fetch_valid = 1;
    decode_valid = 1;
    commit_valid = 1;
    for (int i = 0; i < 140; i++) begin
      fetch_taken = i[0];
      decode_taken = i[1];
      commit_taken = i[2];
      fetch_pc_bit = i[2];
      decode_pc_bit = i[0];
      commit_pc_bit = i[1];
      #1;
      assert (&correct)
      else $fatal(1, "long-history query");
      @(negedge clock);
      assert (&correct)
      else $fatal(1, "long-history shift/truncation");
    end
    for (int i = 0; i < 10000; i++) begin
      rng ^= rng << 13;
      rng ^= rng >> 17;
      rng ^= rng << 5;
      {clear, flush, decode_recover, fetch_valid, fetch_taken, fetch_pc_bit,
       decode_valid, decode_taken, decode_pc_bit, commit_valid, commit_taken, commit_pc_bit} = rng[11:0];
      clear = rng[18:12] == 0;
      flush = rng[22:19] == 0;
      decode_recover = rng[26:23] == 0;
      #1;
      assert (&correct)
      else $fatal(1, "history query/reference disagreement");
      @(negedge clock);
      assert (&correct)
      else $fatal(1, "history state/reference disagreement");
    end
    $display("PASS: history boundaries + combinational next-query, three widths, seed %0d", seed);
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "history timeout");
  end
endmodule


// ---- tb_predict_history_pipeline ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_predict_history_pipeline;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rou_cmu_if rou_cmu ();
  ifu_bpu_if ifu_bpu ();
  ifu_idu_if ifu_idu ();
  idu_rnu_if idu_rnu ();
  idu_bpu_if idu_bpu ();
  rapt_recovery_if recovery ();
  rapt_idu idu (.*);
  rapt_cmu cmu (.*);
  rapt_bpu bpu (.*);
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb_branch;
  rapt_ieu_pipe_branch branch_pipe (.*);
  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  task automatic receive(input logic [31:0] inst, input logic [XLEN-1:0] pc, prediction,
                         input bit predicted_taken);
    ifu_idu.slot[0] = '0;
    ifu_idu.slot[0].inst = inst;
    ifu_idu.slot[0].pc = pc;
    ifu_idu.slot[0].pnpc = prediction;
    ifu_idu.slot[0].predicted_taken = predicted_taken;
    ifu_idu.valid[0] = 1;
    tick(1);
    ifu_idu.valid[0] = 0;
    #1;
  endtask

  initial begin
    recovery.pending = 0;
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 0);
    rou_cmu.slot = '{default:'0};
    rou_cmu.next_pc = 0;
    rou_cmu.redirect_pc = 0;
    rou_cmu.btaken = 0;
    rou_cmu.ben = 0;
    rou_cmu.jen = 0;
    rou_cmu.jren = 0;
    rou_cmu.atomic_sc = 0;
    rou_cmu.fence_time = 0;
    rou_cmu.fence_i = 0;
    rou_cmu.flush_pipe = 0;
    rou_cmu.flush_redirect = 0;
    rou_cmu.sys_resume = 0;
    rou_cmu.time_trap = 0;
    rou_cmu.rob_head = 0;
    ifu_idu.slot = '{default:'0};
    ifu_idu.valid = '{default:0};
    idu_rnu.ready = '{default:1};
    iss = '0;
    ifu_bpu.pc = 0;
    ifu_bpu.nextpc = 0;
    ifu_bpu.pc_update = 1;
    ifu_bpu.history_valid = 0;
    ifu_bpu.history_taken = 0;
    ifu_bpu.history_pc_bit = 0;
`ifdef RAPT_FETCH_LOOKAHEAD
    ifu_bpu.aux_query = 0;
    ifu_bpu.aux_pc = 0;
`endif
    tick(3);
    reset = 0;
    tick(3);
    check(bpu.gshare == 0 && bpu.rgshare == 0, "query-only history must hold");
    ifu_bpu.history_valid = 1;
    ifu_bpu.history_taken = 1;
    ifu_bpu.history_pc_bit = 1;
    #1;
    check(bpu.dirp_read_ghr == 1 && bpu.dirp_read_phr == 1,
          "query includes current accepted branch");
    tick(1);
    ifu_bpu.history_taken = 0;
    ifu_bpu.history_pc_bit = 0;
    tick(1);
    ifu_bpu.history_valid = 0;
    check(bpu.gshare == 2 && bpu.phr == 2, "two fetched branch outcomes");
    tick(3);
    check(bpu.gshare == 2, "repeated query must not append");

    // BEQ +8 accepted by IDU: repair stale target and discard younger fetched
    // history, while retaining this very branch's taken and PC[1] bits.
    receive(32'h00000463, 'h1002, 'h2000, 1);
    check(
        idu_bpu.history_valid && idu_bpu.history_taken && idu_bpu.history_pc_bit
        && idu_bpu.history_recover,
        "decode branch/resteer event");
    check(bpu.dirp_read_ghr == 1 && bpu.dirp_read_phr == 1,
          "resteer query uses post-decode watermark");
    tick(1);
    check(bpu.gshare == 1 && bpu.u_history.decode_ghr == 1, "IDU watermark recovery");

    idu_rnu.ready = '{default: 0};
    receive(32'h00000463, 'h3000, 'h3004, 0);
    ifu_bpu.history_valid = 1;
    ifu_bpu.history_taken = 1;
    tick(1);
    ifu_bpu.history_valid = 0;
    check(!idu_bpu.history_valid && bpu.gshare == 3 && bpu.u_history.decode_ghr == 1,
          "stalled decode must not advance its history");
    // Commit in non-first slot + flush restores POST-commit history and kills
    // the stalled instruction, even if its ready is asserted on this edge.
    rou_cmu.slot[0].valid = 1;
    rou_cmu.slot[1].valid = 1;
    rou_cmu.slot[1].ben = 1;
    rou_cmu.slot[1].pc = 'h1002;
    rou_cmu.slot[1].btaken = 1;
    rou_cmu.flush_pipe = 1;
    idu_rnu.ready = '{default:1};
    #1;
    check(!idu_bpu.history_valid && bpu.dirp_read_ghr == 1 && bpu.dirp_read_phr == 1,
          "commit-flush query uses true branch outcome");
    tick(1);
    rou_cmu.slot = '{default:'0};
    rou_cmu.flush_pipe = 0;
    check(bpu.gshare == 1 && bpu.rgshare == 1 && bpu.rphr == 1, "commit flush state");
    // Non-branch flush, then faulting branch flush: neither appends history.
    rou_cmu.slot[0].valid = 1;
    rou_cmu.flush_pipe = 1;
    tick(1);
    check(bpu.gshare == 1 && bpu.phr == 1, "non-branch flush fabricated history");
    rou_cmu.slot[0].ben = 1;
    rou_cmu.slot[0].trap = 1;
    #1;
    check(!cmu_bcast.ben, "faulting branch must not train history");
    tick(1);
    check(bpu.gshare == 1 && bpu.rgshare == 1, "trap branch fabricated history");
    rou_cmu.slot = '{default:'0};
    rou_cmu.flush_pipe = 0;
    rou_cmu.fence_time = 1;
    tick(1);
    rou_cmu.fence_time = 0;
    check(
        bpu.gshare == 0 && bpu.phr == 0 && bpu.rgshare == 0 && bpu.rphr == 0
        && bpu.u_history.decode_ghr == 0,
        "fence_time clears all watermarks");

    // Next-PC equality does not encode direction when branch target == PC+4.
    receive(32'h00000263, 'h4000, 'h4004, 1);
    check(idu_rnu.slot[0].uop.execute.branch.predicted_taken && idu_bpu.history_taken,
          "direction metadata lost when taken target equals fall-through");
    iss = '0;
    iss.valid = 1;
    iss.uop = idu_rnu.slot[0].uop;
    iss.op1 = 0;
    iss.op2 = 0;
    #1;
    check(wb_branch.btaken && wb_branch.npc == 'h4004 && !wb_branch.mispredict,
          "matching direction");
    iss.uop.execute.branch.predicted_taken = 0;
    #1;
    check(wb_branch.mispredict, "same-PC wrong direction must repair history");
    iss.op2 = 1;
    #1;
    check(!wb_branch.btaken && !wb_branch.mispredict, "matching not-taken direction");
    iss.uop.execute.branch.predicted_taken = 1;
    #1;
    check(wb_branch.mispredict, "wrong taken hint with same next PC");
    $display("PASS: history IDU/BPU/CMU boundaries, trap/clear, and branch direction metadata");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "history pipeline timeout");
  end
endmodule
