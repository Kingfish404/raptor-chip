// Included only in the NPC wrapper with RAPT_LRSC_OBSERVE and !SYNTHESIS.
// Read-only pre-NBA edge observations. These events are not liveness proofs.
`define LRSC_CORE cpu.core
`define LRSC_BACKEND cpu.core.backend
longint unsigned lrsc_observe_cycle = 0;
always @(posedge clock) begin
  if (reset) lrsc_observe_cycle <= 0;
  else begin
    lrsc_observe_cycle <= lrsc_observe_cycle + 1;
    if (`LRSC_CORE.cmu_bcast.flush_pipe || `LRSC_CORE.cmu_bcast.fence_time)
      $display("LRSC_EVT %0d F %0d %0d", lrsc_observe_cycle,
        `LRSC_CORE.cmu_bcast.flush_pipe, `LRSC_CORE.cmu_bcast.fence_time);
    if (external_write_valid_i || external_write_pending_i)
      $display("LRSC_EVT %0d E %0d %0d %h %h %0d %0d",
        lrsc_observe_cycle, external_write_valid_i, external_write_pending_i,
        external_write_first_i, external_write_last_i,
        `LRSC_CORE.lsu_l1d.rvalid, `LRSC_CORE.lsu_l1d.atomic_lock);
    if (`LRSC_BACKEND.lsu.u_ioq.ioq_valid[`LRSC_BACKEND.lsu.u_ioq.ioq_head]
        && `LRSC_BACKEND.lsu.u_ioq.ioq_atom[`LRSC_BACKEND.lsu.u_ioq.ioq_head])
      $display("LRSC_EVT %0d A %h %0d %0d %0d %0d %0d %h %0d %0d %0d %0d",
        lrsc_observe_cycle,
        `LRSC_BACKEND.lsu.u_ioq.ioq_pc[`LRSC_BACKEND.lsu.u_ioq.ioq_head],
        `LRSC_BACKEND.lsu.u_ioq.ioq_dest[`LRSC_BACKEND.lsu.u_ioq.ioq_head],
        `LRSC_BACKEND.lsu.u_ioq.ioq_generation[`LRSC_BACKEND.lsu.u_ioq.ioq_head],
        `LRSC_BACKEND.lsu.u_ioq.ioq_alu[`LRSC_BACKEND.lsu.u_ioq.ioq_head],
        `LRSC_BACKEND.exu_ioq_bcast.valid, `LRSC_BACKEND.lsu.wb_accept,
        `LRSC_BACKEND.exu_ioq_bcast.result, `LRSC_CORE.exu_l1d.reservation_valid,
        `LRSC_CORE.exu_l1d.reservation_blocked,
        `LRSC_CORE.exu_l1d.reservation_clear, `LRSC_CORE.cmu_bcast.flush_pipe);
    if ((|`LRSC_BACKEND.lsu.u_sq.sq_alloc_oh)
        || (|`LRSC_BACKEND.lsu.u_sq.sq_commit_oh)
        || (|`LRSC_BACKEND.lsu.u_sq.sq_drain_oh)
        || (|`LRSC_BACKEND.lsu.u_sq.sq_flush_clear_oh))
      $display("LRSC_EVT %0d Q %h %h %h %h %h %0d %0d %h",
        lrsc_observe_cycle, `LRSC_BACKEND.lsu.u_sq.sq_alloc_oh,
        `LRSC_BACKEND.lsu.u_sq.sq_commit_oh, `LRSC_BACKEND.lsu.u_sq.sq_drain_oh,
        `LRSC_BACKEND.lsu.u_sq.sq_flush_clear_oh,
        `LRSC_BACKEND.exu_ioq_bcast.pc, `LRSC_BACKEND.exu_ioq_bcast.dest,
        `LRSC_BACKEND.exu_ioq_bcast.generation, `LRSC_BACKEND.exu_ioq_bcast.sq_waddr);
    for (int c=0;c<rapt_pkg::CommitWidth;c++)
      if (`LRSC_BACKEND.rou_cmu.slot[c].valid && `LRSC_BACKEND.rou_cmu.slot[c].atomic)
        $display("LRSC_EVT %0d R %h %h %0d %0d %0d %0d",
          lrsc_observe_cycle, `LRSC_BACKEND.rou_cmu.slot[c].pc,
          `LRSC_BACKEND.rou_cmu.slot[c].inst,
          `LRSC_BACKEND.rou.commit_index[c],
          `LRSC_BACKEND.rou.rob_entry[`LRSC_BACKEND.rou.commit_index[c]].generation,
          `LRSC_BACKEND.rou_cmu.slot[c].trap,
          `LRSC_BACKEND.rou.rob_entry[`LRSC_BACKEND.rou.commit_index[c]].wen);
  end
end
`undef LRSC_BACKEND
`undef LRSC_CORE
