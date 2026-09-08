`include "rapt.svh"
`include "rapt_if.svh"
module tb_ifu_stream_events;
  localparam int XLEN = rapt_pkg::XLENPkg;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  ifu_bpu_if ifu_bpu ();
  ifu_l1i_if ifu_l1i ();
  ifu_idu_if ifu_idu ();
  rapt_recovery_if #(.XLEN(XLEN)) recovery ();
  int history_events = 0;
  logic last_history_taken, last_history_pc_bit;
  always_ff @(posedge clock) begin
    if (reset) history_events <= 0;
    else if (ifu_bpu.history_valid) begin
      history_events <= history_events + 1;
      last_history_taken <= ifu_bpu.history_taken;
      last_history_pc_bit <= ifu_bpu.history_pc_bit;
    end
  end
  rapt_ifu dut (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu,
      .ifu_hazard()
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  initial begin
    init_cmu_bcast_defaults();
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.target = 0;
    ifu_bpu.taken = 0;
    ifu_bpu.npc = 0;
    ifu_bpu.aux_taken = 0;
    ifu_idu.ready = '{default: 0};
    ifu_idu.resteer = 0;
    ifu_idu.resteer_pc = 0;
    ifu_l1i.valid = 1;
    ifu_l1i.trap = 0;
    ifu_l1i.cause = 0;
    ifu_l1i.tval = 0;
    ifu_l1i.inst_n0 = 32'h00000063;  // conditional branch terminates fetched prefix
    ifu_l1i.inst_n1 = 32'h00010001;
    ifu_l1i.inst_n2 = 32'h00010001;
    ifu_l1i.inst_n1_valid = 1;
    ifu_l1i.inst_n2_valid = 1;
    repeat (3) tick();
    reset = 0;
    tick();
    assert (dut.held_count == 1 && dut.pmu_fetch_response_consume && dut.pmu_fetch_first_control)
    else $fatal(1, "registered fetch/control event was lost after PC advanced");
    assert (history_events == 1 && !last_history_taken && !ifu_idu.slot[0].predicted_taken)
    else $fatal(1, "not-taken branch/BTB miss must enter history once");
    tick();
    assert (!dut.pmu_fetch_response_consume && dut.pmu_fetch_downstream_blocked)
    else $fatal(1, "stall duplicated a response event");
    assert (history_events == 1)
    else $fatal(1, "stalled fetch appended history");
    ifu_l1i.valid = 0;
    ifu_idu.ready = '{default: 1};
    tick();
    assert (dut.pmu_fetch_slots == 1 && dut.pmu_fetch_fire)
    else $fatal(1, "held instruction delivery not counted");
    // Four compressed instructions; consume a two-instruction prefix and
    // verify suffix PCs and counters survive the partial handshake.
    ifu_idu.ready   = '{default: 0};
    ifu_l1i.valid   = 1;
    ifu_l1i.inst_n0 = 32'h00010001;
    tick();
    assert (dut.held_count == 4)
    else $fatal(1, "four-slot compressed assembly");
    begin
      automatic logic [31:0] first_pc = ifu_idu.slot[0].pc;
      ifu_l1i.valid = 0;
      ifu_idu.ready[0] = 1;
      ifu_idu.ready[1] = 1;
      tick();
      assert (dut.held_count == 2 && dut.pmu_fetch_slots == 2 && dut.pmu_fetch_multi_fire)
      else $fatal(1, "partial delivery count");
      assert (ifu_idu.slot[0].pc == first_pc + 4 && ifu_idu.slot[1].pc == first_pc + 6)
      else $fatal(1, "held suffix reordered");
    end
    // Flush cancels the otherwise-ready suffix; PMU must not count delivery.
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = 'h80001000;
    tick();
    assert (dut.held_count == 0 && dut.pmu_fetch_slots == 0 && dut.pmu_ifu_flush_stall)
    else $fatal(1, "flush/event snapshot mismatch");
    cmu_bcast.flush_pipe = 0;
    ifu_idu.ready = '{default:0};
    ifu_l1i.valid = 1;
    ifu_l1i.inst_n0 = 32'h00000263; // BEQ target == fall-through
    ifu_bpu.taken = 1;
    ifu_bpu.npc = 'h80001004;
    tick();
    assert (history_events == 2 && last_history_taken && ifu_idu.slot[0].predicted_taken
        && ifu_idu.slot[0].pnpc == ifu_idu.slot[0].pc + 4)
    else $fatal(1, "taken direction cannot be inferred from next PC");
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = 'h80002000;
    tick();
    cmu_bcast.flush_pipe = 0;
    ifu_bpu.taken = 0;
    ifu_bpu.aux_taken = 1;
    // C.NOP; BEQ +4 at PC+2; C.NOP -- secondary conditional terminates group.
    ifu_l1i.inst_n0 = 32'h02630001;
    ifu_l1i.inst_n1 = 32'h00010000;
    tick();
    assert (history_events == 3 && last_history_taken && last_history_pc_bit
        && dut.held_count == 2 && ifu_idu.slot[1].predicted_taken)
    else $fatal(1, "secondary branch must use same history event contract");
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    ifu_l1i.inst_n0 = 32'h00000263;
    ifu_l1i.trap = 1;
    tick();
    assert (history_events == 3)
    else $fatal(1, "fetch fault fabricated branch history");
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    ifu_l1i.trap = 0;
    ifu_l1i.inst_n0 = 32'h00002063; // Reserved branch funct3.
    tick();
    assert (history_events == 3)
    else $fatal(1, "illegal branch fabricated history");
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    ifu_l1i.inst_n0 = 32'h00000013;
    ifu_bpu.taken = 1;
    tick();
    assert (history_events == 3)
    else $fatal(1, "BTB alias on ALU instruction fabricated history");

    // A registered execution-time recovery redirect cancels held fetch work
    // and starts the target lookup before the later precise retirement flush.
    ifu_l1i.valid = 0;
    recovery.pending = 1;
    recovery.redirect_valid = 1;
    recovery.target = 'h80003000;
    #1;
    assert (dut.redirect_event && dut.redirect_pc == recovery.target
            && ifu_l1i.prefetch_valid && ifu_l1i.prefetch_pc == recovery.target)
    else $fatal(1, "completion-time recovery target did not reach fetch prefetch");
    tick();
    recovery.redirect_valid = 0;
    #1;
    assert (dut.pc_ifu == 'h80003000 && dut.held_count == 0 && !dut.redirect_event)
    else $fatal(1, "registered recovery redirect was not a one-cycle fetch event");

    // A simultaneous precise trap/retirement redirect is architecturally
    // older and therefore has priority over a speculative recovery target.
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = 'h80004000;
    recovery.redirect_valid = 1;
    recovery.target = 'h80005000;
    #1;
    assert (dut.redirect_pc == cmu_bcast.cpc)
    else $fatal(1, "precise redirect lost priority over recovery prefetch");
    tick();
    cmu_bcast.flush_pipe = 0;
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    // Ordering-only Svinval instructions do not issue a system resume at
    // retirement: accepting them must leave fetch able to make progress.
    ifu_bpu.taken = 0;
    ifu_bpu.aux_taken = 0;
    ifu_idu.ready = '{default: 1};
    ifu_l1i.valid = 1;
    ifu_l1i.inst_n0 = 32'h18000073;
    ifu_l1i.inst_n1 = 32'h18100073;
    ifu_l1i.inst_n2 = 32'h00000013;
    tick();
    assert (!dut.blocked && dut.held_count == 3)
    else $fatal(1, "Svinval ordering fences incorrectly block fetch awaiting sys_resume");
    ifu_l1i.inst_n0 = 32'h00000013;
    tick();
    assert (!dut.blocked && dut.pmu_fetch_slots == 3 && dut.held_count == 3)
    else $fatal(1, "fetch failed to progress past Svinval ordering fences");
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    ifu_l1i.inst_n0 = 32'h16000073;
    tick();
    assert (dut.blocked && dut.held_count == 1)
    else $fatal(1, "SINVAL.VMA must retain its serializing fetch behavior");
    // AMOs terminate the fetched prefix, including when a younger AMO is
    // already present in lookahead. Older long-latency work cannot release
    // this stop: only a redirect resumes fetching after the atomic.
    for (int kind = 0; kind < (XLEN == 64 ? 4 : 2); kind++) begin
      for (int position = 0; position < 3; position++) begin
        automatic logic [31:0] atomic_inst;
        case (kind)
          0: atomic_inst = 32'h1005202f; // LR.W x0,(a0)
          1: atomic_inst = 32'h18b5232f; // SC.W t1,a1,(a0)
          2: atomic_inst = 32'h1005302f; // LR.D x0,(a0)
          default: atomic_inst = 32'h18b5332f;
        endcase
        cmu_bcast.flush_pipe = 1;
        cmu_bcast.cpc = 'h80006000;
        tick();
        cmu_bcast.flush_pipe = 0;
        ifu_idu.ready = '{default: 0};
        ifu_l1i.inst_n0 = position == 0 ? atomic_inst : 32'h00000013;
        ifu_l1i.inst_n1 = position == 1 ? atomic_inst : 32'h18b5232f;
        if (position == 2) ifu_l1i.inst_n1 = 32'h00000013;
        ifu_l1i.inst_n2 = position == 2 ? atomic_inst : 32'h18b5232f;
        tick();
        assert (dut.blocked && dut.held_count == position + 1
            && ifu_idu.slot[position].inst == atomic_inst)
        else $fatal(1, "atomic failed to terminate fetch prefix");
        ifu_idu.ready = '{default: 1};
        tick();
        assert (dut.held_count == 0 && dut.pmu_fetch_slots == position + 1)
        else $fatal(1, "atomic prefix was not delivered exactly once");
        repeat (70) begin
          tick();
          assert (dut.blocked && !dut.recv_ready && dut.held_count == 0
              && !ifu_idu.valid[0] && !dut.pmu_fetch_fire)
          else $fatal(1, "younger fetch escaped atomic stop before redirect");
        end
        cmu_bcast.flush_pipe = 1;
        cmu_bcast.cpc = 'h80006000 + XLEN'(4 * (position + 1));
        tick();
        cmu_bcast.flush_pipe = 0;
        ifu_l1i.inst_n0 = 32'h00000013;
        ifu_l1i.inst_n1 = 32'h00000013;
        ifu_l1i.inst_n2 = 32'h00000013;
        tick();
        assert (!dut.blocked && dut.held_count == 3 && ifu_idu.slot[0].pc == cmu_bcast.cpc)
        else $fatal(1, "retirement redirect did not resume sequential fetch");
      end
    end
    $display("PASS: IFU stream events, history, Svinval and atomic fetch stop XLEN=%0d", XLEN);
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "IFU event timeout");
  end
endmodule
