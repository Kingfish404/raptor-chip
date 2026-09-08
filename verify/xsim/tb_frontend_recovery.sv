`include "rapt.svh"
`include "rapt_if.svh"

// Integration contract for completion-time branch recovery.  The redirect
// may warm the target-side instruction path immediately, while all mutable
// IFU/FQU/IDU stream state remains empty until the precise cleanup fence drops.
module tb_frontend_recovery;
  localparam int XLEN = 32;
  localparam logic [XLEN-1:0] RecoveryTarget = 32'h8000_3000;

  logic clock = 0, reset = 1;
  always #5 clock = ~clock;

  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_recovery_if #(.XLEN(XLEN)) recovery ();
  ifu_bpu_if #(.XLEN(XLEN)) ifu_bpu ();
  idu_bpu_if #(.XLEN(XLEN)) idu_bpu ();
  ifu_l1i_if #(.XLEN(XLEN)) ifu_l1i ();
  ifu_idu_if #(.XLEN(XLEN)) ifu_fqu ();
  ifu_idu_if #(.XLEN(XLEN)) fqu_idu ();
  idu_rnu_if #(.XLEN(XLEN)) idu_rnu ();

  rapt_ifu #(
      .XLEN(XLEN)
  ) ifu (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu(ifu_fqu),
      .ifu_hazard()
  );

  rapt_fqu #(
      .XLEN(XLEN)
  ) fqu (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_in(ifu_fqu),
      .idu_out(fqu_idu)
  );

  rapt_idu #(
      .XLEN(XLEN)
  ) idu (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .csr_bcast,
      .ifu_idu(fqu_idu),
      .idu_rnu,
      .idu_bpu
  );

  `include "tb_core_bcast_defaults.svh"

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(2'b11, '0, 1'b1);

    recovery.pending = 1'b0;
    recovery.redirect_valid = 1'b0;
    recovery.owner = '0;
    recovery.generation = '0;
    recovery.target = '0;
    recovery.checkpoint_valid = 1'b0;
    recovery.checkpoint = '0;

    ifu_bpu.npc = '0;
    ifu_bpu.taken = 1'b0;
    ifu_bpu.aux_taken = 1'b0;
    idu_bpu.ras_valid = 1'b0;
    idu_bpu.ras_addr = '0;

    // Four C.NOPs per response make occupancy visible at every front-end
    // boundary.  Backpressure at RNU lets IDU retain the oldest group.
    ifu_l1i.valid = 1'b1;
    ifu_l1i.inst_n0 = 32'h0001_0001;
    ifu_l1i.inst_n1 = 32'h0001_0001;
    ifu_l1i.inst_n2 = 32'h0001_0001;
    ifu_l1i.inst_n1_valid = 1'b1;
    ifu_l1i.inst_n2_valid = 1'b1;
    ifu_l1i.trap = 1'b0;
    ifu_l1i.cause = '0;
    ifu_l1i.tval = '0;
    idu_rnu.ready = '{default: 1'b0};

    repeat (3) tick();
    reset = 1'b0;
    repeat (4) tick();
    assert (ifu.held_count != 0 && fqu.pmu_count != 0 && idu.count != 0)
    else $fatal(1, "front-end did not establish work before recovery");

    recovery.pending = 1'b1;
    recovery.redirect_valid = 1'b1;
    recovery.target = RecoveryTarget;
    #1;
    assert (ifu.redirect_event && ifu_l1i.prefetch_valid && ifu_l1i.prefetch_pc == RecoveryTarget)
    else $fatal(1, "recovery redirect did not launch target read-ahead");
    tick();
    recovery.redirect_valid = 1'b0;
    #1;
    assert (ifu.pc_ifu == RecoveryTarget && ifu.held_count == 0
            && fqu.pmu_count == 0 && idu.count == 0)
    else $fatal(1, "recovery did not atomically cancel front-end stream state");

    // The L1I response remains available, deliberately stressing the fence.
    // No stage may consume it, append history, or present work downstream.
    repeat (3) begin
      assert (!ifu.recv_ready && !ifu_bpu.history_valid
              && !idu_bpu.history_valid && !idu_rnu.valid[0])
      else $fatal(1, "recovery fence leaked a front-end acceptance event");
      tick();
      assert (ifu.held_count == 0 && fqu.pmu_count == 0 && idu.count == 0)
      else $fatal(1, "front-end repopulated while recovery remained pending");
    end

    // Once precise cleanup releases the fence, the warmed target is the first
    // instruction stream admitted to decode.
    recovery.pending = 1'b0;
    begin : wait_for_target
      automatic bit target_seen = 1'b0;
      for (int cycle = 0; cycle < 8; cycle++) begin
        tick();
        if (idu_rnu.valid[0]) begin
          assert (idu_rnu.slot[0].uop.pc == RecoveryTarget)
          else $fatal(1, "post-recovery decode resumed at the wrong PC");
          target_seen = 1'b1;
          break;
        end
      end
      assert (target_seen)
      else $fatal(1, "target stream did not resume after recovery release");
    end
    $display("PASS: unified recovery redirects once, fences IFU/FQU/IDU, and resumes at target");
    $finish;
  end

  initial begin
    #1500;
    $fatal(1, "front-end recovery timeout");
  end
endmodule
