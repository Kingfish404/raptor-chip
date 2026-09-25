`include "rapt.svh"
`include "rapt_if.svh"

// Decode-throughput experiment. The image supplies real wrong-path bytes;
// committed control flow in the NEMU trace supplies delayed branch feedback.
module tb_frontend_trace;
  localparam int XLEN = `RAPT_XLEN;
  localparam int MaxTrace = 200000;
  localparam int MaxImage = 262144;
  localparam int MaxEvents = 1024;
  localparam logic [XLEN-1:0] ImageBase = XLEN'('h80000000);

  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_recovery_if recovery ();
  ifu_l1i_if ifu_l1i ();
  idu_rnu_if idu_rnu ();
  logic empty;
  logic [63:0] snapshot_ghr;
  logic [7:0] snapshot_phr;
  rapt_frontend dut (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .recovery,
      .ifu_l1i,
      .idu_rnu,
      .empty_o(empty),
      .snapshot_ghr,
      .snapshot_phr,
      .history_restore(1'b0),
      .restore_ghr('0),
      .restore_phr('0)
  );

  byte unsigned image[MaxImage];
  logic [XLEN-1:0] trace_pc[MaxTrace], trace_npc[MaxTrace];
  logic [31:0] trace_inst[MaxTrace];
  int trace_count, image_size;
  int sink_width, fetch_gap, feedback_delay, max_cycles;
  int gap_left;
  int event_head, event_tail;
  int event_due[MaxEvents];
  logic [XLEN-1:0] event_pc[MaxEvents], event_npc[MaxEvents];
  logic event_cond[MaxEvents], event_jump[MaxEvents], event_indirect[MaxEvents];
  logic event_taken[MaxEvents], event_flush[MaxEvents], event_serial[MaxEvents];

  function automatic logic [31:0] image_word(input logic [XLEN-1:0] pc);
    int unsigned offset;
    offset = int'(pc - ImageBase);
    if (pc < ImageBase || offset + 3 >= image_size) return 32'h00000013;
    return {image[offset+3], image[offset+2], image[offset+1], image[offset]};
  endfunction

  always_comb begin
    ifu_l1i.valid = !reset && gap_left == 0;
    // L1I returns a 32-bit window beginning at PC, including the next
    // aligned word's low half when PC[1] is set.
    ifu_l1i.inst_n0 = image_word(ifu_l1i.pc);
`ifdef RAPT_FETCH_LOOKAHEAD
    ifu_l1i.inst_n1 = image_word((ifu_l1i.pc & ~XLEN'(3)) + XLEN'(4));
    ifu_l1i.inst_n2 = image_word((ifu_l1i.pc & ~XLEN'(3)) + XLEN'(8));
    ifu_l1i.inst_n1_valid = ifu_l1i.valid;
    ifu_l1i.inst_n2_valid = ifu_l1i.valid;
`endif
    ifu_l1i.trap = 0;
    ifu_l1i.cause = '0;
    ifu_l1i.tval = '0;
  end

  `include "tb_core_bcast_defaults.svh"

  initial begin : run
    string image_path, trace_path;
    int fd, status, idx, cycles, delivered, correct, redirects, last_progress;
    int empty_cycles, gap_cycles, blocked_cycles, mismatches, control_count;
    int cond_misses, indirect_misses, direct_misses, noncontrol_misses, serial_count;
    int flushing;
    logic [XLEN-1:0] pc_value, npc_value;
    logic [31:0] inst_value;
    bit recovery_pending, did_fetch;

    if (!$value$plusargs("IMG=%s", image_path)) $fatal(1, "+IMG required");
    if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "+TRACE required");
    if (!$value$plusargs("SINK_WIDTH=%d", sink_width)) sink_width = rapt_pkg::DecodeWidth;
    if (!$value$plusargs("FETCH_GAP=%d", fetch_gap)) fetch_gap = 0;
    if (!$value$plusargs("FEEDBACK_DELAY=%d", feedback_delay)) feedback_delay = 4;
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 200000;
    if (sink_width < 1 || sink_width > rapt_pkg::DecodeWidth || fetch_gap < 0 || feedback_delay < 1)
      $fatal(1, "invalid FE experiment parameter");
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
    ) && trace_count < MaxTrace) begin
      status = $fscanf(fd, "%h %h %h\n", pc_value, inst_value, npc_value);
      if (status == 3 && pc_value >= ImageBase && pc_value < ImageBase + XLEN'(image_size)) begin
        trace_pc[trace_count] = pc_value;
        // NEMU expands C instructions in its execution record. Read original
        // bytes so sequential length and predictor training match the DUT.
        trace_inst[trace_count] = image_word(pc_value);
        trace_npc[trace_count] = npc_value;
        trace_count++;
      end
    end
    $fclose(fd);
    if (trace_count < 100) $fatal(1, "trace too short for a bandwidth measurement");

    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(2'b11, '0, 1'b1);
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.owner = '0;
    recovery.head = '0;
    recovery.generation = '0;
    recovery.target = '0;
    recovery.checkpoint_valid = 0;
    recovery.checkpoint = '0;
    foreach (idu_rnu.ready[s]) idu_rnu.ready[s] = 0;
    gap_left = 0;
    event_head = 0;
    event_tail = 0;
    idx = 0;
    cycles = 0;
    delivered = 0;
    correct = 0;
    redirects = 0;
    mismatches = 0;
    control_count = 0;
    cond_misses = 0;
    indirect_misses = 0;
    direct_misses = 0;
    noncontrol_misses = 0;
    serial_count = 0;
    empty_cycles = 0;
    gap_cycles = 0;
    blocked_cycles = 0;
    recovery_pending = 0;
    last_progress = 0;

    repeat (4) @(negedge clock);
    reset = 0;
    init_cmu_bcast_defaults();
    cmu_bcast.flush_redirect = 1;
    cmu_bcast.redirect_pc = trace_pc[0];
    @(negedge clock);
    init_cmu_bcast_defaults();

    while (idx < trace_count && cycles < max_cycles) begin
      // Drive the delayed commit/redirect event before the next active edge.
      flushing = 0;
      if (event_head != event_tail && event_due[event_head] <= cycles) begin
        cmu_bcast.rpc = event_pc[event_head];
        cmu_bcast.cpc = event_npc[event_head];
        cmu_bcast.ben = event_cond[event_head];
        cmu_bcast.jen = event_jump[event_head];
        cmu_bcast.jren = event_indirect[event_head];
        cmu_bcast.btaken = event_taken[event_head];
        if (event_serial[event_head]) begin
          cmu_bcast.sys_resume = 1;
          cmu_bcast.flush_pipe = 1;
          cmu_bcast.redirect_pc = event_npc[event_head];
          flushing = 1;
          redirects++;
        end else if (event_flush[event_head]) begin
          cmu_bcast.flush_pipe = 1;
          cmu_bcast.flush_redirect = 1;
          cmu_bcast.redirect_pc = event_npc[event_head];
          flushing = 1;
          redirects++;
        end
        event_head = (event_head + 1) % MaxEvents;
      end
      foreach (idu_rnu.ready[s]) idu_rnu.ready[s] = !recovery_pending && s < sink_width;
      #1;
      if (!idu_rnu.valid[0]) empty_cycles++;
      if (gap_left != 0) gap_cycles++;
      if (idu_rnu.valid[0] && !idu_rnu.ready[0]) blocked_cycles++;
      @(posedge clock);
      did_fetch = ifu_l1i.valid && ifu_l1i.consumed;
      for (int s = 0; s < rapt_pkg::DecodeWidth; s++) begin
        if (idu_rnu.valid[s] && idu_rnu.ready[s] && idx < trace_count) begin
          delivered++;
          if (idu_rnu.slot[s].uop.pc == trace_pc[idx]) begin
            logic [XLEN-1:0] sequential_pc;
            bit control, mismatch, serial;
            sequential_pc = trace_pc[idx] + XLEN'((trace_inst[idx][1:0] == 2'b11) ? 4 : 2);
            control = idu_rnu.slot[s].uop.execute.branch.conditional
                || idu_rnu.slot[s].uop.execute.branch.jump
                || idu_rnu.slot[s].uop.execute.branch.indirect;
            serial = idu_rnu.slot[s].uop.execute.sys.valid
                || idu_rnu.slot[s].uop.execute.sys.fence_i
                || idu_rnu.slot[s].uop.execute.sys.fence;
            mismatch = idu_rnu.slot[s].uop.pnpc != trace_npc[idx];
            if (control || mismatch || serial) begin
              if ((event_tail + 1) % MaxEvents == event_head)
                $fatal(1, "feedback event queue overflow");
              event_due[event_tail] = cycles + feedback_delay;
              event_pc[event_tail] = trace_pc[idx];
              event_npc[event_tail] = trace_npc[idx];
              event_cond[event_tail] = idu_rnu.slot[s].uop.execute.branch.conditional;
              event_jump[event_tail] = idu_rnu.slot[s].uop.execute.branch.jump;
              event_indirect[event_tail] = idu_rnu.slot[s].uop.execute.branch.indirect;
              event_taken[event_tail] = trace_npc[idx] != sequential_pc;
              event_flush[event_tail] = mismatch;
              event_serial[event_tail] = serial;
              event_tail = (event_tail + 1) % MaxEvents;
              control_count += int'(control);
              mismatches += int'(mismatch);
              serial_count += int'(serial);
              if (mismatch && idu_rnu.slot[s].uop.execute.branch.conditional) cond_misses++;
              else if (mismatch && idu_rnu.slot[s].uop.execute.branch.indirect) indirect_misses++;
              else if (mismatch && idu_rnu.slot[s].uop.execute.branch.jump) direct_misses++;
              else if (mismatch) noncontrol_misses++;
              if (mismatch && mismatches <= 8)
                $display(
                    "FE divergence PC=%h raw=%h predicted=%h actual=%h C=%b J=%b JR=%b sys=%b",
                    trace_pc[idx],
                    trace_inst[idx],
                    idu_rnu.slot[s].uop.pnpc,
                    trace_npc[idx],
                    idu_rnu.slot[s].uop.execute.branch.conditional,
                    idu_rnu.slot[s].uop.execute.branch.jump,
                    idu_rnu.slot[s].uop.execute.branch.indirect,
                    serial
                );
              if (mismatch || serial) recovery_pending = 1;
            end
            idx++;
            correct++;
            last_progress = cycles;
          end else if (!recovery_pending) begin
            $fatal(1, "FE diverged without pending correction: got %h expected %h",
                   idu_rnu.slot[s].uop.pc, trace_pc[idx]);
          end
        end
      end
      if (flushing) recovery_pending = 0;
      cycles++;
      if (cycles - last_progress > 1000)
        $fatal(
            1,
            "FE stalled at trace %0d PC %h pending=%0d events=%0d IFU_PC=%h",
            idx,
            trace_pc[idx],
            recovery_pending,
            event_tail - event_head,
            ifu_l1i.pc
        );
      @(negedge clock);
      init_cmu_bcast_defaults();
      if (gap_left > 0) gap_left--;
      if (did_fetch && fetch_gap > 0) gap_left = fetch_gap;
    end
    if (idx < trace_count) $fatal(1, "FE trace timeout at %0d/%0d", idx, trace_count);
    $display(
        "PASS: FE trace=%s instructions=%0d cycles=%0d delivered=%0d correct=%0d uops_per_cycle=%0f width_loss=%0f redirects=%0d mismatches=%0d controls=%0d cond_misses=%0d indirect_misses=%0d direct_misses=%0d noncontrol_misses=%0d serial=%0d empty_cycles=%0d gap_cycles=%0d blocked_cycles=%0d",
        trace_path, idx, cycles, delivered, correct, real'(correct) / cycles,
        1.0 - real'(correct) / (cycles * rapt_pkg::DecodeWidth), redirects, mismatches,
        control_count, cond_misses, indirect_misses, direct_misses, noncontrol_misses,
        serial_count, empty_cycles, gap_cycles, blocked_cycles);
    $finish;
  end
endmodule
