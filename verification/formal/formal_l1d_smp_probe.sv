`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

// Closed-loop SMP probe + L1D/bus formal contract:
// Real rapt_l1d (2 sets, 1 way, 2 words/line) + rapt_bus under concurrent
// load, store, I-PTW, SMP back-invalidation probe, and post-probe victim
// verification read.
// Proves:
//   1. Bounded progress of probe_ready_o + load/store/PTW/verify (no deadlock)
//   2. Exact cycle-for-cycle synchronization between u_data and u_tags writes
//   3. End-to-end resident victim data integrity across colliding probe+refill
//   4. No stale refill install after mid-refill probe, and immediate LR clear
module formal_l1d_smp_probe #(
    parameter bit WriteBack = 1'b0,
    parameter bit TargetedCoherence = `RAPT_L1D_TARGETED_COHERENCE
) (
    input logic clock,
    input logic reset,
    input logic [3:0] advance,
    input logic [1:0] load_start,
    input logic [1:0] store_start,
    input logic [1:0] ptw_start,
    input logic [3:0] probe_start,
    input logic [1:0] relation,
    input logic [1:0] kind,
    input logic [1:0] probe_target
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam int Deadline = 48;
  localparam int LineOffW = $clog2(2 * Bytes);
  localparam logic [XLEN-1:0] AddrLoad = XLEN'('h80000100);
  localparam logic [XLEN-1:0] AddrSet1 = XLEN'('h80000400 + 2 * Bytes);
  localparam logic [XLEN-1:0] AddrVictim = XLEN'('h80000800);
  localparam logic [XLEN-1:0] InitVictim = (XLEN == 64) ? 64'h1122_3344_5566_7788 : 32'h1122_3344;
  localparam logic [XLEN-1:0] StoreData = (XLEN == 64) ? 64'hCAFE_BABE_DEAD_8800 : 32'hCAFE_8800;
  localparam logic [XLEN-1:0] LoadFill0 = (XLEN == 64) ? 64'hA5A5_5A5A_0100_0000 : 32'hA5A5_0100;

  logic past_valid = 1'b0;
  always @(posedge clock) past_valid <= 1'b1;
  always_comb begin
    assume (reset == !past_valid);
    assume (relation < 3);
    assume (kind < 3);
    assume (probe_target < 3);
    assume (probe_start <= 4'd12);
  end
  wire [15:0] cfg_now = {
      load_start, store_start, ptw_start, probe_start, relation, kind, probe_target
  };
  logic [15:0] cfg_prev;
  always @(posedge clock) begin
    cfg_prev <= cfg_now;
    if (past_valid) assume (cfg_now == cfg_prev);
  end

  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  l1d_bus_if l1d_bus ();
  l1i_bus_if l1i_bus ();
  mem_link_if mem ();

  logic coherent_request, coherent_write, coherent_ready;
  logic [XLEN-1:0] coherent_addr;
  logic probe_valid, probe_ready;
  logic [XLEN-1:0] probe_addr;
  logic probe_release_valid, probe_release_ready, probe_rel_wait;

  rapt_l1d #(
      .WriteBack(WriteBack),
      .TargetedCoherence(TargetedCoherence),
      .LineRefill(1),
      .L1D_LEN(1),
      .L1D_N_WAYS(1),
      .L1D_LINE_LEN(1)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock,
      .reset,
      .coherent_request,
      .coherent_addr,
      .coherent_write,
      .coherent_ready,
      .cmu_bcast,
      .csr_bcast,
      .pmp_update,
      .lsu_l1d,
      .exu_l1d,
      .l1d_bus,
      .probe_valid_i(probe_valid),
      .probe_addr_i(probe_addr),
      .probe_ready_o(probe_ready),
      .probe_release_valid_o(probe_release_valid),
      .probe_release_ready_i(probe_release_ready),
      .release_ready_i(1'b0),
      .release_ack_i(1'b0),
      .probe_window_i(probe_valid),
      .writeback_drain(1'b0),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0)
  );
  rapt_bus #(
      .TargetedCoherence(TargetedCoherence)
  ) bus_dut (
      .clock,
      .reset,
      .coherent_request,
      .coherent_addr,
      .coherent_write,
      .coherent_ready,
      .cmu_bcast,
      .csr_bcast,
      .l1i_bus,
      .l1d_bus,
      .mem
  );
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS

  logic [4:0] cycle;
  logic load_done, store_done, ptw_done, probe_done, verify_done;
  logic [6:0] load_age, store_age, ptw_age, probe_age, verify_age;
  logic saw_probe_during_refill;
  logic saw_probe_dirty_wb;
  logic saw_probe_hit_lr;
  logic saw_probe_blocked_data;
  logic victim_probed;
  logic [XLEN-1:0] mem_victim_w0;
  logic [XLEN-1:0] arch_victim_w0;

  wire verify_active = !reset && load_done && store_done && ptw_done && probe_done && !verify_done;

  always_comb begin
    init_l1d_inputs();
    if (verify_active) begin
      lsu_l1d.raddr = AddrVictim;
      lsu_l1d.ralu = (XLEN == 64) ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
      lsu_l1d.rvalid = 1'b1;
      lsu_l1d.rmisaligned = 1'b0;
      lsu_l1d.atomic_lock = 1'b0;
      lsu_l1d.rcheck_valid = 1'b0;
      lsu_l1d.rorig_size_m1 = (XLEN == 64) ? 4'd7 : 4'd3;
    end else begin
      lsu_l1d.raddr = AddrLoad;
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.rvalid = !reset && cycle >= {3'b0, load_start} && !load_done;
      lsu_l1d.rmisaligned = kind == 1;
      lsu_l1d.atomic_lock = kind == 2;
      lsu_l1d.rcheck_valid = kind == 1;
      lsu_l1d.rorig_size_m1 = 1;
    end
    lsu_l1d.waddr = relation == 1 ? (AddrLoad + Bytes)
        : relation == 2 ? AddrVictim : AddrSet1;
    lsu_l1d.wdata = StoreData;
    lsu_l1d.walu = (XLEN == 64) ? 8'hff : 8'h0f;
    lsu_l1d.wvalid = !reset && cycle >= {3'b0, store_start} && !store_done;
    l1i_bus.arvalid = !reset && cycle >= {3'b0, ptw_start} && !ptw_done;
    l1i_bus.araddr = AddrVictim;
    l1i_bus.ar_ptw = 1'b1;
    l1i_bus.arburst = 0;
    l1i_bus.rpbmt = 0;
    l1i_bus.noallocate = 0;

    probe_valid = !reset && cycle >= {1'b0, probe_start} && !probe_done;
    probe_addr = probe_target == 0 ? AddrLoad
        : probe_target == 1 ? lsu_l1d.waddr : AddrVictim;
  end

  logic read_pending, write_pending, read_valid, write_valid;
  logic ar_wait, aw_wait, r_wait, b_wait;
  logic [3:0] read_id, write_id;
  logic [7:0] beats;
  logic [XLEN-1:0] read_beat_addr;
  assign mem.rd_req_ready = !read_pending && (advance[0] || ar_wait);
  assign mem.wr_req_ready = !write_pending && (advance[1] || aw_wait);
  assign probe_release_ready = WriteBack && (advance[0] || probe_rel_wait);
  assign mem.rd_rsp_valid = read_valid;
  assign mem.rd_rsp_id = read_id;
  assign mem.rd_rsp_data = (read_beat_addr == AddrVictim)
      ? mem_victim_w0 : (LoadFill0 ^ read_beat_addr);
  assign mem.rd_rsp_last = beats == 1;
  assign mem.rd_rsp_error = 1'b0;
  assign mem.wr_rsp_valid = write_valid;
  assign mem.wr_rsp_id = write_id;
  assign mem.wr_rsp_error = 1'b0;

  wire probe_matches_load_line = probe_valid
      && (probe_addr[XLEN-1:LineOffW] == dut.l1d_addr[XLEN-1:LineOffW]);
  wire probe_matches_resv = probe_valid
      && (probe_addr[XLEN-1:LineOffW] == exu_l1d.reservation[XLEN-1:LineOffW]);
  wire probe_matches_victim = probe_valid
      && (probe_addr[XLEN-1:LineOffW] == AddrVictim[XLEN-1:LineOffW]);
  wire data_we = dut.l1d_update && dut.l1d_valid_u && !dut.data_write_blocked;
  wire tag_we  = dut.u_tags.update_enable && dut.l1d_valid_u;

  always @(posedge clock) begin
    if (reset) begin
      cycle <= '0;
      load_done <= 1'b0;
      store_done <= 1'b0;
      ptw_done <= 1'b0;
      probe_done <= 1'b0;
      verify_done <= 1'b0;
      load_age <= '0;
      store_age <= '0;
      ptw_age <= '0;
      probe_age <= '0;
      verify_age <= '0;
      saw_probe_during_refill <= 1'b0;
      saw_probe_dirty_wb <= 1'b0;
      saw_probe_hit_lr <= 1'b0;
      saw_probe_blocked_data <= 1'b0;
      victim_probed <= 1'b0;
      mem_victim_w0 <= InitVictim;
      arch_victim_w0 <= InitVictim;
      read_pending <= 1'b0;
      write_pending <= 1'b0;
      read_valid <= 1'b0;
      write_valid <= 1'b0;
      ar_wait <= 1'b0;
      aw_wait <= 1'b0;
      probe_rel_wait <= 1'b0;
      r_wait <= 1'b0;
      b_wait <= 1'b0;
      read_id <= '0;
      write_id <= '0;
      beats <= '0;
      read_beat_addr <= '0;
    end else begin
      if (cycle < 5'd16) cycle <= cycle + 5'd1;
      if (!load_done && lsu_l1d.rvalid && lsu_l1d.rready) load_done <= 1'b1;
      if (verify_active && lsu_l1d.rvalid && lsu_l1d.rready) verify_done <= 1'b1;
      if (lsu_l1d.wvalid && lsu_l1d.wready) begin
        store_done <= 1'b1;
        if (lsu_l1d.waddr == AddrVictim) arch_victim_w0 <= lsu_l1d.wdata;
      end
      if (l1i_bus.ptw_rvalid) ptw_done <= 1'b1;
      if (probe_valid && probe_ready) probe_done <= 1'b1;
      if (probe_matches_victim) victim_probed <= 1'b1;
      if (dut.l1d_update && dut.l1d_valid_u && !dut.wb_blocked
          && (dut.line_clearing || probe_valid || (|dut.fence_clear_set))) begin
        saw_probe_blocked_data <= 1'b1;
      end

      if (!load_done && lsu_l1d.rvalid) load_age <= load_age + 7'd1;
      if (verify_active) verify_age <= verify_age + 7'd1;
      if (lsu_l1d.wvalid) store_age <= store_age + 7'd1;
      if (l1i_bus.arvalid) ptw_age <= ptw_age + 7'd1;
      if (probe_valid) probe_age <= probe_age + 7'd1;

      // 1. Bounded progress: SMP probe must never deadlock load/store/PTW or itself
      load_progress : assert (load_age < Deadline);
      verify_progress : assert (verify_age < Deadline);
      store_progress : assert (store_age < Deadline);
      ptw_progress : assert (ptw_age < Deadline);
      probe_progress : assert (probe_age < Deadline);
      no_trap : assert (!lsu_l1d.trap);
      no_duplicate_ptw : assert (!(ptw_done && l1i_bus.ptw_rvalid));

      // 2. Exact tag/data array write-enable synchronization (prevents silent
      //    victim corruption when line_clearing / fence_clear_set suppresses u_tags)
      tag_data_write_sync : assert (data_we == tag_we);

      // 3. End-to-end resident victim integrity: if AddrVictim was not probed,
      //    reading AddrVictim after colliding Set-0 activity + probe must return
      //    its exact architectural value (never a cancelled fill's data).
      if (verify_active && lsu_l1d.rready && !victim_probed) begin
        victim_data_intact : assert (lsu_l1d.rdata == arch_victim_w0);
      end

      // 4. Immediate LR reservation invalidation on matching SMP probe
      if (probe_matches_resv) begin
        probe_clears_lr : assert (!exu_l1d.reservation_valid);
        if (dut.reservation_valid) saw_probe_hit_lr <= 1'b1;
      end

      // 5. No stale non-MSHR refill install after a matching probe during LD_A/LD_D
      if (dut.l1d_state == 0) begin
        saw_probe_during_refill <= 1'b0;
      end else if ((dut.l1d_state == 1 || dut.l1d_state == 2) && probe_matches_load_line) begin
        saw_probe_during_refill <= 1'b1;
      end
      if (saw_probe_during_refill && dut.l1d_state == 2) begin
        poison_latched : assert (dut.ld_refill_poison_q);
      end
      if (dut.probe_dirty_request) saw_probe_dirty_wb <= 1'b1;

      // Backing memory updates from bus writes and dirty probe releases
      if (mem.wr_req_valid && mem.wr_req_ready && (mem.wr_req_addr == AddrVictim)) begin
        mem_victim_w0 <= mem.wr_req_data;
      end
      if (WriteBack && probe_release_valid && probe_release_ready
          && (dut.probe_release_addr_o == AddrVictim)) begin
        mem_victim_w0 <= dut.probe_release_data_o;
      end

      // Bus responder (bounded fairness)
      ar_wait <= mem.rd_req_valid && !mem.rd_req_ready && !read_pending;
      aw_wait <= mem.wr_req_valid && !mem.wr_req_ready && !write_pending;
      probe_rel_wait <= probe_release_valid && !probe_release_ready;
      if (mem.rd_req_valid && mem.rd_req_ready) begin
        read_pending <= 1'b1;
        read_id <= mem.rd_req_id;
        beats <= mem.rd_req_len + 8'd1;
        read_beat_addr <= mem.rd_req_addr;
        r_wait <= 1'b0;
      end else if (read_pending && !read_valid) begin
        r_wait <= 1'b1;
        if (advance[2] || r_wait) read_valid <= 1'b1;
      end else if (mem.rd_rsp_valid && mem.rd_rsp_ready) begin
        read_valid <= 1'b0;
        r_wait <= 1'b0;
        beats <= beats - 8'd1;
        read_beat_addr <= read_beat_addr + XLEN'(Bytes);
        if (beats == 8'd1) read_pending <= 1'b0;
      end
      if (mem.wr_req_valid && mem.wr_req_ready) begin
        write_pending <= 1'b1;
        write_id <= mem.wr_req_id;
        b_wait <= 1'b0;
      end else if (write_pending && !write_valid) begin
        b_wait <= 1'b1;
        if (advance[3] || b_wait) write_valid <= 1'b1;
      end else if (mem.wr_rsp_valid && mem.wr_rsp_ready) begin
        write_valid <= 1'b0;
        write_pending <= 1'b0;
        b_wait <= 1'b0;
      end

      cov_probe_refill : cover (saw_probe_during_refill && load_done && probe_done);
      cov_victim_intact : cover (verify_done && !victim_probed && saw_probe_blocked_data);
      if (WriteBack) begin : g_cov_dirty
        cov_probe_dirty : cover (saw_probe_dirty_wb && probe_done && store_done);
      end
      cov_probe_lr : cover (saw_probe_hit_lr && probe_done);
      cov_all_done : cover (verify_done && ptw_done);
    end
  end
endmodule
