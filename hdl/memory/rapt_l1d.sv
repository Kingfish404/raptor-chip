`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

/* verilator lint_off PINCONNECTEMPTY */
module rapt_l1d #(
    parameter bit WriteBack = 1'b0,
    parameter bit LineRefill = 1,
    parameter int L1D_LINE_LEN = `RAPT_L1D_LINE_LEN,
    parameter int unsigned L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
    parameter int L1D_LEN = `RAPT_L1D_LEN,
    parameter int unsigned L1D_SIZE = 2 ** L1D_LEN,
    parameter int XLEN = `RAPT_XLEN,
    parameter unsigned L1D_N_WAYS = `RAPT_L1D_N_WAYS,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS
) (
    input clock,
    input logic coherent_request = 1'b0,
    input logic coherent_write = 1'b0,
    output logic coherent_ready,
    output logic writeback_error,
    output logic writeback_idle,
    input logic writeback_drain = 1'b0,
    // Device writes are reported before a later SC may complete. Pending
    // holds SC while the platform drains a finite batch of notifications.
    input logic external_write_valid_i = 1'b0,
    input logic external_write_pending_i = 1'b0,
    input logic [XLEN-1:0] external_write_first_i = '0,
    input logic [XLEN-1:0] external_write_last_i = '0,


    cmu_bcast_if.in cmu_bcast,

    lsu_l1d_if.slave  lsu_l1d,
    l1d_bus_if.master l1d_bus,

    csr_bcast_if.in csr_bcast,
    pmp_update_if.in pmp_update,
    lsu_l1d_mmu_if.slave exu_l1d,

    input reset
);
  localparam unsigned L1dOffsetBits = $clog2(XLEN / 8);
  localparam unsigned L1dTagW = PADDR_BITS - L1D_LEN - L1D_LINE_LEN - L1dOffsetBits;
  typedef enum logic [2:0] {
    IDLE = 3'b000,
    PTWAIT = 3'b100,  // waiting for PTW to complete
    TRAP = 3'b101,
    LD_CHECK = 3'b011,
    LD_A = 3'b001,
    LD_D = 3'b010,
    LD_MSHR_RSP = 3'b110
  } l1d_state_t;

  l1d_state_t l1d_state;
  // Permission sampled beside the speculative SRAM read; LD_A consumes the
  // registered result so PMP decode stays off rready/fast-wakeup.
  logic load_perm_denied_q;
  logic [XLEN-1:0] perm_base_addr;
  // Shared state used by MSHR eligibility and invalidation below.
  logic fence_clear_busy;
  logic refill_safe, refill_pmp_uniform;
  logic l1d_atomic_lock;
  logic l1d_orig_misaligned;
  // The MSHR lookup below consumes the accepted load's address-space epoch.
  rapt_pkg::mem_context_t load_context_q;

  // Declare shared lookup signals before the generate instance. Otherwise
  // synthesis can bind a forward port reference to an implicit scalar net.
  logic [XLEN-1:0] l1d_addr;
  logic tag_hit;
  logic [L1D_N_WAYS-1:0] load_way_hit;
  logic mshr_busy, mshr_wake, mshr_ready, mshr_error, mshr_wait;
  logic mshr_lookup, mshr_eligible, mshr_complete, mshr_release, mshr_buffered;
  logic mshr_req_valid, mshr_req_ready, mshr_select, legacy_arvalid;
  logic [1:0] mshr_req_id;
  logic [XLEN-1:0] mshr_req_addr, mshr_data;
  logic [XLEN-1:0] mshr_rsp_data_q;
  logic legacy_rvalid, legacy_rready;
  logic mshr_invalidate, mshr_invalidate_line;
  logic mshr_fill_valid, mshr_fill_ready;
  logic [XLEN-1:0] mshr_fill_addr;
  logic [L1D_LINE_SIZE-1:0] mshr_fill_mask, line_update_mask;
  logic [L1D_LINE_SIZE*XLEN-1:0] mshr_fill_data, line_update_data;
  logic line_update;
  assign legacy_rvalid = l1d_bus.rvalid && !l1d_bus.r_mshr;
  assign legacy_rready = l1d_bus.rready && !l1d_bus.ar_mshr;
  assign mshr_invalidate = cmu_bcast.flush_pipe || fence_clear_busy || external_write_valid_i;
  assign mshr_invalidate_line = lsu_l1d.wvalid && !mshr_busy;
  // Only requests which can replay as a whole may release LSU ownership.
  // Permission has already been registered before LD_A looks up tags.
  assign mshr_eligible = !WriteBack && (`RAPT_L1D_MSHRS > 0) && LineRefill && refill_safe
      && !load_perm_denied_q && lsu_l1d.replay_allowed && !l1d_atomic_lock
      && !l1d_orig_misaligned;
  // Miss allocation needs the tag result, not SRAM read data. A valid cache
  // word without a matching buffer waits for its array read; an absent word
  // can allocate while a different refill is writing the array.
  assign mshr_lookup = mshr_eligible && l1d_state == LD_A && !lsu_l1d.wvalid && !mshr_invalidate;
  assign mshr_complete = mshr_lookup && mshr_ready;
  assign mshr_release = mshr_lookup && mshr_wait;
  assign lsu_l1d.rmiss = mshr_release && lsu_l1d.rvalid;
  assign lsu_l1d.miss_wake = mshr_wake;
  if (!WriteBack && `RAPT_L1D_MSHRS > 0) begin : g_mshr
    rapt_l1d_mshr #(
        .Xlen(XLEN),
        .Entries(`RAPT_L1D_MSHRS),
        .LineBytes(L1D_LINE_SIZE * (XLEN / 8))
    ) misses (
        .clock,
        .reset,
        .invalidate(mshr_invalidate),
        .invalidate_line(mshr_invalidate_line),
        .invalidate_addr(lsu_l1d.waddr),
        .fill_valid(mshr_fill_valid),
        .fill_ready(mshr_fill_ready),
        .fill_addr(mshr_fill_addr),
        .fill_mask(mshr_fill_mask),
        .fill_data(mshr_fill_data),
        .lookup_valid(mshr_lookup),
        .cache_hit(tag_hit || (!mshr_buffered && |load_way_hit)),
        .lookup_addr(l1d_addr),
        .lookup_version(load_context_q.version),
        .lookup_ready(mshr_ready),
        .lookup_error(mshr_error),
        .lookup_buffered(mshr_buffered),
        .lookup_wait(mshr_wait),
        .lookup_data(mshr_data),
        .busy(mshr_busy),
        .wake(mshr_wake),
        .req_valid(mshr_req_valid),
        .req_id(mshr_req_id),
        .req_addr(mshr_req_addr),
        .req_ready(mshr_req_ready),
        .rsp_valid(l1d_bus.rvalid && l1d_bus.r_mshr),
        .rsp_id(l1d_bus.r_mshr_id),
        .rsp_data(l1d_bus.rdata),
        .rsp_error(l1d_bus.rerr),
        .rsp_last(l1d_bus.rlast)
    );
  end else begin : g_no_mshr
    assign mshr_ready = 0;
    assign mshr_buffered = 0;
    assign mshr_error = 0;
    assign mshr_wait = 0;
    assign mshr_data = '0;
    assign mshr_busy = 0;
    assign mshr_wake = 0;
    assign mshr_req_valid = 0;
    assign mshr_req_id = '0;
    assign mshr_req_addr = '0;
    assign mshr_fill_valid = 0;
    assign mshr_fill_addr = '0;
    assign mshr_fill_mask = '0;
    assign mshr_fill_data = '0;
  end

  pmp_state_if pmp_state ();

  rapt_pmp_state pmp_state_regs (
      .clock (clock),
      .reset (reset),
      .update(pmp_update),
      .state (pmp_state)
  );

  logic [1:0] l1d_pbmt;
  logic l1d_check_valid;
  logic [2:0] l1d_check_offset;
  logic [3:0] l1d_check_size_m1;
  logic [3:0] l1d_orig_size_m1;
  logic load_io_size_fault, store_io_size_fault;
  assign load_io_size_fault = l1d_orig_misaligned && (l1d_pbmt == 2'b10 || rapt_pkg::addr_device(
      l1d_addr
  ));
  assign store_io_size_fault = exu_l1d.misaligned
      && (exu_l1d.pbmt == 2'b10 || rapt_pkg::addr_device(
      exu_l1d.paddr
  ));
  logic [4:0] l1d_ralu;
  logic [XLEN-1:0] rec_addr;
  // The load and store-translation ports can wait concurrently, even at the
  // same VA. A shared TRAP state must complete only the captured owner.
  logic rec_store;

  // Tag and valid arrays (kept as registers for multi-port read and fast bulk invalidation)
  // Per-line tag + per-word valid: one tag per (way, set); each word in a
  // cache line has independent valid tracking so partial fills / invalidates
  // don't require whole-line eviction.  When a new tag is installed in a
  // line (tag mismatch), all valid bits except the new target are cleared.
  if (PADDR_BITS > XLEN || PADDR_BITS <= L1D_LEN + L1D_LINE_LEN + L1dOffsetBits)
    begin : g_invalid_paddr_width
    $error("L1D physical address width must fit its request and cache geometry");
  end
  localparam unsigned L1dWayW = L1D_N_WAYS > 1 ? $clog2(L1D_N_WAYS) : 1;
  logic [L1D_SIZE-1:0] fence_clear_set;
  logic [L1D_SIZE-1:0] maintenance_set;
  logic zero_complete;
  logic cacheable_w;
  logic ptw_awvalid;
  // Maintenance and refill logic reference these before the address logic.
  logic [L1D_LEN-1:0] waddr_idx;
  logic [L1D_LINE_LEN-1:0] addr_offset;
  assign zero_complete = lsu_l1d.wvalid && lsu_l1d.wready && lsu_l1d.wzero;

  // No tag lookup: invalidate every way of the VA-selected set. A CBO block
  // is 64 bytes even for presets with smaller cache lines, so ignore index
  // bits below bit 6. Index bits above the page offset are also ignored: a
  // larger custom geometry clears all possible physical colors safely.
  localparam unsigned L1dLineOffset = L1D_LINE_LEN + L1dOffsetBits;
  localparam logic [11:0] CboIndexMask = 12'((L1D_SIZE - 1) << L1dLineOffset) & 12'hfc0;
  for (genvar s = 0; s < L1D_SIZE; s++) begin : g_maintenance_set
    assign maintenance_set[s] = cmu_bcast.fence_time
      || (WriteBack && (coherent_write || ptw_awvalid
        || (lsu_l1d.wvalid && lsu_l1d.wready && !cacheable_w)))
      || (cmu_bcast.cbo_inval
        && (12'(s << L1dLineOffset) & CboIndexMask)
            == ({cmu_bcast.cbo_block, 6'b0} & CboIndexMask))
        || (zero_complete && ((s >> (L1dLineOffset < 6 ? 6-L1dLineOffset : 0))
            == (int'(waddr_idx) >> (L1dLineOffset < 6 ? 6-L1dLineOffset : 0))));
  end
  assign fence_clear_busy = cmu_bcast.fence_time || cmu_bcast.cbo_inval || |fence_clear_set;

  logic refill_line, demand_done;
  logic [L1D_LINE_LEN-1:0] refill_word;
  logic demand_beat, line_read_request;
  logic [XLEN-1:0] refill_base, refill_last;
  assign refill_base = {l1d_addr[XLEN-1:L1dLineOffset], {L1dLineOffset{1'b0}}};
  assign refill_last = refill_base | XLEN'((1 << L1dLineOffset) - 1);
  assign line_read_request = LineRefill && refill_safe;
  assign demand_beat = !refill_line || refill_word == addr_offset;
`ifdef RAPT_L2_EN
`ifdef RAPT_L2_LINE_LEN
  localparam int DownstreamLineOffset = `RAPT_L2_LINE_LEN + $clog2(XLEN / 8);
`else
  localparam int DownstreamLineOffset = $clog2(`RAPT_CACHE_LINE_BYTES);
`endif
`else
  localparam int DownstreamLineOffset = L1dLineOffset;
`endif
  localparam int GuardOffset = DownstreamLineOffset > L1dLineOffset
      ? DownstreamLineOffset : L1dLineOffset;
  rapt_pmp_line_uniform #(
      .XLEN(XLEN),
      .LineOffset(GuardOffset)
  ) u_refill_pmp (
      .addr(perm_base_addr),
      .state(pmp_state),
      .uniform_o(refill_pmp_uniform)
  );
  // Keep narrow ROM/SRAM/device bridges on their established word protocol.
  // A RAM burst stays in one physical PMA range and one translated page.
  function automatic logic refill_ram(input logic [XLEN-1:0] first, input logic [XLEN-1:0] last);
    return (rapt_pkg::canonical_addr(first) >= XLEN'('h80000000) &&
            rapt_pkg::canonical_addr(last) < XLEN'('h80000000) + XLEN'(rapt_pkg::PmemBytes)) ||
        (rapt_pkg::canonical_addr(first) >= XLEN'('ha0000000) &&
         rapt_pkg::canonical_addr(last) < XLEN'('ha2000000));
  endfunction

  logic [7:0] rstrb;

  logic [L1dTagW-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic data_hit;  // SRAM data ready after 1-cycle read latency
  logic [XLEN-1:0] l1d_data;
  logic cacheable_r;

  logic [L1dTagW-1:0] waddr_tag;
  logic [L1D_LINE_LEN-1:0] waddr_offset;
  logic hit_w;

  logic mmu_en;
  logic store_tlb_miss;
  logic load_tlb_miss;
  rapt_pkg::mem_context_t ptw_context_q;
  rapt_pkg::mem_context_t perm_load_context;
  rapt_pkg::mem_context_t ptw_request_context;
  logic tlb_hit;
  logic [XLEN-1:10] dtlb_ptag;
  logic [6:0] dtlb_pte;

  logic stlb_mmu;  // PTW was started for a store (vs load)
  logic stlb_hit;
  logic [XLEN-1:10] dstlb_ptag;
  logic [6:0] dstlb_pte;

  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] store_paddr;

  // atomic support
  logic [XLEN-1:0] reservation;
  logic reservation_valid;
  logic [3:0] reservation_size_m1;
  logic lr_interfered;
  logic external_hits_reservation, external_hits_lr;
  function automatic logic external_overlap(input logic [XLEN-1:0] first,
                                            input logic [3:0] size_m1);
    return external_write_valid_i
        && {1'b0, external_write_first_i} <= ({1'b0, first} + (XLEN+1)'(size_m1))
        && external_write_last_i >= first;
  endfunction
  assign external_hits_reservation = reservation_valid && external_overlap(
      reservation, reservation_size_m1
  );
  // Translation has not produced a PA during PTWAIT. Poison that in-flight
  // LR conservatively; subsequent hot-TLB attempts use physical overlap.
  assign external_hits_lr = l1d_atomic_lock
      && ((l1d_state == PTWAIT && external_write_valid_i)
        || ((l1d_state == LD_CHECK || l1d_state == LD_A || l1d_state == LD_D)
          && external_overlap(
      l1d_addr, l1d_ralu[1:0] == 2'b11 ? 4'd7 : 4'd3
  )));


  // PTW instance signals
  logic ptw_req;
  /* verilator lint_off UNUSEDSIGNAL */
  logic ptw_busy;
  logic load_killed;
  /* verilator lint_on UNUSEDSIGNAL */
  logic ptw_done, ptw_fault;
  logic                    ptw_arvalid;
  logic [        XLEN-1:0] ptw_araddr;
  logic [        XLEN-1:0] ptw_awaddr;
  logic                    ptw_wvalid;
  logic [        XLEN-1:0] ptw_wdata;
  logic [             7:0] ptw_wstrb;
  logic                    ptw_wready;
  logic [        XLEN-1:0] ptw_vaddr;
  logic [       XLEN-1:10] ptw_result_ptag;
  logic [       XLEN-1:12] ptw_result_vtag;
  logic [             6:0] ptw_result_pte;

  // mis-alignment check
  logic                    mis_align_load;
  logic                    mis_align_store;

  logic                    l1d_update;
  logic [        XLEN-1:0] l1d_data_u;
  logic                    l1d_valid_u;
  // When set together with valid_u==0, the update commit invalidates the
  // selected (idx, off) word in EVERY way (broadcast invalidate).  Used for
  // partial stores so that any duplicate-tag legacy line cannot keep stale
  // data in a non-`store_hit_way` slot.
  logic                    l1d_inv_all_ways;
  logic [     L1dTagW-1:0] l1d_tag_u;
  logic [     L1D_LEN-1:0] l1d_idx;
  logic [L1D_LINE_LEN-1:0] l1d_off;
  logic [     L1dWayW-1:0] l1d_way;  // which way for pending l1d_update
  logic [     L1dWayW-1:0] ld_fill_way_r;  // registered fill way for load miss
  logic [    L1D_SIZE-1:0] d_replace_bit;  // random replacement toggle per set (2-way only)

  typedef enum logic [2:0] {
    WB_IDLE,
    WB_SCAN,
    WB_READ,
    WB_CAPTURE,
    WB_WAIT,
    WB_CLEAN
  } wb_state_t;
  wb_state_t wb_state;
  logic dirty_any, wb_busy, wb_valid, wb_capture_ready, wb_blocked;
  logic update_dirty, local_store, local_store_ready, wb_hold;
  logic [L1D_LEN-1:0] wb_set;
  logic [L1dWayW-1:0] wb_way;
  logic [L1dWayW-1:0] ld_fill_way;
  logic [L1D_LEN-1:0] mshr_fill_idx;
  logic [L1dTagW-1:0] mshr_fill_tag;
  logic [L1D_LEN-1:0] tag_store_idx;
  logic [L1dTagW-1:0] tag_store_tag;
  logic [L1dTagW-1:0] wb_tag;
  logic [L1D_LINE_SIZE-1:0] wb_dirty;
  logic [L1D_LINE_SIZE*XLEN-1:0] wb_line_data;
  logic [XLEN-1:0] wb_addr, wb_data;
  logic l1d_rmw;
  logic [XLEN-1:0] data_bank_rdata[L1D_N_WAYS][L1D_LINE_SIZE];
  logic wb_drain_request;
  localparam logic [7:0] FullStoreWstrb = 8'({XLEN / 8{1'b1}});
  logic [L1dWayW-1:0] store_hit_way, store_fill_way;
  logic wb_global_request, wb_victim_request, wb_targeted;
  logic store_allocate, wb_store_probe, wb_store_victim;
  logic [L1D_LEN-1:0] wb_probe_set;
  logic [L1dWayW-1:0] wb_probe_way;
  assign store_allocate = cacheable_w && !lsu_l1d.wzero
      && lsu_l1d.walu == FullStoreWstrb && lsu_l1d.waddr[L1dOffsetBits-1:0] == '0;
  assign wb_store_probe = l1d_state == IDLE && lsu_l1d.wvalid && store_allocate;
  assign wb_probe_set = wb_store_probe ? waddr_idx : addr_idx;
  assign wb_probe_way = wb_store_probe ? store_fill_way : ld_fill_way;
  assign wb_store_victim = wb_store_probe && !hit_w && |wb_dirty && wb_tag != waddr_tag;
  assign wb_global_request = writeback_drain || coherent_request || fence_clear_busy
      || (lsu_l1d.wvalid && (!cacheable_w || lsu_l1d.wzero))
      // A hot TLB lookup, like a bare-mode address check, does not read page
      // tables. Only an actual walk needs dirty PTEs published to memory.
      || (l1d_state == IDLE && (store_tlb_miss
        || (lsu_l1d.rcontext.mmu_en && load_tlb_miss)))
      || (l1d_state == LD_A && (!cacheable_r || l1d_atomic_lock))
      || ptw_busy;
  assign wb_victim_request = l1d_state == LD_A && !load_perm_denied_q
      && cacheable_r && !(|load_way_hit) && |wb_dirty
      && (line_read_request || wb_tag != addr_tag);
  assign wb_drain_request = wb_global_request || wb_victim_request || wb_store_victim;
  assign wb_hold = WriteBack && ((dirty_any && wb_drain_request) || wb_busy || wb_state != WB_IDLE || writeback_error
      || (update_dirty && (l1d_update || l1d_rmw)));
  // Idle/ready must depend only on registered writeback state and dirty data.
  // wb_hold also contains the current drain request; feeding it into these
  // outputs creates request -> hold -> ready/idle -> request loops across the
  // bus, frontend cancellation, and retirement fence logic.
  assign writeback_idle = !WriteBack || (!dirty_any && !wb_busy && wb_state == WB_IDLE
      && !writeback_error && !l1d_update && !l1d_rmw);
  assign coherent_ready = !WriteBack || (!dirty_any && !wb_busy && wb_state == WB_IDLE
      && !writeback_error && !l1d_update && !l1d_rmw
      && l1d_state == IDLE && !ptw_busy);
  assign local_store = WriteBack && cacheable_w && !lsu_l1d.wzero
      && (hit_w || (store_allocate && !wb_store_victim));
  assign local_store_ready = lsu_l1d.wvalid && local_store && l1d_state == IDLE && wb_state == WB_IDLE
      && !writeback_error && !l1d_update && !l1d_rmw && !ptw_busy
      && !coherent_request && !fence_clear_busy;
  for (genvar word_idx = 0; word_idx < L1D_LINE_SIZE; word_idx++) begin : g_wb_data
    assign wb_line_data[word_idx*XLEN+:XLEN] = data_bank_rdata[wb_way][word_idx];
  end
  rapt_l1d_writeback #(
      .Xlen(XLEN),
      .LineWords(L1D_LINE_SIZE)
  ) writeback (
      .clock(clock),
      .reset(reset),
      .capture_valid(WriteBack && wb_state == WB_CAPTURE),
      .capture_ready(wb_capture_ready),
      .capture_addr(XLEN'({wb_tag, wb_set, {L1dLineOffset{1'b0}}})),
      .capture_dirty(wb_dirty),
      .capture_data(wb_line_data),
      .busy(wb_busy),
      .error(writeback_error),
      .retry(1'b0),
      .write_valid(wb_valid),
      .write_addr(wb_addr),
      .write_data(wb_data),
      .write_ready(l1d_bus.wready),
      .write_error(l1d_bus.werr)
  );
  always_ff @(posedge clock) begin
    if (reset) begin
      wb_state <= WB_IDLE;
      wb_targeted <= 0;
      wb_set <= '0;
      wb_way <= '0;
    end else if (WriteBack) begin
      case (wb_state)
        WB_IDLE:
        if (dirty_any && wb_drain_request && l1d_bus.idle && !l1d_update && !l1d_rmw
          && !local_store_ready
          && (l1d_state == IDLE || l1d_state == LD_A || l1d_state == PTWAIT)) begin
          wb_targeted <= !wb_global_request;
          wb_set <= wb_global_request ? '0 : wb_probe_set;
          wb_way <= wb_global_request ? '0 : wb_probe_way;
          wb_state <= wb_global_request ? WB_SCAN : WB_READ;
        end
        WB_SCAN: begin
          if (!dirty_any) wb_state <= WB_IDLE;
          else if (|wb_dirty) wb_state <= WB_READ;
          else if (wb_way == L1dWayW'(L1D_N_WAYS - 1)) begin
            wb_way <= '0;
            wb_set <= wb_set + 1'b1;
            if (&wb_set) wb_state <= WB_IDLE;
          end else wb_way <= wb_way + 1'b1;
        end
        WB_READ: wb_state <= WB_CAPTURE;
        WB_CAPTURE: if (wb_capture_ready) wb_state <= WB_WAIT;
        WB_WAIT: if (!wb_busy && !writeback_error) wb_state <= WB_CLEAN;
        WB_CLEAN: wb_state <= wb_targeted ? WB_IDLE : WB_SCAN;
        default: wb_state <= WB_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clock) disable iff (reset)
    (WriteBack && wb_state == WB_SCAN && !dirty_any) |=> wb_state == WB_IDLE);
  assert property (@(posedge clock) disable iff (reset)
    WriteBack && writeback_idle |-> !dirty_any && !wb_busy && wb_state == WB_IDLE
      && !writeback_error);
  assert property (@(posedge clock) disable iff (reset)
    WriteBack && coherent_ready |-> writeback_idle && l1d_state == IDLE && !ptw_busy);
  assert property (@(posedge clock) disable iff (reset)
    WriteBack && writeback_error |-> wb_busy && !wb_valid && !writeback_idle
      && !coherent_ready);
  assert property (@(posedge clock) disable iff (reset)
    WriteBack && local_store_ready |-> !l1d_bus.wvalid);
  assert property (@(posedge clock) disable iff (reset) WriteBack && $past(
      wb_state == WB_IDLE
  ) && wb_state != WB_IDLE |-> $past(
      l1d_bus.idle
  ));
`endif

  // Report quiescence from registered activity.  wb_hold includes the
  // current coherent request, while coherent IO-fetch authorization itself
  // depends on this idle indication; using wb_hold here closes that request
  // loop.  Dirty resident lines remain idle until a registered writeback
  // operation actually starts.
  assign lsu_l1d.idle = !mshr_busy && l1d_state == IDLE && !ptw_busy && !l1d_update
      && !fence_clear_busy && !lsu_l1d.rvalid && !lsu_l1d.rvalid_b
      && !lsu_l1d.wvalid && !exu_l1d.valid && !wb_busy && wb_state == WB_IDLE
      && !writeback_error && !l1d_rmw;

  // Read-Modify-Write (RMW) for partial store cache updates.
  // When a partial store (SB/SH, or SW in RV64) hits in cache, instead of
  // invalidating, we read the old SRAM word, merge in the new bytes, and
  // write back the full merged word. This takes 2 cycles:
  //   Cycle N:   detect hit, steer sram_raddr to store's set, register store info
  //   Cycle N+1: SRAM data available, compute merge, set l1d_update for write
  logic [XLEN-1:0] l1d_rmw_wdata;
  logic [L1dOffsetBits-1:0] l1d_rmw_waddr_lo;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0] l1d_rmw_walu;
  /* verilator lint_on UNUSEDSIGNAL */

  // RMW trigger: partial store that hits in cache, SRAM read port is free.
  // Only allowed in IDLE (with no pending load) to avoid corrupting the
  // speculative SRAM read that feeds the LD_A hit path.  In PTWAIT/LD_D
  // the SRAM read port may be redirected, and if the FSM transitions to
  // LD_A on the same cycle, data_bank_rdata would contain the store's set
  // data instead of the load's: causing silent data corruption.
  logic partial_store_rmw;
  logic load_speculate;
  assign load_speculate = (l1d_state == IDLE && lsu_l1d.rvalid
      && !cmu_bcast.flush_pipe && !fence_clear_busy && !wb_hold && !local_store_ready);

`ifdef RAPT_LSU_HUM
  // Hit-under-miss B channel arm (full logic further below): in LD_D the
  // SRAM read port is idle, steer it to the B request's set this cycle and
  // tag-compare next cycle.  Declared here so the sram_raddr mux can see it.
  logic b_arm_ok;
  logic [L1D_LEN-1:0] b_idx_in;
  // Shared with the tag-array probe port; declare before its instance.
  logic [L1dTagW-1:0] b_tag;
  logic [L1D_LEN-1:0] b_idx;
  logic [L1D_LINE_LEN-1:0] b_off;
  logic [L1D_N_WAYS-1:0] b_way_hit;
`endif

  assign partial_store_rmw = !l1d_rmw && !l1d_update
      && (l1d_state == IDLE)  // Only in IDLE; PTWAIT/LD_D would steal read port
      && !load_speculate  // load speculation uses SRAM read port
      && lsu_l1d.wvalid && lsu_l1d.wready && !lsu_l1d.werr && cacheable_w && hit_w
      && (lsu_l1d.walu != FullStoreWstrb);  // partial-store RMW: SRAM read port is free in IDLE,
  // hit-line for byte-lane merge on next cycle. wready is gated by
  // `!l1d_rmw` so an incoming store on the merge-write cycle is
  // held one cycle (preventing silent drop).

  // Speculative SRAM read: when IDLE with a pending load, drive the *incoming*
  // virtual index directly instead of waiting for l1d_addr to be registered.
  // Safe because L1D_LEN+L1D_LINE_LEN+L1dOffsetBits < 12 (page offset), so
  // virt_idx == phys_idx (VIPT constraint satisfied). PTW paths are also safe:
  // l1d_addr holds the virtual address during PTW, whose index equals the
  // final physical index.
  logic [L1D_LEN-1:0] sram_raddr;
  logic [L1D_LEN-1:0] sram_raddr_fallback;
`ifdef RAPT_LSU_HUM
  assign sram_raddr_fallback = b_arm_ok ? b_idx_in : addr_idx;
`else
  assign sram_raddr_fallback = addr_idx;
`endif
  assign sram_raddr = WriteBack && wb_state != WB_IDLE ? wb_set : partial_store_rmw ? waddr_idx
      : load_speculate
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits]
      : sram_raddr_fallback;

  // Data-array ownership includes SRAM geometry and read-valid tracking.
  logic sram_read_valid_r;
  logic [L1D_LEN-1:0] sram_read_idx_r;
  rapt_l1d_data #(
      .Xlen(XLEN),
      .SetBits(L1D_LEN),
      .WordBits(L1D_LINE_LEN),
      .Ways(L1D_N_WAYS),
      .LineWords(L1D_LINE_SIZE)
  ) u_data (
      .clock(clock),
      .reset(reset),
      .read_addr(sram_raddr),
      .write_valid(l1d_update && l1d_valid_u && !wb_blocked),
      .write_addr(l1d_idx),
      .write_word(l1d_off),
      .write_way(l1d_way),
      .write_data(l1d_data_u),
      .write_line(line_update),
      .write_mask(line_update_mask),
      .write_line_data(line_update_data),
      .read_valid(sram_read_valid_r),
      .read_index(sram_read_idx_r),
      .read_data(data_bank_rdata)
  );

  // Partial store RMW merge logic: byte-lane merge of old SRAM data with new store data
  logic [XLEN/8-1:0] rmw_byte_mask;
  logic [  XLEN-1:0] rmw_bit_mask;
  logic [  XLEN-1:0] rmw_data_shifted;
  logic [  XLEN-1:0] rmw_merged_data;

  assign rmw_byte_mask = l1d_rmw_walu[XLEN/8-1:0] << l1d_rmw_waddr_lo;
  always_comb begin
    for (int i = 0; i < XLEN / 8; i++) begin
      rmw_bit_mask[i*8+:8] = {8{rmw_byte_mask[i]}};
    end
  end
  assign rmw_data_shifted = l1d_rmw_wdata << (l1d_rmw_waddr_lo * 8);
  assign rmw_merged_data = (data_bank_rdata[l1d_way][l1d_off] & ~rmw_bit_mask)
                         | (rmw_data_shifted & rmw_bit_mask);

  assign mmu_en = (exu_l1d.mmu_en && exu_l1d.valid)
      || (lsu_l1d.rvalid && lsu_l1d.rcontext.mmu_en);
  assign ptw_request_context = store_tlb_miss ? exu_l1d.mem_context : lsu_l1d.rcontext;

  // The load/store lookup arrays are replicas (two combinational read ports),
  // so every successful data walk warms both of them.  Besides avoiding a
  // second walk for pages used by both loads and stores, this keeps their
  // replacement state/content coherent.
  logic [1:0] ptw_result_pbmt;
  logic [1:0] dtlb_pbmt;
  logic [1:0] dstlb_pbmt;
  logic dtlb_fill, dstlb_fill;
  assign dtlb_fill  = (l1d_state == PTWAIT) && ptw_done;
  assign dstlb_fill = (l1d_state == PTWAIT) && ptw_done;

  rapt_tlb #(
      .XLEN   (XLEN),
      .ENTRIES(`RAPT_DTLB_ENTRIES)
  ) u_dtlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(lsu_l1d.raddr[XLEN-1:12]),
      .lookup_asid(lsu_l1d.rcontext.asid),
      .hit(tlb_hit),
      .ptag(dtlb_ptag),
      .pte_flags(dtlb_pte),
      .pbmt(dtlb_pbmt),
      .fill_valid(dtlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(ptw_context_q.asid),
      .fill_pbmt(ptw_result_pbmt),
      .fill_pte(ptw_result_pte)
  );

  rapt_tlb #(
      .XLEN   (XLEN),
      .ENTRIES(`RAPT_DTLB_ENTRIES)
  ) u_dstlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(exu_l1d.vaddr[XLEN-1:12]),
      .lookup_asid(exu_l1d.mem_context.asid),
      .hit(stlb_hit),
      .ptag(dstlb_ptag),
      .pte_flags(dstlb_pte),
      .pbmt(dstlb_pbmt),
      .fill_valid(dstlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(ptw_context_q.asid),
      .fill_pbmt(ptw_result_pbmt),
      .fill_pte(ptw_result_pte)
  );

  // Shared PTW: serves both load and store TLB misses
  assign store_tlb_miss = exu_l1d.mmu_en && exu_l1d.valid && !stlb_hit && !mis_align_store;
  assign ptw_vaddr = store_tlb_miss ? exu_l1d.vaddr : lsu_l1d.raddr;

  logic ptw_read_error;
  assign ptw_read_error = l1d_bus.ptw_rvalid && l1d_bus.ptw_rerr;
  assign load_tlb_miss = lsu_l1d.rvalid && !tlb_hit && !mis_align_load
                       && !(exu_l1d.mmu_en && exu_l1d.valid);
  assign ptw_req = (l1d_state == IDLE) && !wb_hold && !local_store_ready
      && !(WriteBack && coherent_write)
      && (store_tlb_miss || (lsu_l1d.rcontext.mmu_en && load_tlb_miss))
      && !cmu_bcast.flush_pipe
      && !ptw_busy
      && (store_tlb_miss || load_tlb_miss);

  rapt_ptw #(
      .XLEN(XLEN)
  ) u_dptw (
      .clock(clock),
      .reset(reset),
      .req_valid(ptw_req),
      // Discard errored PTE payload through the same drain path as cancellation.
      // The requester below reports an access fault only for a live walk.
      .kill(cmu_bcast.fence_time || cmu_bcast.flush_pipe || ptw_read_error),
      .vaddr(ptw_vaddr),
      .satp_ppn(csr_bcast.satp_ppn),
      .mmu_en(ptw_request_context.mmu_en),
      .pbmte(ptw_request_context.pbmte),
      .sbe(csr_bcast.sbe),
      // CBO management checks A but not D; make the Svade walker treat it as
      // a non-store while the requester applies the CMO R-or-W permission.
      .req_store(store_tlb_miss && !exu_l1d.cmo_mgmt),
      .bus_arvalid(ptw_arvalid),
      .bus_araddr(ptw_araddr),
      .bus_arready(legacy_rready),
      .bus_rvalid(l1d_bus.ptw_rvalid),
      .bus_rdata(l1d_bus.rdata),
      .bus_awvalid(ptw_awvalid),
      .bus_awaddr(ptw_awaddr),
      .bus_wvalid(ptw_wvalid),
      .bus_wdata(ptw_wdata),
      .bus_wstrb(ptw_wstrb),
      .bus_wready(ptw_wready),
      .bus_werr(l1d_bus.ptw_werr),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptw_result_ptag),
      .result_vtag(ptw_result_vtag),
      .result_pte(ptw_result_pte),
      .result_pbmt(ptw_result_pbmt),
      .busy(ptw_busy)
  );

  logic [7:0] rstrb_rv64;
`ifdef RAPT_RV64
  assign rstrb_rv64 = ({8{l1d_ralu == `RAPT_ALU_LWU_}} & 8'hf)
                     | ({8{l1d_ralu == `RAPT_ALU_LD__}} & 8'hff);
`else
  assign rstrb_rv64 = '0;
`endif
  assign rstrb = (
      ({8{l1d_ralu == `RAPT_ALU_LB__}} & 8'h1)
    | ({8{l1d_ralu == `RAPT_ALU_LBU_}} & 8'h1)
    | ({8{l1d_ralu == `RAPT_ALU_LH__}} & 8'h3)
    | ({8{l1d_ralu == `RAPT_ALU_LHU_}} & 8'h3)
    | ({8{l1d_ralu == `RAPT_ALU_LW__}} & 8'hf)
    | rstrb_rv64
    );

  assign addr_tag = l1d_addr[PADDR_BITS-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign addr_idx = l1d_addr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign addr_offset = l1d_addr[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];

  rapt_l1d_tags #(
      .L1D_LEN(L1D_LEN),
      .L1D_LINE_LEN(L1D_LINE_LEN),
      .L1D_SIZE(L1D_SIZE),
      .L1D_LINE_SIZE(L1D_LINE_SIZE),
      .L1D_N_WAYS(L1D_N_WAYS),
      .L1dTagW(L1dTagW),
      .WriteBack(WriteBack)
  ) u_tags (
      .update_dirty(update_dirty),
      .inspect_set(wb_state == WB_IDLE ? wb_probe_set : wb_set),
      .inspect_way(wb_state == WB_IDLE ? wb_probe_way : wb_way),
      .clean_valid(WriteBack && wb_state == WB_CLEAN),
      .clean_mask('1),
      .inspect_tag(wb_tag),
      .inspect_dirty(wb_dirty),
      .dirty_any(dirty_any),
      .update_blocked(wb_blocked),
      .clock(clock),
      .reset(reset),
      .fence_time(cmu_bcast.fence_time),
      .clear_set(wb_hold ? '0 : fence_clear_set),
      .addr_idx(addr_idx),
      .addr_offset(addr_offset),
      .addr_tag(addr_tag),
      .waddr_idx(tag_store_idx),
      .waddr_offset(waddr_offset),
      .waddr_tag(tag_store_tag),
`ifdef RAPT_LSU_HUM
      .probe_idx(b_idx),
      .probe_offset(b_off),
      .probe_tag(b_tag),
      .probe_way_hit(b_way_hit),
`else
      .probe_idx('0),
      .probe_offset('0),
      .probe_tag('0),
      .probe_way_hit(),
`endif
      .load_hit(tag_hit),
      .load_replace(d_replace_bit[addr_idx]),
      .store_replace(d_replace_bit[tag_store_idx]),
      .load_way_hit(load_way_hit),
      .hit_w(hit_w),
      .store_hit_way(store_hit_way),
      .store_fill_way(store_fill_way),
      .ld_fill_way(ld_fill_way),
      .l1d_update(l1d_update),
      .l1d_valid_u(l1d_valid_u),
      .line_update(line_update),
      .line_mask(line_update_mask),
      .l1d_inv_all_ways(l1d_inv_all_ways),
      .l1d_tag_u(l1d_tag_u),
      .l1d_idx(l1d_idx),
      .l1d_off(l1d_off),
      .l1d_way(l1d_way)
  );

  // Refill and stores are mutually exclusive at this boundary, so they share
  // the write-side tag/replacement probe. The load-hit probe remains on the
  // accepted load address; refill/flush arbitration cannot enter that
  // same-cycle fast-load path, and no third full-set tag mux is needed.
  assign mshr_fill_ready = mshr_fill_valid && !mshr_invalidate
      && !mshr_invalidate_line && !lsu_l1d.wvalid && !l1d_rmw && !l1d_update
      && (l1d_state == IDLE || l1d_state == LD_CHECK);
  assign mshr_fill_idx = mshr_fill_addr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign mshr_fill_tag = mshr_fill_addr[PADDR_BITS-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign tag_store_idx = mshr_fill_ready ? mshr_fill_idx : waddr_idx;
  assign tag_store_tag = mshr_fill_ready ? mshr_fill_tag : waddr_tag;

  // A load may consume SRAM data only when every way/subarray completed a
  // read for its index. Writes invalidate that shared correspondence; LD_A
  // then holds the request while the following free cycle re-reads it.
  logic l1d_sram_busy;
  assign l1d_sram_busy = l1d_update || !sram_read_valid_r || (sram_read_idx_r != addr_idx);
  assign tag_hit = (l1d_state == LD_A) && !load_perm_denied_q
    && cacheable_r && !(l1d_atomic_lock && mshr_busy)
    && !l1d_sram_busy
    && |load_way_hit;
  // data_hit: SRAM data ready in LD_A. IDLE (or PTW-wait) speculated the
  // array read while permission was captured into load_perm_denied_q.
  assign data_hit = (l1d_state == LD_A) && tag_hit && !wb_hold;
  // AND-OR mux: each way gates its data with its hit, then all ways OR.
  // Replaces the priority-encoder → indexed-mux chain.
  logic [XLEN-1:0] way_data_masked[L1D_N_WAYS];
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_ao_load
      assign way_data_masked[w] = load_way_hit[w] ? data_bank_rdata[w][addr_offset] : '0;
    end
  endgenerate
  always_comb begin
    l1d_data = '0;
    for (int w = 0; w < int'(L1D_N_WAYS); w++) l1d_data |= way_data_masked[w];
  end

  // ==========================================================================
  //  Hit-under-miss B channel (Phase A2, RAPT_LSU_HUM)
  //
  //  When A returns a cache hit, its SRAM data was read on the preceding
  //  cycle, so use that response cycle to pre-read a best-effort B request.
  //  The same channel remains available while A waits on a miss refill
  //  (LD_D). If A drains before B can be armed, B may use an otherwise idle
  //  cycle so its pending IOQ owner cannot strand. Bare mode only
  //  (!mmu_en): under MMU the B vaddr is untranslated, so it is not served.
  //
  //  Data hazards: a fill, merge write, or writeback scan can own the SRAM
  //  read port. Only arm B when the port is free, and confirm that the
  //  registered SRAM read index still matches B before returning data.
  // ==========================================================================
`ifdef RAPT_LSU_HUM
  logic b_armed;
  logic [XLEN-1:0] b_addr_r;
  logic b_sram_ready;
  assign b_idx_in
      = lsu_l1d.raddr_b[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign b_arm_ok = (l1d_state == LD_D || (l1d_state == LD_A && data_hit)
                  || (l1d_state == IDLE && !load_speculate && !b_armed))
                  && lsu_l1d.rvalid_b && !lsu_l1d.rcontext_b.mmu_en
                  && !l1d_rmw && !l1d_update && !fence_clear_busy && !wb_hold
                  && rapt_pkg::addr_cacheable(
      lsu_l1d.raddr_b
  ) && !cmu_bcast.flush_pipe;

  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      b_armed  <= 1'b0;
      b_addr_r <= '0;
    end else begin
      b_armed <= b_arm_ok;
      if (b_arm_ok) b_addr_r <= lsu_l1d.raddr_b;
    end
  end

  // B-side decode + tag compare (parallel to A's, on the registered B addr)
  assign b_tag = b_addr_r[PADDR_BITS-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign b_idx = b_addr_r[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign b_off = b_addr_r[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];
  assign b_sram_ready = sram_read_valid_r && sram_read_idx_r == b_idx && !wb_hold;

  logic [XLEN-1:0] b_way_data_masked[L1D_N_WAYS];
  logic [XLEN-1:0] b_data;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_b_ao
      assign b_way_data_masked[w] = b_way_hit[w] ? data_bank_rdata[w][b_off] : '0;
    end
  endgenerate
  always_comb begin
    b_data = '0;
    for (int w = 0; w < int'(L1D_N_WAYS); w++) b_data |= b_way_data_masked[w];
  end

  // Complete only while the held request is unchanged and no write raced us.
  assign lsu_l1d.rready_b = b_armed
                         && lsu_l1d.rvalid_b
                         && (lsu_l1d.raddr_b == b_addr_r)
                         && |b_way_hit
                         && b_sram_ready && !l1d_rmw && !l1d_update && !fence_clear_busy
                         && !cmu_bcast.flush_pipe;
  assign lsu_l1d.rretry_b = b_armed
                         && lsu_l1d.rvalid_b
                         && (lsu_l1d.raddr_b == b_addr_r)
                         && (!(|b_way_hit) || !b_sram_ready || l1d_rmw || l1d_update
                             || fence_clear_busy)
                         && !cmu_bcast.flush_pipe;
  assign lsu_l1d.rdata_b = b_data;
`else
  assign lsu_l1d.rready_b = 1'b0;
  assign lsu_l1d.rretry_b = 1'b0;
  assign lsu_l1d.rdata_b  = '0;
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_hum_b;
  assign _unused_hum_b = lsu_l1d.rvalid_b ^ (^lsu_l1d.raddr_b) ^ (^lsu_l1d.ralu_b);
  /* verilator lint_on UNUSEDSIGNAL */
`endif

  assign waddr_tag = lsu_l1d.waddr[PADDR_BITS-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign waddr_idx = lsu_l1d.waddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign waddr_offset = lsu_l1d.waddr[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];

  assign cacheable_r = rapt_pkg::addr_cacheable(l1d_addr) && l1d_pbmt == 2'b00;
  assign cacheable_w = rapt_pkg::addr_cacheable(lsu_l1d.waddr) && lsu_l1d.wpbmt == 2'b00;

  // Access policy is combinational; this controller owns fault timing.
  logic pmp_load_fault, load_unmapped_fault;
  logic load_region_unmapped_fault;
  logic [XLEN-1:0] idle_load_pa;
  logic [1:0] idle_load_pbmt;
  assign idle_load_pa   = lsu_l1d.rcontext.mmu_en
      ? XLEN'({dtlb_ptag, lsu_l1d.raddr[11:0]}) : lsu_l1d.raddr;
  assign idle_load_pbmt = lsu_l1d.rcontext.mmu_en ? dtlb_pbmt : 2'b00;
  // Match the IDLE load-capture arm: store translation still has priority.
  logic idle_load_capture;
  assign idle_load_capture = (l1d_state == IDLE) && lsu_l1d.rvalid
      && !cmu_bcast.flush_pipe && !fence_clear_busy
      && (!lsu_l1d.atomic_lock || !exu_l1d.reservation_blocked)
      && !(exu_l1d.mmu_en && exu_l1d.valid)
      && (!lsu_l1d.rcontext.mmu_en || tlb_hit);
  logic idle_load_perm;
  assign idle_load_perm = idle_load_capture && !ptw_arvalid;
  assign perm_load_context = idle_load_perm ? lsu_l1d.rcontext : load_context_q;
  logic [XLEN-1:0] ptw_load_pa;
  assign ptw_load_pa = XLEN'({ptw_result_ptag, l1d_addr[11:0]});
  logic ptw_load_perm;
  assign ptw_load_perm  = (l1d_state == PTWAIT) && ptw_done && !stlb_mmu && !ptw_arvalid;
  assign perm_base_addr = idle_load_perm ? idle_load_pa : (ptw_load_perm ? ptw_load_pa : l1d_addr);
  logic perm_check_valid;
  logic [2:0] perm_check_offset;
  logic [3:0] perm_check_size_m1;
  logic [3:0] perm_orig_size_m1;
  logic [1:0] perm_ralu_size;
  logic perm_atomic;
  assign perm_check_valid = idle_load_perm ? lsu_l1d.rcheck_valid : l1d_check_valid;
  assign perm_check_offset = idle_load_perm ? lsu_l1d.rcheck_offset : l1d_check_offset;
  assign perm_check_size_m1 = idle_load_perm ? lsu_l1d.rcheck_size_m1 : l1d_check_size_m1;
  assign perm_orig_size_m1 = idle_load_perm ? lsu_l1d.rorig_size_m1 : l1d_orig_size_m1;
  assign perm_ralu_size = idle_load_perm ? lsu_l1d.ralu[1:0] : l1d_ralu[1:0];
  assign perm_atomic = idle_load_perm ? lsu_l1d.atomic_lock : l1d_atomic_lock;
  logic [XLEN-1:0] perm_load_addr;
  logic [3:0] perm_load_size_m1;
  assign perm_load_addr = perm_base_addr + (perm_check_valid ? XLEN'(perm_check_offset) : XLEN'(0));
  assign perm_load_size_m1 = perm_check_valid ? perm_check_size_m1
      : ((4'd1 << perm_ralu_size) - 4'd1);
  logic [1:0] perm_pbmt;
  assign perm_pbmt = idle_load_perm ? idle_load_pbmt : (ptw_load_perm ? ptw_result_pbmt : l1d_pbmt);
  logic capture_io_size_fault;
  assign capture_io_size_fault = (idle_load_perm ? lsu_l1d.rmisaligned
      : l1d_orig_misaligned) && (perm_pbmt == 2'b10
      || rapt_pkg::addr_device(
      perm_base_addr
  ));
  logic capture_load_denied;
  logic capture_refill_safe;
  // LR never forwards from SQ. Check its translated physical address before
  // either a cache-hit response or an external read can establish reservation.
  assign load_unmapped_fault = load_region_unmapped_fault || !rapt_pkg::addr_device_width_capable(
      perm_load_addr, perm_check_valid ? perm_orig_size_m1 : perm_load_size_m1
  ) || (perm_atomic && !rapt_pkg::addr_atomic_capable(
      perm_base_addr, perm_ralu_size == 2'b11 ? 4'd7 : 4'd3
  ));
  assign capture_load_denied = pmp_load_fault || load_unmapped_fault || capture_io_size_fault;
  assign capture_refill_safe = rapt_pkg::addr_cacheable(
      perm_base_addr
  ) && perm_pbmt == 2'b00 && refill_pmp_uniform && L1dLineOffset <= 12 && refill_ram(
      {perm_base_addr[XLEN-1:L1dLineOffset], {L1dLineOffset{1'b0}}},
      {perm_base_addr[XLEN-1:L1dLineOffset], {L1dLineOffset{1'b0}}}
              | XLEN'((1 << L1dLineOffset) - 1)
  );
  logic pmp_store_fault_mmu, store_unmapped_fault_mmu, pmp_ptw_fault;
  logic pf_load_tlb, pf_store_tlb, pf_load_ptw, pf_store_ptw;
  rapt_l1d_access #(
      .XLEN(XLEN),
      .ShareLoadWalk(1'b1)
  ) u_access (
      .load_context(perm_load_context),
      .store_context(exu_l1d.mem_context),
      .ptw_context(ptw_context_q),
      .pmp_state(pmp_state),
      .load_addr(perm_load_addr),
      .store_addr(exu_l1d.paddr),
      .ptw_addr(ptw_araddr),
      .ptw_check_active(ptw_arvalid),
      .load_size_m1(perm_load_size_m1),
      .store_walu(8'(exu_l1d.walu)),
      .cmo_mgmt(exu_l1d.cmo_mgmt),
      .tlb_hit(tlb_hit),
      .stlb_hit(stlb_hit),
      .dtlb_pte(dtlb_pte),
      .dstlb_pte(dstlb_pte),
      .ptw_result_pte(ptw_result_pte),
      .pmp_load_fault(pmp_load_fault),
      .load_unmapped_fault(load_region_unmapped_fault),
      .pmp_store_fault_mmu(pmp_store_fault_mmu),
      .store_unmapped_fault_mmu(store_unmapped_fault_mmu),
      .pmp_ptw_fault(pmp_ptw_fault),
      .pf_load_tlb(pf_load_tlb),
      .pf_store_tlb(pf_store_tlb),
      .pf_load_ptw(pf_load_ptw),
      .pf_store_ptw(pf_store_ptw)
  );

  // Misaligned accesses are split by the LSU's MA-split FSM into aligned
  // beats (including an optional third RV32D beat) before they reach this
  // L1D, so we never see a true misaligned cache request.
  // The LSU issues each load beat with its own virtual address, so a high beat
  // on the next page receives an independent DTLB lookup/PTW.  Stores are
  // pre-translated in the IOQ before allocation and carry the second page's PA
  // into the SQ.  Suppress address-misaligned traps here because Zicclsm is
  // implemented by those split paths; page/access faults still propagate.
  assign mis_align_load = 1'b0;
  assign mis_align_store = 1'b0;

  // read channel: PTW takes priority over cache miss reads
  assign legacy_arvalid = !wb_hold && (ptw_arvalid
    ? !pmp_ptw_fault
    : (l1d_state == LD_A) && !load_perm_denied_q
      && !tag_hit && !mshr_eligible && !mshr_busy
      && !l1d_sram_busy
      && (cacheable_r || lsu_l1d.ordered)
      && !cmu_bcast.flush_pipe
      && (!line_read_request || !lsu_l1d.wvalid || local_store));
  assign mshr_select = !legacy_arvalid && mshr_req_valid;
  assign l1d_bus.arvalid = legacy_arvalid || mshr_select;
  assign l1d_bus.ar_mshr = mshr_select;
  assign l1d_bus.ar_mshr_id = mshr_req_id;
  assign mshr_req_ready = mshr_select && l1d_bus.rready;
  assign l1d_bus.araddr = mshr_select ? mshr_req_addr
      : ptw_arvalid ? ptw_araddr : line_read_request ? refill_base : l1d_addr;
  assign l1d_bus.rstrb = (mshr_select || cacheable_r || ptw_arvalid) ? 8'($unsigned(
      {XLEN / 8{1'b1}}
  )) : rstrb;
  assign l1d_bus.ar_ptw = ptw_arvalid && !mshr_select;
  assign l1d_bus.rpbmt = (mshr_select || ptw_arvalid) ? 2'b00 : l1d_pbmt;

  // A buffered miss response is captured locally before it can wake the
  // backend. Cache hits retain their existing single-cycle response path.
  assign lsu_l1d.rdata = l1d_state == LD_MSHR_RSP ? mshr_rsp_data_q
      : data_hit ? l1d_data : l1d_state == LD_D ? l1d_bus.rdata : '0;
  // Difftest skip propagation for MMIO loads: cache-hit loads (data_hit=1) are
  // by construction cacheable (and thus non-MMIO), so they don't need to skip
  // the reference model. For misses that go to bus, mirror the bus-side mmio
  // bit so the commit-time DPI can skip REF on the owning instruction.
  assign lsu_l1d.difftest_skip = (l1d_state == LD_MSHR_RSP || data_hit || lsu_l1d.trap)
      ? 1'b0 : l1d_bus.difftest_skip;
  assign lsu_l1d.trap = (l1d_state == TRAP) && !rec_store && (rec_addr == lsu_l1d.raddr)
      && !load_killed && !cmu_bcast.flush_pipe;
  assign lsu_l1d.cause = cause;
  // LD_A consumes the permission result registered with the SRAM speculation.
  // Live PMP decode stays off the ready/fast-wakeup path.
  // A translated device load may be younger than a not-yet-ready RAM load.
  // Parking here would occupy their only request channel indefinitely.
  // No load AR has been accepted in LD_A; return ownership without data.
  assign lsu_l1d.rretry = (l1d_state == LD_A) && !load_perm_denied_q
      && lsu_l1d.rvalid
      && (rec_addr == lsu_l1d.raddr) && !cacheable_r && !lsu_l1d.ordered
      && !load_killed && !cmu_bcast.flush_pipe;
  assign lsu_l1d.rready = !load_killed && !cmu_bcast.flush_pipe && (((l1d_state == LD_MSHR_RSP) && lsu_l1d.rvalid && rec_addr == lsu_l1d.raddr)
      || (lsu_l1d.rvalid && lsu_l1d.trap)
      || (data_hit
        && lsu_l1d.rvalid
        && rec_addr == lsu_l1d.raddr)
      || ((l1d_state == LD_D)
          && (lsu_l1d.rvalid)
          && (legacy_rvalid) && demand_beat && !demand_done
          && !l1d_bus.rerr
          && (rec_addr == lsu_l1d.raddr)));

  // write channel
  assign l1d_bus.wzero = !wb_valid && !ptw_wvalid && lsu_l1d.wzero;
  assign l1d_bus.noallocate = mshr_select || ptw_arvalid || !refill_safe;
  assign l1d_bus.arlen = (mshr_select || (!ptw_arvalid && line_read_request)) ? 8'(L1D_LINE_SIZE-1) : 8'd0;
  assign l1d_bus.awvalid = wb_valid || (!wb_hold && (ptw_awvalid ? 1'b1
      : lsu_l1d.wvalid && !local_store && !mshr_busy && !(l1d_state == LD_D && refill_line)));
  assign l1d_bus.awaddr = wb_valid ? wb_addr : ptw_awvalid ? ptw_awaddr : lsu_l1d.waddr;
  assign l1d_bus.aw_ptw = !wb_valid && ptw_awvalid;
  assign l1d_bus.wpbmt = (wb_valid || ptw_awvalid) ? 2'b00 : lsu_l1d.wpbmt;
  assign l1d_bus.wstrb = wb_valid ? FullStoreWstrb : ptw_wvalid ? ptw_wstrb : lsu_l1d.walu;
  assign l1d_bus.wvalid = wb_valid || (!wb_hold && (ptw_wvalid ? 1'b1
      : lsu_l1d.wvalid && !local_store && !mshr_busy && !(l1d_state == LD_D && refill_line)));
  assign l1d_bus.wdata = wb_valid ? wb_data : ptw_wvalid ? ptw_wdata : lsu_l1d.wdata;

  assign ptw_wready = ptw_wvalid && l1d_bus.ptw_wready;
  // Gate lsu wready while an RMW is in its merge-write phase: the SET block
  // below runs the `if (l1d_rmw)` branch this cycle, which means an incoming
  // store would not be consumed by the `else if (lsu_l1d.wvalid ...)` branch
  // and would be silently dropped if wready had fired. Stalling the store
  // for one cycle lets the merge-write complete and the next-cycle SET will
  // re-evaluate the new store.
  // A dirty update can become visible after a write-through request has
  // already entered the bus.  A newly requested drain must stop subsequent
  // requests, but the matching response still belongs to the SQ request.
  // Let that response retire while WB is idle; WB itself starts only after
  // l1d_bus.idle, so a response can never be consumed by both owners.
  assign lsu_l1d.wready = local_store_ready || ((!wb_hold
      || (!wb_valid && wb_state == WB_IDLE && !l1d_bus.idle && l1d_bus.wready))
      && !local_store
      && !ptw_wvalid && l1d_bus.wready && !mshr_busy && !l1d_rmw && !fence_clear_busy
      && !(l1d_state == LD_D && refill_line));
  assign lsu_l1d.werr = lsu_l1d.wready && !local_store_ready && l1d_bus.werr;

  // store address translation: stlb_hit uses TLB, otherwise wait for PTW
  assign store_paddr = XLEN'({ptw_result_ptag, exu_l1d.vaddr[11:0]});
  assign exu_l1d.paddr = stlb_hit ? XLEN'({dstlb_ptag, exu_l1d.vaddr[11:0]}) : store_paddr;
  assign exu_l1d.pbmt = exu_l1d.mmu_en ? (stlb_hit ? dstlb_pbmt : ptw_result_pbmt) : 2'b00;
  assign exu_l1d.trap = (l1d_state == TRAP) && rec_store && (rec_addr == exu_l1d.vaddr);
  assign exu_l1d.cause = cause;
  assign exu_l1d.reservation = reservation;
  assign exu_l1d.reservation_size_m1 = reservation_size_m1;
  assign exu_l1d.reservation_valid = reservation_valid && !external_hits_reservation;
  assign exu_l1d.reservation_blocked = external_write_pending_i || external_write_valid_i;
  always_ff @(posedge clock) begin
    if (reset || l1d_state == IDLE) lr_interfered <= 1'b0;
    else if (external_hits_lr) lr_interfered <= 1'b1;
  end
  assign exu_l1d.ready = exu_l1d.valid && (exu_l1d.trap
    || (stlb_hit
      && !mis_align_store
      && !pmp_store_fault_mmu
      && !store_unmapped_fault_mmu && !store_io_size_fault && !pf_store_tlb)
    || (stlb_mmu
      && ptw_done
      && !pf_store_ptw
      && !pmp_store_fault_mmu
      && !store_unmapped_fault_mmu && !store_io_size_fault));

  always_ff @(posedge clock) begin
    if (reset) begin
      l1d_state <= IDLE;
      load_context_q <= '0;
      ptw_context_q <= '0;
      load_perm_denied_q <= 1'b0;
      rec_store <= 1'b0;
      fence_clear_set <= '0;
      l1d_update <= 0;
      update_dirty <= 0;
      line_update <= 0;
      l1d_inv_all_ways <= 0;
      l1d_rmw    <= 0;
      d_replace_bit <= '0;
      ld_fill_way_r <= '0;
      l1d_way <= '0;

      reservation <= 'h0;
      reservation_valid <= 1'b0;
      reservation_size_m1 <= 4'd3;
      l1d_atomic_lock <= 1'b0;
      load_killed <= 1'b0;
      mshr_rsp_data_q <= '0;
      refill_safe <= 0;
      refill_line <= 0;
      refill_word <= '0;
      demand_done <= 0;

    end else begin
      if (ptw_req) ptw_context_q <= ptw_request_context;
      fence_clear_set <= WriteBack && wb_hold ? fence_clear_set | maintenance_set : maintenance_set;
      if (external_hits_reservation) begin
        reservation_valid <= 1'b0;
      end
      unique case (l1d_state)
        IDLE: begin
          load_killed <= 1'b0;
          load_perm_denied_q <= 1'b0;
          l1d_atomic_lock <= 1'b0;
          if (!cmu_bcast.flush_pipe && !fence_clear_busy && !wb_hold && !local_store_ready
              && !(WriteBack && coherent_write)
              && (!lsu_l1d.atomic_lock || !exu_l1d.reservation_blocked)) begin
            if (mmu_en) begin
              // Store TLB lookup (priority)
              if (exu_l1d.mmu_en && exu_l1d.valid) begin
                rec_store <= 1'b1;
                if (mis_align_store) begin
                  cause <= 'h6;  // store address mis-aligned
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (stlb_hit && pf_store_tlb) begin
                  // PTE permission denies store.
                  cause <= `RAPT_CAUSE_STORE_PAGE_FAULT;
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (stlb_hit && (pmp_store_fault_mmu || store_unmapped_fault_mmu
                    || store_io_size_fault)) begin
                  // PMP violation on translated store address.
                  cause <= `RAPT_CAUSE_STORE_ACC_FAULT;
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (!stlb_hit && !ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr  <= exu_l1d.vaddr;
                  rec_addr  <= exu_l1d.vaddr;
                  stlb_mmu  <= 'b1;
                  l1d_state <= PTWAIT;
                end
              end else if (lsu_l1d.rvalid) begin
                rec_store <= 1'b0;
                load_context_q <= lsu_l1d.rcontext;
                // Load TLB lookup
                if (mis_align_load) begin
                  cause <= 'h4;  // load address mis-aligned
                  rec_addr <= lsu_l1d.raddr;
                  l1d_state <= TRAP;
                end else if (tlb_hit && pf_load_tlb) begin
                  cause <= `RAPT_CAUSE_LOAD_PAGE_FAULT;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_state <= TRAP;
                end else if (tlb_hit) begin
                  // Capture the physical request before its permission stage.
                  l1d_addr <= XLEN'({dtlb_ptag, lsu_l1d.raddr[11:0]});
                  l1d_pbmt <= dtlb_pbmt;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu <= lsu_l1d.ralu;
                  l1d_orig_misaligned <= lsu_l1d.rmisaligned;
                  l1d_check_valid <= lsu_l1d.rcheck_valid;
                  l1d_check_offset <= lsu_l1d.rcheck_offset;
                  l1d_check_size_m1 <= lsu_l1d.rcheck_size_m1;
                  l1d_orig_size_m1 <= lsu_l1d.rorig_size_m1;
                  l1d_atomic_lock <= lsu_l1d.atomic_lock;
                  if (ptw_arvalid) l1d_state <= LD_CHECK;
                  else begin
                    load_perm_denied_q <= capture_load_denied;
                    refill_safe <= capture_refill_safe;
                    l1d_state <= LD_A;
                  end
                end else if (!ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr <= lsu_l1d.raddr;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu <= lsu_l1d.ralu;
                  l1d_orig_misaligned <= lsu_l1d.rmisaligned;
                  l1d_check_valid <= lsu_l1d.rcheck_valid;
                  l1d_check_offset <= lsu_l1d.rcheck_offset;
                  l1d_check_size_m1 <= lsu_l1d.rcheck_size_m1;
                  l1d_orig_size_m1 <= lsu_l1d.rorig_size_m1;
                  l1d_atomic_lock <= lsu_l1d.atomic_lock;
                  stlb_mmu <= 'b0;
                  l1d_state <= PTWAIT;
                end
              end
            end else begin
              if (lsu_l1d.rvalid) begin
                rec_store <= 1'b0;
                load_context_q <= lsu_l1d.rcontext;
                l1d_addr <= lsu_l1d.raddr;
                l1d_pbmt <= 2'b00;
                rec_addr <= lsu_l1d.raddr;
                l1d_ralu <= lsu_l1d.ralu;
                l1d_orig_misaligned <= lsu_l1d.rmisaligned;
                l1d_check_valid <= lsu_l1d.rcheck_valid;
                l1d_check_offset <= lsu_l1d.rcheck_offset;
                l1d_check_size_m1 <= lsu_l1d.rcheck_size_m1;
                l1d_orig_size_m1 <= lsu_l1d.rorig_size_m1;
                l1d_atomic_lock <= lsu_l1d.atomic_lock;
                if (ptw_arvalid) l1d_state <= LD_CHECK;
                else begin
                  load_perm_denied_q <= capture_load_denied;
                  refill_safe <= capture_refill_safe;
                  l1d_state <= LD_A;
                end
              end
            end
          end
        end
        PTWAIT: begin
          if (cmu_bcast.flush_pipe) begin
            stlb_mmu  <= 'b0;
            l1d_state <= IDLE;
          end else if (ptw_read_error) begin
            // Implicit read errors retain the original operation's fault class
            // and rec_addr, including store-class CBO management operations.
            cause <= stlb_mmu ? `RAPT_CAUSE_STORE_ACC_FAULT : `RAPT_CAUSE_LOAD_ACC_FAULT;
            stlb_mmu <= 1'b0;
            l1d_state <= TRAP;
          end else if (ptw_arvalid && pmp_ptw_fault) begin
            // PMP denies PTE fetch on the PTW's bus address.
            if (stlb_mmu) begin
              cause <= `RAPT_CAUSE_STORE_ACC_FAULT;
              stlb_mmu <= 'b0;
            end else begin
              cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
            end
            l1d_state <= TRAP;
          end else if (ptw_done) begin
            if (stlb_mmu) begin
              // Store PTW done: TLB filled by u_dstlb
              stlb_mmu <= 'b0;
              if (pf_store_ptw) begin
                cause <= `RAPT_CAUSE_STORE_PAGE_FAULT;
                l1d_state <= TRAP;
              end else if (pmp_store_fault_mmu || store_unmapped_fault_mmu
                  || store_io_size_fault) begin
                // PMP denies store on the freshly-translated PA.
                cause <= `RAPT_CAUSE_STORE_ACC_FAULT;
                l1d_state <= TRAP;
              end else begin
                l1d_state <= IDLE;
              end
            end else begin
              // Load PTW done: TLB filled by u_dtlb, compute physical address
              if (pf_load_ptw) begin
                cause <= `RAPT_CAUSE_LOAD_PAGE_FAULT;
                l1d_state <= TRAP;
              end else begin
                l1d_addr <= XLEN'({ptw_result_ptag, l1d_addr[11:0]});
                l1d_pbmt <= ptw_result_pbmt;
                if (ptw_arvalid) l1d_state <= LD_CHECK;
                else begin
                  load_perm_denied_q <= capture_load_denied;
                  refill_safe <= capture_refill_safe;
                  l1d_state <= LD_A;
                end
              end
            end
          end else if (ptw_fault) begin
            if (stlb_mmu) begin
              cause <= 'hf;  // store page fault
              stlb_mmu <= 'b0;
            end else begin
              cause <= 'hd;  // load page fault
            end
            l1d_state <= TRAP;
          end
        end
        TRAP: begin
          l1d_state <= IDLE;
        end
        LD_CHECK: begin
          refill_safe <= cacheable_r && refill_pmp_uniform && L1dLineOffset <= 12 && refill_ram(
              refill_base, refill_last
          );
          if (cmu_bcast.flush_pipe) begin
            l1d_addr  <= '0;
            l1d_state <= IDLE;
          end else if (ptw_arvalid) begin
            // A PTW request can survive until trap recovery after a denied
            // PTE read. It owns the shared read checker, so keep this load
            // captured without consuming the PTW's permission result.
            l1d_state <= LD_CHECK;
          end else if (pmp_load_fault || load_unmapped_fault || load_io_size_fault) begin
            // PMP denies load at this physical address for eff_priv,
            // or the address is unmapped (bus error -> access fault).
            cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
            l1d_state <= TRAP;
          end else begin
            load_perm_denied_q <= 1'b0;
            l1d_state <= LD_A;
          end
        end
        LD_A: begin
          if (load_perm_denied_q) begin
            cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
            l1d_state <= TRAP;
          end else if (cmu_bcast.flush_pipe) begin
            l1d_addr  <= '0;
            l1d_state <= IDLE;
          end else if (wb_hold) begin
            l1d_state <= LD_A;
          end else if (mshr_complete) begin
            if (mshr_error) begin
              cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
              l1d_state <= TRAP;
            end else begin
              mshr_rsp_data_q <= mshr_data;
              l1d_state <= LD_MSHR_RSP;
            end
          end else if (mshr_release) begin
            l1d_state <= IDLE;
          end else if (!cacheable_r && !lsu_l1d.ordered) begin
            l1d_addr  <= '0;
            l1d_state <= IDLE;
          end else if (l1d_atomic_lock) begin
            if (tag_hit) begin
              reservation <= l1d_addr;
              reservation_valid <= !lr_interfered && !external_hits_lr;
              reservation_size_m1 <= l1d_ralu[1:0] == 2'b11 ? 4'd7 : 4'd3;
              l1d_addr <= '0;
              l1d_state <= IDLE;
            end else begin
              // Only advance on OUR OWN cache-miss AR acceptance. The PTW
              // shares this bus with read priority (see l1d_bus.arvalid mux),
              // so an `legacy_rready` (= AR-capture) pulse while ptw_arvalid
              // is high belongs to the PTW, not this load. Advancing on it
              // would make LD_D consume the PTW's read beat as fill data.
              if (legacy_rready && !ptw_arvalid) begin
                l1d_state <= LD_D;
                ld_fill_way_r <= ld_fill_way;
                refill_line <= line_read_request;
                refill_word <= '0;
                demand_done <= 0;
              end
            end
          end else if (tag_hit) begin
            l1d_addr  <= '0;
            l1d_state <= IDLE;
          end else if (l1d_sram_busy) begin
            // Same-cycle SRAM write hazard: load latched stale data and
            // would falsely promote to LD_D (miss). Stall in LD_A; next
            // cycle the SRAM holds the merged value and tag_hit can fire.
            l1d_state <= LD_A;
          end else begin
            if (legacy_rready && !ptw_arvalid) begin
              l1d_state <= LD_D;
              ld_fill_way_r <= ld_fill_way;
              refill_line <= line_read_request;
              refill_word <= '0;
              demand_done <= 0;
            end
          end
        end
        LD_D: begin
          if (cmu_bcast.flush_pipe) load_killed <= 1'b1;
          if (legacy_rvalid) begin
            if (demand_beat && !demand_done) begin

              demand_done <= !l1d_bus.rerr;
              if (!l1d_bus.rerr && l1d_atomic_lock && !load_killed && !cmu_bcast.flush_pipe) begin
                reservation <= l1d_addr;
                reservation_valid <= !lr_interfered && !external_hits_lr;
                reservation_size_m1 <= l1d_ralu[1:0] == 2'b11 ? 4'd7 : 4'd3;
              end
            end
            refill_word <= refill_word + 1'b1;
            if (!refill_line || l1d_bus.rlast) begin
              // Early demand completion does not release the bus owner. Drain
              // through RLAST even after cancellation or an errored demand beat.
              if (load_killed || cmu_bcast.flush_pipe || demand_done
                  || (demand_beat && !l1d_bus.rerr))
                l1d_state <= IDLE;
              else begin
                cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
                l1d_state <= TRAP;
              end
            end
          end
        end
        LD_MSHR_RSP: begin
          // Hold the single buffered response until its owner handshakes.
          // A flush cancels it through the rready gate without publishing it.
          if (cmu_bcast.flush_pipe || (lsu_l1d.rvalid && rec_addr == lsu_l1d.raddr))
            l1d_state <= IDLE;
        end
        default: begin
          l1d_addr  <= '0;
          l1d_state <= IDLE;
        end
      endcase

      // A new LR may replace an invalidated old reservation at another PA.
      // SC clear and interference with the new LR still win on this edge.
      if (exu_l1d.reservation_clear || external_hits_lr) reservation_valid <= 1'b0;

      // l1d_update CLEAR: consume pending update (write tag/valid registers).
      // Must be textually BEFORE the SET block so that when both fire on the
      // same cycle (e.g. load-fill completes, then store write-through arrives
      // next cycle while l1d_update is still high), the SET's NBA wins and the
      // new update is not lost.
      if (|fence_clear_set && !wb_hold) begin
        // Never replay a pending fill into a set just invalidated. Updates
        // to other sets remain pending while the tag clear port is occupied.
        if (fence_clear_set[l1d_idx]) begin
          l1d_rmw <= 0;
          l1d_update <= 0;
          line_update <= 0;
          l1d_inv_all_ways <= 0;
        end
      end else if (l1d_update && !wb_blocked) begin
        // u_tags consumes the same pending update on this edge.
        l1d_update <= 0;
        update_dirty <= 0;
        line_update <= 0;
        l1d_inv_all_ways <= 0;
      end


      // l1d_update SET: request a new SRAM + tag/valid write next cycle.
      // Textually last so its NBA to l1d_update wins over the CLEAR above.
      if ((|fence_clear_set && !(WriteBack && update_dirty && l1d_rmw))
          || (wb_hold && !local_store_ready && !l1d_rmw)) begin
        // Clear takes priority over every new tag/data update below.
      end else if (l1d_rmw) begin
        // RMW phase 2: SRAM data available from previous cycle read,
        // compute byte-lane merge and schedule the write-back.
        l1d_rmw <= 0;
        l1d_update <= 1'b1;
        l1d_data_u <= rmw_merged_data;
        l1d_valid_u <= 1'b1;
        // l1d_idx, l1d_off, l1d_tag_u already set at RMW trigger
      end else if (zero_complete) begin
        // The ZERO descriptor updates memory as a burst. Its complete block
        // is invalidated through maintenance_set, including on a failed B.
      end else if (lsu_l1d.wvalid && lsu_l1d.wready && lsu_l1d.werr) begin
        // An errored posted write may have modified some external bytes.
        // Do not install the intended value or retain a potentially stale
        // physical alias, including a hot PMA copy of an NC/IO write target.
        l1d_update <= 1'b1;
        l1d_valid_u <= 1'b0;
        l1d_inv_all_ways <= 1'b1;
        l1d_tag_u <= waddr_tag;
        l1d_idx <= waddr_idx;
        l1d_off <= waddr_offset;
        l1d_way <= store_hit_way;
      end else if (lsu_l1d.wvalid && lsu_l1d.wready && cacheable_w && !lsu_l1d.wzero) begin
        update_dirty <= local_store_ready;
        // Treat any full-width request at an unaligned cache offset as
        // partial. Split stores normally arrive aligned with an already
        // lane-shifted mask/data pair; unsplit requests may still rely on
        // their address offset during the RMW merge.
        if (lsu_l1d.walu == FullStoreWstrb && lsu_l1d.waddr[L1dOffsetBits-1:0] == '0) begin
          l1d_update <= 1'b1;
          l1d_data_u <= lsu_l1d.wdata;
          l1d_valid_u <= 1'b1;
          l1d_tag_u <= waddr_tag;
          l1d_idx <= waddr_idx;
          l1d_off <= waddr_offset;
          l1d_way <= hit_w ? store_hit_way : store_fill_way;
          if (!hit_w && L1D_N_WAYS == 2) d_replace_bit[waddr_idx] <= ~d_replace_bit[waddr_idx];
        end else begin
          if (hit_w) begin
            if (partial_store_rmw) begin
              // Partial store hit, SRAM read port free: initiate RMW
              l1d_rmw <= 1'b1;
              l1d_rmw_wdata <= lsu_l1d.wdata;
              l1d_rmw_waddr_lo <= lsu_l1d.waddr[L1dOffsetBits-1:0];
              l1d_rmw_walu <= lsu_l1d.walu;
              l1d_tag_u <= waddr_tag;
              l1d_idx <= waddr_idx;
              l1d_off <= waddr_offset;
              l1d_way <= store_hit_way;
            end else begin
              // Fallback: invalidate (SRAM read port busy).  Broadcast across
              // all ways at this (idx, off) so duplicate-tag stale copies
              // cannot survive in a non-store_hit_way slot.
              l1d_update <= 1'b1;
              l1d_valid_u <= 0;
              l1d_inv_all_ways <= 1'b1;
              l1d_tag_u <= waddr_tag;
              l1d_idx <= waddr_idx;
              l1d_off <= waddr_offset;
              l1d_way <= store_hit_way;
            end
          end
        end
      end else if (mshr_fill_ready) begin
        l1d_update <= 1'b1;
        line_update <= 1'b1;
        line_update_mask <= mshr_fill_mask;
        line_update_data <= mshr_fill_data;
        l1d_valid_u <= 1'b1;
        l1d_tag_u <= mshr_fill_tag;
        l1d_idx <= mshr_fill_idx;
        l1d_off <= '0;
        l1d_way <= store_fill_way;
        if (L1D_N_WAYS == 2) d_replace_bit[mshr_fill_idx] <= ~d_replace_bit[mshr_fill_idx];
      end else if (l1d_state == LD_D) begin
        if ((refill_line || lsu_l1d.rvalid) && legacy_rvalid && !l1d_bus.rerr
            && !load_killed && !cmu_bcast.flush_pipe) begin
          if (cacheable_r) begin
            l1d_update <= 1'b1;
            l1d_data_u <= l1d_bus.rdata;
            l1d_valid_u <= 1'b1;
            l1d_tag_u <= addr_tag;
            l1d_idx <= addr_idx;
            l1d_off <= refill_line ? refill_word : addr_offset;
            l1d_way <= ld_fill_way_r;
            if (L1D_N_WAYS == 2) d_replace_bit[addr_idx] <= ~d_replace_bit[addr_idx];
          end
        end
      end
    end
  end

  `RAPT_SVA_IMPLY(clock, reset, L1D_REFILL_LAST, l1d_state == LD_D && refill_line && legacy_rvalid,
                  l1d_bus.rlast == (refill_word == L1D_LINE_LEN'(L1D_LINE_SIZE - 1)))
  `RAPT_SVA_IMPLY(clock, reset, L1D_REFILL_STORE_EXCLUSION, l1d_state == LD_D && refill_line,
                  !lsu_l1d.wready && !(l1d_bus.awvalid && !l1d_bus.aw_ptw))
  `RAPT_SVA_IMPLY(clock, reset, L1D_MMIO_READ_REQUIRES_ORDER,
                  legacy_arvalid && !l1d_bus.ar_ptw && !cacheable_r, lsu_l1d.ordered)
  `RAPT_SVA_IMPLY(clock, reset, L1D_RETRY_NO_COMPLETION_OR_READ, lsu_l1d.rretry,
                  !lsu_l1d.rready && !lsu_l1d.trap && !(legacy_arvalid && !l1d_bus.ar_ptw))
  `RAPT_SVA_IMPLY(clock, reset, L1D_FLUSH_BLOCKS_NEW_READ, cmu_bcast.flush_pipe, !l1d_bus.arvalid)
  `RAPT_SVA_IMPLY(clock, reset, L1D_PERMISSION_STAGE_BLOCKS_ACCESS,
                  (l1d_state == LD_CHECK) || (l1d_state == LD_A && load_perm_denied_q),
                  !lsu_l1d.rready && !(legacy_arvalid && !l1d_bus.ar_ptw))
  // Antecedents extracted so the SVA macro arguments stay short and the
  // formatter cannot rejoin them past the column limit.
  logic l1d_permission_stage_denied;
  assign l1d_permission_stage_denied = !cmu_bcast.flush_pipe && (
      (l1d_state == LD_CHECK && !ptw_arvalid
          && (pmp_load_fault || load_unmapped_fault || load_io_size_fault))
      || (l1d_state == LD_A && load_perm_denied_q));
  `RAPT_SVA_NEXT(clock, reset, L1D_PERMISSION_STAGE_DENIED, l1d_permission_stage_denied,
                 l1d_state == TRAP)
  `RAPT_SVA_NEXT(clock, reset, L1D_PERMISSION_STAGE_WAITS_FOR_PTW,
                 l1d_state == LD_CHECK && ptw_arvalid && !cmu_bcast.flush_pipe,
                 l1d_state == LD_CHECK)
  logic l1d_lr_hit_establishes_reservation;
  assign l1d_lr_hit_establishes_reservation = (l1d_state == LD_A) && tag_hit
      && l1d_atomic_lock && !cmu_bcast.flush_pipe
      && !exu_l1d.reservation_clear && !external_hits_lr && !lr_interfered;
  `RAPT_SVA_NEXT(clock, reset, L1D_LR_HIT_ESTABLISHES_RESERVATION,
                 l1d_lr_hit_establishes_reservation, reservation_valid && reservation == $past
                 (l1d_addr))
  logic l1d_lr_response_establishes_reservation;
  assign l1d_lr_response_establishes_reservation = (l1d_state == LD_D)
      && legacy_rvalid && demand_beat && !demand_done && !l1d_bus.rerr
      && l1d_atomic_lock && !load_killed && !cmu_bcast.flush_pipe
      && !exu_l1d.reservation_clear && !external_hits_lr && !lr_interfered;
  `RAPT_SVA_NEXT(clock, reset, L1D_LR_RESPONSE_ESTABLISHES_RESERVATION,
                 l1d_lr_response_establishes_reservation, reservation_valid && reservation == $past
                 (l1d_addr))
  logic l1d_killed_lr_response_no_new_reservation;
  assign l1d_killed_lr_response_no_new_reservation = (l1d_state == LD_D)
      && legacy_rvalid && l1d_atomic_lock && !reservation_valid
      && (load_killed || cmu_bcast.flush_pipe);
  `RAPT_SVA_NEXT(clock, reset, L1D_KILLED_LR_RESPONSE_NO_NEW_RESERVATION,
                 l1d_killed_lr_response_no_new_reservation, !reservation_valid)
endmodule
/* verilator lint_on PINCONNECTEMPTY */
