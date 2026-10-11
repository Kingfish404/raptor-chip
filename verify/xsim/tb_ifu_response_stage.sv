`include "rapt.svh"
`include "rapt_if.svh"

// An address-driven cache/predictor model checks the visible instruction stream,
// including speculative packet-boundary corrections. It never derives the
// expected stream from IFU state or the currently requested cache address.
module tb_ifu_response_stage;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Width = rapt_pkg::DecodeWidth;
  initial begin
    assert ($bits(dut.held_count) == $clog2(Width + 1))
    else $fatal(1, "IFU count shape");
  end
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  ifu_bpu_if ifu_bpu ();
  ifu_l1i_if ifu_l1i ();
  ifu_idu_if ifu_idu ();
  rapt_recovery_if recovery ();
  logic hazard, response_pending, io_authorized;
  rapt_ifu dut (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu,
      .ifu_hazard(hazard),
      .response_pending_o(response_pending)
  );
  rapt_ifetch_io_guard io_guard (
      .clock,
      .reset,
      .owner_pc(ifu_l1i.pc),
      .frontier_pc(Base),
      .frontier_advance(1'b0),
      .blocked(ifu_l1i.cancel),
      .pipeline_empty(!response_pending && !ifu_idu.valid[0]),
      .memory_idle(1'b1),
      .io_start(1'b0),
      .authorized(io_authorized)
  );
  `include "tb_core_bcast_defaults.svh"

  int phase = 0, cycles = 0, delivered = 0, branches = 0, histories = 0;
  int queue_full_cycles = 0, push_pop_cycles = 0, killed_queued_cycles = 0;
  logic checking = 0, cache_enabled = 1;
  logic force_self_prediction = 0;
  logic late_aux_taken = 0;
  logic [XLEN-1:0] expected_pc, fault_tval, fault_cause;
  logic [31:0] rng = 32'hf38a915c;
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic logic [31:0] loop_branch();
    logic [12:0] immediate;
    immediate = -13'(2 * (Width - 1));
    return {
      immediate[12], immediate[10:5], 5'd0, 5'd0, 3'b000, immediate[4:1], immediate[11], 7'b1100011
    };
  endfunction
  function automatic logic [15:0] half_at(input logic [XLEN-1:0] pc);
    if (phase == 8) begin
      if (pc == Base) return 16'h0063;  // BEQ zero,zero,0.
      if (pc == Base + 2) return 16'h0000;
      return 16'h0001;
    end
    if (phase == 9) return (pc - Base) % XLEN'(2 * Width) == 0 ? 16'he009 : 16'h0001;
    if (phase inside {6, 7}) begin
      if (pc == Base + XLEN'(2 * (Width - 1))) return 16'(loop_branch());
      if (pc == Base + XLEN'(2 * Width)) return 16'(loop_branch() >> 16);
      return 16'h0001;
    end
    if (phase == 0) return 16'h0001;
    if (phase == 5) return (pc - Base) % XLEN'(2 * Width) == 0 ? 16'he009 : 16'h0001;
    if (phase == 4) return pc == Base + XLEN'(4 * Width - 2) ? 16'hc419 : 16'h0001;
    if (phase == 3) begin
      case (int'(pc - Base))
        'h02: return 16'hc419; // C.BEQZ s0,+14, predicted taken.
        'h12: return 16'he009; // C.BNEZ s0,+2, predicted not taken.
        'h14: return 16'hb7f5; // C.J -20.
        default: return 16'h0001;
      endcase
    end
    // C.NOP; ADDI; C.NOP; C.NOP; BEQ +22 (taken) ...
    // BEQ +32 (taken) ... ADDI; BEQ +16 (not taken); JAL -72.
    case (int'(pc - Base))
      'h02: return 16'h0093;
      'h04: return 16'h0050;
      'h0a: return 16'h0b63;
      'h0c: return 16'h0000;
      'h20: return 16'h0063;
      'h22: return 16'h0200;
      'h40: return 16'h0093;
      'h42: return 16'h0070;
      'h44: return 16'h0863;
      'h46: return 16'h0000;
      'h48: return 16'hf06f;
      'h4a: return 16'hfb9f;
      default: return 16'h0001;
    endcase
  endfunction
  function automatic logic [31:0] word_at(input logic [XLEN-1:0] pc);
    return {half_at(pc + 2), half_at(pc)};
  endfunction
  function automatic logic predicted_taken(input logic [XLEN-1:0] pc);
    return (phase == 8 && pc == Base)
        || (phase == 6 && pc == Base + XLEN'(2 * (Width - 1)))
        || (phase == 1 && (pc == Base+'ha || pc == Base+'h20 || pc == Base+'h48))
        || (phase == 3 && (pc == Base+2 || pc == Base+'h14))
        || (phase == 4 && pc == Base + XLEN'(4 * Width - 2) && late_aux_taken);
  endfunction
  function automatic logic [XLEN-1:0] following(input logic [XLEN-1:0] pc);
    logic [15:0] first_half;
    first_half = half_at(pc);
    if (phase == 8 && pc == Base) return Base;
    if (phase == 6 && pc == Base + XLEN'(2 * (Width - 1))) return Base;
    if (phase == 4 && pc == Base + XLEN'(4 * Width - 2) && late_aux_taken)
      return Base + XLEN'(4 * Width + 12);
    if (phase == 1) begin
      if (pc == Base + 'ha) return Base + 'h20;
      if (pc == Base + 'h20) return Base + 'h40;
      if (pc == Base + 'h48) return Base;
    end
    if (phase == 3) begin
      if (pc == Base + 2) return Base + 'h10;
      if (pc == Base + 'h14) return Base;
    end
    return pc + (first_half[1:0] == 2'b11 ? XLEN'(4) : XLEN'(2));
  endfunction

  always_comb begin
    ifu_l1i.inst_n0 = word_at(ifu_l1i.pc);
    ifu_l1i.inst_n1 = word_at({ifu_l1i.pc[XLEN-1:2], 2'b00} + 4);
    ifu_l1i.inst_n2 = word_at({ifu_l1i.pc[XLEN-1:2], 2'b00} + 8);
`ifdef RAPT_FETCH_WIDE
    ifu_l1i.inst_n3 = word_at({ifu_l1i.pc[XLEN-1:2], 2'b00} + 12);
    ifu_l1i.inst_n4 = word_at({ifu_l1i.pc[XLEN-1:2], 2'b00} + 16);
    ifu_l1i.inst_n3_valid = !(phase inside {1,3}) || rng[4];
    ifu_l1i.inst_n4_valid = !(phase inside {1,3}) || rng[5];
`endif
    ifu_l1i.inst_n1_valid = !(phase inside {1,3}) || rng[2];
    ifu_l1i.inst_n2_valid = !(phase inside {1,3}) || rng[3];
    ifu_l1i.valid = cache_enabled && (!(phase inside {1,3}) || rng[1:0] != 0);
    ifu_l1i.trap = phase == 2;
    ifu_l1i.cause = fault_cause;
    ifu_l1i.tval = fault_tval;
    ifu_bpu.taken = phase == 8 ? 1'b0 : phase == 9 ? 1'b1
        : force_self_prediction || predicted_taken(dut.pc_ifu);
    ifu_bpu.npc = phase == 9 ? dut.pc_ifu
        : force_self_prediction ? Base : following(dut.pc_ifu);
    ifu_bpu.aux_taken = ifu_bpu.aux_query && predicted_taken(ifu_bpu.aux_pc);
  end
  always @(posedge clock) begin
    if (!reset) begin
      cycles++;
      if (`RAPT_FETCH_RESPONSE_STAGE) begin
        if (dut.response_count_q == 2) queue_full_cycles++;
        if (dut.capture_response && dut.pop_response) push_pop_cycles++;
        if (dut.response_kill_younger && dut.response_count_q == 2) killed_queued_cycles++;
      end
`ifdef RAPT_FETCH_LOOKAHEAD
      if (`RAPT_FETCH_RESPONSE_STAGE && ifu_bpu.aux_query) begin
        assert (ifu_bpu.aux_pc == dut.candidate_pc[dut.secondary_index])
        else $fatal(1, "registered auxiliary PC does not match the buffered branch PC");
      end
`endif
      if (checking) begin
        if (ifu_bpu.history_valid) histories++;
        for (int s = 0; s < Width; s++) begin
          if (ifu_idu.valid[s] && ifu_idu.ready[s]) begin
            assert (ifu_idu.slot[s].pc == expected_pc)
            else $fatal(1, "stream PC got=%h expected=%h", ifu_idu.slot[s].pc, expected_pc);
            assert (ifu_idu.slot[s].inst[15:0] == half_at(
                expected_pc
            ) && (ifu_idu.slot[s].inst[1:0] != 2'b11 || ifu_idu.slot[s].inst == word_at(
                expected_pc
            )))
            else $fatal(1, "response data mixed with a different request");
            assert (!ifu_idu.slot[s].trap && ifu_idu.slot[s].pnpc == following(expected_pc))
            else
              $fatal(
                  1,
                  "response prediction/exception identity mismatch pc=%h pnpc=%h",
                  expected_pc,
                  ifu_idu.slot[s].pnpc
              );
            if ((phase == 1 && (expected_pc == Base+'ha || expected_pc == Base+'h20 || expected_pc == Base+'h44))
                || (phase == 3 && (expected_pc == Base+2 || expected_pc == Base+'h12))) begin
              assert (ifu_idu.slot[s].predicted_taken == predicted_taken(expected_pc))
              else $fatal(1, "primary/auxiliary direction mismatch");
              branches++;
            end
            expected_pc = following(expected_pc);
            delivered++;
          end
        end
      end
    end
  end
  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  task automatic redirect;
    checking = 0;
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = Base;
    tick();
    cmu_bcast.flush_pipe = 0;
    expected_pc = Base;
  endtask
  initial begin
    init_cmu_bcast_defaults();
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.target = Base;
    ifu_idu.resteer = 0;
    ifu_idu.resteer_pc = Base;
    ifu_idu.ready = '{default: 1};
    fault_tval = 0;
    fault_cause = 0;
    repeat (3) tick();
    reset = 0;
    redirect();
    checking = 1;
    repeat (8) tick();
    begin
      automatic int before_count = delivered;
      repeat (64) tick();
      assert (delivered - before_count == 64 * Width)
      else $fatal(1, "response stage introduced sequential packet bubbles");
      $display("COVER: steady hits delivered=%0d in 64 cycles width=%0d", delivered - before_count,
               Width);
    end

    // One not-taken conditional at the beginning of every packet must not
    // force a response correction just to fetch the rest of its fallthrough.
    phase = 5;
    redirect();
    checking = 1;
    repeat (8) tick();
    begin
      automatic int before_count = delivered;
      automatic int before_history = histories;
      repeat (64) tick();
      $display("COVER: not-taken prefix delivered=%0d histories=%0d in 64 cycles width=%0d",
               delivered - before_count, histories - before_history, Width);
      assert (delivered - before_count == 64 * Width && histories - before_history == 64)
      else $fatal(1, "not-taken packet boundary inserted correction bubbles");
    end

    // A repeated taken branch at the end of a packet should sustain one
    // packet per cycle once its successor hint is warm. The stream checker
    // independently checks every PC, instruction and predicted successor.
    phase = 6;
    redirect();
    checking = 1;
    repeat (16) tick();
    begin
      automatic int before_count = delivered;
      automatic int before_history = histories;
      repeat (64) tick();
      $display("COVER: taken suffix delivered=%0d histories=%0d in 64 cycles width=%0d",
               delivered - before_count, histories - before_history, Width);
      assert (delivered - before_count == 64 * Width && histories - before_history == 64)
      else $fatal(1, "taken suffix lost steady packet throughput");
    end
    // Preserve the trained hint across a redirect but reverse the direction.
    // The stale target must be corrected before it can reach the output.
    phase = 7;
    redirect();
    checking = 1;
    repeat (32) tick();
    assert (expected_pc > Base + XLEN'(32 * Width))
    else $fatal(1, "stale successor did not recover to the fallthrough stream");

`ifdef RAPT_BPU_DIRP_TAGE
`ifdef RAPT_FETCH_LOOKAHEAD
    if (`RAPT_FETCH_RESPONSE_STAGE) begin
      // The early primary result belongs to an older history position. The
      // registered response must use the fresh head-history query instead.
      phase = 8;
      cmu_bcast.fence_i = 1;
      redirect();
      cmu_bcast.fence_i = 0;
      checking = 1;
      repeat (16) tick();
      begin
        automatic int before_count = delivered;
        automatic int before_history = histories;
        repeat (64) tick();
        assert (delivered - before_count == 64 && histories - before_history == 64)
        else $fatal(1, "first conditional did not use refreshed head history");
        $display("COVER: stale not-taken primary refreshed for 64 taken branches");
      end
      phase = 9;
      cmu_bcast.fence_i = 1;
      redirect();
      cmu_bcast.fence_i = 0;
      checking = 1;
      repeat (64) tick();
      assert (expected_pc > Base + XLEN'(32 * Width))
      else $fatal(1, "stale taken primary prevented fresh fallthrough");
      $display("COVER: stale taken primary refreshed to fallthrough");
    end
`endif
`endif
    phase = 1;
    redirect();
    checking = 1;
    branches = 0;
    histories = 0;
    for (int c = 0; c < 3000; c++) begin
      automatic int ready_count = int'(random_word() % (Width + 1));
      for (int s = 0; s < Width; s++) ifu_idu.ready[s] = s < ready_count;
      tick();
    end
    cache_enabled = 0;
    ifu_idu.ready = '{default: 1};
    repeat (8) tick();
    assert (branches > 100 && histories == branches)
    else $fatal(1, "conditional history missing, duplicated or appended for a discarded response");
    $display("COVER: random backpressure/cache availability branches=%0d history=%0d", branches,
             histories);

    phase = 3;
    redirect();
    cache_enabled = 1;
    checking = 1;
    branches = 0;
    histories = 0;
    for (int c = 0; c < 1000; c++) begin
      automatic int ready_count = int'(random_word() % (Width + 1));
      for (int s = 0; s < Width; s++) ifu_idu.ready[s] = s < ready_count;
      tick();
    end
    cache_enabled = 0;
    ifu_idu.ready = '{default: 1};
    repeat (8) tick();
    assert (branches > 100 && histories == branches)
    else $fatal(1, "compressed branch history missing or duplicated");
    $display("COVER: compressed branches=%0d history=%0d", branches, histories);

    // While the held packet stalls, fill the queue behind a not-taken auxiliary
    // branch in its head. Change that direction only after the younger packet
    // is resident: correction must cancel it without relying on downstream ready.
    if (`RAPT_FETCH_RESPONSE_STAGE && Width > 1) begin
      phase = 4;
      // This fixture replaces the instruction image and needs a cold successor
      // table for its exact queue-fill schedule. Stale hints are exercised
      // separately above without FENCE.I.
      cmu_bcast.fence_i = 1;
      redirect();
      cmu_bcast.fence_i = 0;
      cache_enabled = 1;
      ifu_idu.ready = '{default: 0};
      repeat (6) tick();
      assert (dut.response_count_q == 2 && dut.response_q.pc == Base + XLEN'(2 * Width))
      else $fatal(1, "late direction scenario did not fill both queue entries");
      late_aux_taken = 1;
      #1;
      assert (ifu_l1i.cancel && !ifu_l1i.consumed && !dut.recv_ready)
      else $fatal(1, "stalled head correction depended on downstream ready");
      tick();
      checking = 1;
      expected_pc = Base;
      ifu_idu.ready = '{default: 1};
      repeat (20) tick();
      checking = 0;
      late_aux_taken = 0;
    end

    // Fill both the held packet and response slot, then cancel at the same PC.
    // No cached packet may reappear while recovery fences the frontend.
    cache_enabled = 1;
    phase = 0;
    cmu_bcast.fence_i = 1;
    redirect();
    cmu_bcast.fence_i = 0;
    ifu_idu.ready = '{default: 0};
    repeat (3) tick();
    if (`RAPT_FETCH_RESPONSE_STAGE)
      assert (dut.response_count_q == 2 && dut.held_count != 0)
      else $fatal(1, "response backpressure scenario was not reached");
    recovery.pending = 1;
    recovery.redirect_valid = 1;
    recovery.target = Base;
    tick();
    recovery.redirect_valid = 0;
    repeat (8) begin
      assert (!ifu_l1i.consumed && !ifu_idu.valid[0] && !ifu_bpu.history_valid)
      else $fatal(1, "same-PC recovery leaked a buffered response");
      tick();
    end
    recovery.pending = 0;
    expected_pc = Base;
    checking = 1;
    ifu_idu.ready = '{default: 1};
    repeat (20) tick();

    // The request PC can equal the retirement frontier while an older dynamic
    // instance of that PC is buffered. PC equality alone cannot authorize IO.
    redirect();
    force_self_prediction = 1;
    ifu_idu.ready = '{default: 0};
    tick();
    assert (ifu_l1i.pc == Base && !io_authorized)
    else $fatal(1, "IO fetch bypassed an older same-PC frontend packet");
    if (`RAPT_FETCH_RESPONSE_STAGE)
      assert (response_pending && !ifu_idu.valid[0])
      else $fatal(1, "IO authorization test did not isolate the response boundary");
    force_self_prediction = 0;

    // A fault response owns its PC, cause and tval even when live cache signals
    // change before the packing edge and while the downstream stream is held.
    phase = 2;
    redirect();
    ifu_idu.ready = '{default: 0};
    fault_tval = Base + 2;
    fault_cause = 1;
    tick();
    cache_enabled = 0;
    fault_tval = Base + 'h100;
    fault_cause = 12;
    if (`RAPT_FETCH_RESPONSE_STAGE) tick();
    repeat (8) begin
      assert (ifu_idu.valid[0] && ifu_idu.slot[0].trap
          && ifu_idu.slot[0].pc == Base && ifu_idu.slot[0].tval == Base+2
          && ifu_idu.slot[0].cause == 1 && hazard)
      else $fatal(1, "fault response metadata changed under backpressure");
      tick();
    end
    if (`RAPT_FETCH_RESPONSE_STAGE) begin
      assert (queue_full_cycles > 0 && push_pop_cycles > 100 && (Width == 1 || killed_queued_cycles > 0))
      else $fatal(1, "missing FIFO full/throughput/queued correction coverage");
      $display("COVER: FIFO full=%0d push_pop=%0d killed_queued=%0d", queue_full_cycles,
               push_pop_cycles, killed_queued_cycles);
    end
    $display("PASS: IFU response boundary XLEN=%0d width=%0d stage=%0d delivered=%0d", XLEN, Width,
             `RAPT_FETCH_RESPONSE_STAGE, delivered);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "response-stage test timeout");
  end
endmodule
