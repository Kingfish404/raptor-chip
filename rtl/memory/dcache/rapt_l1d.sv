`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

/* verilator lint_off PINCONNECTEMPTY */
module rapt_l1d #(
    parameter bit WriteBack = `RAPT_L1D_WRITEBACK,
    parameter bit TargetedCoherence = `RAPT_L1D_TARGETED_COHERENCE,
    parameter bit LineRefill = 1,
`ifdef RAPT_L1D_DIRTY_SKIP
    parameter bit DirtySkip = `RAPT_L1D_DIRTY_SKIP,
`else
    parameter bit DirtySkip = 0,
`endif
    parameter int L1D_LINE_LEN = `RAPT_L1D_LINE_LEN,
    parameter int unsigned L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
    parameter int L1D_LEN = `RAPT_L1D_LEN,
    parameter int unsigned L1D_SIZE = 2 ** L1D_LEN,
    parameter int XLEN = `RAPT_XLEN,
    parameter unsigned L1D_N_WAYS = `RAPT_L1D_WAYS,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS,
    parameter bit L2Tlb = 0,
    // L2 subsystem capabilities (rapt_pkg::L2LinkConfig). An inclusive L2
    // tracks L1D lines and probes them; a release-capable L2 also accepts
    // voluntary victim releases. An L2 cache allocates 2**L2LineOffset bytes.
    parameter bit L2Cache = rapt_pkg::L2LinkConfig.cache,
    parameter bit L2Inclusive = rapt_pkg::L2LinkConfig.inclusive,
    parameter bit L2Release = rapt_pkg::L2LinkConfig.victim_release,
    parameter int L2LineOffset = rapt_pkg::L2LinkConfig.line_offset
) (
    input clock,
    input logic coherent_request = 1'b0,
    input logic coherent_write = 1'b0,
    input logic [XLEN-1:0] coherent_addr = '0,
    output logic coherent_ready,
    input logic probe_valid_i = 1'b0,
    input logic [XLEN-1:0] probe_addr_i = '0,
    output logic probe_ready_o,
    output logic probe_release_valid_o,
    output logic [XLEN-1:0] probe_release_addr_o,
    output logic [XLEN-1:0] probe_release_data_o,
    input logic probe_release_ready_i = 1'b0,
    output logic release_valid_o,
    output logic [XLEN-1:0] release_addr_o,
    output logic [XLEN-1:0] release_data_o,
    output logic release_has_data_o,
    output logic release_mask_o,
    output logic release_last_o,
    input logic release_ready_i = 1'b0,
    input logic release_ack_i = 1'b0,
    input logic probe_window_i = 1'b0,
    output logic writeback_bus_pending_o,
    output logic writeback_error,
    output logic writeback_idle,
    input logic writeback_drain = 1'b0,
    input logic writeback_cbo = 1'b0,
    input logic writeback_cbo_invalidate = 1'b0,
    input logic [XLEN-1:6] writeback_block = '0,
    output logic writeback_cbo_done,
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

    input reset,
    output rapt_pkg::l2tlb_req_t l2tlb_req_o,
    input logic l2tlb_ready_i = 1'b0,
    input rapt_pkg::l2tlb_rsp_t l2tlb_rsp_i = '0
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
  // Permission is registered before LD_A consumes the speculative SRAM read,
  // keeping PMP decode off rready/fast-wakeup.
  logic load_perm_denied_q;
  logic load_page_fault_q;
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
  logic wb_hold, probe_wb_hold, load_miss_wb_hold;
  logic store_accept, store_error, store_rsp_valid_q, store_rsp_error_q;
  logic mshr_busy, mshr_wake, mshr_ready, mshr_error, mshr_wait;
  logic mshr_lookup, mshr_eligible, mshr_complete, mshr_release, mshr_buffered;
  logic mshr_store_yield;
  logic mshr_req_valid, mshr_req_ready, mshr_select, legacy_arvalid;
  logic [1:0] mshr_req_id;
  logic [XLEN-1:0] mshr_req_addr, mshr_data;
  logic [XLEN-1:0] mshr_rsp_data_q;
  logic legacy_rvalid, legacy_rready;
  logic mshr_invalidate, mshr_invalidate_line;
  logic mshr_evict_valid;
  logic [XLEN-1:0] mshr_evict_addr;
  logic mshr_fill_valid, mshr_fill_ready;
  logic [XLEN-1:0] mshr_fill_addr;
  logic [L1D_LINE_SIZE-1:0] mshr_fill_mask, line_update_mask;
  logic [L1D_LINE_SIZE*XLEN-1:0] mshr_fill_data, line_update_data;
  logic line_update;
  assign legacy_rvalid = l1d_bus.rvalid && !l1d_bus.r_mshr;
  assign legacy_rready = l1d_bus.rready && !l1d_bus.ar_mshr;
  assign mshr_invalidate = cmu_bcast.flush_pipe || fence_clear_busy || external_write_valid_i;
  assign mshr_invalidate_line = (lsu_l1d.wvalid && !mshr_busy) || mshr_evict_valid;
  // Only requests which can replay as a whole may release LSU ownership.
  // Permission has already been registered before LD_A looks up tags.
  assign mshr_eligible = (`RAPT_L1D_MSHRS > 0) && LineRefill && refill_safe
      && !load_perm_denied_q && lsu_l1d.replay_allowed && !l1d_atomic_lock
      && !l1d_orig_misaligned;
  // Miss allocation needs the tag result, not SRAM read data. A valid cache
  // word without a matching buffer waits for its array read; an absent word
  // can allocate while a different refill is writing the array.
  assign mshr_lookup = mshr_eligible && l1d_state == LD_A && !lsu_l1d.wvalid
      && !mshr_invalidate && !load_miss_wb_hold;
  assign mshr_complete = mshr_lookup && mshr_ready;
  assign mshr_release = mshr_lookup && mshr_wait;
  // A local store arriving after load acceptance needs IDLE to update the
  // array. Yield the held load instead of waiting in LD_A for that store;
  // store completion (or refill progress) wakes its IOQ owner for replay.
  assign mshr_store_yield = mshr_eligible && l1d_state == LD_A
      && lsu_l1d.wvalid && !tag_hit && !load_miss_wb_hold && !mshr_invalidate;
  assign lsu_l1d.rmiss = (mshr_release || mshr_store_yield) && lsu_l1d.rvalid;
  assign lsu_l1d.miss_wake = mshr_wake || (lsu_l1d.wvalid && lsu_l1d.wready);
  if (`RAPT_L1D_MSHRS > 0) begin : g_mshr
    rapt_l1d_mshr #(
        .Xlen(XLEN),
        .Entries(`RAPT_L1D_MSHRS),
        // mshr_fill_ready already excludes every line-invalidation cycle.
        .StallFillOnLineInvalidate(1'b1),
        .LineBytes(L1D_LINE_SIZE * (XLEN / 8))
    ) misses (
        .clock,
        .reset,
        .invalidate(mshr_invalidate),
        .invalidate_line(mshr_invalidate_line),
        .invalidate_addr(mshr_evict_valid ? mshr_evict_addr : lsu_l1d.waddr),
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
  logic [L1D_LEN-1:0] probe_set;
  logic [L1dTagW-1:0] probe_tag;
  logic probe_clearing;
  logic local_cbo_line_clear, line_clearing;
  logic [L1D_LEN-1:0] line_clear_set;
  logic [L1dTagW-1:0] line_clear_tag;
  logic [L1D_N_WAYS-1:0] probe_dirty_way;
  logic [L1dWayW-1:0] probe_dirty_selected_way;
  logic probe_dirty_request;
  logic target_request, target_invalidate, target_dirty_request, target_clear;
  // Only the physical line index/tag participates in maintenance lookup.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] target_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [L1D_LEN-1:0] first_dirty_set;
  logic [L1dWayW-1:0] first_dirty_way;
  localparam int CboLines = (64 > (L1D_LINE_SIZE * XLEN / 8)) ? 64 / (L1D_LINE_SIZE * XLEN / 8) : 1;
  localparam int CboLineBits = CboLines > 1 ? $clog2(CboLines) : 1;
  logic [CboLineBits-1:0] cbo_line_q;
  logic cbo_done_q;
  logic target_cbo, target_store, target_load;
  logic zero_complete;
  logic cacheable_w;
  // Maintenance and refill logic reference these before the address logic.
  logic [L1D_LEN-1:0] waddr_idx;
  logic [L1D_LINE_LEN-1:0] addr_offset;
  assign zero_complete = lsu_l1d.wvalid && store_accept && lsu_l1d.wzero;

  // No tag lookup: invalidate every way of the VA-selected set. A CBO block
  // is 64 bytes even for presets with smaller cache lines, so ignore index
  // bits below bit 6. Index bits above the page offset are also ignored: a
  // larger custom geometry clears all possible physical colors safely.
  localparam unsigned L1dLineOffset = L1D_LINE_LEN + L1dOffsetBits;
  // The CBO broadcast omits address bits [5:0]. Reconstruct them before
  // slicing by cache-line geometry, which can start below bit 6 for 16-byte
  // lines (small, middle and formal presets).
  logic [XLEN-1:0] cbo_addr;
  assign cbo_addr = {cmu_bcast.cbo_block, 6'b0};
  assign probe_set = probe_addr_i[L1dLineOffset+:L1D_LEN];
  assign probe_tag = probe_addr_i[L1dLineOffset+L1D_LEN+:L1dTagW];
  assign local_cbo_line_clear = WriteBack && L2Inclusive && cmu_bcast.cbo_inval;
  assign probe_clearing = probe_valid_i && !probe_wb_hold && !local_cbo_line_clear;
  assign probe_dirty_request = WriteBack && probe_valid_i && |probe_dirty_way;
  always_comb begin
    probe_dirty_selected_way = '0;
    for (int way = L1D_N_WAYS - 1; way >= 0; way--)
    if (probe_dirty_way[way]) probe_dirty_selected_way = L1dWayW'(way);
  end
  localparam logic [11:0] CboIndexMask = 12'((L1D_SIZE - 1) << L1dLineOffset) & 12'hfc0;
  for (genvar s = 0; s < L1D_SIZE; s++) begin : g_maintenance_set
    assign maintenance_set[s] = (WriteBack && (L2Inclusive || !TargetedCoherence) && (coherent_write
        || (lsu_l1d.wvalid && store_accept && !cacheable_w)))
      || ((!WriteBack || (!L2Inclusive && !TargetedCoherence)) && cmu_bcast.cbo_inval
        && (12'(s << L1dLineOffset) & CboIndexMask)
            == (cbo_addr[11:0] & CboIndexMask))
        || (zero_complete && ((s >> (L1dLineOffset < 6 ? 6-L1dLineOffset : 0))
            == (int'(waddr_idx) >> (L1dLineOffset < 6 ? 6-L1dLineOffset : 0))))
        // A failed posted store already updated a resident copy at acceptance.
        // Drop that set; write-through lines hold no other dirty state.
        || (!WriteBack && l1d_bus.posted_error
        && 32'(s) == 32'(l1d_bus.posted_error_addr[L1D_LEN+L1dLineOffset-1:L1dLineOffset]));
  end
  assign fence_clear_busy = cmu_bcast.cbo_inval || probe_valid_i || |fence_clear_set;
  // The L2 holds its probe until the exact physical line has been cleared by
  // the tag array. The registered response prevents an early replacement.
  always_ff @(posedge clock) begin
    if (reset) probe_ready_o <= 1'b0;
    else probe_ready_o <= probe_clearing;
  end

  logic refill_line, demand_done;
  logic [L1D_LINE_LEN-1:0] refill_word;
  logic demand_beat, line_read_request;
  logic [XLEN-1:0] refill_base, refill_last;
  assign refill_base = {l1d_addr[XLEN-1:L1dLineOffset], {L1dLineOffset{1'b0}}};
  assign refill_last = refill_base | XLEN'((1 << L1dLineOffset) - 1);
  assign line_read_request = LineRefill && refill_safe;
  assign demand_beat = !refill_line || refill_word == addr_offset;
  // An L2 cache allocates whole L2 lines; refills guard the larger line.
  localparam int DownstreamLineOffset = L2Cache ? L2LineOffset : L1dLineOffset;
  localparam int GuardOffset = DownstreamLineOffset > L1dLineOffset
      ? DownstreamLineOffset : L1dLineOffset;
  if (GuardOffset <= `RAPT_PMP_GRANULARITY_LOG2) begin : g_refill_page
    assign refill_pmp_uniform = 1'b1;
  end else begin : g_refill_fine
    rapt_pmp_line_uniform #(
        .XLEN(XLEN),
        .LineOffset(GuardOffset)
    ) u_refill_pmp (
        .addr(perm_base_addr),
        .state(pmp_state),
        .uniform_o(refill_pmp_uniform)
    );
  end
  // Keep narrow ROM/SRAM/device bridges on their established word protocol.
  // A RAM burst stays in one physical PMA range and one translated page.
  function automatic logic refill_ram(input logic [XLEN-1:0] first, input logic [XLEN-1:0] last);
    return (rapt_pkg::addr_in_pmem(first) && rapt_pkg::addr_in_pmem(last) &&
            rapt_pkg::canonical_addr(first) <= rapt_pkg::canonical_addr(last)) ||
        (rapt_pkg::PmemBytes < 32'h80000000 && rapt_pkg::addr_upper_valid(first) &&
         rapt_pkg::addr_upper_valid(last) && rapt_pkg::canonical_addr(first) >= XLEN'('ha0000000) &&
         rapt_pkg::canonical_addr(first) <= rapt_pkg::canonical_addr(last) &&
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
  logic [1:0] store_pbmt;
  logic store_access_fault;
  logic store_check_valid, store_page_fault;
  logic store_check_capture;

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
  logic [        XLEN-1:0] ptw_vaddr;
  logic [       XLEN-1:10] ptw_result_ptag;
  logic [       XLEN-1:12] ptw_result_vtag;
  logic [             6:0] ptw_result_pte;

  // mis-alignment check
  logic                    mis_align_load;
  logic                    mis_align_store;

  logic                    l1d_update;
  logic [        XLEN-1:0] l1d_data_u;
  logic [      XLEN/8-1:0] l1d_strobe_u;
  logic                    l1d_valid_u;
  // When set together with valid_u==0, the update commit invalidates the
  // selected (idx, off) word in EVERY way (broadcast invalidate).  Used for
  // failed stores so that any duplicate-tag legacy line cannot keep stale
  // data in a non-`store_hit_way` slot.
  logic                    l1d_inv_all_ways;
  logic [     L1dTagW-1:0] l1d_tag_u;
  logic [     L1D_LEN-1:0] l1d_idx;
  // Bound the word-selector fanout into the independently placed data banks.
  (* max_fanout = 16 *) logic [L1D_LINE_LEN-1:0] l1d_off;
  logic [     L1dWayW-1:0] l1d_way;  // which way for pending l1d_update
  logic [     L1dWayW-1:0] ld_fill_way_r;  // registered fill way for load miss
  logic [    L1D_SIZE-1:0] d_replace_bit;  // random replacement toggle per set (2-way only)

  typedef enum logic [3:0] {
    WB_IDLE,
    WB_SCAN,
    WB_READ,
    WB_CAPTURE,
    WB_WAIT,
    WB_CLEAN,
    WB_RELEASE_SEND,
    WB_RELEASE_ACK,
    WB_RELEASE_CLEAR
  } wb_state_t;
  wb_state_t wb_state;
  logic dirty_any, wb_dirty_any, wb_busy, wb_valid, wb_capture_ready, wb_blocked;
  logic update_dirty, local_store, local_store_ready;
  logic lsu_bus_write_pending_q;
  logic lsu_bus_write_allowed, lsu_bus_write_response;
  logic [L1D_LEN-1:0] wb_set;
  logic [L1dWayW-1:0] wb_way;
  logic [L1dWayW-1:0] ld_fill_way;
  logic [L1D_LEN-1:0] mshr_fill_idx;
  logic [L1dTagW-1:0] mshr_fill_tag;
  logic [L1D_LEN-1:0] tag_store_idx;
  logic [L1dTagW-1:0] tag_store_tag;
  logic [L1dTagW-1:0] wb_tag;
  logic [L1D_LEN-1:0] tag_inspect_set, tag_load_read_set;
  logic [1:0] tag_inspect_source;
  logic [L1D_LINE_SIZE-1:0] wb_dirty, wb_valid_words;
  logic [L1D_LINE_SIZE*XLEN-1:0] wb_line_data;
  logic [L1D_LINE_SIZE*XLEN-1:0] release_line_q;
  logic [L1D_LINE_SIZE-1:0] release_mask_q;
  logic [XLEN-1:0] release_line_addr_q;
  logic [L1D_LINE_LEN-1:0] release_word_q;
  logic wb_release_mode, release_clearing;
  assign release_clearing = wb_state == WB_RELEASE_CLEAR;
  assign line_clearing = release_clearing || probe_clearing || local_cbo_line_clear
      || target_clear;
  assign line_clear_set = release_clearing ? wb_set
      : local_cbo_line_clear ? cbo_addr[L1dLineOffset+:L1D_LEN]
      : (!probe_valid_i && target_request) ? target_addr[L1dLineOffset+:L1D_LEN] : probe_set;
  assign line_clear_tag = release_clearing
      ? release_line_addr_q[L1dLineOffset+L1D_LEN+:L1dTagW]
      : local_cbo_line_clear ? cbo_addr[L1dLineOffset+L1D_LEN+:L1dTagW]
      : (!probe_valid_i && target_request)
      ? target_addr[L1dLineOffset+L1D_LEN+:L1dTagW] : probe_tag;
  // A completed refill buffer is also a readable copy. Voluntary Release
  // relinquishes that copy along with the array, or an L2 write could leave
  // a stale replay buffer after the directory no longer lists this client.
  assign mshr_evict_valid = release_clearing || local_cbo_line_clear || target_clear;
  assign mshr_evict_addr = XLEN'({line_clear_tag, line_clear_set, {L1dLineOffset{1'b0}}});
  logic [XLEN-1:0] wb_addr, wb_data;
  localparam int DataChunks = L1D_LINE_SIZE * XLEN / 64;
  localparam int DataBanks  = ((L1D_N_WAYS + DataChunks - 1) / DataChunks) * DataChunks;
  logic [63:0] data_bank_rdata[DataBanks];
  logic wb_drain_request;
  localparam logic [7:0] FullStoreWstrb = 8'({XLEN / 8{1'b1}});
  logic [L1dWayW-1:0] store_hit_way, store_fill_way;
  logic wb_global_request, wb_victim_request, wb_targeted;
  logic load_victim_request, load_victim_valid, load_victim_dirty;
  logic [L1dTagW-1:0] load_victim_tag;
  logic wb_global_dirty;
  logic wb_fill_probe, wb_fill_victim, wb_read_match, wb_miss_match;
  logic tag_probe_fill;
  logic wb_probe_mode;
  logic wb_start;
  logic store_allocate, wb_store_lookup, wb_store_probe, wb_store_victim;
  logic [L1D_LEN-1:0] wb_probe_set;
  logic [L1dWayW-1:0] wb_probe_way;
  assign store_allocate = cacheable_w && !lsu_l1d.wzero
      && lsu_l1d.walu == FullStoreWstrb && lsu_l1d.waddr[L1dOffsetBits-1:0] == '0;
  // Choose store metadata before cacheability and byte-mask decode. Those
  // gate the victim request, not its lookup; other stores cannot capture it.
  assign wb_store_lookup = l1d_state == IDLE && lsu_l1d.wvalid;
  assign wb_store_probe = wb_store_lookup && store_allocate;
  assign wb_fill_probe = tag_probe_fill && mshr_fill_valid
      && (l1d_state == IDLE || l1d_state == LD_CHECK);
  assign wb_probe_set = (probe_dirty_request || target_dirty_request) ? line_clear_set
      : wb_store_lookup ? waddr_idx
      : wb_fill_probe ? mshr_fill_idx : addr_idx;
  assign wb_probe_way = (probe_dirty_request || target_dirty_request) ? probe_dirty_selected_way
      : (wb_store_lookup || wb_fill_probe) ? store_fill_way : ld_fill_way;
  // Completed refills choose their victim at installation, not allocation.
  // The writeback queue must own every dirty byte before the array is reused.
  assign wb_fill_victim = wb_fill_probe && (L2Release
      ? (|wb_valid_words && wb_tag != mshr_fill_tag) : wb_dirty_any);
  assign wb_store_victim = wb_store_probe && !hit_w
      && (L2Release ? |wb_valid_words : wb_dirty_any) && wb_tag != waddr_tag;
  // The L1D is this hart's point of coherence. Only instruction publication
  // needs a global clean; walkers and mismatched attributes select one line.
  // Keep the inclusive L2's established probe/release protocol unchanged.
  assign wb_global_request = !probe_valid_i && (writeback_drain || |fence_clear_set
      || (lsu_l1d.wvalid && lsu_l1d.wzero)
      || (!TargetedCoherence && !L2Inclusive && cmu_bcast.cbo_inval)
      || ((L2Inclusive || !TargetedCoherence) && (writeback_cbo || coherent_request || coherent_write
          || ptw_arvalid || (lsu_l1d.wvalid && (!cacheable_w || lsu_l1d.wzero))
          || (l1d_state == LD_A && (!cacheable_r || l1d_atomic_lock)))));
  assign target_cbo = TargetedCoherence && writeback_cbo && !cbo_done_q;
  assign target_store = lsu_l1d.wvalid && !cacheable_w
      && rapt_pkg::addr_cacheable(lsu_l1d.waddr);
  assign target_load = l1d_state == LD_A && !load_perm_denied_q
      && ((!cacheable_r && lsu_l1d.ordered && rapt_pkg::addr_cacheable(l1d_addr))
          || l1d_atomic_lock);
  assign target_request = WriteBack && TargetedCoherence && !L2Inclusive
      && (target_cbo || ptw_arvalid || coherent_request || target_store || target_load);
  assign target_addr = target_cbo
      ? ({writeback_block, 6'b0} | (XLEN'(cbo_line_q) << L1dLineOffset))
      : ptw_arvalid ? ptw_araddr : target_load ? l1d_addr
      : coherent_request ? coherent_addr : lsu_l1d.waddr;
  assign target_invalidate = target_cbo ? writeback_cbo_invalidate
      : ptw_arvalid ? 1'b0 : target_load ? !cacheable_r
      : !coherent_request && target_store;
  assign target_dirty_request = target_request && !probe_valid_i && |probe_dirty_way;
  // Dirty ownership moves to the queue at capture; external observers must
  // still wait for B. Clean invalidations cannot race an array installation.
  assign target_clear = target_request && target_invalidate && !probe_valid_i
      && !(|probe_dirty_way) && wb_state == WB_IDLE && !wb_busy
      && !writeback_error && !l1d_update;
  assign writeback_cbo_done = !WriteBack
      || ((L2Inclusive || !TargetedCoherence) ? writeback_idle : cbo_done_q);
  always_ff @(posedge clock) begin
    if (reset || !writeback_cbo) begin
      cbo_line_q <= '0;
      cbo_done_q <= 1'b0;
    end else if (target_cbo && !probe_valid_i && !(|probe_dirty_way)
        && wb_state == WB_IDLE && !wb_busy && !writeback_error && !l1d_update) begin
      if (cbo_line_q == CboLineBits'(CboLines - 1)) cbo_done_q <= 1'b1;
      else cbo_line_q <= cbo_line_q + 1'b1;
    end
  end
  assign wb_victim_request = l1d_state == LD_A && !load_perm_denied_q
      && cacheable_r && !(|load_way_hit)
      && (L2Release ? |wb_valid_words : wb_dirty_any)
      && (line_read_request || wb_tag != addr_tag);
  assign load_victim_request = l1d_state == LD_A && !load_perm_denied_q
      && cacheable_r && !(|load_way_hit)
      && (L2Release ? load_victim_valid : load_victim_dirty)
      && (line_read_request || load_victim_tag != addr_tag);
  assign wb_drain_request = probe_valid_i ? probe_dirty_request
      : wb_global_request || target_dirty_request || wb_victim_request || wb_store_victim || wb_fill_victim;
  // A global drain with no dirty words must not displace a clean victim
  // release. Otherwise WB_SCAN immediately returns to IDLE and retries the
  // same scan forever while the waiting load remains held in LD_A.
  assign wb_global_dirty = wb_global_request && dirty_any;
  // Reserve the L2 read/CBO port only when this writeback can actually start.
  // A request blocked by an existing L2 probe/window or an unfinished bus
  // transaction cannot make progress yet; advertising it as pending there
  // would keep the very transaction it waits for from completing. Without
  // inclusive L2, capture can overlap reads and older queued writebacks;
  // an outstanding SQ write still retains exclusive response ownership.
  assign wb_start = wb_state == WB_IDLE && wb_drain_request
      && (dirty_any || (L2Release && (wb_victim_request || wb_store_victim || wb_fill_victim)))
      && (probe_dirty_request || !probe_window_i)
      && (L2Inclusive ? (l1d_bus.idle || probe_dirty_request)
          : (!lsu_bus_write_pending_q && !l1d_bus.posted_busy
              && l1d_state != LD_D))
      && (!probe_dirty_request || !wb_busy)
      && !l1d_update && !local_store_ready
      && (probe_dirty_request || l1d_state == IDLE || l1d_state == LD_A
          || l1d_state == PTWAIT || l1d_state == LD_CHECK);
  assign writeback_bus_pending_o = WriteBack && !probe_valid_i
      && ((wb_state != WB_IDLE && !wb_probe_mode) || wb_start || wb_busy);
  // A Probe can clear a clean copy before an unstarted voluntary Release.
  // Keep that Release hold on ordinary requests: a Probe of another line
  // must not let a waiting miss overwrite its own dirty victim.
  assign probe_wb_hold = WriteBack && ((dirty_any && wb_drain_request)
      || (wb_busy && (L2Inclusive || probe_valid_i || wb_global_request
          || (l1d_state == LD_A && !mshr_eligible)))
      || target_dirty_request || (target_request && wb_busy)
      || wb_state != WB_IDLE || writeback_error
      || (update_dirty && l1d_update));
  assign wb_hold = probe_wb_hold
      || (WriteBack && L2Release && (wb_victim_request || wb_store_victim || wb_fill_victim));
  // Only the load victim can be requested in LD_A. Express that state
  // contract before the shared tag probe so store/refill selection cannot
  // reach a load's retry/miss response.
  assign load_miss_wb_hold = WriteBack
      && ((dirty_any && (probe_valid_i ? probe_dirty_request
          : (wb_global_request || load_victim_request)))
          || (wb_busy && (L2Inclusive || probe_valid_i || wb_global_request || !mshr_eligible))
          || target_dirty_request || (target_request && wb_busy)
      || wb_state != WB_IDLE || writeback_error
          || (update_dirty && l1d_update) || (L2Release && load_victim_request));
  `RAPT_SVA_IMPLY(clock, reset, L1D_LOAD_HOLD_EQUIVALENT, l1d_state == LD_A,
                  load_miss_wb_hold == wb_hold)
  // Idle/ready must depend only on registered writeback state and dirty data.
  // wb_hold also contains the current drain request; feeding it into these
  // outputs creates request -> hold -> ready/idle -> request loops across the
  // bus, frontend cancellation, and retirement fence logic.
  // Posted write-through stores have left the SQ before their B response;
  // ordering points that drain the SQ must also wait for those responses.
  // Buffered writebacks retain wb_busy until every B has completed.
  assign writeback_idle = (!WriteBack || (!dirty_any && !wb_busy && wb_state == WB_IDLE
      && !writeback_error && !l1d_update)) && !l1d_bus.posted_busy;
  assign coherent_ready = !WriteBack || (((L2Inclusive || !TargetedCoherence) ? !dirty_any
      : coherent_request && !ptw_arvalid && !target_cbo && !probe_valid_i
          && !(|probe_dirty_way)) && !wb_busy && wb_state == WB_IDLE
      && !writeback_error && !l1d_update
      && l1d_state == IDLE && !ptw_busy && !lsu_bus_write_pending_q);
  // Once a store is offered to the bus, its response retains ownership even
  // if a pending cache update makes that address a hit before B returns.
  always_ff @(posedge clock) begin
    if (reset) lsu_bus_write_pending_q <= 1'b0;
    else if (lsu_l1d.wvalid && store_accept) lsu_bus_write_pending_q <= 1'b0;
    else if (l1d_bus.awvalid && !wb_valid) lsu_bus_write_pending_q <= 1'b1;
  end
  // PTW coherence also covers nonallocating partial store misses. Keep an
  // already offered store live until B; coherence waits for that owner above.
  // New SQ stores wait until the I-side request or D-side walk completes.
  assign lsu_bus_write_allowed = !WriteBack || lsu_bus_write_pending_q
      || (!coherent_request && !ptw_busy && !(TargetedCoherence && target_load && target_store && !L2Inclusive));
  // A maintenance request may arrive while this response is in flight.
  // The bus identifies its owner; invalidating a clean copy must not discard
  // the one-cycle SQ acknowledgement or turn it into a writeback response.
  assign lsu_bus_write_response = WriteBack && lsu_bus_write_pending_q
      && l1d_bus.wready && wb_state == WB_IDLE && !wb_busy;
  assign local_store = WriteBack && !lsu_bus_write_pending_q && cacheable_w && !lsu_l1d.wzero
      && (hit_w || (!L2Inclusive && store_allocate && !wb_store_victim));
  assign local_store_ready = lsu_l1d.wvalid && !store_rsp_valid_q && local_store
      && l1d_state == IDLE && wb_state == WB_IDLE
      && !writeback_error && !l1d_update && !ptw_busy
      && !coherent_request && !fence_clear_busy && !mshr_busy && !wb_busy;
  assign probe_release_valid_o = wb_probe_mode && wb_valid;
  assign probe_release_addr_o = wb_addr;
  assign probe_release_data_o = wb_data;
  assign release_valid_o = wb_state == WB_RELEASE_SEND;
  assign release_addr_o = release_line_addr_q | (XLEN'(release_word_q) << L1dOffsetBits);
  assign release_data_o = release_line_q[release_word_q*XLEN+:XLEN];
  assign release_has_data_o = |release_mask_q;
  assign release_mask_o = release_mask_q[release_word_q];
  assign release_last_o = !release_has_data_o || &release_word_q;
  rapt_l1d_writeback #(
      .Xlen(XLEN),
      .Entries(2),
      .Pipelined(!L2Inclusive),
      .LineWords(L1D_LINE_SIZE)
  ) writeback (
      .clock(clock),
      .reset(reset),
      .capture_valid(WriteBack && wb_state == WB_CAPTURE && !wb_release_mode),
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
      .write_accept(wb_probe_mode ? probe_release_ready_i : l1d_bus.waccept),
      .write_ready(wb_probe_mode ? probe_release_ready_i : l1d_bus.wready),
      .write_error(!wb_probe_mode && l1d_bus.werr),
      .read_addr(l1d_addr),
      .miss_addr(mshr_req_addr),
      .read_match(wb_read_match),
      .miss_match(wb_miss_match)
  );
  always_ff @(posedge clock) begin
    if (reset) begin
      wb_state <= WB_IDLE;
      wb_targeted <= 0;
      wb_probe_mode <= 1'b0;
      wb_release_mode <= 1'b0;
      wb_set <= '0;
      wb_way <= '0;
      release_line_q <= '0;
      release_mask_q <= '0;
      release_line_addr_q <= '0;
      release_word_q <= '0;
    end else if (WriteBack) begin
      case (wb_state)
        WB_IDLE:
        if (wb_start) begin
          wb_probe_mode <= probe_dirty_request;
          wb_release_mode <= L2Release && !probe_dirty_request
              && !wb_global_dirty && (wb_victim_request || wb_store_victim || wb_fill_victim);
          wb_targeted <= probe_dirty_request || !wb_global_dirty;
          wb_set <= wb_global_dirty ? '0 : wb_probe_set;
          wb_way <= wb_global_dirty ? '0 : wb_probe_way;
          wb_state <= wb_global_dirty ? WB_SCAN : WB_READ;
        end
        WB_SCAN: begin
          if (!dirty_any) wb_state <= WB_IDLE;
          else if (DirtySkip) begin
            wb_set <= first_dirty_set;
            wb_way <= first_dirty_way;
            wb_state <= WB_READ;
          end else if (wb_dirty_any) wb_state <= WB_READ;
          else if (wb_way == L1dWayW'(L1D_N_WAYS - 1)) begin
            wb_way <= '0;
            wb_set <= wb_set + 1'b1;
            if (&wb_set) wb_state <= WB_IDLE;
          end else wb_way <= wb_way + 1'b1;
        end
        WB_READ: wb_state <= WB_CAPTURE;
        WB_CAPTURE:
        if (wb_release_mode) begin
          release_line_q <= wb_line_data;
          release_mask_q <= wb_dirty;
          release_line_addr_q <= XLEN'({wb_tag, wb_set, {L1dLineOffset{1'b0}}});
          release_word_q <= '0;
          wb_state <= WB_RELEASE_SEND;
        end else if (wb_capture_ready)
          // The queue now owns the dirty data. Inclusive/Probe transfers
          // keep the array owner until their existing response protocol ends.
          wb_state <= (L2Inclusive || wb_probe_mode) ? WB_WAIT : WB_CLEAN;
        WB_WAIT: if (!wb_busy && !writeback_error) wb_state <= WB_CLEAN;
        WB_CLEAN: begin
          wb_state <= wb_release_mode ? WB_RELEASE_CLEAR : wb_targeted ? WB_IDLE : WB_SCAN;
          wb_probe_mode <= 1'b0;
        end
        WB_RELEASE_SEND:
        if (release_valid_o && release_ready_i) begin
          if (release_last_o) wb_state <= WB_RELEASE_ACK;
          else release_word_q <= release_word_q + 1'b1;
        end
        WB_RELEASE_ACK: if (release_ack_i) wb_state <= WB_CLEAN;
        WB_RELEASE_CLEAR: begin
          wb_release_mode <= 1'b0;
          wb_state <= WB_IDLE;
        end
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
    WriteBack && coherent_ready |-> !wb_busy && wb_state == WB_IDLE
      && l1d_state == IDLE && !ptw_busy);
  assert property (@(posedge clock) disable iff (reset)
    WriteBack && writeback_error |-> wb_busy && !wb_valid && !writeback_idle
      && !coherent_ready);
  assert property (@(posedge clock) disable iff (reset)
    WriteBack && local_store_ready |-> !l1d_bus.wvalid);
  assert property (@(posedge clock) disable iff (reset) WriteBack && $past(
      wb_state == WB_IDLE
  ) && wb_state != WB_IDLE |-> $past(
      l1d_bus.idle || (!L2Inclusive && !lsu_bus_write_pending_q)
  ));
`endif

  // Report quiescence from registered activity.  wb_hold includes the
  // current coherent request, while coherent IO-fetch authorization itself
  // depends on this idle indication; using wb_hold here closes that request
  // loop.  Dirty resident lines remain idle until a registered writeback
  // operation actually starts.
  assign lsu_l1d.idle = !mshr_busy && !mshr_fill_valid && l1d_state == IDLE && !ptw_busy && !l1d_update
      && !fence_clear_busy && !lsu_l1d.rvalid && !lsu_l1d.rvalid_b
      && !lsu_l1d.wvalid && !exu_l1d.valid && !wb_busy && wb_state == WB_IDLE
      && !writeback_error;

  // An LR owns the A port only after older MSHR bus traffic has drained.
  // No MSHR allocation can occur while that atomic owner is active, so its
  // hit response need not re-evaluate the table's busy reduction.
  logic load_admit;
  assign load_admit = lsu_l1d.rvalid && (!lsu_l1d.atomic_lock || !mshr_busy);
  `RAPT_SVA_IMPLY(clock, reset, L1D_ATOMIC_ADMISSION_DRAINED, l1d_state == LD_A && l1d_atomic_lock,
                  !mshr_busy)
  logic load_speculate;
  assign load_speculate = (l1d_state == IDLE && lsu_l1d.rvalid
      && !cmu_bcast.flush_pipe && !fence_clear_busy && !wb_hold && !local_store_ready);

`ifdef RAPT_LSU_HUM
  // Hit-under-miss B channel arm (full logic further below): in LD_D the
  // SRAM read port is idle, steer it to the B request's set this cycle and
  // tag-compare next cycle.  Declared here so the sram_raddr mux can see it.
  logic b_arm_ok;
  logic b_armed;
  logic [L1D_LEN-1:0] b_idx_in;
  // Shared with the tag-array probe port; declare before its instance.
  logic [L1dTagW-1:0] b_tag;
  logic [L1D_LEN-1:0] b_idx;
  logic [L1D_LINE_LEN-1:0] b_off;
  logic [L1D_N_WAYS-1:0] b_way_hit;
`endif

  // Speculative SRAM read: when IDLE with a pending load, drive the *incoming*
  // virtual index directly instead of waiting for l1d_addr to be registered.
  // Safe because L1D_LEN+L1D_LINE_LEN+L1dOffsetBits < 12 (page offset), so
  // virt_idx == phys_idx (VIPT constraint satisfied). PTW paths are also safe:
  // l1d_addr holds the virtual address during PTW, whose index equals the
  // final physical index.
  logic [L1D_LEN-1:0] sram_raddr;
  logic [L1D_LINE_LEN-1:0] sram_rword;
  logic [L1D_LEN-1:0] sram_expected_idx;
  logic sram_read_authorized_r;
  logic load_read_early;
  logic [L1D_N_WAYS-1:0] load_way_data_ready;
  assign load_read_early = l1d_state == IDLE && lsu_l1d.rvalid;
`ifdef RAPT_LSU_HUM
  logic b_read_early;
  // Choose an address before store/victim arbitration. A blocked read is
  // harmless: the original arbitration still controls response ownership.
  assign b_read_early = lsu_l1d.rvalid_b
      && (l1d_state == LD_D || (l1d_state == LD_A
          && cacheable_r && !load_perm_denied_q
          && |load_way_hit && !(|(load_way_hit & ~load_way_data_ready)))
          || (l1d_state == IDLE && !load_read_early && !b_armed));
  assign sram_raddr = WriteBack && wb_state != WB_IDLE ? wb_set
      : load_read_early
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits]
      : b_read_early ? b_idx_in : addr_idx;
  assign sram_expected_idx = WriteBack && wb_state != WB_IDLE ? wb_set : load_speculate
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits]
      : b_arm_ok ? b_idx_in : addr_idx;
`else
  assign sram_raddr = WriteBack && wb_state != WB_IDLE ? wb_set : load_read_early
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits]
      : addr_idx;
  assign sram_expected_idx = WriteBack && wb_state != WB_IDLE ? wb_set : load_speculate
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits]
      : addr_idx;
`endif
`ifdef RAPT_LSU_HUM
  assign sram_rword = WriteBack && wb_state != WB_IDLE ? addr_offset : load_read_early
      ? lsu_l1d.raddr[L1dOffsetBits+:L1D_LINE_LEN]
      : b_read_early ? lsu_l1d.raddr_b[L1dOffsetBits+:L1D_LINE_LEN] : addr_offset;
`else
  assign sram_rword = WriteBack && wb_state != WB_IDLE ? addr_offset : load_read_early
      ? lsu_l1d.raddr[L1dOffsetBits+:L1D_LINE_LEN] : addr_offset;
`endif
  // Only the capture phases need a whole victim line. Later WB phases read
  // the held load's chunk across all ways, preserving its same-set resume cycle.
  logic sram_read_line;
  assign sram_read_line = WriteBack && (wb_state == WB_READ || wb_state == WB_CAPTURE);
  // Late arbitration reaches only tracking flops, never the SRAM address.
  // Record that the actual address matched the originally authorized index.
  always_ff @(posedge clock) begin
    sram_read_authorized_r <= sram_raddr == sram_expected_idx;
  end

  // Data-array ownership includes SRAM geometry and read-valid tracking.
  wire [DataBanks-1:0] sram_bank_valid;
  logic [L1D_LEN-1:0] sram_read_idx_r;
  logic [L1D_LINE_LEN-1:0] sram_read_word_r;
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
      .read_word(sram_rword),
      .read_line(sram_read_line),
      .read_way(wb_way),
      .write_valid(l1d_update && l1d_valid_u),
      .write_blocked(wb_blocked),
      .write_addr(l1d_idx),
      .write_word(l1d_off),
      .write_way(l1d_way),
      .write_data(l1d_data_u),
      .write_strobe(l1d_strobe_u),
      .write_line(line_update),
      .write_mask(line_update_mask),
      .write_line_data(line_update_data),
      .read_index(sram_read_idx_r),
      .read_word_index(sram_read_word_r),
      .read_bank_valid(sram_bank_valid),
      .read_data(data_bank_rdata),
      .read_line_valid(),
      .read_line_data(wb_line_data)
  );

  assign mmu_en = (exu_l1d.mmu_en && exu_l1d.valid) || (lsu_l1d.rvalid && lsu_l1d.rcontext.mmu_en);
  assign ptw_request_context = store_tlb_miss ? exu_l1d.mem_context : lsu_l1d.rcontext;

  // The load/store lookup arrays are replicas (two combinational read ports),
  // so every successful data walk warms both of them.  Besides avoiding a
  // second walk for pages used by both loads and stores, this keeps their
  // replacement state/content coherent.
  logic [1:0] ptw_result_pbmt;
  logic [1:0] ptw_result_level;
  logic [1:0] dtlb_pbmt;
  logic [1:0] dstlb_pbmt;
  // Verdict bits describe a complete 4 KiB physical portion. A zero uniform
  // bit keeps unusual PMP/PMA boundaries on the registered checker path.
  localparam int VUniform = 0, VRead = 1, VWrite = 2, VMapped = 3, VWritable = 4,
      VCacheable = 5, VDevice = 6, VAtomic = 7, VWidth32 = 8, VRefill = 9;
  logic [9:0] fill_verdict, dtlb_verdict, dstlb_verdict, store_verdict;
  logic [XLEN-1:0] verdict_page;
  logic verdict_uniform, verdict_pma_uniform, verdict_read_fault, verdict_write_fault;
  logic pmp_flush;
  assign pmp_flush = pmp_update.addr_we || |pmp_update.cfg_we;
  assign verdict_page = XLEN'({ptw_result_ptag, 12'b0});
  if (`RAPT_PMP_GRANULARITY_LOG2 >= 12) begin : g_uniform_page
    assign verdict_uniform = 1'b1;
  end else begin : g_uniform_fine
    rapt_pmp_window_uniform #(
        .XLEN(XLEN),
        .Words(1023),
        .AlignedWindow(1'b1)
    ) u_page_uniform (
        .addr(verdict_page),
        .state(pmp_state),
        .uniform_o(verdict_uniform)
    );
  end
  rapt_pmp_permissions #(
      .XLEN(XLEN)
  ) u_page_permissions (
      .addr(verdict_page),
      .size_m1(4'd3),
      .priv(`RAPT_PRIV_S),
      .op_r(1'b1),
      .op_w(1'b0),
      .op_x(1'b0),
      .pmp_raw_addr(pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r(pmp_state.pmp_cfg_r),
      .pmp_cfg_w(pmp_state.pmp_cfg_w),
      .pmp_cfg_x(pmp_state.pmp_cfg_x),
      .pmp_cfg_l(pmp_state.pmp_cfg_l),
      .pmp_mode_off(pmp_state.pmp_mode_off),
      .pmp_mode_tor(pmp_state.pmp_mode_tor),
      .pmp_mode_na4(pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault(),
      .fault_lo_o(),
      .fault_read_o(verdict_read_fault),
      .fault_write_o(verdict_write_fault)
  );
  always_comb begin
    verdict_pma_uniform = 1'b1;
    // Only a non-page-aligned PMA endpoint can split this aligned page.
    // Constant aligned endpoints disappear instead of building range adders.
    for (int r = 0; r < rapt_pkg::PmaRegionCount; r++) begin
      if (rapt_pkg::PmaRegions[r].enabled
          && ((rapt_pkg::PmaRegions[r].base_addr[11:0] != 0
               && rapt_pkg::PmaRegions[r].base_addr[63:12] == 52'(verdict_page[31:12]))
              || (rapt_pkg::PmaRegions[r].end_addr[11:0] != 0
                  && rapt_pkg::PmaRegions[r].end_addr[63:12] == 52'(verdict_page[31:12]))))
        verdict_pma_uniform = 1'b0;
    end
    fill_verdict = '0;
    fill_verdict[VUniform] = verdict_uniform && verdict_pma_uniform;
    fill_verdict[VRead] = !verdict_read_fault;
    fill_verdict[VWrite] = !verdict_write_fault;
    fill_verdict[VMapped] = rapt_pkg::addr_mapped(verdict_page);
    fill_verdict[VWritable] = rapt_pkg::addr_writable(verdict_page);
    fill_verdict[VCacheable] = rapt_pkg::addr_cacheable(verdict_page);
    fill_verdict[VDevice] = rapt_pkg::addr_device(verdict_page);
    fill_verdict[VAtomic] = rapt_pkg::addr_atomic_capable(verdict_page, 4'd3);
    fill_verdict[VWidth32] = !rapt_pkg::addr_device_width_capable(verdict_page, 4'd0);
    fill_verdict[VRefill] = L1dLineOffset <= 12 && GuardOffset <= 12 &&
        refill_ram(verdict_page, verdict_page | XLEN'(4095));
  end
  logic cached_load_check, cached_load_denied;
  logic [12:0] cached_first, cached_last;
  logic [3:0] cached_size, cached_orig_size;
  assign cached_size = lsu_l1d.rcheck_valid ? lsu_l1d.rcheck_size_m1
      : ((4'd1 << lsu_l1d.ralu[1:0]) - 4'd1);
  assign cached_orig_size = lsu_l1d.rcheck_valid ? lsu_l1d.rorig_size_m1 : cached_size;
  assign cached_first = {1'b0, lsu_l1d.raddr[11:0]}
      + (lsu_l1d.rcheck_valid ? 13'(lsu_l1d.rcheck_offset) : 13'd0);
  assign cached_last = cached_first + 13'(cached_size);
  assign cached_load_check = dtlb_verdict[VUniform]
      && cached_last < 13'd4096 && cached_size <= 7 && !pmp_flush;
  assign cached_load_denied = !dtlb_verdict[VRead] || !dtlb_verdict[VMapped]
      || (dtlb_verdict[VWidth32] && (cached_orig_size != 3 || cached_first[1:0] != 0))
      || (lsu_l1d.rmisaligned && (dtlb_verdict[VDevice] || dtlb_pbmt == 2'b10))
      || (lsu_l1d.atomic_lock && (!dtlb_verdict[VAtomic]
          || (lsu_l1d.ralu[1:0] == 2'b11 ? (XLEN != 64 || lsu_l1d.raddr[2:0] != 0)
              : lsu_l1d.raddr[1:0] != 0)));
  logic dtlb_fill, dstlb_fill;
  assign dtlb_fill  = (l1d_state == PTWAIT) && ptw_done;
  assign dstlb_fill = (l1d_state == PTWAIT) && ptw_done;

  if (`RAPT_DTLB_POLICY < 0 || `RAPT_DTLB_POLICY > 2
      || `RAPT_DSTLB_POLICY < 0 || `RAPT_DSTLB_POLICY > 2) begin : g_invalid_dtlb_policy
    initial $fatal(1, "RAPT_DTLB_POLICY and RAPT_DSTLB_POLICY must be 0, 1 or 2");
  end
  rapt_data_tlb #(
      .XLEN(XLEN),
      .WAYS(`RAPT_DTLB_WAYS),
      .ENTRIES(`RAPT_DTLB_ENTRIES),
      .TlbLru(`RAPT_DTLB_POLICY == 1),
      .TlbPlru(`RAPT_DTLB_POLICY == 2)
  ) u_dtlb (
      .clock(clock),
      .reset(reset),
      .flush((`RAPT_SFENCE_SELECTIVE == 0 && cmu_bcast.fence_time) || pmp_flush),
      .sfence_valid(cmu_bcast.sfence_valid),
      .sfence_vpn(cmu_bcast.sfence_vpn),
      .sfence_asid(cmu_bcast.sfence_asid),
      .sfence_all_vpn(cmu_bcast.sfence_all_vpn),
      .sfence_all_asid(cmu_bcast.sfence_all_asid),
      .lookup_vtag(lsu_l1d.raddr[XLEN-1:12]),
      .lookup_valid(l1d_state == IDLE && load_admit && lsu_l1d.rcontext.mmu_en
          && !(exu_l1d.mmu_en && exu_l1d.valid) && !mis_align_load
          && !cmu_bcast.flush_pipe && !fence_clear_busy && !wb_hold && !local_store_ready
          && !(WriteBack && coherent_write)
          && (!lsu_l1d.atomic_lock || !exu_l1d.reservation_blocked)),
      .lookup_asid(lsu_l1d.rcontext.asid),
      .hit(tlb_hit),
      .ptag(dtlb_ptag),
      .pte_flags(dtlb_pte),
      .pbmt(dtlb_pbmt),
      .verdict(dtlb_verdict),
      .fill_verdict(fill_verdict),
      .fill_valid(dtlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(ptw_context_q.asid),
      .fill_pbmt(ptw_result_pbmt),
      .fill_level(ptw_result_level),
      .fill_pte(ptw_result_pte)
  );

  rapt_data_tlb #(
      .XLEN(XLEN),
      .WAYS(`RAPT_DTLB_WAYS),
      .ENTRIES(`RAPT_DTLB_ENTRIES),
      .TlbLru(`RAPT_DSTLB_POLICY == 1),
      .TlbPlru(`RAPT_DSTLB_POLICY == 2)
  ) u_dstlb (
      .clock(clock),
      .reset(reset),
      .flush((`RAPT_SFENCE_SELECTIVE == 0 && cmu_bcast.fence_time) || pmp_flush),
      .sfence_valid(cmu_bcast.sfence_valid),
      .sfence_vpn(cmu_bcast.sfence_vpn),
      .sfence_asid(cmu_bcast.sfence_asid),
      .sfence_all_vpn(cmu_bcast.sfence_all_vpn),
      .sfence_all_asid(cmu_bcast.sfence_all_asid),
      .lookup_vtag(exu_l1d.vaddr[XLEN-1:12]),
      .lookup_valid(store_check_capture && !cmu_bcast.flush_pipe),
      .lookup_asid(exu_l1d.mem_context.asid),
      .hit(stlb_hit),
      .ptag(dstlb_ptag),
      .pte_flags(dstlb_pte),
      .pbmt(dstlb_pbmt),
      .verdict(dstlb_verdict),
      .fill_verdict(fill_verdict),
      .fill_valid(dstlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(ptw_context_q.asid),
      .fill_pbmt(ptw_result_pbmt),
      .fill_level(ptw_result_level),
      .fill_pte(ptw_result_pte)
  );

  // Shared PTW: serves both load and store TLB misses
  // A captured response owns this descriptor even if a concurrent fill or
  // invalidation removes its TLB entry before the requester consumes ready.
  assign store_tlb_miss = exu_l1d.mmu_en && exu_l1d.valid && !store_check_valid
      && !stlb_hit && !mis_align_store;
  assign ptw_vaddr = store_tlb_miss ? exu_l1d.vaddr : lsu_l1d.raddr;

  logic ptw_read_error;
  logic ptw_read_accepted;
  assign ptw_read_error = l1d_bus.ptw_rvalid && l1d_bus.ptw_rerr;
  assign load_tlb_miss = lsu_l1d.rvalid && !tlb_hit && !mis_align_load
                       && !(exu_l1d.mmu_en && exu_l1d.valid);
  assign ptw_req = (l1d_state == IDLE) && !wb_hold && !local_store_ready
      && !(WriteBack && coherent_write)
      && !(WriteBack && (lsu_l1d.wvalid || lsu_bus_write_pending_q))
      && (store_tlb_miss || (lsu_l1d.rcontext.mmu_en && load_tlb_miss))
      && !cmu_bcast.flush_pipe
      && !ptw_busy
      && (store_tlb_miss || load_tlb_miss);

  rapt_cached_ptw #(
      .XLEN(XLEN),
      .Enable(L2Tlb)
  ) u_dptw (
      .asid(ptw_request_context.asid),
      .l2_req_o(l2tlb_req_o),
      .l2_ready_i(l2tlb_ready_i),
      .l2_rsp_i(l2tlb_rsp_i),
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
      .bus_arready(ptw_read_accepted),
      .bus_rvalid(l1d_bus.ptw_rvalid),
      .bus_rdata(l1d_bus.rdata),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptw_result_ptag),
      .result_vtag(ptw_result_vtag),
      .result_pte(ptw_result_pte),
      .result_pbmt(ptw_result_pbmt),
      .result_level(ptw_result_level),
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

  // The B response follows a completed A hit, an idle cycle, or a miss
  // wait. It never overlaps LD_A. Writeback inspection borrows the store
  // lookup while its registered state holds off stores/refills.
  assign tag_inspect_source = wb_state != WB_IDLE ? 2'd1
      : (probe_dirty_request || target_dirty_request) ? 2'd2
      : (wb_store_lookup || wb_fill_probe) ? 2'd1 : 2'd0;
`ifdef RAPT_LSU_HUM
  `RAPT_SVA_IMPLY(clock, reset, L1D_SHARED_TAG_PHASES, b_armed, l1d_state != LD_A)
  assign tag_load_read_set = b_armed ? b_idx : addr_idx;
`else
  assign tag_load_read_set = addr_idx;
`endif
  assign tag_inspect_set = wb_state != WB_IDLE ? wb_set
      : (probe_dirty_request || target_dirty_request) ? line_clear_set
      : (wb_store_lookup || wb_fill_probe) ? tag_store_idx : tag_load_read_set;

  rapt_l1d_tags #(
      .L1D_LEN(L1D_LEN),
      .L1D_LINE_LEN(L1D_LINE_LEN),
      .L1D_SIZE(L1D_SIZE),
      .L1D_LINE_SIZE(L1D_LINE_SIZE),
      .L1D_N_WAYS(L1D_N_WAYS),
      .L1dTagW(L1dTagW),
      .WriteBack(WriteBack),
      .DirtySkip(DirtySkip),
      .SharedReadPorts(1'b1)
  ) u_tags (
      .update_dirty(update_dirty),
      .inspect_set(tag_inspect_set),
      .inspect_read(wb_state != WB_IDLE),
      .inspect_source(tag_inspect_source),
      .inspect_way(wb_state == WB_IDLE ? wb_probe_way : wb_way),
      .clean_valid(WriteBack && wb_state == WB_CLEAN),
      .clean_mask('1),
      .inspect_tag(wb_tag),
      .inspect_valid(wb_valid_words),
      .inspect_dirty(wb_dirty),
      .inspect_dirty_any(wb_dirty_any),
      .dirty_any(dirty_any),
      .first_dirty_set(first_dirty_set),
      .first_dirty_way(first_dirty_way),
      .update_blocked(wb_blocked),
      .clock(clock),
      .reset(reset),
      .fence_time(cmu_bcast.fence_time),
      .clear_set(fence_clear_set),
      .clear_enable(!wb_hold),
      .clear_line_valid(line_clearing),
      .clear_line_idx(line_clear_set),
      .clear_line_tag(line_clear_tag),
      .clear_line_dirty_way(probe_dirty_way),
      .addr_idx(addr_idx),
      .addr_offset(addr_offset),
      .addr_tag(addr_tag),
      .waddr_idx(tag_store_idx),
      .waddr_offset(waddr_offset),
      .waddr_tag(tag_store_tag),
`ifdef RAPT_LSU_HUM
      .probe_read(b_armed),
      .probe_idx(b_idx),
      .probe_offset(b_off),
      .probe_tag(b_tag),
      .probe_way_hit(b_way_hit),
`else
      .probe_read(1'b0),
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
      .load_victim_tag(load_victim_tag),
      .load_victim_valid(load_victim_valid),
      .load_victim_dirty(load_victim_dirty),
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
      && !mshr_invalidate_line && !lsu_l1d.wvalid && !l1d_update
      && !wb_hold && !probe_valid_i && !line_clearing
      && (l1d_state == IDLE || l1d_state == LD_CHECK);
  assign mshr_fill_idx = mshr_fill_addr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign mshr_fill_tag = mshr_fill_addr[PADDR_BITS-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  // A valid store always owns this probe; a refill is consumed only when
  // mshr_fill_ready holds, which already excludes stores. Choose the inactive
  // refill probe early so flush/arbitration cannot traverse the tag lookup.
  // Stores retain priority; refills may use the probe in both store policies.
  assign tag_probe_fill = (`RAPT_L1D_MSHRS > 0) && !lsu_l1d.wvalid;
  assign tag_store_idx = tag_probe_fill ? mshr_fill_idx : waddr_idx;
  assign tag_store_tag = tag_probe_fill ? mshr_fill_tag : waddr_tag;

  // A tag miss needs no SRAM data. On a hit, only the matching way and word's
  // bank must have read this set; unrelated banks can read during a write.
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_load_bank_ready
    wire bank_ready = sram_bank_valid[(way / DataChunks) * DataChunks
        + ((way + int'(addr_offset) / (64 / XLEN)) % DataChunks)];
    assign load_way_data_ready[way] = bank_ready && sram_read_idx_r == addr_idx
        && int'(sram_read_word_r) / (64 / XLEN) == int'(addr_offset) / (64 / XLEN)
        && sram_read_authorized_r;
  end
  logic l1d_sram_busy;
  assign l1d_sram_busy = l1d_update || |(load_way_hit & ~load_way_data_ready);
  assign tag_hit = (l1d_state == LD_A) && !load_perm_denied_q
    && cacheable_r
    && !l1d_sram_busy
    && |load_way_hit;
  // data_hit: SRAM data ready in LD_A. IDLE (or PTW-wait) speculated the
  // array read while permission was captured into load_perm_denied_q.
  // In LD_A with a tag hit, store/refill victim requests are inactive:
  // stores probe in IDLE, refills in IDLE/LD_CHECK, and load victims miss tags.
  // Specialize this hold for hits so those tag/replacement cones do not enter
  // the same-cycle load response. Other users retain the complete wb_hold.
  logic load_hit_wb_hold;
  assign load_hit_wb_hold = WriteBack
      && ((dirty_any && (probe_valid_i ? probe_dirty_request : wb_global_request))
          || (wb_busy && (L2Inclusive || probe_valid_i || wb_global_request
              || !mshr_eligible))
          || target_dirty_request || (target_request && wb_busy)
      || wb_state != WB_IDLE || writeback_error
          || (update_dirty && l1d_update));
  assign data_hit = (l1d_state == LD_A) && tag_hit && !load_hit_wb_hold;
  // Rotate the small hit vector into physical bank order. Data stays in
  // place: one AND/OR selection across the chunks, independent of way count.
  logic [XLEN-1:0] bank_data_masked[DataBanks];
  for (genvar bank = 0; bank < DataBanks; bank++) begin : g_load_bank_select
    logic selected;
    always_comb begin
      selected = 1'b0;
      for (
          int way = (bank / DataChunks) * DataChunks;
          way < L1D_N_WAYS && way < (bank / DataChunks + 1) * DataChunks;
          way++
      ) begin
        selected |= load_way_hit[way]
            && (way + int'(addr_offset) / (64 / XLEN)) % DataChunks == bank % DataChunks;
      end
    end
    assign bank_data_masked[bank] = selected
        ? XLEN'(data_bank_rdata[bank] >> ((int'(addr_offset) % (64 / XLEN)) * XLEN)) : '0;
  end
  always_comb begin
    l1d_data = '0;
    for (int bank = 0; bank < DataBanks; bank++) l1d_data |= bank_data_masked[bank];
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
  logic [XLEN-1:0] b_addr_r;
  logic b_sram_ready;
  assign b_idx_in
      = lsu_l1d.raddr_b[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign b_arm_ok = (l1d_state == LD_D || (l1d_state == LD_A && data_hit)
                  || (l1d_state == IDLE && !load_speculate && !b_armed))
                  && lsu_l1d.rvalid_b && !lsu_l1d.rcontext_b.mmu_en
                  && !l1d_update && !fence_clear_busy && !wb_hold
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
  logic [XLEN-1:0] b_paddr;
  assign b_paddr = rapt_pkg::canonical_paddr(b_addr_r);
  assign b_tag = b_paddr[PADDR_BITS-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign b_idx = b_addr_r[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign b_off = b_addr_r[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];
  logic [L1D_N_WAYS-1:0] b_way_data_ready;
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_b_bank_ready
    wire bank_ready = sram_bank_valid[(way / DataChunks) * DataChunks
        + ((way + int'(b_off) / (64 / XLEN)) % DataChunks)];
    assign b_way_data_ready[way] = bank_ready && sram_read_idx_r == b_idx
        && int'(sram_read_word_r) / (64 / XLEN) == int'(b_off) / (64 / XLEN)
        && sram_read_authorized_r;
  end
  // The arm edge already checked writeback arbitration. A new victim
  // request cannot change the data read on that edge: array writes and
  // invalidation are checked below, and bank ownership is registered.
  // Do not let this cycle's refill/tag/victim lookup cancel that response.
  assign b_sram_ready = |(b_way_hit & b_way_data_ready);

  logic [XLEN-1:0] b_bank_data_masked[DataBanks];
  logic [XLEN-1:0] b_data;
  for (genvar bank = 0; bank < DataBanks; bank++) begin : g_b_bank_select
    logic selected;
    always_comb begin
      selected = 1'b0;
      for (
          int way = (bank / DataChunks) * DataChunks;
          way < L1D_N_WAYS && way < (bank / DataChunks + 1) * DataChunks;
          way++
      ) begin
        selected |= b_way_hit[way] && b_way_data_ready[way]
            && (way + int'(b_off) / (64 / XLEN)) % DataChunks == bank % DataChunks;
      end
    end
    assign b_bank_data_masked[bank] = selected
        ? XLEN'(data_bank_rdata[bank] >> ((int'(b_off) % (64 / XLEN)) * XLEN)) : '0;
  end
  always_comb begin
    b_data = '0;
    for (int bank = 0; bank < DataBanks; bank++) b_data |= b_bank_data_masked[bank];
  end

  // Complete only while the held request is unchanged and no write raced us.
  assign lsu_l1d.rready_b = b_armed
                         && lsu_l1d.rvalid_b
                         && (lsu_l1d.raddr_b == b_addr_r)
                         && |b_way_hit
                         && b_sram_ready && !l1d_update && !fence_clear_busy
                         && !cmu_bcast.flush_pipe;
  assign lsu_l1d.rretry_b = b_armed
                         && lsu_l1d.rvalid_b
                         && (lsu_l1d.raddr_b == b_addr_r)
                         && (!(|b_way_hit) || !b_sram_ready || l1d_update
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
  // Only bare requests bypass the registered physical address. In particular,
  // neither TLB hit/PA nor PTW completion can select an input of the PMP cone.
  logic idle_load_perm;
  assign idle_load_perm = (l1d_state == IDLE) && !lsu_l1d.rcontext.mmu_en;
  // PTE policy in IDLE uses the incoming context even for translated loads.
  assign perm_load_context = (l1d_state == IDLE) ? lsu_l1d.rcontext : load_context_q;
  assign perm_base_addr = idle_load_perm ? rapt_pkg::canonical_paddr(lsu_l1d.raddr) : l1d_addr;
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
  assign perm_pbmt = idle_load_perm ? 2'b00 : l1d_pbmt;
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

  // The shared read checker selects the walker's registered PTE address
  // while ptw_arvalid is held. Capture that owned permission result before
  // bus admission so the live load-address comparator cannot feed AR and
  // return through bus idle into cache control. Ordinary load checks keep
  // their existing capture path; only a new implicit PTE read waits here.
  logic ptw_permission_valid_q, ptw_permission_fault_q;
  assign ptw_read_accepted = ptw_arvalid && legacy_arvalid && legacy_rready;
  always_ff @(posedge clock) begin
    if (reset) begin
      ptw_permission_valid_q <= 1'b0;
      ptw_permission_fault_q <= 1'b0;
    end else if (cmu_bcast.flush_pipe || cmu_bcast.fence_time || ptw_read_error
        || !ptw_arvalid) begin
      ptw_permission_valid_q <= 1'b0;
    end else if (!ptw_permission_valid_q) begin
      ptw_permission_valid_q <= 1'b1;
      ptw_permission_fault_q <= pmp_ptw_fault;
    end else if (ptw_read_accepted) begin
      // The walker leaves its request state on this same acceptance edge.
      // Each subsequent level needs a fresh result for its own PTE address.
      ptw_permission_valid_q <= 1'b0;
    end
  end

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
  // A true tag miss needs no SRAM data. A hit whose bank did not read still
  // waits in LD_A; keep that bank-ready path off the miss AR request.
  // Only an issuable/owned nonlocal store precedes a line refill. A new
  // store blocked by PTW coherence must not hold this load in LD_A: the
  // coherence requester itself needs L1D to reach IDLE. Already offered
  // writes keep lsu_bus_write_allowed set until B, preserving their order.
  assign legacy_arvalid = !wb_hold && !(WriteBack && wb_read_match) && (ptw_arvalid
    ? (ptw_permission_valid_q && !ptw_permission_fault_q)
    : (l1d_state == LD_A) && !load_perm_denied_q
      && (!cacheable_r || !(|load_way_hit)) && !mshr_eligible && !mshr_busy
      && !l1d_update
      && (cacheable_r || lsu_l1d.ordered)
      && !cmu_bcast.flush_pipe
      && (!line_read_request || !lsu_l1d.wvalid || local_store || !lsu_bus_write_allowed));
  assign mshr_select = !legacy_arvalid && mshr_req_valid
      && !(WriteBack && (wb_miss_match || writeback_error));
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
  assign l1d_bus.wzero = !wb_valid && lsu_l1d.wzero;
  // An inclusive L2 must record the D client before a buffered refill can
  // become resident/dirty in L1. No-allocate would bypass that directory mark.
  assign l1d_bus.noallocate = mshr_select ? !L2Inclusive : ptw_arvalid || !refill_safe;
  assign l1d_bus.arlen = (mshr_select || (!ptw_arvalid && line_read_request)) ? 8'(L1D_LINE_SIZE-1) : 8'd0;
  // A line install (the last legacy refill beat or an MSHR fill) becomes
  // visible to hit_w one cycle after its update is queued. A store to that
  // line offered meanwhile would complete as write-through by its B response,
  // which cannot update the now-resident copy under wb_hold. Delay only a new
  // offer to that line; an offered store keeps its request and response.
  logic store_line_installing;
  assign store_line_installing = l1d_update && l1d_valid_u && !lsu_bus_write_pending_q
      && l1d_idx == waddr_idx && l1d_tag_u == waddr_tag;
  // An all-issued writeback still owns its B responses. Do not let a younger
  // SQ request claim response ownership while wb_busy remains asserted.
  assign l1d_bus.awvalid = (wb_valid && !wb_probe_mode) || (!wb_hold
      && lsu_l1d.wvalid && !store_rsp_valid_q && lsu_bus_write_allowed && !local_store && !mshr_busy
      && !wb_busy && !store_line_installing
      && !(l1d_state == LD_D && refill_line));
  assign l1d_bus.awaddr = wb_valid ? wb_addr : lsu_l1d.waddr;
  assign l1d_bus.wpbmt = wb_valid ? 2'b00 : lsu_l1d.wpbmt;
  assign l1d_bus.wstrb = wb_valid ? FullStoreWstrb : lsu_l1d.walu;
  assign l1d_bus.wvalid = (wb_valid && !wb_probe_mode) || (!wb_hold
      && lsu_l1d.wvalid && !store_rsp_valid_q && lsu_bus_write_allowed && !local_store && !mshr_busy
      && !wb_busy && !store_line_installing
      && !(l1d_state == LD_D && refill_line));
  assign l1d_bus.wdata = wb_valid ? wb_data : lsu_l1d.wdata;

  // A dirty update can become visible after a write-through request has
  // already entered the bus.  A newly requested drain must stop subsequent
  // requests, but the matching response still belongs to the SQ request.
  // Let that response retire while WB is idle. A pending SQ bus write
  // excludes victim capture, and queued writebacks cannot acknowledge SQ.
  assign store_accept = !store_rsp_valid_q && (local_store_ready || lsu_bus_write_response || ((!wb_hold
      || (!wb_valid && wb_state == WB_IDLE && !l1d_bus.idle && l1d_bus.wready))
      && !local_store
      && !wb_busy && l1d_bus.wready && !mshr_busy && !fence_clear_busy
      && !(l1d_state == LD_D && refill_line)));
  assign store_error = store_accept && !local_store_ready && l1d_bus.werr;
  // The cache consumes a committed store on store_accept. Keep its SQ owner
  // until the registered acknowledgement; suppress a duplicate bus offer
  // while that acknowledgement is pending. Local updates already occupy
  // this cycle, so the two-cycle write-back hit throughput is unchanged.
  always_ff @(posedge clock) begin
    if (reset) store_rsp_valid_q <= 1'b0;
    else store_rsp_valid_q <= lsu_l1d.wvalid && store_accept;
    store_rsp_error_q <= store_error;
  end
  assign lsu_l1d.wready = store_rsp_valid_q;
  assign lsu_l1d.werr = store_rsp_error_q && store_rsp_valid_q;
  `RAPT_SVA_NEXT(clock, reset, L1D_STORE_RESPONSE_REGISTERED, lsu_l1d.wvalid && store_accept,
                 lsu_l1d.wready)
  `RAPT_SVA_IMPLY(clock, reset, L1D_STORE_RESPONSE_NO_REACCEPT, store_rsp_valid_q,
                  !store_accept && !local_store_ready && (!l1d_bus.awvalid || wb_valid))
  // The bus may acknowledge this store at AXI acceptance only when every
  // non-bus condition of the synchronous `wready` above already holds, and
  // its hit/miss decision is final: a completed refill may still be
  // installing its tag (`l1d_update`/`line_update`). A synchronous store
  // would observe that line by its B response; a posted one must not miss
  // it and leave the stale refill resident.
  assign l1d_bus.wmore = lsu_l1d.wmore;
  assign l1d_bus.wbuffered = WriteBack && wb_valid && !wb_probe_mode;
  assign l1d_bus.wpost = l1d_bus.wbuffered || (!WriteBack && cacheable_w && !lsu_l1d.wzero && !wb_hold
      && !local_store && !mshr_busy
      && !l1d_update && !line_update
      && !fence_clear_busy && !(l1d_state == LD_D && refill_line));

  // Translation completes only after the captured PA has passed PMP/PMA.
  // The requester holds its descriptor until ready, including split stores.
  assign exu_l1d.paddr = store_paddr;
  assign exu_l1d.pbmt = store_pbmt;
  assign store_access_fault = (store_verdict[VUniform] && !pmp_flush
      ? ((exu_l1d.cmo_mgmt ? !(store_verdict[VRead] || store_verdict[VWrite])
                           : !store_verdict[VWrite])
          || (exu_l1d.cmo_mgmt ? !store_verdict[VMapped] : !store_verdict[VWritable]))
      : (pmp_store_fault_mmu || store_unmapped_fault_mmu)) || store_io_size_fault;
  assign exu_l1d.trap = ((l1d_state == TRAP) && rec_store
      && (rec_addr == exu_l1d.vaddr)) || (store_check_valid && (store_page_fault || store_access_fault));
  assign exu_l1d.cause = store_check_valid
      ? (store_page_fault ? XLEN'(`RAPT_CAUSE_STORE_PAGE_FAULT)
                          : XLEN'(`RAPT_CAUSE_STORE_ACC_FAULT)) : cause;
  assign exu_l1d.reservation = reservation;
  assign exu_l1d.reservation_size_m1 = reservation_size_m1;
  assign exu_l1d.reservation_valid = reservation_valid && !external_hits_reservation;
  assign exu_l1d.reservation_blocked = external_write_pending_i || external_write_valid_i;
  always_ff @(posedge clock) begin
    if (reset || l1d_state == IDLE) lr_interfered <= 1'b0;
    else if (external_hits_lr) lr_interfered <= 1'b1;
  end
  // Ready denotes a completed translation, not permission to issue a store.
  // Its structural state is independent of the TLB and permission result;
  // trap accompanies a denied response before the LSU can issue any write.
  assign exu_l1d.ready = exu_l1d.valid && !cmu_bcast.flush_pipe
      && (store_check_valid || ((l1d_state == TRAP) && rec_store
          && rec_addr == exu_l1d.vaddr));

  // Keep the translation response independent of the load FSM: an older
  // store may translate while a younger load owns the cache or refill bus.
  // The held request supplies size/context until this response is consumed.
  assign store_check_capture = exu_l1d.mmu_en && exu_l1d.valid && !store_check_valid
      && !mis_align_store && (stlb_hit || (stlb_mmu && ptw_done));
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      store_check_valid <= 1'b0;
    end else begin
      store_check_valid <= store_check_capture;
    end
  end
  // Only occupied responses expose this payload. Free-running payload
  // flops avoid distributing the capture enable across the PA bus.
  always_ff @(posedge clock) begin
    store_paddr <= stlb_hit ? XLEN'({dstlb_ptag, exu_l1d.vaddr[11:0]})
        : XLEN'({ptw_result_ptag, exu_l1d.vaddr[11:0]});
    store_verdict <= stlb_hit && !pmp_flush ? dstlb_verdict : 10'b0;
    store_pbmt <= stlb_hit ? dstlb_pbmt : ptw_result_pbmt;
    store_page_fault <= stlb_hit ? pf_store_tlb : pf_store_ptw;
  end

  // Fill acceptance requires !l1d_update. Preload the wide line payload
  // while this update buffer is vacant; the original line_update control
  // publishes it. Pending updates retain their payload until consumption.
  always_ff @(posedge clock) begin
    if (!l1d_update) begin
      line_update_mask <= mshr_fill_mask;
      line_update_data <= mshr_fill_data;
    end
    // LD_MSHR_RSP publishes the preceding LD_A lookup. Capture independently
    // of victim arbitration; a held response retains its payload.
    if (l1d_state == LD_A) mshr_rsp_data_q <= mshr_data;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      l1d_state <= IDLE;
      load_context_q <= '0;
      ptw_context_q <= '0;
      load_perm_denied_q <= 1'b0;
      load_page_fault_q <= 1'b0;
      rec_store <= 1'b0;
      fence_clear_set <= '0;
      l1d_update <= 0;
      update_dirty <= 0;
      line_update <= 0;
      l1d_inv_all_ways <= 0;
      d_replace_bit <= '0;
      ld_fill_way_r <= '0;
      l1d_way <= '0;

      reservation <= 'h0;
      reservation_valid <= 1'b0;
      reservation_size_m1 <= 4'd3;
      l1d_atomic_lock <= 1'b0;
      load_killed <= 1'b0;
      refill_safe <= 0;
      refill_line <= 0;
      refill_word <= '0;
      demand_done <= 0;

    end else begin
      if (ptw_req) ptw_context_q <= ptw_request_context;
      fence_clear_set <= WriteBack && wb_hold ? fence_clear_set | maintenance_set : maintenance_set;
      if (probe_valid_i && l1d_state == LD_D && addr_idx == probe_set && addr_tag == probe_tag)
        load_killed <= 1'b1;
      if (external_hits_reservation) begin
        reservation_valid <= 1'b0;
      end
      unique case (l1d_state)
        IDLE: begin
          load_killed <= 1'b0;
          load_perm_denied_q <= 1'b0;
          load_page_fault_q <= 1'b0;
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
                end else if (!stlb_hit && ptw_req) begin
                  // PTW request issued via ptw_req
                  l1d_addr  <= exu_l1d.vaddr;
                  rec_addr  <= exu_l1d.vaddr;
                  stlb_mmu  <= 'b1;
                  l1d_state <= PTWAIT;
                end
              end else if (load_admit) begin
                rec_store <= 1'b0;
                load_context_q <= lsu_l1d.rcontext;
                // Load TLB lookup
                if (mis_align_load) begin
                  cause <= 'h4;  // load address mis-aligned
                  rec_addr <= lsu_l1d.raddr;
                  l1d_state <= TRAP;
                end else if (tlb_hit) begin
                  // Capture the physical request before its permission stage.
                  l1d_addr <= XLEN'({dtlb_ptag, lsu_l1d.raddr[11:0]});
                  l1d_pbmt <= dtlb_pbmt;
                  load_page_fault_q <= pf_load_tlb;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu <= lsu_l1d.ralu;
                  l1d_orig_misaligned <= lsu_l1d.rmisaligned;
                  l1d_check_valid <= lsu_l1d.rcheck_valid;
                  l1d_check_offset <= lsu_l1d.rcheck_offset;
                  l1d_check_size_m1 <= lsu_l1d.rcheck_size_m1;
                  l1d_orig_size_m1 <= lsu_l1d.rorig_size_m1;
                  l1d_atomic_lock <= lsu_l1d.atomic_lock;
                  if (cached_load_check) begin
                    load_perm_denied_q <= cached_load_denied;
                    refill_safe <= dtlb_verdict[VCacheable] && dtlb_pbmt == 2'b00
                        && dtlb_verdict[VRefill];
                    if (pf_load_tlb || cached_load_denied) begin
                      cause <= pf_load_tlb ? XLEN'(`RAPT_CAUSE_LOAD_PAGE_FAULT)
                          : XLEN'(`RAPT_CAUSE_LOAD_ACC_FAULT);
                      l1d_state <= TRAP;
                    end else l1d_state <= LD_A;
                  end else l1d_state <= LD_CHECK;
                end else if (ptw_req) begin
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
              if (load_admit) begin
                rec_store <= 1'b0;
                load_context_q <= lsu_l1d.rcontext;
                l1d_addr <= rapt_pkg::canonical_paddr(lsu_l1d.raddr);
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
          end else if (ptw_arvalid && ptw_permission_valid_q && ptw_permission_fault_q) begin
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
              // The independent response stage captures PA and PTE policy.
              l1d_state <= IDLE;
            end else begin
              // Register the walk result before the physical permission check.
              l1d_addr <= XLEN'({ptw_result_ptag, l1d_addr[11:0]});
              l1d_pbmt <= ptw_result_pbmt;
              load_page_fault_q <= pf_load_ptw;
              l1d_state <= LD_CHECK;
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
          end else if (load_page_fault_q) begin
            cause <= `RAPT_CAUSE_LOAD_PAGE_FAULT;
            l1d_state <= TRAP;
          end else if (ptw_arvalid) begin
            // A PTW request can survive until trap recovery after a denied
            // PTE read. It owns the shared read checker, so keep this load
            // captured without consuming the PTW's permission result.
            l1d_state <= LD_CHECK;
          end else if (capture_load_denied) begin
            load_perm_denied_q <= 1'b1;
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
          end else if (!cacheable_r && !lsu_l1d.ordered) begin
            // Retry releases the LSU owner on this edge, even while dirty
            // writeback is pending. Do not retain a request whose ordered
            // permission can next belong to a different load.
            l1d_addr <= '0;
            l1d_state <= IDLE;
          end else if (load_miss_wb_hold) begin
            l1d_state <= LD_A;
          end else if (mshr_complete) begin
            if (mshr_error) begin
              cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
              l1d_state <= TRAP;
            end else begin
              l1d_state <= LD_MSHR_RSP;
            end
          end else if (mshr_release || mshr_store_yield) begin
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
      if ((|fence_clear_set && !wb_hold) || line_clearing) begin
        // Never replay a pending fill into a set just invalidated. Updates
        // to other sets remain pending while the tag clear port is occupied.
        if (fence_clear_set[l1d_idx]
            || (line_clearing && l1d_idx == line_clear_set
                && l1d_tag_u == line_clear_tag)) begin
          l1d_update <= 0;
          update_dirty <= 0;
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
      if (|fence_clear_set || line_clearing || probe_valid_i
          || (wb_hold && !local_store_ready)) begin
        // Clear takes priority over every new tag/data update below.
      end else if (zero_complete) begin
        // The ZERO descriptor updates memory as a burst. Its complete block
        // is invalidated through maintenance_set, including on a failed B.
      end else if (lsu_l1d.wvalid && store_accept && store_error) begin
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
      end else if (lsu_l1d.wvalid && store_accept && cacheable_w && !lsu_l1d.wzero) begin
        update_dirty <= local_store_ready;
        // Only full aligned stores allocate. Hits use the SRAM byte enables;
        // split stores already carry aligned addresses and lane-shifted data.
        if (hit_w || store_allocate) begin
          l1d_update <= 1'b1;
          l1d_data_u <= lsu_l1d.wdata << (lsu_l1d.waddr[L1dOffsetBits-1:0] * 8);
          l1d_strobe_u <= lsu_l1d.walu[XLEN/8-1:0] << lsu_l1d.waddr[L1dOffsetBits-1:0];
          l1d_valid_u <= 1'b1;
          l1d_tag_u <= waddr_tag;
          l1d_idx <= waddr_idx;
          l1d_off <= waddr_offset;
          l1d_way <= hit_w ? store_hit_way : store_fill_way;
          if (!hit_w && L1D_N_WAYS == 2) d_replace_bit[waddr_idx] <= ~d_replace_bit[waddr_idx];
        end
      end else if (mshr_fill_ready) begin
        l1d_update <= 1'b1;
        line_update <= 1'b1;
        l1d_valid_u <= 1'b1;
        l1d_tag_u <= mshr_fill_tag;
        l1d_idx <= mshr_fill_idx;
        l1d_off <= '0;
        l1d_way <= store_fill_way;
        if (L1D_N_WAYS == 2) d_replace_bit[mshr_fill_idx] <= ~d_replace_bit[mshr_fill_idx];
      end else if (l1d_state == LD_D) begin
        if ((refill_line || lsu_l1d.rvalid) && legacy_rvalid && !l1d_bus.rerr
            && !load_killed && !cmu_bcast.flush_pipe) begin
          // The BOOM-layout L2 does not allocate a scalar read marked
          // noallocate. Keep the L1 inclusive by installing only full-line
          // refills; the scalar response still completes the demand.
          if (cacheable_r && (!L2Release || refill_line)) begin
            l1d_update <= 1'b1;
            l1d_data_u <= l1d_bus.rdata;
            l1d_strobe_u <= '1;
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
                  !store_accept && !l1d_bus.awvalid)
`ifdef RAPT_SVA_ACTIVE
  // A store completed by its bus response must update a resident copy; the
  // update chain drops it under wb_hold, leaving a stale clean word.
  logic sva_bus_store_hit;
  assign sva_bus_store_hit = WriteBack && lsu_l1d.wvalid && store_accept && !local_store_ready
      && !store_error && cacheable_w && !lsu_l1d.wzero && hit_w;
  `RAPT_SVA_IMPLY(clock, reset, L1D_BUS_STORE_HIT_UPDATES, sva_bus_store_hit, !wb_hold)
`endif
  `RAPT_SVA_IMPLY(clock, reset, L1D_MMIO_READ_REQUIRES_ORDER,
                  legacy_arvalid && !l1d_bus.ar_ptw && !cacheable_r, lsu_l1d.ordered)
  `RAPT_SVA_IMPLY(clock, reset, L1D_RETRY_NO_COMPLETION_OR_READ, lsu_l1d.rretry,
                  !lsu_l1d.rready && !lsu_l1d.trap && !(legacy_arvalid && !l1d_bus.ar_ptw))
  `RAPT_SVA_NEXT(clock, reset, L1D_RETRY_RELEASES_OWNER, lsu_l1d.rretry, l1d_state == IDLE)
  `RAPT_SVA_IMPLY(clock, reset, L1D_FLUSH_BLOCKS_NEW_READ, cmu_bcast.flush_pipe, !l1d_bus.arvalid)
  `RAPT_SVA_IMPLY(clock, reset, L1D_PTW_PERMISSION_BLOCKS_READ, legacy_arvalid && ptw_arvalid,
                  ptw_permission_valid_q && !ptw_permission_fault_q)
  `RAPT_SVA_NEXT(
      clock, reset, L1D_PTW_PERMISSION_DENIED,
      l1d_state == PTWAIT && ptw_arvalid && ptw_permission_valid_q && ptw_permission_fault_q && !cmu_bcast.flush_pipe,
      l1d_state == TRAP)
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
  `RAPT_SVA_NEXT(
      clock, reset, L1D_PERMISSION_STAGE_WAITS_FOR_PTW,
      l1d_state == LD_CHECK && ptw_arvalid && !load_page_fault_q && !cmu_bcast.flush_pipe,
      l1d_state == LD_CHECK)
  logic l1d_lr_hit_establishes_reservation;
  // A dirty-cache drain holds LD_A before the LR hit can be accepted.
  assign l1d_lr_hit_establishes_reservation = data_hit
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
