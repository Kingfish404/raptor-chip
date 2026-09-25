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
  logic backend_empty, sq_empty, writeback_idle, writeback_drain;
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
      .writeback_idle,
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
      .writeback_idle_o(writeback_idle),
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
    repeat (5) @(negedge clock);
    reset = 0;
    while (commit_index < trace_count && cycles < max_cycles) begin
      @(posedge clock);
      // Retire is the source of truth for a trace after any precise flush.
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
          last_progress = cycles;
        end
      end
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
    $finish;
  end
endmodule
