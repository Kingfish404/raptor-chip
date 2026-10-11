`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

// Backend fed by decoded committed instructions from a NEMU execution trace.
// Actual next PC is supplied as an oracle prediction, isolating backend
// admission/issue/commit capacity. The real memory composition supplies data.
module tb_backend_trace;
  localparam int XLEN = `RAPT_XLEN;
  localparam int MaxTrace = 200000;
  localparam int MaxImage = 262144;
  localparam int SecondSlot = rapt_pkg::CommitWidth > 1 ? 1 : 0;
  localparam logic [XLEN-1:0] ImageBase = XLEN'('h80000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  idu_rnu_if idu_rnu ();
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_recovery_if recovery ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  ifu_l1i_if ifu_l1i ();
  axi4_if axi ();
  logic backend_empty, sq_empty, writeback_done, writeback_drain;
  logic memory_data_idle, memory_wb_error, io_start, halted, commit_fire;
  logic [XLEN-1:0] io_owner, halt_pc, dbg_gpr_data;
  logic history_restore;
  logic [63:0] restore_ghr;
  logic [7:0] restore_phr;
  logic sim_finish;
  logic [31:0] sim_exit_code;

  rapt_backend dut (
      .clock,
      .reset,
      .writeback_done,
      .writeback_drain,
      .idu_rnu,
      .cmu_bcast,
      .csr_bcast,
      .recovery,
      .pmp_update,
      .lsu_l1d,
      .exu_l1d,
      .empty_o(backend_empty),
      .sq_empty_o(sq_empty),
      .clint_timer_int_i(1'b0),
      .clint_sw_int_i(1'b0),
      .mtime_i(64'(cycles)),
      .io_interrupt(1'b0),
      .s_ext_irq_i(1'b0),
      .hart_id_i('0),
      .dm_haltreq_i(1'b0),
      .halted_o(halted),
      .halt_pc_o(halt_pc),
      .commit_fire_o(commit_fire),
      .dbg_gpr_rdata_o(dbg_gpr_data),
      .dbg_gpr_we_i(1'b0),
      .dbg_gpr_addr_i('0),
      .dbg_gpr_wdata_i('0),
      .snapshot_ghr('0),
      .snapshot_phr('0),
      .history_restore,
      .restore_ghr,
      .restore_phr
  );
  rapt_memory memory_env (
      .clock,
      .reset,
      .ifu_l1i,
      .lsu_l1d,
      .exu_l1d,
      .cmu_bcast,
      .csr_bcast,
      .pmp_update,
      .io_master(axi),
      .ifetch_io_authorized_i(1'b0),
      .ifetch_io_start_o(io_start),
      .ifetch_io_owner_pc_o(io_owner),
      .data_idle_o(memory_data_idle),
      .writeback_idle_o(),
      .writeback_done_o(writeback_done),
      .stores_empty_i(sq_empty),
      .writeback_drain_i(writeback_drain),
      .writeback_error_o(memory_wb_error)
  );
  tb_axi_image #(
      .XLEN(XLEN)
  ) external_memory (
      .clock,
      .reset,
      .axi,
      .sim_finish,
      .sim_exit_code
  );

  byte unsigned image[MaxImage];
  logic [XLEN-1:0] trace_pc[MaxTrace], trace_npc[MaxTrace];
  logic [31:0] trace_inst[MaxTrace];
  rapt_pkg::fetch_slot_t fetched[rapt_pkg::DecodeWidth];
  rapt_pkg::decoded_slot_t decoded[rapt_pkg::DecodeWidth];
  int trace_count, image_size, feed_index, commit_index, feed_width, cycles;

  for (genvar s = 0; s < rapt_pkg::DecodeWidth; s++) begin : g_decode
    rapt_decode_slot decoder (
        .fetched(fetched[s]),
        .csr_bcast,
        .decoded(decoded[s])
    );
    always_comb begin
      fetched[s] = '0;
      if (feed_index + s < trace_count) begin
        fetched[s].pc = trace_pc[feed_index+s];
        fetched[s].inst = trace_inst[feed_index+s];
        fetched[s].pnpc = trace_npc[feed_index+s];
        fetched[s].predicted_taken = trace_npc[feed_index+s]
            != trace_pc[feed_index+s]
                + XLEN'((trace_inst[feed_index+s][1:0] == 2'b11) ? 4 : 2);
      end
      idu_rnu.slot[s] = decoded[s];
      idu_rnu.valid[s] = !reset && s < feed_width && feed_index+s < trace_count
          && !cmu_bcast.flush_pipe && !cmu_bcast.sys_resume;
    end
  end

  function automatic logic [31:0] image_inst(input logic [XLEN-1:0] pc);
    logic [31:0] raw;
    int unsigned offset;
    offset = int'(pc - ImageBase);
    if (pc < ImageBase || offset + 3 >= image_size) return 32'h00000013;
    raw = {image[offset+3], image[offset+2], image[offset+1], image[offset]};
    if (raw[1:0] != 2'b11) raw[31:16] = '0;
    return raw;
  endfunction

  always_comb begin
    // Keep the unused instruction-side memory interface at one stable PC.
    ifu_l1i.pc = ImageBase;
    ifu_l1i.invalid = 0;
    ifu_l1i.consumed = 0;
    ifu_l1i.cancel = 0;
    ifu_l1i.prefetch_pc = '0;
    ifu_l1i.prefetch_valid = 0;
  end

  initial begin : run
    string image_path, trace_path;
    int fd, status, max_insts, max_cycles;
    int accepted, committed, front_stall, commit_empty, flushes, next_feed_index;
    int loads, stores, axi_reads, axi_writes, last_progress;
    int commit_slots[rapt_pkg::CommitWidth+1];
    int head_empty, head_dispatch, head_execute, head_writeback;
    int head_store_wait, head_drain_wait, rename_stall, operand_stall;
    int dispatch_stops[rapt_pkg::DispatchStopCount];
    int head_wait_domain[rapt_pkg::ExecutionDomains];
    int ioq_full_cycles, head_wait_ioq_full, rob_stop_ioq_full;
    int second_empty, second_dispatch, second_execute, second_writeback;
    int store_first_second_wb, store_first_second_plain_wb;
    int second_wait_domain[rapt_pkg::ExecutionDomains];
    int load_b_hits, load_b_retries, load_a_misses, load_a_retries, wake_next_requests;
    int head_mem_l1d_state[8];
    int head_mem_ioq_empty, head_mem_operand_wait, head_mem_addr_wait;
    int head_mem_no_a_request, head_mem_a_request, head_mem_b_request;
    int head_mem_ioq_load, head_mem_ioq_store, head_mem_ioq_complete;
    int head_mem_idle_no_a, head_mem_idle_a, head_mem_no_a_issue_ready;
    int head_mem_a_owner_head, head_mem_a_owner_younger;
    int early_load_complete_events, early_load_wait_cycles, early_load_broadcasts;
    int early_bcast_next_dependent, early_bcast_next_request_slot;
    int early_bcast_next_b_request_slot;
    logic [rapt_pkg::CoreConfig.ioq_entries-1:0] last_ioq_complete;
    int committed_this_cycle;
    logic [XLEN-1:0] pc_value, npc_value;
    logic [31:0] inst_value;
    if (!$value$plusargs("IMG=%s", image_path)) $fatal(1, "+IMG required");
    if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "+TRACE required");
    if (!$value$plusargs("MAX_INSTS=%d", max_insts)) max_insts = 20000;
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 100000;
    if (!$value$plusargs("FEED_WIDTH=%d", feed_width)) feed_width = rapt_pkg::DecodeWidth;
    if (feed_width < 1 || feed_width > rapt_pkg::DecodeWidth) $fatal(1, "invalid feed width");
    fd = $fopen(image_path, "rb");
    if (!fd) $fatal(1, "cannot open image %s", image_path);
    image_size = $fread(image, fd);
    $fclose(fd);
    if (image_size == 0 || image_size == MaxImage) $fatal(1, "invalid image size");
    fd = $fopen(trace_path, "r");
    if (!fd) $fatal(1, "cannot open trace %s", trace_path);
    trace_count = 0;
    while (!$feof(
        fd
    ) && trace_count < MaxTrace && trace_count < max_insts) begin
      status = $fscanf(fd, "%h %h %h\n", pc_value, inst_value, npc_value);
      if (status == 3 && pc_value >= ImageBase && pc_value < ImageBase + XLEN'(image_size)) begin
        trace_pc[trace_count] = pc_value;
        trace_npc[trace_count] = npc_value;
        trace_inst[trace_count] = image_inst(pc_value);
        trace_count++;
      end
    end
    $fclose(fd);
    if (trace_count < 100) $fatal(1, "trace too short");
    feed_index = 0;
    commit_index = 0;
    cycles = 0;
    accepted = 0;
    committed = 0;
    front_stall = 0;
    commit_empty = 0;
    flushes = 0;
    loads = 0;
    stores = 0;
    axi_reads = 0;
    axi_writes = 0;
    last_progress = 0;
    foreach (commit_slots[s]) commit_slots[s] = 0;
    foreach (dispatch_stops[s]) dispatch_stops[s] = 0;
    foreach (head_wait_domain[s]) head_wait_domain[s] = 0;
    foreach (second_wait_domain[s]) second_wait_domain[s] = 0;
    head_empty = 0;
    head_dispatch = 0;
    head_execute = 0;
    head_writeback = 0;
    head_store_wait = 0;
    head_drain_wait = 0;
    rename_stall = 0;
    operand_stall = 0;
    ioq_full_cycles = 0;
    head_wait_ioq_full = 0;
    rob_stop_ioq_full = 0;
    second_empty = 0;
    second_dispatch = 0;
    second_execute = 0;
    second_writeback = 0;
    store_first_second_wb = 0;
    store_first_second_plain_wb = 0;
    load_b_hits = 0;
    load_b_retries = 0;
    load_a_misses = 0;
    load_a_retries = 0;
    wake_next_requests = 0;
    foreach (head_mem_l1d_state[s]) head_mem_l1d_state[s] = 0;
    head_mem_ioq_empty = 0;
    head_mem_operand_wait = 0;
    head_mem_addr_wait = 0;
    head_mem_no_a_request = 0;
    head_mem_a_request = 0;
    head_mem_b_request = 0;
    head_mem_ioq_load = 0;
    head_mem_ioq_store = 0;
    head_mem_ioq_complete = 0;
    head_mem_idle_no_a = 0;
    head_mem_idle_a = 0;
    head_mem_no_a_issue_ready = 0;
    head_mem_a_owner_head = 0;
    head_mem_a_owner_younger = 0;
    early_load_complete_events = 0;
    early_load_wait_cycles = 0;
    early_load_broadcasts = 0;
    early_bcast_next_dependent = 0;
    early_bcast_next_request_slot = 0;
    early_bcast_next_b_request_slot = 0;
    last_ioq_complete = '0;
    repeat (5) @(negedge clock);
    reset = 0;
    while (commit_index < trace_count && cycles < max_cycles) begin
      @(posedge clock);
      // Retire is the source of truth for a trace after any precise flush.
      committed_this_cycle = 0;
      for (int s = 0; s < rapt_pkg::CommitWidth; s++) begin
        if (dut.rou_cmu.slot[s].valid) begin
          if (dut.rou_cmu.slot[s].pc != trace_pc[commit_index])
            $fatal(
                1,
                "BE commit PC mismatch at %0d: got %h expected %h",
                commit_index,
                dut.rou_cmu.slot[s].pc,
                trace_pc[commit_index]
            );
          if (dut.rou_cmu.slot[s].npc != trace_npc[commit_index])
            $fatal(
                1,
                "BE commit NPC mismatch at %0d: got %h expected %h",
                commit_index,
                dut.rou_cmu.slot[s].npc,
                trace_npc[commit_index]
            );
          commit_index++;
          committed++;
          committed_this_cycle++;
          last_progress = cycles;
        end
      end
      commit_slots[committed_this_cycle]++;
      if (committed_this_cycle == 1 && rapt_pkg::CommitWidth > 1) begin
        if (dut.rou.rob_entry[dut.rou.commit_index[0]].wen
            && dut.rou.rob_entry_busy[dut.rou.commit_index[SecondSlot]]
            && dut.rou.rob_entry[dut.rou.commit_index[SecondSlot]].state == rapt_pkg::ROB_WB) begin
          store_first_second_wb++;
          if (!dut.rou.rob_entry[dut.rou.commit_index[SecondSlot]].wen
              && !dut.rou.rob_control_flow[dut.rou.commit_index[SecondSlot]]
              && !dut.rou.rob_serializing[dut.rou.commit_index[SecondSlot]]
              && !dut.rou.rob_atomic[dut.rou.commit_index[SecondSlot]]
              && !dut.rou.rob_entry[dut.rou.commit_index[SecondSlot]].trap
              && !dut.rou.rob_entry[dut.rou.commit_index[SecondSlot]].mispredict
              && !dut.rou.rob_entry[dut.rou.commit_index[SecondSlot]].difftest_skip)
            store_first_second_plain_wb++;
        end
        if (!dut.rou.rob_entry_busy[dut.rou.commit_index[SecondSlot]]) second_empty++;
        else
          case (dut.rou.rob_entry[dut.rou.commit_index[SecondSlot]].state)
            rapt_pkg::ROB_DP: second_dispatch++;
            rapt_pkg::ROB_EX: begin
              second_execute++;
              if (int'(dut.rou.uop_pl[dut.rou.commit_index[SecondSlot]].schedule.domain)
                  < rapt_pkg::ExecutionDomains)
                second_wait_domain[int'(dut.rou.uop_pl[dut.rou.commit_index[SecondSlot]].schedule.domain)]++;
            end
            rapt_pkg::ROB_WB: second_writeback++;
            default: second_empty++;
          endcase
      end
      if (!dut.rou.pmu_head_busy) head_empty++;
      else
        case (dut.rou.pmu_head_state)
          rapt_pkg::ROB_DP: head_dispatch++;
          rapt_pkg::ROB_EX: head_execute++;
          rapt_pkg::ROB_WB: head_writeback++;
          default: head_empty++;
        endcase
      if (dut.rou.pmu_head_store_wait) head_store_wait++;
      if (dut.rou.pmu_head_drain_wait) head_drain_wait++;
      if (dut.lsu.u_ioq.pmu_ioq_all_full) ioq_full_cycles++;
      for (int e = 0; e < rapt_pkg::CoreConfig.ioq_entries; e++) begin
        if (dut.lsu.u_ioq.ioq_valid[e] && dut.lsu.u_ioq.ioq_complete[e]
            && dut.lsu.u_ioq.ioq_ren[e] && !dut.lsu.u_ioq.ioq_wen[e]
            && !dut.lsu.u_ioq.ioq_atom[e] && !dut.lsu.u_ioq.ioq_load_trap[e]
            && !dut.lsu.u_ioq.ioq_load_skip[e] && !dut.lsu.u_ioq.ioq_fp_valid[e]
            && e != int'(dut.lsu.u_ioq.ioq_head)) begin
          early_load_wait_cycles++;
          if (!last_ioq_complete[e]) early_load_complete_events++;
        end
      end
      last_ioq_complete = dut.lsu.u_ioq.ioq_complete;
      if (dut.lsu.u_ioq.early_bcast_issue && dut.lsu.u_ioq.wb_accept) begin
        int next_idx;
        early_load_broadcasts++;
        next_idx = (int'(dut.lsu.u_ioq.early_bcast_idx) + 1) % rapt_pkg::CoreConfig.ioq_entries;
        if (dut.lsu.u_ioq.ioq_valid[next_idx] && dut.lsu.u_ioq.ioq_ren[next_idx]
            && !dut.lsu.u_ioq.ioq_wen[next_idx] && !dut.lsu.u_ioq.ioq_atom[next_idx]
            && dut.lsu.u_ioq.ioq_pr1[next_idx] != '0
            && dut.lsu.u_ioq.ioq_fwd1_hit[next_idx]
            && dut.lsu.u_ioq.ioq_pr2[next_idx] == '0) begin
          early_bcast_next_dependent++;
          if (!dut.lsu.u_ioq.ioq_issue_found
              && (!dut.lsu.u_ioq.load_req_valid_q || dut.lsu.u_ioq.exu_lsu.rready
                  || dut.lsu.u_ioq.exu_lsu.rretry || dut.lsu.u_ioq.exu_lsu.rmiss))
            early_bcast_next_request_slot++;
          if (dut.lsu.u_ioq.a_req_holds && !dut.lsu.u_ioq.b_issue_found
              && (!dut.lsu.u_ioq.b_req_valid_q || dut.lsu.u_ioq.exu_lsu.rready_b
                  || dut.lsu.u_ioq.exu_lsu.rretry_b))
            early_bcast_next_b_request_slot++;
        end
      end
      if (dut.rou.pmu_head_busy && dut.rou.pmu_head_state != rapt_pkg::ROB_WB
          && int'(dut.rou.pmu_head_domain) < rapt_pkg::ExecutionDomains) begin
        head_wait_domain[int'(dut.rou.pmu_head_domain)]++;
        if (dut.lsu.u_ioq.pmu_ioq_all_full) head_wait_ioq_full++;
        if (dut.rou.pmu_head_domain == rapt_pkg::DOMAIN_MEMORY) begin
          head_mem_l1d_state[int'(memory_env.l1d_cache.l1d_state)]++;
          if (memory_env.l1d_cache.l1d_state == 0) begin
            if (dut.lsu.u_ioq.load_req_valid_q) head_mem_idle_a++;
            else head_mem_idle_no_a++;
          end
          if (!dut.lsu.u_ioq.ioq_valid[dut.lsu.u_ioq.ioq_head]) head_mem_ioq_empty++;
          else if (dut.lsu.u_ioq.ioq_pr1[dut.lsu.u_ioq.ioq_head] != '0
                   || dut.lsu.u_ioq.ioq_pr2[dut.lsu.u_ioq.ioq_head] != '0)
            head_mem_operand_wait++;
          else if (!dut.lsu.u_ioq.ioq_addr_ready[dut.lsu.u_ioq.ioq_head]) head_mem_addr_wait++;
          else if (!dut.lsu.u_ioq.load_req_valid_q) head_mem_no_a_request++;
          else head_mem_a_request++;
          if (dut.lsu.u_ioq.ioq_ren[dut.lsu.u_ioq.ioq_head]) head_mem_ioq_load++;
          if (dut.lsu.u_ioq.ioq_wen[dut.lsu.u_ioq.ioq_head]) head_mem_ioq_store++;
          if (dut.lsu.u_ioq.ioq_complete[dut.lsu.u_ioq.ioq_head]) head_mem_ioq_complete++;
          if (!dut.lsu.u_ioq.load_req_valid_q && dut.lsu.u_ioq.ioq_issue_found)
            head_mem_no_a_issue_ready++;
          if (dut.lsu.u_ioq.load_req_valid_q) begin
            if (dut.lsu.u_ioq.load_req_idx_q == dut.lsu.u_ioq.ioq_head) head_mem_a_owner_head++;
            else head_mem_a_owner_younger++;
          end
`ifdef RAPT_LSU_HUM
          if (dut.lsu.u_ioq.b_req_valid_q) head_mem_b_request++;
`endif
        end
      end
      if (dut.rnu_rou.valid[0] && !dut.rnu_rou.ready[0]) rename_stall++;
      if (dut.rnu_operand.valid[0] && !dut.rnu_operand.ready[0]) operand_stall++;
      if (int'(dut.rou.pmu_dispatch_reason) < rapt_pkg::DispatchStopCount)
        dispatch_stops[int'(dut.rou.pmu_dispatch_reason)]++;
      if (dut.rou.pmu_dispatch_reason == rapt_pkg::DispatchStopRob
          && dut.lsu.u_ioq.pmu_ioq_all_full)
        rob_stop_ioq_full++;
      next_feed_index = feed_index;
      if (cmu_bcast.flush_pipe || cmu_bcast.sys_resume) begin
        flushes++;
        next_feed_index = commit_index;
      end else begin
        for (int s = 0; s < rapt_pkg::DecodeWidth; s++) begin
          if (idu_rnu.valid[s] && idu_rnu.ready[s]) begin
            next_feed_index++;
            accepted++;
          end
        end
      end
      if (idu_rnu.valid[0] && !idu_rnu.ready[0]) front_stall++;
      if (!commit_fire) commit_empty++;
      if (lsu_l1d.rvalid && lsu_l1d.rready) loads++;
      if (lsu_l1d.rvalid && lsu_l1d.rmiss) load_a_misses++;
      if (lsu_l1d.rvalid && lsu_l1d.rretry) load_a_retries++;
      if (lsu_l1d.rvalid_b && lsu_l1d.rready_b) load_b_hits++;
      if (lsu_l1d.rvalid_b && lsu_l1d.rretry_b) load_b_retries++;
      if (dut.lsu.u_ioq.wake_next_req_valid) wake_next_requests++;
      if (lsu_l1d.wvalid && lsu_l1d.wready) stores++;
      if (axi.rvalid && axi.rready) axi_reads++;
      if (axi.wvalid && axi.wready) axi_writes++;
      if (memory_wb_error) $fatal(1, "BE memory writeback error");
      cycles++;
      if (cycles - last_progress > 2000)
        $fatal(
            1,
            "BE stalled feed=%0d commit=%0d/%0d PC=%h",
            feed_index,
            commit_index,
            trace_count,
            trace_pc[commit_index]
        );
      @(negedge clock);
      feed_index = next_feed_index;
    end
    if (commit_index < trace_count)
      $fatal(1, "BE timeout commit=%0d/%0d", commit_index, trace_count);
    $display(
        "PASS: BE instructions=%0d cycles=%0d commit_ipc=%0f width_loss=%0f accepted=%0d front_stall=%0d commit_empty=%0d flushes=%0d loads=%0d stores=%0d axi_reads=%0d axi_writes=%0d",
        committed, cycles, real'(committed) / cycles,
        1.0 - real'(committed) / (cycles * rapt_pkg::CommitWidth), accepted, front_stall,
        commit_empty, flushes, loads, stores, axi_reads, axi_writes);
    for (int s = 0; s <= rapt_pkg::CommitWidth; s++)
    $display("PROFILE: commit_slots[%0d]=%0d", s, commit_slots[s]);
    $display(
        "PROFILE: head_empty=%0d head_dispatch=%0d head_execute=%0d head_writeback=%0d head_store_wait=%0d head_drain_wait=%0d rename_stall=%0d operand_stall=%0d",
        head_empty, head_dispatch, head_execute, head_writeback, head_store_wait, head_drain_wait,
        rename_stall, operand_stall);
    for (int s = 0; s < rapt_pkg::DispatchStopCount; s++)
    if (dispatch_stops[s] != 0) $display("PROFILE: dispatch_stop[%0d]=%0d", s, dispatch_stops[s]);
    for (int s = 0; s < rapt_pkg::ExecutionDomains; s++)
    if (head_wait_domain[s] != 0)
      $display("PROFILE: head_wait_domain[%0d]=%0d", s, head_wait_domain[s]);
    $display("PROFILE: ioq_full=%0d head_wait_ioq_full=%0d rob_stop_ioq_full=%0d", ioq_full_cycles,
             head_wait_ioq_full, rob_stop_ioq_full);
    $display(
        "PROFILE: second_empty=%0d second_dispatch=%0d second_execute=%0d second_writeback=%0d",
        second_empty, second_dispatch, second_execute, second_writeback);
    $display("PROFILE: store_first_second_wb=%0d store_first_second_plain_wb=%0d",
             store_first_second_wb, store_first_second_plain_wb);
    for (int s = 0; s < rapt_pkg::ExecutionDomains; s++)
    if (second_wait_domain[s] != 0)
      $display("PROFILE: second_wait_domain[%0d]=%0d", s, second_wait_domain[s]);
    $display(
        "PROFILE: load_a_done=%0d load_a_misses=%0d load_a_retries=%0d load_b_hits=%0d load_b_retries=%0d",
        loads, load_a_misses, load_a_retries, load_b_hits, load_b_retries);
    $display("PROFILE: wake_next_requests=%0d", wake_next_requests);
    $display(
        "PROFILE: younger_completed_loads=%0d younger_wait_entry_cycles=%0d early_broadcasts=%0d",
        early_load_complete_events, early_load_wait_cycles, early_load_broadcasts);
    $display("PROFILE: early_next_dependent=%0d early_next_a_slot=%0d early_next_b_slot=%0d",
             early_bcast_next_dependent, early_bcast_next_request_slot,
             early_bcast_next_b_request_slot);
    for (int s = 0; s < 8; s++)
    if (head_mem_l1d_state[s] != 0)
      $display("PROFILE: head_memory_l1d_state[%0d]=%0d", s, head_mem_l1d_state[s]);
    $display(
        "PROFILE: head_memory_ioq_empty=%0d operand_wait=%0d addr_wait=%0d no_a_request=%0d a_request=%0d b_request=%0d",
        head_mem_ioq_empty, head_mem_operand_wait, head_mem_addr_wait, head_mem_no_a_request,
        head_mem_a_request, head_mem_b_request);
    $display(
        "PROFILE: head_memory_load=%0d store=%0d complete=%0d idle_no_a=%0d idle_a=%0d no_a_issue_ready=%0d a_owner_head=%0d a_owner_younger=%0d",
        head_mem_ioq_load, head_mem_ioq_store, head_mem_ioq_complete, head_mem_idle_no_a,
        head_mem_idle_a, head_mem_no_a_issue_ready, head_mem_a_owner_head,
        head_mem_a_owner_younger);
    $finish;
  end
endmodule
