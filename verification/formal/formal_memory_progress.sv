`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

// Closed-loop progress contract, not a whole-cache/data equivalence proof.
// Real L1D + bus control; two sets, one way, two words/line, MSHRs disabled
// by the runner. Three one-shot requests start independently in cycles 0..3.
module formal_memory_progress #(
    parameter bit TargetedCoherence = `RAPT_L1D_TARGETED_COHERENCE
) (
    input logic clock,
    input logic reset,
    input logic [3:0] advance,
    input logic [1:0] load_start,
    store_start,
    ptw_start,
    input logic [1:0] relation,
    kind
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam int Deadline = 32;
  logic past_valid = 0;
  always @(posedge clock) past_valid <= 1;
  always_comb begin
    assume (reset == !past_valid);
    assume (relation < 3);
    assume (kind < 3);
  end
  always @(posedge clock)
    if (past_valid)
      assume ($stable({load_start, store_start, ptw_start, relation, kind}));

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
  logic [`RAPT_XLEN-1:0] coherent_addr;
  rapt_l1d #(
      .WriteBack(1),
      .TargetedCoherence(TargetedCoherence),
      .LineRefill(1),
      .L1D_LEN(1),
      .L1D_N_WAYS(1),
      .L1D_LINE_LEN(1)
  ) dut (
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
      .l1d_bus
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

  logic [2:0] cycle;
  logic load_done, store_done, ptw_done;
  logic [6:0] load_age, store_age, ptw_age;
  logic saw_collision, saw_owned_collision;
  always_comb begin
    init_l1d_inputs();
    lsu_l1d.raddr = XLEN'('h80000100);
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = !reset && cycle >= {1'b0, load_start} && !load_done;
    lsu_l1d.rmisaligned = kind == 1;
    lsu_l1d.atomic_lock = kind == 2;
    lsu_l1d.rcheck_valid = kind == 1;
    lsu_l1d.rorig_size_m1 = 1;
    lsu_l1d.waddr = relation == 1 ? XLEN'('h80000100 + Bytes)
        : relation == 2 ? XLEN'('h80000800) : XLEN'('h80000418);
    lsu_l1d.walu = 8'h03;
    lsu_l1d.wvalid = !reset && cycle >= {1'b0, store_start} && !store_done;
    l1i_bus.arvalid = !reset && cycle >= {1'b0, ptw_start} && !ptw_done;
    l1i_bus.araddr = XLEN'('h80000800);
    l1i_bus.ar_ptw = 1;
    l1i_bus.arburst = 0;
    l1i_bus.rpbmt = 0;
    l1i_bus.noallocate = 0;
  end

  // External fairness is constructive: AR/AW has at most one stall while
  // its slot is free; each response beat becomes valid within two edges of
  // being pending/rearmed, then holds until accepted. Choices are independent.
  // Never assume progress of an internal ready, FSM, or coherence signal.
  logic read_pending, write_pending, read_valid, write_valid;
  logic ar_wait, aw_wait, r_wait, b_wait;
  logic [3:0] read_id, write_id;
  logic [7:0] beats;
  assign mem.rd_req_ready = !read_pending && (advance[0] || ar_wait);
  assign mem.wr_req_ready = !write_pending && (advance[1] || aw_wait);
  assign mem.rd_rsp_valid = read_valid;
  assign mem.rd_rsp_id = read_id;
  assign mem.rd_rsp_data = '0;
  assign mem.rd_rsp_last = beats == 1;
  assign mem.rd_rsp_error = 0;
  assign mem.wr_rsp_valid = write_valid;
  assign mem.wr_rsp_id = write_id;
  assign mem.wr_rsp_error = 0;
  always @(posedge clock) begin
    if (reset) begin
      cycle <= 0;
      load_done <= 0;
      store_done <= 0;
      ptw_done <= 0;
      load_age <= 0;
      store_age <= 0;
      ptw_age <= 0;
      saw_collision <= 0;
      saw_owned_collision <= 0;
      read_pending <= 0;
      write_pending <= 0;
      read_valid <= 0;
      write_valid <= 0;
      ar_wait <= 0;
      aw_wait <= 0;
      r_wait <= 0;
      b_wait <= 0;
      read_id <= 0;
      write_id <= 0;
      beats <= 0;
    end else begin
      if (cycle < 4) cycle <= cycle + 1;
      if (lsu_l1d.rvalid && lsu_l1d.rready) load_done <= 1;
      if (lsu_l1d.wvalid && lsu_l1d.wready) store_done <= 1;
      if (l1i_bus.ptw_rvalid) ptw_done <= 1;
      // Start at presentation (before even L1D admission or AR). Never reset
      // age on an unrelated completion, state transition or attempted retry.
      if (lsu_l1d.rvalid) load_age <= load_age + 1;
      if (lsu_l1d.wvalid) store_age <= store_age + 1;
      if (l1i_bus.arvalid) ptw_age <= ptw_age + 1;
      load_progress : assert (load_age < Deadline);
      store_progress : assert (store_age < Deadline);
      ptw_progress : assert (ptw_age < Deadline);
      no_trap : assert (!lsu_l1d.trap);
      no_load_replay : assert (!lsu_l1d.rmiss);
      no_duplicate_load : assert (!(load_done && lsu_l1d.rready));
      no_duplicate_ptw : assert (!(ptw_done && l1i_bus.ptw_rvalid));
      owned_store_order :
      assert (!(dut.lsu_bus_write_pending_q && l1d_bus.arvalid && !l1d_bus.ar_ptw));

      ar_wait <= mem.rd_req_valid && !mem.rd_req_ready && !read_pending;
      aw_wait <= mem.wr_req_valid && !mem.wr_req_ready && !write_pending;
      if (mem.rd_req_valid && mem.rd_req_ready) begin
        read_pending <= 1;
        read_id <= mem.rd_req_id;
        beats <= mem.rd_req_len + 1;
        r_wait <= 0;
        read_length : assert (mem.rd_req_len <= 1);
      end else if (read_pending && !read_valid) begin
        r_wait <= 1;
        if (advance[2] || r_wait) read_valid <= 1;
      end else if (mem.rd_rsp_valid && mem.rd_rsp_ready) begin
        read_valid <= 0;
        r_wait <= 0;
        beats <= beats - 1;
        if (beats == 1) read_pending <= 0;
      end
      if (mem.wr_req_valid && mem.wr_req_ready) begin
        write_pending <= 1;
        write_id <= mem.wr_req_id;
        b_wait <= 0;
      end else if (write_pending && !write_valid) begin
        b_wait <= 1;
        if (advance[3] || b_wait) write_valid <= 1;
      end else if (mem.wr_rsp_valid && mem.wr_rsp_ready) begin
        write_valid <= 0;
        write_pending <= 0;
        b_wait <= 0;
      end
      collision :
      cover (dut.l1d_state == 1 && coherent_request && lsu_l1d.wvalid
          && !dut.local_store && !dut.lsu_bus_write_pending_q && !coherent_ready);
      if (dut.l1d_state == 1 && coherent_request && lsu_l1d.wvalid
          && !dut.local_store && !dut.lsu_bus_write_pending_q && !coherent_ready)
        saw_collision <= 1;
      owned_collision :
      cover (dut.l1d_state == 1 && coherent_request && dut.lsu_bus_write_pending_q);
      if (dut.l1d_state == 1 && coherent_request && dut.lsu_bus_write_pending_q)
        saw_owned_collision <= 1;
      same_line : cover (relation == 1 && load_done && store_done && ptw_done);
      pte_alias : cover (relation == 2 && load_done && store_done && ptw_done);
      finished : cover (load_done && store_done && ptw_done);
      escaped_collision : cover (saw_collision && load_done && store_done && ptw_done);
      escaped_owned_collision : cover (saw_owned_collision && load_done && store_done && ptw_done);
    end
  end
endmodule
