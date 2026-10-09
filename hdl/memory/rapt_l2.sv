/**
 * rapt_l2 -- L2 unified cache (AXI4-slave on CPU side, AXI4-master on
 * memory side).
 *
 * Sits between `rapt_bus` and the external `io_master` AXI port:
 *
 *   L1I -+
 *        +-> rapt_bus --> rapt_l2 --> io_master (external)
 *   L1D -+
 *
 * Both ports are AXI4. When `RAPT_L2_EN` is not defined the module
 * collapses to a transparent passthrough, so adding the instantiation
 * is a no-op until L2 is opted in.
 *
 * --- Design summary (RAPT_L2_EN) ---
 *
 *   * Set-associative; a 16-bit LFSR selects a victim on a miss, as in
 *     SiFive's inclusive-cache directory used by Medium BOOM.
 *   * Line size  = `RAPT_CACHE_LINE_BYTES bytes, expressed internally as
 *     1 << L2_LINE_LEN XLEN-wide words.
 *   * Sets       = 1 << L2_LEN. The default-l2 preset selects 1024 sets,
 *     eight ways and 64-byte lines for 512 KiB in either XLEN mode.
 *   * The 512 KiB preset uses BOOM's 8-way SRAM directory and four-bank data
 *     layout. Cacheable reads and writes use the one-port directory lookup;
 *     in-flight requests track invalidation without a flop tag mirror.
 *     Smaller presets retain the original flop tags and word banks.
 *   * Cacheable region: external main memory windows only. MMIO/ROM/SRAM
 *     traffic is forwarded straight through with no cache lookup.
 *   * Read policy : on miss allocate a full-line refill from memory
 *     (INCR burst of LineSize beats). The first matching beat is
 *     forwarded to the requester as it streams in (early-restart);
 *     remaining beats are returned from the line buffer once the fill
 *     completes.
 *   * BOOM-layout bufferable single-beat stores update hits locally. On a
 *     miss, a dirty victim is written back, the line is refilled, the store
 *     mask is merged, and the new line is installed dirty. Non-bufferable
 *     stores forward to memory. Bufferable cacheable INCR, FIXED, and valid
 *     WRAP bursts allocate locally, including narrow and crossing-line
 *     transfers. Each line segment commits before the next directory lookup.
 *     A complete all-byte line skips the outer read, while shorter or masked
 *     writes merge with the resident or fetched line. Other shapes forward.
 *   * BOOM's 40-cycle sizing gives five ordinary RV64 or three RV32 clean
 *     read misses that may refill concurrently. Dirty or
 *     client-owned victims still use the blocking write-back/probe path.
 *     Same-line scalar reads join each live MSHR through BOOM's shared
 *     21-list/33-entry RV64 or 15-list/35-entry RV32 secondary buffer.
 *     The independent outer AXI IDs
 *     preserve the original upstream IDs.
 *   * AXI ID is preserved end-to-end so multi-master upstream traffic
 *     (L1I/L1D) keeps its rid/bid routing.
 *
 * Known TODO / future work:
 *   * Multi-client probe arbitration beyond the single L1D owner.
 *   * Report CBO write-back errors to software instead of latching busy.
 *   * Multiple independently outstanding full-line writes.
 *   * General nested BC/C transitions and independent allocated Put execution.
 */
`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

`ifndef RAPT_L2_LEN
`define RAPT_L2_LEN 7
`endif
`ifndef RAPT_L2_LINE_LEN
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`endif
`ifndef RAPT_L2_N_WAYS
`define RAPT_L2_N_WAYS 1
`endif

/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module rapt_l2 #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter int L2_LEN = `RAPT_L2_LEN,
    parameter int L2_LINE_LEN = `RAPT_L2_LINE_LEN,
    parameter int L2_N_WAYS = `RAPT_L2_N_WAYS,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS
) (
    input clock,
    input reset,
    input logic cbo_inval_i = 1'b0,
    input logic [XLEN-1:6] cbo_block_i = '0,
    output logic probe_valid_o,
    output logic [XLEN-1:0] probe_addr_o,
    input logic probe_ready_i = 1'b1,
    input logic probe_release_valid_i = 1'b0,
    input logic [XLEN-1:0] probe_release_addr_i = '0,
    input logic [XLEN-1:0] probe_release_data_i = '0,
    output logic probe_release_ready_o,
    input logic release_valid_i = 1'b0,
    input logic [XLEN-1:0] release_addr_i = '0,
    input logic [XLEN-1:0] release_data_i = '0,
    input logic release_has_data_i = 1'b0,
    input logic release_mask_i = 1'b0,
    input logic release_last_i = 1'b0,
    output logic release_ready_o,
    output logic release_ack_o,
    input logic l1d_writeback_pending_i = 1'b0,
    output logic probe_window_o,

    // CPU / rapt_bus side
    axi4_if.slave  axi_s,
    // External memory side
    axi4_if.master axi_m
);

  // Explicit cache enable; otherwise the AXI interface is a passthrough.
`ifdef RAPT_L2_EN
  `define RAPT_L2_ACTIVE
`endif

`ifndef RAPT_L2_ACTIVE
  // =====================================================================
  // Pure passthrough (L2 disabled). Kept lint-clean.
  // =====================================================================
  assign probe_valid_o         = 1'b0;
  assign probe_addr_o          = '0;
  assign probe_release_ready_o = 1'b0;
  assign release_ready_o       = 1'b0;
  assign release_ack_o         = 1'b0;
  assign probe_window_o        = 1'b0;
  assign axi_m.arvalid         = axi_s.arvalid;
  assign axi_m.araddr          = axi_s.araddr;
  assign axi_m.arid            = axi_s.arid;
  assign axi_m.arlen           = axi_s.arlen;
  assign axi_m.arsize          = axi_s.arsize;
  assign axi_m.arburst         = axi_s.arburst;
  assign axi_m.arcache         = axi_s.arcache;
  assign axi_s.arready         = axi_m.arready;

  assign axi_s.rvalid          = axi_m.rvalid;
  assign axi_s.rdata           = axi_m.rdata;
  assign axi_s.rid             = axi_m.rid;
  assign axi_s.rresp           = axi_m.rresp;
  assign axi_s.rlast           = axi_m.rlast;
  assign axi_m.rready          = axi_s.rready;

  assign axi_m.awvalid         = axi_s.awvalid;
  assign axi_m.awaddr          = axi_s.awaddr;
  assign axi_m.awid            = axi_s.awid;
  assign axi_m.awlen           = axi_s.awlen;
  assign axi_m.awsize          = axi_s.awsize;
  assign axi_m.awburst         = axi_s.awburst;
  assign axi_m.awcache         = axi_s.awcache;
  assign axi_s.awready         = axi_m.awready;

  assign axi_m.wvalid          = axi_s.wvalid;
  assign axi_m.wdata           = axi_s.wdata;
  assign axi_m.wstrb           = axi_s.wstrb;
  assign axi_m.wlast           = axi_s.wlast;
  assign axi_s.wready          = axi_m.wready;

  assign axi_s.bvalid          = axi_m.bvalid;
  assign axi_s.bid             = axi_m.bid;
  assign axi_s.bresp           = axi_m.bresp;
  assign axi_m.bready          = axi_s.bready;
`else
  // =====================================================================
  // Active L2 cache implementation.
  // =====================================================================
  localparam int LineSize = 1 << L2_LINE_LEN;  // words per line
  localparam int LineBits = LineSize * XLEN;
  localparam int NSets = 1 << L2_LEN;
  localparam int WayBits = (L2_N_WAYS <= 1) ? 1 : $clog2(L2_N_WAYS);
  // Medium BOOM uses four 16384 x 64-bit logical data banks:
  // row={way[2:0],set[9:0],chunk[2]}, bank=chunk[1:0].
  localparam bit BoomBankedStore = L2_N_WAYS == 8 && L2_LEN == 10
                                && (LineSize * XLEN == 512) && (XLEN == 32 || XLEN == 64);
  if (L2_N_WAYS < 1 || L2_N_WAYS > 1024 || (L2_N_WAYS & (L2_N_WAYS - 1)) != 0) begin : g_invalid_ways
    $error("L2 ways must be a power of two between 1 and 1024");
  end
  localparam int WordBytes = XLEN / 8;
  localparam int OffsetBits = L2_LINE_LEN + $clog2(WordBytes);
  // A legal AXI WRAP has at most 16 beats, each no wider than this data bus.
  localparam int ReadWrapBits = $clog2(16 * WordBytes);
  localparam int IndexBits = L2_LEN;
  // BOOM's generated directory stores address bits [33:16] in each entry.
  // Raptor's RV64 physical-address datapath is wider, but the cacheable DDR
  // windows fit below bit 34; keep the default-l2 SRAM entry at BOOM's 22 bits.
  localparam int TagBits = BoomBankedStore ? 18 : PADDR_BITS - IndexBits - OffsetBits;
  if (PADDR_BITS > XLEN || PADDR_BITS <= IndexBits + OffsetBits) begin : g_invalid_paddr_width
    $error("L2 physical address width must fit its request and cache geometry");
  end
  localparam int ByteOffsetBits = $clog2(WordBytes);
  localparam int WordOffsetLsb = ByteOffsetBits;
  localparam int WordOffsetMsb = ByteOffsetBits + L2_LINE_LEN - 1;
  localparam int IndexLsb = OffsetBits;
  localparam int IndexMsb = OffsetBits + IndexBits - 1;
  localparam int TagLsb = OffsetBits + IndexBits;

  // A forwarded AXI4 burst can contain 256 W beats. Keep resident-hit beats
  // until the real outer B before applying them to the cache.
  localparam int ForwardLogDepth = 256;
  localparam int ForwardLogAddrBits = TagLsb + TagBits;
  typedef struct packed {
    logic [ForwardLogAddrBits-1:0] addr;
    logic [WayBits-1:0] way;
    logic clients;
    logic [XLEN-1:0] data;
    logic [WordBytes-1:0] mask;
  } forward_log_entry_t;
  typedef enum logic [2:0] {
    F_IDLE,
    F_FETCH,
    F_PROBE,
    F_APPLY,
    F_DONE
  } forward_replay_state_t;
  forward_replay_state_t forward_replay_state;
  forward_log_entry_t forward_log_mem[ForwardLogDepth];
  forward_log_entry_t forward_log_wdata, forward_log_rdata;
  logic [8:0] forward_log_count;
  logic [7:0] forward_replay_index;
  // Cached-hit forwarding blocks new AR/AW until B, so an invalidated
  // client cannot reacquire this line between journal entries.
  logic forward_replay_probed_valid;
  logic [ForwardLogAddrBits-OffsetBits-1:0] forward_replay_probed_line;
  logic forward_replay_line_probed;
  logic forward_replay_probe_request;
  logic forward_replay_b_match;
  assign forward_replay_line_probed = forward_replay_probed_valid
      && forward_replay_probed_line == forward_log_rdata.addr[ForwardLogAddrBits-1:OffsetBits];

  typedef enum logic [1:0] {
    REL_IDLE,
    REL_LOOKUP,
    REL_DATA,
    REL_DIRECTORY
  } release_state_t;
  release_state_t release_state;
  logic release_head_valid, release_head_complete, release_head_pop, release_head_has_data;
  logic release_head_word_valid;
  logic release_buffer_busy;
  logic release_buffer_push_ready;
  logic [XLEN-1:0] release_head_addr, release_head_data;
  logic release_head_mask;
  logic [L2_LINE_LEN-1:0] release_word;
  logic [WayBits-1:0] release_way_q;
  logic [1:0] release_dir_state_q;
  logic release_dir_dirty_q;
  logic release_nested_q, release_nested_candidate;
  logic release_nested_retry;
  logic [2:0] release_nested_slot_q, release_nested_slot;
  logic release_lookup_candidate, release_lookup_fire, release_word_fire;
  logic release_forward_active_preempt, release_probe_preempt;
  logic release_dir_write_candidate, release_dir_write_fire;
  logic release_word_step;
  logic release_pending;
  // Reserve the directory from the first C beat, including a possible gap
  // before the last beat makes a complete Release visible at the buffer head.
  assign release_pending = (BoomBankedStore && release_valid_i)
      || release_buffer_busy || release_state != REL_IDLE;
  assign forward_replay_probe_request = forward_replay_state == F_PROBE && !release_pending;
  assign release_head_pop = release_dir_write_fire;
  assign release_ack_o = release_dir_write_fire;
  assign release_ready_o = BoomBankedStore && release_buffer_push_ready;
  rapt_l2_release_buffer #(
      .Xlen(XLEN),
      .LineBytes(LineSize * WordBytes)
  ) u_release_buffer (
      .clock,
      .reset,
      .push_valid(BoomBankedStore && release_valid_i),
      .push_ready(release_buffer_push_ready),
      .push_addr(release_addr_i),
      .push_data(release_data_i),
      .push_has_data(release_has_data_i),
      .push_mask(release_mask_i),
      .push_last(release_last_i),
      .busy_o(release_buffer_busy),
      .head_valid(release_head_valid),
      .head_complete(release_head_complete),
      .head_pop(release_head_pop),
      .head_addr(release_head_addr),
      .head_has_data(release_head_has_data),
      .head_word(release_word),
      .head_word_valid(release_head_word_valid),
      .head_data(release_head_data),
      .head_mask(release_head_mask)
  );

  // Queue CBO set masks while accepted AXI work drains. Blocking new
  // requests through the clear edge prevents an older fill from resurrecting
  // a line and makes the next demand observe the completed maintenance.
  localparam logic [11:0] CboIndexMask = 12'((NSets - 1) << OffsetBits) & 12'hfc0;
  logic [NSets-1:0] cbo_pending, cbo_mask;
  logic [NSets-1:0] cbo_pending_broad;
  logic [17:0] cbo_pending_tag[NSets];
  logic [XLEN-1:0] cbo_address;
  logic [IndexBits-1:0] cbo_request_set;
  logic [17:0] cbo_request_tag, cbo_active_tag;
  logic cbo_active_broad, cbo_active_requeue, cbo_match;
  logic cbo_probe_dirty;
  logic cbo_exact_invalidate;
  logic cbo_busy, cbo_apply;
  logic [IndexBits-1:0] cbo_clear_set, wipe_set;
  typedef enum logic [3:0] {
    C_IDLE,
    C_SCAN,
    C_SCAN_RESULT,
    C_PICK,
    C_PROBE,
    C_AW,
    C_READ,
    C_W,
    C_B,
    C_CLEAR,
    C_ERROR
  } cbo_state_t;
  cbo_state_t cbo_state;
  logic [IndexBits-1:0] cbo_active_set;
  logic [WayBits-1:0] cbo_way;
  logic [L2_LINE_LEN-1:0] cbo_word;
  logic [L2_N_WAYS*22-1:0] cbo_entries_q, dir_scan_entries;
  logic [21:0] cbo_entry;
  logic [17:0] cbo_tag;
  logic dir_scan_ready, dir_scan_result_valid;
  logic cbo_scan_valid;
  logic wipe_done;
  logic burst_active, burst_aw_pending, burst_input_started, burst_input_done, burst_w_done;
  logic burst_allocate, burst_all_full, burst_segment_ready;
  logic [L2_LINE_LEN-1:0] burst_fill_count;
  logic [XLEN-1:0] burst_line_buf[LineSize];
  logic [XLEN/8-1:0] burst_mask_buf[LineSize];
  logic [XLEN-1:0] burst_start, burst_addr, burst_pop_addr, burst_pop_next_addr;
  logic [ReadWrapBits-1:0] burst_wrap_mask;
  logic [ID_W-1:0] burst_id;
  logic [7:0] burst_len;
  logic [2:0] burst_size;
  logic [1:0] burst_kind;
  logic [3:0] burst_cache;
  logic burst_write_fire;
  logic burst_lookup_required, burst_lookup_pending, burst_lookup_ready;
  logic burst_lookup_hit, burst_forward_ready, burst_hit_update;
  logic forward_cache_pending, forward_log_push;
  logic forward_replay_request, forward_replay_commit;
  logic burst_direct_hit, burst_direct_hit_pop, burst_direct_commit;
  logic [WayBits-1:0] burst_lookup_way;
  logic [TagBits-1:0] burst_lookup_tag;
  logic [1:0] burst_lookup_state;
  logic burst_lookup_dirty, burst_lookup_clients;
  logic burst_alloc_needs_read, dir_burst_alloc_read_fire;
  logic [XLEN-1:0] burst_aw_last_addr, burst_aw_wrap_base, burst_aw_wrap_last;
  logic [XLEN-1:0] burst_aw_span;
  logic dir_burst_read_valid, dir_result_for_burst_q;
  assign cbo_address = rapt_pkg::canonical_addr({cbo_block_i, 6'b0});
  assign cbo_request_set = cbo_address[IndexMsb:IndexLsb];
  assign cbo_request_tag = 18'(cbo_address >> TagLsb);
  for (genvar s = 0; s < NSets; s++) begin : g_cbo_set
    assign cbo_mask[s] = cbo_inval_i
        && (BoomBankedStore ? cbo_request_set == IndexBits'(s)
                            : (12'(s << OffsetBits) & CboIndexMask)
                                == ({cbo_block_i[11:6], 6'b0} & CboIndexMask));
  end
  assign cbo_busy = cbo_inval_i || |cbo_pending;
  // A balanced priority tree keeps the 1024-set CBO clear path to log2(NSets)
  // mux levels. The previous procedural scan built a 1024-deep priority path.
  logic [  2*NSets-1:1] cbo_tree_has;
  logic [IndexBits-1:0] cbo_tree_idx [2*NSets];
  for (genvar leaf = 0; leaf < NSets; leaf++) begin : g_cbo_leaf
    assign cbo_tree_has[NSets+leaf] = cbo_pending[leaf] || cbo_mask[leaf];
    assign cbo_tree_idx[NSets+leaf] = IndexBits'(leaf);
  end
  for (genvar node = 1; node < NSets; node++) begin : g_cbo_node
    assign cbo_tree_has[node] = cbo_tree_has[2*node] || cbo_tree_has[2*node+1];
    assign cbo_tree_idx[node] = cbo_tree_has[2*node] ? cbo_tree_idx[2*node]
                                                       : cbo_tree_idx[2*node+1];
  end
  assign cbo_clear_set = cbo_tree_idx[1];
  assign cbo_entry = cbo_entries_q[int'(cbo_way)*22+:22];
  assign cbo_tag = cbo_entry[17:0];
  assign cbo_scan_valid = BoomBankedStore && cbo_state == C_SCAN;

  // ---------------------------------------------------------------------
  // Storage. BOOM geometry uses the SRAM directory as its only tag/valid
  // state. Small legacy configurations retain the flop directory.
  // ---------------------------------------------------------------------
  /* verilator lint_off UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */
  logic               line_valid  [L2_N_WAYS][   NSets];
  logic [TagBits-1:0] line_tag    [L2_N_WAYS][   NSets];
  logic [   XLEN-1:0] line_data_r [L2_N_WAYS][LineSize];
  logic [       15:0] victim_lfsr;
  logic [WayBits-1:0] victim_way_q, install_way;
  logic dir_ready, dir_read_ready, dir_result_valid, dir_result_hit;
  logic [WayBits-1:0] dir_result_way;
  logic [TagBits-1:0] dir_result_tag;
  logic [1:0] dir_result_state;
  logic dir_result_dirty;
  logic dir_result_clients;
  logic dir_read_valid, dir_write_valid, dir_write_ready, dir_clear_valid, dir_clear_ready;
  logic [IndexBits-1:0] dir_read_set, dir_write_set, dir_clear_set;
  logic [TagBits-1:0] dir_read_tag, dir_write_tag;
  logic [WayBits-1:0] dir_write_way;
  logic [1:0] dir_write_state;
  logic dir_write_clients, dir_write_dirty;
  // Used by the directory instance below; declare before its port binding
  // so synthesis does not create an implicit generate-local scalar net.
  logic dir_lookup_dirty;
  logic dir_client_mark, r_client_marked;
  logic ms_alloc_invalidate;
  logic ms_direct_complete;
  logic blocking_refill_invalidate;
  logic [XLEN-1:0] w_snoop_addr;
  logic dir_demand_read_valid, dir_aw_needs_read, dir_aw_read_fire, dir_result_for_aw_q;
  logic dir_error_lookup_request, dir_result_for_error_q;
  logic [IndexBits-1:0] write_error_idx;
  logic [  TagBits-1:0] write_error_tag;
  logic dir_error_inv, dir_error_pending, dir_error_hit;
  logic [WayBits-1:0] dir_error_way;
  logic cbo_candidate;
  logic w_hit_update;
  logic forward_scalar_pending, forward_scalar_head;
  logic forward_scalar_probe_request, forward_scalar_probe_done;
  logic forward_scalar_write_request, forward_scalar_commit;
  logic forward_scalar_release_preempt;
  logic [WayBits-1:0] error_lookup_way_q;
  logic probe_release_fire;
  logic cache_install_dirty;
  logic hit_probe_active, hit_probe_commit;

  if (BoomBankedStore) begin : g_boom_directory
    rapt_l2_directory #(
        .SetBits(IndexBits),
        .Ways(L2_N_WAYS),
        .TagBits(18),
        .ClientBits(1)
    ) u_directory (
        .clock,
        .reset,
        .ready(dir_ready),
        .read_valid(dir_read_valid),
        .read_ready(dir_read_ready),
        .read_set(dir_read_set),
        .read_tag(18'(dir_read_tag)),
        .result_valid(dir_result_valid),
        .result_hit(dir_result_hit),
        .result_way(dir_result_way),
        .result_tag(dir_result_tag),
        .result_clients(dir_result_clients),
        .result_state(dir_result_state),
        .result_dirty(dir_result_dirty),
        .scan_valid(cbo_scan_valid),
        .scan_ready(dir_scan_ready),
        .scan_set(cbo_active_set),
        .scan_result_valid(dir_scan_result_valid),
        .scan_entries(dir_scan_entries),
        .clear_valid(dir_clear_valid),
        .clear_ready(dir_clear_ready),
        .clear_set(dir_clear_set),
        .write_valid(dir_write_valid),
        .write_ready(dir_write_ready),
        .write_set(dir_write_set),
        .write_way(dir_write_way),
        .write_tag(18'(dir_write_tag)),
        .write_clients(dir_write_clients),
        .write_state(dir_write_state),
        .write_dirty(dir_write_dirty)
    );
    assign victim_lfsr = '0;
  end else begin : g_legacy_directory
    assign dir_ready = 1'b1;
    assign dir_read_ready = 1'b1;
    assign dir_result_valid = 1'b0;
    assign dir_result_hit = 1'b0;
    assign dir_result_way = '0;
    assign dir_result_tag = '0;
    assign dir_result_clients = 1'b0;
    assign dir_result_state = '0;
    assign dir_result_dirty = 1'b0;
    assign dir_scan_ready = 1'b0;
    assign dir_scan_result_valid = 1'b0;
    assign dir_scan_entries = '0;
    assign dir_write_ready = 1'b1;
    assign dir_clear_ready = 1'b1;
    // The original direct-mapped/small configurations keep their flop tags.
    always_ff @(posedge clock) begin
      if (reset) victim_lfsr <= 16'h0001;
      else if ((axi_s.arvalid && axi_s.arready && cacheable_line(
              axi_s.araddr
          ) && |axi_s.arcache[3:2]) || (axi_s.awvalid && axi_s.awready && cacheable_line(
              axi_s.awaddr
          ) && |axi_s.awcache[3:2]))
        victim_lfsr <= {
          victim_lfsr[14:0], victim_lfsr[15] ^ victim_lfsr[13] ^ victim_lfsr[12] ^ victim_lfsr[10]
        };
    end
  end
  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------
  // L2 is intentionally narrower than the L1 addr_cacheable() allowlist: keep
  // ROM/SRAM/flash single-beat through the LiteX fabric and reserve L2 line
  // fills for external main memory where Linux/app payloads execute.
  function automatic logic cacheable(input logic [XLEN-1:0] a);
    logic [XLEN-1:0] physical;
    physical = rapt_pkg::canonical_addr(a);
    return rapt_pkg::addr_upper_valid(
        a
    ) && (!BoomBankedStore || (64'(physical) >> (TagLsb + TagBits)) == '0) &&
        (rapt_pkg::addr_in_pmem(
        a
    ) || (rapt_pkg::PmemBytes < 32'h80000000 && physical >= XLEN'('ha0000000) &&
          physical < XLEN'('ha2000000)));
  endfunction

  function automatic logic cacheable_line(input logic [XLEN-1:0] a);
    return cacheable(a) && cacheable(a | XLEN'((1 << OffsetBits) - 1));
  endfunction

  function automatic logic same_line(input logic [XLEN-1:0] a, b);
    return (rapt_pkg::canonical_addr(a) >> OffsetBits) ==
        (rapt_pkg::canonical_addr(b) >> OffsetBits);
  endfunction

  function automatic logic [ReadWrapBits-1:0] read_wrap_mask(input logic [7:0] len,
                                                             input logic [2:0] size);
    return ((ReadWrapBits'(len) + ReadWrapBits'(1)) << size) - ReadWrapBits'(1);
  endfunction

  function automatic logic [XLEN-1:0] advance_read_addr(
      input logic [XLEN-1:0] addr, input logic [2:0] size, input logic [1:0] burst,
      input logic [ReadWrapBits-1:0] wrap_mask);
    logic [ReadWrapBits-1:0] wrap_next;
    wrap_next = addr[ReadWrapBits-1:0] + (ReadWrapBits'(1) << size);
    case (burst)
      2'b01: return addr + (XLEN'(1) << size);
      2'b10:
      return {
        addr[XLEN-1:ReadWrapBits], (addr[ReadWrapBits-1:0] & ~wrap_mask) | (wrap_next & wrap_mask)
      };
      default: return addr;
    endcase
  endfunction

  function automatic logic source_read_shape(input logic [XLEN-1:0] addr, input logic [7:0] len,
                                             input logic [2:0] size, input logic [1:0] burst);
    logic wrap_valid;
    wrap_valid = (len == 8'd1 || len == 8'd3 || len == 8'd7 || len == 8'd15)
        && ((int'(len) + 1) << int'(size)) <= (1 << OffsetBits)
        && (int'(addr[OffsetBits-1:0]) & ((1 << int'(size)) - 1)) == 0;
    return size <= 3'($clog2(
        WordBytes
    )) && (burst == 2'b00 || burst == 2'b01 || (burst == 2'b10 && wrap_valid)) &&
        (burst != 2'b01 ||
         int'(addr[OffsetBits-1:0]) + (int'(len) << int'(size)) < (1 << OffsetBits));
  endfunction

  // A no-allocate DDR read must still observe an existing L2 line. The
  // outer RAM may be stale while that line is dirty.
  logic ar_cache_lookup;
  assign ar_cache_lookup = cacheable_line(
      axi_s.araddr
  ) && (|axi_s.arcache[3:2] || (BoomBankedStore && axi_s.arcache[1:0] == 2'b11));

  function automatic logic [XLEN-1:0] merge_store_word(input logic [XLEN-1:0] old_data,
                                                       input logic [XLEN-1:0] new_data,
                                                       input logic [XLEN/8-1:0] byte_enable);
    logic [XLEN-1:0] merged;
    merged = old_data;
    for (int byte_idx = 0; byte_idx < XLEN / 8; byte_idx++) begin
      if (byte_enable[byte_idx]) merged[byte_idx*8+:8] = new_data[byte_idx*8+:8];
    end
    return merged;
  endfunction

  // =====================================================================
  // READ PATH
  // =====================================================================
  typedef enum logic [4:0] {
    R_IDLE,
    R_HIT,
    R_HIT_DATA,
    R_HIT_PROBE,
    R_HIT_PROBE_COMMIT,
    R_MISS_INVALIDATE,
    R_MISS_AR,
    R_MISS_R,
    R_STORE_MERGE_READ,
    R_STORE_MERGE_LATCH,
    R_STORE_MERGE_WRITE,
    R_INSTALL_WAIT,
    R_INSTALL_READ,
    R_MSHR_EARLY_INSTALL,
    R_ERROR,
    R_BYPASS_WAIT,
    R_BYPASS_AR,
    R_BYPASS_R,
    R_EVICT_AW,
    R_EVICT_PROBE,
    R_EVICT_READ,
    R_EVICT_W,
    R_EVICT_B,
    R_STORE_DONE,
    R_STORE_ERROR,
    R_BURST_HIT_READ,
    R_BURST_HIT_MERGE,
    R_BURST_PUT_WRITE,
    R_BURST_DONE,
    R_BURST_ERROR
  } state_r_t;

  state_r_t rs;
  logic [ID_W-1:0] r_id;
  logic [XLEN-1:0] r_addr;  // captured AR address (start of req)
  logic [7:0] r_len;  // remaining beats - 1 of upstream burst
  logic [2:0] r_size;
  logic [1:0] r_burst;
  logic [ReadWrapBits-1:0] r_wrap_mask;
  logic [3:0] r_cache;
  logic [L2_LINE_LEN-1:0] r_word;  // current word offset within line
  logic [XLEN-1:0] r_line_buf[LineSize];
  logic [L2_LINE_LEN-1:0] r_fill_cnt;  // next word slot to write on fill
  logic [L2_LINE_LEN-1:0] evict_word;
  logic [1:0] r_resp;  // sticky worst rresp during fill
  logic r_up_done;  // upstream burst fully delivered (early-restart latch)
  logic r_store_fill;
  logic [XLEN-1:0] r_store_merge_data;
  logic r_burst_fill;

  function automatic logic d_client_read_id(input logic [ID_W-1:0] id);
    return id == ID_W'(2) || (ID_W >= 4 && (id & ID_W'('hc)) == ID_W'('h8));
  endfunction

  // Hit detection on currently latched address (only meaningful while
  // rs == R_IDLE handshake or in R_HIT/R_MISS_*).
  logic [IndexBits-1:0] r_idx_q;
  logic [TagBits-1:0] r_tag_q;
  logic r_hit_q;
  logic [WayBits-1:0] r_hit_way;
  logic dir_lookup_hold_valid, dir_lookup_hold_hit;
  logic [WayBits-1:0] dir_lookup_hold_way;
  logic [TagBits-1:0] dir_lookup_hold_tag;
  logic [1:0] dir_lookup_hold_state;
  logic dir_lookup_hold_dirty, dir_lookup_hold_clients;
  logic dir_lookup_hit;
  logic [WayBits-1:0] dir_lookup_way;
  logic [TagBits-1:0] dir_lookup_tag;
  logic [1:0] dir_lookup_state;
  logic dir_lookup_clients;
  logic rs_rvalid, cache_install, any_write_in_flight;
  logic [XLEN-1:0] rs_rdata;
  logic rs_rlast;
  logic [1:0] rs_rresp;
  logic [ID_W-1:0] rs_rid;
  // The ordinary BOOM MSHR slots handle independent clean A-channel
  // refills. The Release handler occupies the reserved C scheduler slot
  // while its buffer head is live; BC remains unconnected.
  // InclusiveCacheParameters.out_mshrs = max(3, ceil(memCycles/blockBeats))
  // with memCycles=40, plus one BC and one C reservation. RV64 therefore
  // has 5+2 contexts and RV32 has 3+2 contexts for a 64-byte line.
  localparam int BoomNormalMshrs = (40 + LineSize - 1) / LineSize > 3
                                   ? (40 + LineSize - 1) / LineSize : 3;
  localparam int BoomMshrs = BoomNormalMshrs + 2;
  // InclusiveCacheParameters.secondary = max(mshrs, memCycles - mshrs).
  localparam int BoomSecondaryEntries = BoomMshrs > 40 - BoomMshrs ? BoomMshrs : 40 - BoomMshrs;
  if (BoomBankedStore && ID_W < $clog2(BoomMshrs)) begin : g_invalid_boom_id_width
    $error("BOOM L2 refill context IDs must fit the complete MSHR table");
  end
  localparam int SecondaryPayloadBits = XLEN + ID_W + 17;
  localparam int SecondaryLenLsb = ID_W + XLEN + 7;
  localparam int SecondaryBurstLsb = SecondaryLenLsb + 8;
  logic [BoomMshrs-1:0] ms_slot_valid, ms_slot_done;
  logic [1:0] ms_slot_resp[BoomMshrs];
  logic [BoomMshrs-1:0] ms_sched_valid, ms_secondary_schedule_onehot;
  logic [BoomMshrs-1:0] ms_secondary_schedule_stalled;
  logic [BoomMshrs-1:0] ms_critical_ready;
  logic [LineSize-1:0] ms_beat_valid[BoomMshrs];
  logic [IndexBits-1:0] ms_set[BoomNormalMshrs];
  logic [XLEN-1:0] ms_line_addr[BoomNormalMshrs];
  logic [ID_W-1:0] ms_id[BoomNormalMshrs];
  logic [7:0] ms_len[BoomNormalMshrs];
  logic [2:0] ms_size[BoomNormalMshrs];
  logic [1:0] ms_burst[BoomNormalMshrs];
  logic [L2_LINE_LEN-1:0] ms_word[BoomNormalMshrs];
  logic [BoomNormalMshrs-1:0] ms_early_sent;
  logic [BoomNormalMshrs-1:0] ms_early_good_accepted;
  logic ms_early_response_pending_q;
  logic [2:0] ms_early_response_slot_q;
  logic [BoomNormalMshrs-1:0] ms_installed, ms_primary_secondary;
  logic [BoomNormalMshrs-1:0] ms_late_response_pending;
  logic ms_late_response_active, ms_late_response_candidate, ms_late_response_issue;
  logic [2:0] ms_late_response_slot, ms_late_response_active_slot;
  logic ms_source_active, ms_source_start, ms_source_secondary_start;
  logic ms_source_read_pending, ms_source_data_valid;
  logic ms_source_read_request, ms_source_read_fire, ms_source_read_capture;
  logic ms_source_response_send, ms_source_issue_done;
  logic [2:0] ms_source_start_slot;
  logic [XLEN-1:0] ms_source_start_addr;
  logic [7:0] ms_source_start_len;
  logic [2:0] ms_source_start_size;
  logic [1:0] ms_source_start_burst;
  logic [ID_W-1:0] ms_source_start_id;
  logic boom_bank_read_result_valid;
  logic [XLEN-1:0] ms_source_addr, ms_source_data;
  logic [XLEN-1:0] ms_source_issue_addr, ms_source_fifo[3];
  logic [ID_W-1:0] ms_source_id;
  logic [7:0] ms_source_len, ms_source_issue_len;
  logic [2:0] ms_source_size;
  logic [1:0] ms_source_burst;
  logic [ReadWrapBits-1:0] ms_source_wrap_mask;
  logic [L2_LINE_LEN-1:0] ms_source_read_word;
  logic [1:0] ms_source_head, ms_source_tail, ms_source_count;
  logic [IndexBits-1:0] ms_source_set;
  logic [WayBits-1:0] ms_source_way;
  logic [2:0] ms_source_chunk;
  logic ms_source_primary_secondary;
  logic ms_busy, ms_done_any, ms_free, ms_ar_conflict, ms_retire_candidate;
  logic ms_failed_early_retry, ms_refill_retry;
  logic ms_active_refills;
  logic ms_id_conflict, ms_secondary_match, ms_secondary_accept, ms_secondary_send;
  logic ms_secondary_capture, ms_secondary_reload_needs_directory;
  logic ms_secondary_needs_ownership;
  // Same-tag secondaries reuse the MSHR metadata, including nested C updates.
  logic [BoomNormalMshrs-1:0] ms_meta_clients, ms_meta_dirty, ms_meta_valid;
  logic [TagBits-1:0] ms_meta_tag[BoomNormalMshrs];
  logic [TagBits-1:0] ms_replay_meta_tag;
  logic [1:0] ms_meta_state[BoomNormalMshrs];
  logic ms_replay_needs_directory, ms_replay_use_metadata;
  logic ms_replay_meta_clients, ms_replay_meta_dirty;
  logic [1:0] ms_replay_meta_state;
  logic [2:0] ms_free_slot, ms_retire_slot, ms_complete_slot, ms_early_slot, ms_peek_slot;
  logic [2:0] ms_failed_early_retry_slot, ms_refill_retry_slot;
  logic [2:0] ms_collector_slot;
  logic [2:0] ms_secondary_slot;
  logic [2:0] ms_alloc_slot;
  logic ms_alloc_valid, ms_alloc_ready, ms_alloc_reload;
  logic ms_retire_valid, ms_complete_valid, ms_complete_candidate;
  logic release_same_line_pending;
  logic ms_early_pending, ms_early_send, ms_early_overlap_state;
  logic blocking_critical_candidate, blocking_last_dir_ready;
  logic ms_secondary_request_valid, ms_secondary_request_ready, ms_secondary_reload_valid;
  logic ms_secondary_allocate_valid;
  logic [BoomMshrs-1:0] ms_secondary_schedule_request;
  logic [3*BoomMshrs-1:0] ms_secondary_queue_valid;
  logic [IndexBits-1:0] ms_sched_set[BoomMshrs];
  logic [TagBits-1:0] ms_sched_tag[BoomMshrs];
  logic [TagBits-1:0] ms_secondary_reload_tag;
  logic [SecondaryPayloadBits-1:0] ms_secondary_reload_payload;
  logic [XLEN-1:0] ms_secondary_reload_addr;
  logic ms_replay_pending, ms_replay_active, ms_replay_issue;
  logic ms_secondary_release_admit;
  logic [2:0] ms_replay_slot;
  logic [SecondaryPayloadBits-1:0] ms_replay_payload;
  logic r_response_secondary;
  logic [(1<<ID_W)-1:0] ms_secondary_id_busy;
  logic ms_response_secondary;
  logic ms_arvalid, ms_arready, ms_rready;
  logic [L2_LINE_LEN-1:0] ms_rbeat;
  logic ms_sinkd_valid, boom_bank_sinkd_ready;
  logic [IndexBits-1:0] ms_sinkd_set;
  logic [  WayBits-1:0] ms_sinkd_way;
  logic blocking_refill_streamed, blocking_refill_sinkd_valid;
  logic bank_sinkd_valid;
  logic [IndexBits-1:0] bank_sinkd_set;
  logic [WayBits-1:0] bank_sinkd_way;
  logic [L2_LINE_LEN-1:0] bank_sinkd_word;
  logic install_streamed;
  logic [XLEN-1:0] ms_araddr;
  logic [ID_W-1:0] ms_arid;
  logic [ID_W-1:0] m_arid;
  logic [7:0] ms_arlen;
  logic [2:0] ms_arsize;
  logic [1:0] ms_arburst;
  logic [3:0] ms_arcache;
  logic [LineBits-1:0] ms_retire_line;
  logic [1:0] ms_retire_resp;
  logic [XLEN-1:0] ms_retire_addr;
  logic [ID_W-1:0] ms_retire_id;
  logic [7:0] ms_retire_len;
  logic [2:0] ms_retire_size;
  logic [1:0] ms_retire_burst;
  logic [3:0] ms_retire_cache;
  logic [WayBits-1:0] ms_way[BoomNormalMshrs];
  logic [TagBits-1:0] victim_tag_q;
  logic [1:0] victim_state_q;
  logic victim_dirty_q, victim_clients_q;
  logic [WayBits-1:0] r_selected_way;
  logic r_selected_resident;
  logic r_lookup_killed;
  logic l2_sram_wblock;
  logic boom_bank_read_ready;
  logic boom_bank_sourcec_ready;
  logic [XLEN-1:0] boom_bank_sourcec_word;
  logic boom_bank_line_busy;
  assign r_idx_q = r_addr[IndexMsb:IndexLsb];
  // RV64 accepts both zero-extended and sign-extended forms of the same
  // implemented 32-bit PA. Directory identity must use the canonical PA;
  // otherwise the two forms can occupy different ways and miss store snoops.
  assign r_tag_q = TagBits'(rapt_pkg::canonical_addr(r_addr) >> TagLsb);
  assign dir_lookup_hit = dir_lookup_hold_valid ? dir_lookup_hold_hit : dir_result_hit;
  assign dir_lookup_way = dir_lookup_hold_valid ? dir_lookup_hold_way : dir_result_way;
  assign dir_lookup_tag = dir_lookup_hold_valid ? dir_lookup_hold_tag : dir_result_tag;
  assign dir_lookup_state = dir_lookup_hold_valid ? dir_lookup_hold_state : dir_result_state;
  assign dir_lookup_dirty = dir_lookup_hold_valid ? dir_lookup_hold_dirty : dir_result_dirty;
  assign dir_lookup_clients = dir_lookup_hold_valid ? dir_lookup_hold_clients : dir_result_clients;
  assign r_selected_resident = BoomBankedStore ? !r_lookup_killed
      : line_valid[r_selected_way][r_idx_q] && line_tag[r_selected_way][r_idx_q] == r_tag_q;
  assign probe_valid_o = (rs == R_EVICT_PROBE && victim_clients_q && !release_pending)
      || (rs == R_HIT_PROBE && victim_clients_q && !release_pending)
      || (cbo_state == C_PROBE && cbo_entry[18] && !release_pending)
      || forward_scalar_probe_request || forward_replay_probe_request;
  assign probe_window_o = rs != R_IDLE || cbo_state != C_IDLE || ms_busy
      || any_write_in_flight || cache_install || boom_bank_line_busy || release_pending;
  assign probe_addr_o = forward_scalar_probe_request
      ? XLEN'({write_error_tag, write_error_idx, {OffsetBits{1'b0}}})
      : forward_replay_state == F_PROBE
      ? XLEN'({forward_log_rdata.addr[ForwardLogAddrBits-1:OffsetBits], {OffsetBits{1'b0}}})
      : cbo_state == C_PROBE
      ? XLEN'({cbo_tag, cbo_active_set, {OffsetBits{1'b0}}})
      : XLEN'({victim_tag_q, r_idx_q, {OffsetBits{1'b0}}});
  always_ff @(posedge clock) begin
    if (reset) begin
      dir_lookup_hold_valid <= 1'b0;
      dir_lookup_hold_hit <= 1'b0;
      dir_lookup_hold_way <= '0;
      dir_lookup_hold_tag <= '0;
      dir_lookup_hold_state <= '0;
      dir_lookup_hold_dirty <= 1'b0;
      dir_lookup_hold_clients <= 1'b0;
    end else if (ms_replay_issue && ms_replay_use_metadata) begin
      dir_lookup_hold_valid <= 1'b1;
      dir_lookup_hold_hit <= ms_replay_meta_state != 2'b00
          && ms_replay_meta_tag == TagBits'(rapt_pkg::canonical_addr(
              ms_replay_payload[ID_W+:XLEN]
          ) >> TagLsb);
      dir_lookup_hold_way <= ms_way[int'(ms_replay_slot)];
      dir_lookup_hold_tag <= ms_replay_meta_tag;
      dir_lookup_hold_state <= ms_replay_meta_state;
      dir_lookup_hold_dirty <= ms_replay_meta_dirty;
      dir_lookup_hold_clients <= ms_replay_meta_clients;
    end else if (dir_demand_read_valid && dir_read_ready) begin
      dir_lookup_hold_valid <= 1'b0;
    end else if (dir_result_valid && !dir_result_for_aw_q && !dir_result_for_error_q
                 && rs == R_HIT) begin
      // A queued metadata write may drain while R_HIT waits for the data
      // SRAM port or while a store makes a separate directory lookup.
      dir_lookup_hold_valid <= 1'b1;
      dir_lookup_hold_hit <= dir_result_hit;
      dir_lookup_hold_way <= dir_result_way;
      dir_lookup_hold_tag <= dir_result_tag;
      dir_lookup_hold_state <= dir_result_state;
      dir_lookup_hold_dirty <= dir_result_dirty;
      dir_lookup_hold_clients <= dir_result_clients;
    end
    // A local store can dirty the same line after the read lookup was
    // captured. Keep the held metadata current before a D-client mark writes
    // that entry back to the one-port directory.
    if (!reset && (rs == R_HIT || hit_probe_active) && w_hit_update && same_line(
            w_snoop_addr, r_addr
        ))
      dir_lookup_hold_dirty <= 1'b1;
    if (!reset && hit_probe_commit) begin
      dir_lookup_hold_clients <= 1'b0;
      dir_lookup_hold_state <= 2'b11;
      dir_lookup_hold_dirty <= victim_dirty_q || dir_lookup_dirty;
    end
  end
  always_comb begin
    if (BoomBankedStore) begin
      r_hit_way = dir_lookup_way;
      r_hit_q   = dir_lookup_hit && !r_lookup_killed;
    end else begin
      r_hit_q   = 1'b0;
      r_hit_way = '0;
      for (int way = 0; way < L2_N_WAYS; way++) begin
        if (line_valid[way][r_idx_q] && line_tag[way][r_idx_q] == r_tag_q) begin
          r_hit_q   = 1'b1;
          r_hit_way = WayBits'(way);
        end
      end
    end
  end

  assign ms_busy = |ms_slot_valid;
  // A client may release a line after receiving its critical word. C may
  // take the reserved way while SinkD still fills it. Each C word waits
  // until SinkD has committed that word, so later refill beats cannot
  // overwrite released data.
  always_comb begin
    release_same_line_pending = 1'b0;
    release_nested_candidate = 1'b0;
    release_nested_slot = '0;
    for (int slot = 0; slot < BoomNormalMshrs; slot++) begin
      if (release_head_valid && ms_slot_valid[slot] && !ms_installed[slot]
          && ms_line_addr[slot][XLEN-1:OffsetBits]
                 == release_head_addr[XLEN-1:OffsetBits]) begin
        if (ms_early_sent[slot] || (ms_slot_done[slot] && ms_slot_resp[slot] == 2'b00)) begin
          release_nested_candidate = 1'b1;
          release_nested_slot = 3'(slot);
        end else release_same_line_pending = 1'b1;
      end
    end
  end
  always_comb begin
    ms_sinkd_valid = 1'b0;
    ms_sinkd_set   = '0;
    ms_sinkd_way   = '0;
    for (int slot = 0; slot < BoomNormalMshrs; slot++) begin
      if (axi_m.rid == ID_W'(slot)) begin
        ms_sinkd_valid = BoomBankedStore && axi_m.rvalid && ms_slot_valid[slot]
            && !ms_slot_done[slot] && !ms_installed[slot];
        ms_sinkd_set = ms_set[slot];
        ms_sinkd_way = ms_way[slot];
      end
    end
  end
  assign blocking_refill_streamed = BoomBankedStore && (!r_burst_fill || !burst_all_full);
  assign blocking_refill_invalidate = BoomBankedStore && rs == R_MISS_INVALIDATE;
  assign blocking_refill_sinkd_valid = blocking_refill_streamed && rs == R_MISS_R
      && axi_m.rvalid && axi_m.rid == m_arid && axi_m.rresp == 2'b00 && r_resp == 2'b00;
  assign bank_sinkd_valid = ms_sinkd_valid || blocking_refill_sinkd_valid;
  assign bank_sinkd_set = blocking_refill_sinkd_valid ? r_idx_q : ms_sinkd_set;
  assign bank_sinkd_way = blocking_refill_sinkd_valid ? victim_way_q : ms_sinkd_way;
  assign bank_sinkd_word = blocking_refill_sinkd_valid ? r_fill_cnt : ms_rbeat;
  assign ms_sched_valid = {
    BoomBankedStore && release_head_valid, 1'b0, ms_slot_valid[BoomNormalMshrs-1:0]
  };
  always_comb begin
    ms_free = 1'b0;
    ms_free_slot = '0;
    ms_done_any = 1'b0;
    ms_active_refills = 1'b0;
    ms_complete_candidate = 1'b0;
    ms_complete_slot = '0;
    ms_retire_candidate = 1'b0;
    ms_retire_slot = '0;
    ms_failed_early_retry = 1'b0;
    ms_failed_early_retry_slot = '0;
    ms_late_response_candidate = 1'b0;
    ms_late_response_slot = '0;
    ms_ar_conflict = 1'b0;
    ms_id_conflict = ms_secondary_id_busy[axi_s.arid];
    ms_secondary_match = 1'b0;
    ms_early_pending = 1'b0;
    ms_early_slot = '0;
    for (int slot = 0; slot < BoomNormalMshrs; slot++) begin
      if (!ms_slot_valid[slot] && !ms_free) begin
        ms_free = 1'b1;
        ms_free_slot = 3'(slot);
      end
      if (ms_slot_valid[slot] && !ms_installed[slot]) ms_active_refills = 1'b1;
      if (ms_slot_valid[slot] && ms_late_response_pending[slot]
          && !ms_late_response_candidate) begin
        ms_late_response_candidate = 1'b1;
        ms_late_response_slot = 3'(slot);
      end
      if (ms_slot_done[slot]) ms_done_any = 1'b1;
      // A grant already sent to the client cannot be replaced by an AXI
      // error response. Keep the MSHR and retry its complete line instead.
      if (ms_slot_done[slot] && !ms_installed[slot] && ms_early_good_accepted[slot]
          && ms_slot_resp[slot] != 2'b00 && !ms_failed_early_retry) begin
        ms_failed_early_retry = 1'b1;
        ms_failed_early_retry_slot = 3'(slot);
      end
      if (ms_slot_done[slot] && !ms_installed[slot]
          && !(ms_early_good_accepted[slot] && ms_slot_resp[slot] != 2'b00)
          && (!ms_secondary_queue_valid[slot] || !ms_early_sent[slot]
              || (ms_replay_pending && ms_replay_slot == 3'(slot)))
          && !ms_complete_candidate) begin
        ms_complete_candidate = 1'b1;
        ms_complete_slot = 3'(slot);
      end
      if (ms_slot_done[slot] && ms_installed[slot] && !ms_secondary_queue_valid[slot]
          && !ms_late_response_pending[slot]
          && !(ms_late_response_active && ms_late_response_active_slot == 3'(slot))
          && !(ms_replay_pending && ms_replay_slot == 3'(slot))
          && !(ms_replay_active && ms_replay_slot == 3'(slot))
          && !ms_retire_candidate) begin
        ms_retire_candidate = 1'b1;
        ms_retire_slot = 3'(slot);
      end
      if (ms_slot_valid[slot] && ms_id[slot] == axi_s.arid) ms_id_conflict = 1'b1;
      if (ms_slot_valid[slot]
          && (ms_set[slot] == axi_s.araddr[IndexMsb:IndexLsb]
              || ms_id[slot] == axi_s.arid))
        ms_ar_conflict = 1'b1;
      if (ms_slot_valid[slot] && ms_set[slot] == axi_s.araddr[IndexMsb:IndexLsb])
        ms_secondary_match = 1'b1;
      if (ms_slot_valid[slot] && (ms_critical_ready[slot] || ms_slot_done[slot])
          && !ms_installed[slot] && !ms_early_sent[slot]
          && ms_len[slot] == 8'd0 && !ms_early_pending
          && (!release_pending
              || (release_head_valid
                  && ms_set[slot] != release_head_addr[IndexMsb:IndexLsb]))) begin
        ms_early_pending = 1'b1;
        ms_early_slot = 3'(slot);
      end
    end
  end
  assign ms_alloc_slot = ms_replay_active ? ms_replay_slot : ms_free_slot;
  assign ms_alloc_reload = ms_replay_active && ms_slot_done[int'(ms_replay_slot)]
      && ms_installed[int'(ms_replay_slot)];
  assign ms_alloc_valid = BoomBankedStore && rs == R_HIT && !r_hit_q
      && |r_cache[3:2]
      && !dir_lookup_clients && !dir_lookup_dirty && (ms_replay_active || ms_free)
      && !l2_sram_wblock && !any_write_in_flight && dir_write_ready
      && !release_dir_write_fire && !cache_install && !dir_error_inv
      && !w_hit_update && !burst_hit_update && !cbo_exact_invalidate
      && !(axi_s.awvalid && axi_s.awready);
  assign ms_alloc_invalidate = ms_alloc_valid && ms_alloc_ready;
  // An unrelated clean MSHR may return its critical word while the blocking
  // miss writes back a victim or accepts refill data. The blocking miss's own
  // critical beat has priority when both responses are ready together.
  assign ms_early_overlap_state = rs == R_EVICT_PROBE || rs == R_EVICT_AW
      || rs == R_EVICT_READ || rs == R_EVICT_W || rs == R_EVICT_B
      || rs == R_MISS_INVALIDATE || rs == R_MISS_AR || rs == R_MISS_R;
  assign blocking_critical_candidate = rs == R_MISS_R && axi_m.rvalid
      && axi_m.rid == m_arid && !r_store_fill && !r_burst_fill
      && !r_up_done && r_len == 8'd0 && r_fill_cnt == r_word
      && axi_m.rresp == 2'b00 && r_resp == 2'b00;
  assign ms_early_send = BoomBankedStore && (rs == R_IDLE || ms_early_overlap_state)
      && ms_early_pending && !blocking_critical_candidate
      && !rs_rvalid && !cache_install && !burst_active;
  // Once SinkD has filled every bank, commit metadata even if an unrelated
  // blocking miss still owns the shared read FSM. Keep the primary response
  // pending until that FSM is available to read the installed line.
  assign ms_late_response_issue = BoomBankedStore && ms_late_response_candidate
      && rs == R_IDLE && !rs_rvalid && !cache_install && !boom_bank_line_busy
      && !burst_active && !release_pending && !ms_early_send
      && !ms_replay_pending && !ms_replay_active && !ms_source_active;
  // SourceD can read a completed ordinary line from its installed banked
  // way while a different miss is still in Probe, eviction, or refill.
  // A line-local FIXED, INCR, or WRAP burst can read the installed way without
  // borrowing the blocking miss's response FSM.
  assign ms_source_start = BoomBankedStore && ms_late_response_candidate
      && ms_early_overlap_state && !release_pending && !ms_source_active
      && !ms_late_response_active
      && source_read_shape(
      ms_line_addr[int'(ms_late_response_slot)],
      ms_len[int'(ms_late_response_slot)],
      ms_size[int'(ms_late_response_slot)],
      ms_burst[int'(ms_late_response_slot)]
  );
  // An installed equal-tag secondary can reuse the MSHR's committed way.
  // Different tags and unsupported burst shapes still replay via the
  // directory after the blocking transaction completes.
  assign ms_source_secondary_start = BoomBankedStore && ms_secondary_reload_valid
      && ms_slot_done[int'(ms_secondary_slot)] && ms_installed[int'(ms_secondary_slot)]
      && ms_early_sent[int'(ms_secondary_slot)] && !ms_secondary_reload_needs_directory
      && ms_slot_resp[int'(ms_secondary_slot)] == 2'b00
      && !ms_secondary_needs_ownership
      && !ms_source_active && !ms_late_response_active
      && source_read_shape(
      ms_secondary_reload_addr,
      ms_secondary_reload_payload[SecondaryLenLsb+:8],
      ms_secondary_reload_payload[ID_W+XLEN+:3],
      ms_secondary_reload_payload[SecondaryBurstLsb+:2]
  );
  assign ms_source_start_slot = ms_source_secondary_start ? ms_secondary_slot
      : ms_late_response_slot;
  assign ms_source_start_addr = ms_source_secondary_start ? ms_secondary_reload_addr
      : ms_line_addr[int'(ms_late_response_slot)];
  assign ms_source_start_len = ms_source_secondary_start
      ? ms_secondary_reload_payload[SecondaryLenLsb+:8] : ms_len[int'(ms_late_response_slot)];
  assign ms_source_start_size = ms_source_secondary_start
      ? ms_secondary_reload_payload[ID_W+XLEN+:3] : ms_size[int'(ms_late_response_slot)];
  assign ms_source_start_burst = ms_source_secondary_start
      ? ms_secondary_reload_payload[SecondaryBurstLsb+:2] : ms_burst[int'(ms_late_response_slot)];
  assign ms_source_start_id = ms_source_secondary_start
      ? ms_secondary_reload_payload[0+:ID_W] : ms_id[int'(ms_late_response_slot)];
  assign ms_source_chunk = 3'(int'(ms_source_issue_addr[WordOffsetMsb:WordOffsetLsb])
      / (64 / XLEN));
  assign ms_source_data_valid = ms_source_count != 2'd0;
  assign ms_source_data = ms_source_fifo[ms_source_head];
  assign ms_source_read_capture = ms_source_read_pending && boom_bank_read_result_valid;
  // Reserve a queue entry for the SRAM result already in flight. A new
  // request may issue as the previous result enters the three-beat skidpad.
  assign ms_source_read_request = ms_source_active && !ms_source_issue_done
      && (!ms_source_read_pending || boom_bank_read_result_valid)
      && int'(ms_source_count) + int'(ms_source_read_pending) < 3
      && (ms_early_overlap_state || rs == R_IDLE) && cbo_state != C_READ;
  assign ms_source_read_fire = ms_source_read_request && boom_bank_read_ready;
  assign ms_source_response_send = ms_source_active && ms_source_data_valid
      && (ms_early_overlap_state || rs == R_IDLE) && !rs_rvalid
      && !blocking_critical_candidate && !ms_early_send && !burst_active;
  // A foreign Get must retrieve a Trunk owner's latest data. A D regrant
  // after C/Probe must re-mark ownership before replying. Before install,
  // only the primary grant contributes a client; queued future grants do not.
  assign ms_secondary_needs_ownership = ms_installed[int'(ms_secondary_slot)]
      ? (!ms_meta_valid[int'(ms_secondary_slot)]
          || ms_meta_tag[int'(ms_secondary_slot)] != ms_sched_tag[int'(ms_secondary_slot)]
          || ms_meta_state[int'(ms_secondary_slot)] == 2'b00
          || ms_meta_clients[int'(ms_secondary_slot)]
              != d_client_read_id(ms_secondary_reload_payload[0+:ID_W]))
      : d_client_read_id(ms_id[int'(ms_secondary_slot)])
          != d_client_read_id(ms_secondary_reload_payload[0+:ID_W]);
  assign ms_secondary_capture = BoomBankedStore && ms_secondary_reload_valid
      && !ms_source_secondary_start
      && (ms_secondary_reload_needs_directory
          || (ms_slot_resp[int'(ms_secondary_slot)] == 2'b00
              && (ms_installed[int'(ms_secondary_slot)] || ms_secondary_needs_ownership
                  || ms_secondary_reload_payload[SecondaryLenLsb+:8] != 8'd0)));
  assign ms_secondary_send = BoomBankedStore && ms_secondary_reload_valid
      && !ms_secondary_capture && !ms_source_secondary_start;
  assign ms_secondary_reload_addr = ms_secondary_reload_payload[ID_W+:XLEN];
  assign ms_peek_slot = ms_early_send ? ms_early_slot
      : ms_late_response_issue ? ms_late_response_slot
      : ms_secondary_send ? ms_secondary_slot : ms_complete_slot;
  assign ms_collector_slot = ms_retire_valid ? ms_retire_slot : ms_peek_slot;
  assign ms_complete_valid = BoomBankedStore && rs == R_IDLE && ms_complete_candidate
      && !rs_rvalid && !cache_install && !boom_bank_line_busy && !burst_active
      && !ms_late_response_issue && !ms_source_active
      // C's first lookup has finished. A completed refill for another set
      // may install while C waits for later data beats. A same-line refill
      // stays reserved until C commits its dirty metadata on ReleaseAck.
      && (!release_pending
          || (release_head_valid && release_state == REL_DATA
              && ms_set[int'(ms_complete_slot)] != release_head_addr[IndexMsb:IndexLsb]))
      && !any_write_in_flight
      && !ms_early_send && !ms_secondary_send && !ms_secondary_capture
      && !ms_source_secondary_start
      && dir_write_ready;
  // SinkD has already written every clean refill beat to its reserved way.
  // The metadata write can commit while another miss waits for Probe,
  // dirty-victim writeback, or outer R, without borrowing its read FSM.
  assign ms_direct_complete = BoomBankedStore && ms_complete_candidate
      && ms_slot_resp[int'(ms_complete_slot)] == 2'b00
      && (rs == R_EVICT_PROBE || rs == R_EVICT_AW || rs == R_EVICT_READ
          || rs == R_EVICT_W || rs == R_EVICT_B || rs == R_MISS_R)
      && ms_set[int'(ms_complete_slot)] != r_idx_q
      && (!release_pending
          || (release_head_valid && release_state == REL_DATA
              && ms_set[int'(ms_complete_slot)] != release_head_addr[IndexMsb:IndexLsb]))
      && !cache_install && !burst_active && !any_write_in_flight && !ms_early_send
      && !(rs == R_MISS_R && axi_m.rvalid && axi_m.rid == m_arid && axi_m.rlast)
      && !release_dir_write_fire && !dir_error_inv && !w_hit_update
      && !burst_hit_update && !cbo_exact_invalidate && !dir_client_mark
      && !ms_alloc_invalidate && dir_write_ready;
  assign ms_retire_valid = BoomBankedStore && rs == R_IDLE && ms_retire_candidate
      && !rs_rvalid && !cache_install && !boom_bank_line_busy && !burst_active
      && !ms_late_response_issue
      && (!release_pending
          || (release_head_valid
              && ms_set[int'(ms_retire_slot)] != release_head_addr[IndexMsb:IndexLsb]))
      && !ms_early_send && !ms_secondary_send && !ms_secondary_capture
      && !ms_complete_valid;
  assign ms_replay_issue = BoomBankedStore && ms_replay_pending
      && ms_installed[int'(ms_replay_slot)] && rs == R_IDLE && !rs_rvalid
      && !cache_install && !boom_bank_line_busy && !burst_active && !ms_source_active
      // C has finished its lookup; a different set can use the one-port
      // directory while ReleaseData waits for subsequent data beats.
      && (!release_pending
          || (release_head_valid && release_state == REL_DATA
              && ms_set[int'(ms_replay_slot)] != release_head_addr[IndexMsb:IndexLsb]))
      && !any_write_in_flight
      && !ms_early_send && !ms_secondary_send && !ms_complete_valid
      && (ms_replay_use_metadata || dir_read_ready);
  always_comb begin
    ms_replay_meta_tag = ms_meta_tag[int'(ms_replay_slot)];
    ms_replay_meta_state = ms_meta_state[int'(ms_replay_slot)];
    ms_replay_meta_clients = ms_meta_clients[int'(ms_replay_slot)];
    ms_replay_meta_dirty = ms_meta_dirty[int'(ms_replay_slot)];
    // Include a metadata write accepted on this edge, as directory bypass does.
    if (dir_write_valid && dir_write_ready
        && dir_write_set == ms_set[int'(ms_replay_slot)]
        && dir_write_way == ms_way[int'(ms_replay_slot)]) begin
      ms_replay_meta_tag = dir_write_tag;
      ms_replay_meta_state = dir_write_state;
      ms_replay_meta_clients = dir_write_clients;
      ms_replay_meta_dirty = dir_write_dirty;
    end
  end
  // Reuse includes an Invalid entry: the same reserved way needs an outer
  // refill, rather than a new directory lookup. Keep eligibility independent
  // of the live metadata-write bypass to avoid feedback into AR/AW admission.
  assign ms_replay_use_metadata = !ms_replay_needs_directory
      && ms_meta_valid[int'(ms_replay_slot)]
      && ms_meta_tag[int'(ms_replay_slot)] == TagBits'(rapt_pkg::canonical_addr(
      ms_replay_payload[ID_W+:XLEN]
  ) >> TagLsb);
  always_ff @(posedge clock) begin
    for (int slot = 0; slot < BoomNormalMshrs; slot++) begin
      if (reset || (ms_alloc_valid && ms_alloc_ready && ms_alloc_slot == 3'(slot))) begin
        ms_meta_valid[slot] <= 1'b0;
        ms_meta_tag[slot] <= '0;
        ms_meta_state[slot] <= 2'b00;
        ms_meta_clients[slot] <= 1'b0;
        ms_meta_dirty[slot] <= 1'b0;
      end else if (ms_slot_valid[slot]) begin
        if (dir_clear_valid && dir_clear_ready && dir_clear_set == ms_set[slot]) begin
          ms_meta_state[slot] <= 2'b00;
          ms_meta_clients[slot] <= 1'b0;
          ms_meta_dirty[slot] <= 1'b0;
        end else if (dir_write_valid && dir_write_ready && dir_write_set == ms_set[slot]
                     && dir_write_way == ms_way[slot]) begin
          // A blocking different-tag secondary may replace this physical way
          // while the old primary still owns the scheduler slot. Track its tag.
          ms_meta_valid[slot] <= 1'b1;
          ms_meta_tag[slot] <= dir_write_tag;
          ms_meta_state[slot] <= dir_write_state;
          ms_meta_clients[slot] <= dir_write_clients;
          ms_meta_dirty[slot] <= dir_write_dirty;
        end
      end
    end
  end
  always_comb begin
    ms_secondary_schedule_request = '0;
    for (int slot = 0; slot < BoomNormalMshrs; slot++) begin
      ms_secondary_schedule_request[slot] = ms_slot_done[slot]
          && (ms_early_sent[slot] || ms_installed[slot])
          && !(ms_early_good_accepted[slot] && ms_slot_resp[slot] != 2'b00)
          && !ms_late_response_pending[slot]
          && !(ms_late_response_active && ms_late_response_active_slot == 3'(slot))
          && ms_secondary_queue_valid[slot]
          && (rs == R_IDLE
              || (ms_early_overlap_state && ms_installed[slot]
                  && ms_early_sent[slot] && ms_slot_resp[slot] == 2'b00))
          && !rs_rvalid
          && !cache_install && !burst_active && !ms_early_send
          && !ms_late_response_issue && !ms_source_start && !ms_source_active
          && (!release_pending
              || (release_head_valid
                  && ms_set[slot] != release_head_addr[IndexMsb:IndexLsb]))
          && !ms_replay_pending && !ms_replay_active;
    end
    ms_secondary_schedule_request[BoomMshrs-1] =
        release_lookup_candidate || release_dir_write_candidate;
  end
  assign ms_secondary_accept = BoomBankedStore && axi_s.arvalid && axi_s.arready
      && ms_secondary_match && (!ms_done_any || ms_secondary_release_admit);
  for (genvar slot = 0; slot < BoomMshrs; slot++) begin : g_mshr_schedule_meta
    if (slot < BoomNormalMshrs) begin : g_normal
      assign ms_sched_set[slot] = ms_set[slot];
      assign ms_sched_tag[slot] = TagBits'(rapt_pkg::canonical_addr(ms_line_addr[slot]) >> TagLsb);
    end else if (slot == BoomMshrs - 1) begin : g_release
      assign ms_sched_set[slot] = release_head_addr[IndexMsb:IndexLsb];
      assign ms_sched_tag[slot] = TagBits'(rapt_pkg::canonical_addr(release_head_addr) >> TagLsb);
    end else begin : g_reserved
      assign ms_sched_set[slot] = '0;
      assign ms_sched_tag[slot] = '0;
    end
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      ms_early_sent <= '0;
      ms_early_good_accepted <= '0;
      ms_early_response_pending_q <= 1'b0;
      ms_early_response_slot_q <= '0;
      ms_installed <= '0;
      ms_primary_secondary <= '0;
      ms_late_response_pending <= '0;
      ms_late_response_active <= 1'b0;
      ms_late_response_active_slot <= '0;
      ms_source_active <= 1'b0;
      ms_source_read_pending <= 1'b0;
      ms_source_addr <= '0;
      ms_source_issue_addr <= '0;
      ms_source_issue_len <= '0;
      ms_source_issue_done <= 1'b0;
      ms_source_read_word <= '0;
      ms_source_head <= '0;
      ms_source_tail <= '0;
      ms_source_count <= '0;
      ms_source_id <= '0;
      ms_source_len <= '0;
      ms_source_size <= '0;
      ms_source_burst <= '0;
      ms_source_wrap_mask <= '0;
      ms_source_set <= '0;
      ms_source_way <= '0;
      ms_source_primary_secondary <= 1'b0;
      ms_secondary_id_busy <= '0;
      ms_replay_pending <= 1'b0;
      ms_replay_active <= 1'b0;
      ms_replay_slot <= '0;
      ms_replay_payload <= '0;
      ms_replay_needs_directory <= 1'b0;
      for (int slot = 0; slot < BoomNormalMshrs; slot++) begin
        ms_set[slot] <= '0;
        ms_line_addr[slot] <= '0;
        ms_id[slot] <= '0;
        ms_len[slot] <= '0;
        ms_size[slot] <= '0;
        ms_burst[slot] <= '0;
        ms_word[slot] <= '0;
        ms_way[slot] <= '0;
      end
    end else begin
      if (rs_rvalid && axi_s.rready && ms_early_response_pending_q) begin
        ms_early_response_pending_q <= 1'b0;
        if (rs_rresp == 2'b00) ms_early_good_accepted[int'(ms_early_response_slot_q)] <= 1'b1;
      end
      if (ms_alloc_valid && ms_alloc_ready) begin
        ms_set[int'(ms_alloc_slot)] <= r_idx_q;
        ms_line_addr[int'(ms_alloc_slot)] <= r_addr;
        ms_id[int'(ms_alloc_slot)] <= r_id;
        ms_len[int'(ms_alloc_slot)] <= r_len;
        ms_size[int'(ms_alloc_slot)] <= r_size;
        ms_burst[int'(ms_alloc_slot)] <= r_burst;
        ms_word[int'(ms_alloc_slot)] <= r_word;
        ms_way[int'(ms_alloc_slot)] <= dir_lookup_way;
        ms_early_sent[int'(ms_alloc_slot)] <= 1'b0;
        ms_early_good_accepted[int'(ms_alloc_slot)] <= 1'b0;
        ms_installed[int'(ms_alloc_slot)] <= 1'b0;
        ms_primary_secondary[int'(ms_alloc_slot)] <= ms_replay_active;
        ms_late_response_pending[int'(ms_alloc_slot)] <= 1'b0;
        if (ms_replay_active) ms_replay_active <= 1'b0;
      end
      if (ms_early_send) begin
        ms_early_sent[int'(ms_early_slot)] <= 1'b1;
        ms_early_response_pending_q <= 1'b1;
        ms_early_response_slot_q <= ms_early_slot;
      end
      if (ms_complete_valid) begin
        ms_installed[int'(ms_complete_slot)] <= 1'b1;
        if (ms_retire_resp != 2'b00) ms_early_sent[int'(ms_complete_slot)] <= 1'b1;
      end
      if (ms_direct_complete) begin
        ms_installed[int'(ms_complete_slot)] <= 1'b1;
        if (!ms_early_sent[int'(ms_complete_slot)])
          ms_late_response_pending[int'(ms_complete_slot)] <= 1'b1;
      end
      if (release_dir_write_fire && release_nested_q) begin
        ms_installed[int'(release_nested_slot_q)] <= 1'b1;
        if (!ms_early_sent[int'(release_nested_slot_q)])
          ms_late_response_pending[int'(release_nested_slot_q)] <= 1'b1;
      end
      if (ms_late_response_issue) begin
        ms_late_response_pending[int'(ms_late_response_slot)] <= 1'b0;
        ms_late_response_active <= 1'b1;
        ms_late_response_active_slot <= ms_late_response_slot;
      end
      if (ms_source_start || ms_source_secondary_start) begin
        if (ms_source_start) ms_late_response_pending[int'(ms_late_response_slot)] <= 1'b0;
        ms_late_response_active <= 1'b1;
        ms_late_response_active_slot <= ms_source_start_slot;
        ms_source_active <= 1'b1;
        ms_source_addr <= ms_source_start_addr;
        ms_source_issue_addr <= ms_source_start_addr;
        ms_source_issue_len <= ms_source_start_len;
        ms_source_issue_done <= 1'b0;
        ms_source_id <= ms_source_start_id;
        ms_source_len <= ms_source_start_len;
        ms_source_size <= ms_source_start_size;
        ms_source_burst <= ms_source_start_burst;
        ms_source_wrap_mask <= read_wrap_mask(ms_source_start_len, ms_source_start_size);
        ms_source_set <= ms_set[int'(ms_source_start_slot)];
        ms_source_way <= ms_way[int'(ms_source_start_slot)];
        ms_source_primary_secondary <= ms_source_secondary_start
            || ms_primary_secondary[int'(ms_late_response_slot)];
      end
      if (ms_source_read_fire) begin
        ms_source_read_word <= ms_source_issue_addr[WordOffsetMsb:WordOffsetLsb];
        if (ms_source_issue_len == 8'd0) ms_source_issue_done <= 1'b1;
        else begin
          ms_source_issue_len <= ms_source_issue_len - 8'd1;
          ms_source_issue_addr <= advance_read_addr(
              ms_source_issue_addr, ms_source_size, ms_source_burst, ms_source_wrap_mask
          );
        end
      end
      if (ms_source_read_fire || ms_source_read_capture)
        ms_source_read_pending <= ms_source_read_fire;
      if (ms_source_read_capture) begin
        ms_source_fifo[ms_source_tail] <= line_data_r[0][ms_source_read_word];
        ms_source_tail <= ms_source_tail == 2'd2 ? 2'd0 : ms_source_tail + 2'd1;
      end
      if (ms_source_response_send)
        ms_source_head <= ms_source_head == 2'd2 ? 2'd0 : ms_source_head + 2'd1;
      case ({
        ms_source_read_capture, ms_source_response_send
      })
        2'b10:   ms_source_count <= ms_source_count + 2'd1;
        2'b01:   ms_source_count <= ms_source_count - 2'd1;
        default: ;
      endcase
      if (ms_source_response_send) begin
        if (ms_source_len == 8'd0) begin
          ms_source_active <= 1'b0;
          ms_late_response_active <= 1'b0;
          ms_early_sent[int'(ms_late_response_active_slot)] <= 1'b1;
        end else begin
          ms_source_len <= ms_source_len - 8'd1;
          ms_source_addr <= advance_read_addr(
              ms_source_addr, ms_source_size, ms_source_burst, ms_source_wrap_mask
          );
        end
      end
      if (ms_late_response_active && !ms_source_active
          && rs == R_HIT_DATA && !l2_sram_wblock
          && r_selected_resident && (!rs_rvalid || axi_s.rready) && r_len == 8'd0) begin
        ms_late_response_active <= 1'b0;
        ms_early_sent[int'(ms_late_response_active_slot)] <= 1'b1;
      end
      if (ms_retire_valid) begin
        ms_installed[int'(ms_retire_slot)] <= 1'b0;
        ms_early_good_accepted[int'(ms_retire_slot)] <= 1'b0;
        ms_primary_secondary[int'(ms_retire_slot)] <= 1'b0;
      end
      if (ms_secondary_capture) begin
        ms_replay_pending <= 1'b1;
        ms_replay_slot <= ms_secondary_slot;
        ms_replay_payload <= ms_secondary_reload_payload;
        ms_replay_needs_directory <= ms_secondary_reload_needs_directory;
      end
      if (ms_replay_issue) begin
        ms_replay_pending <= 1'b0;
        ms_replay_active  <= 1'b1;
      end
      if (ms_replay_active
          && ((rs == R_HIT_DATA && r_selected_resident && !l2_sram_wblock
               && (!rs_rvalid || axi_s.rready) && r_len == 8'd0)
              || (rs == R_ERROR && (!rs_rvalid || axi_s.rready) && r_len == 8'd0)
              || (rs == R_MISS_R && axi_m.rvalid && !r_store_fill && !r_burst_fill
                  && !r_up_done && r_len == 8'd0 && r_fill_cnt == r_word
                  && axi_m.rresp == 2'b00 && r_resp == 2'b00
                  && (!rs_rvalid || axi_s.rready))))
        ms_replay_active <= 1'b0;
      if (ms_secondary_accept) begin
        ms_secondary_id_busy[axi_s.arid] <= 1'b1;
      end
      if (rs_rvalid && axi_s.rready && rs_rlast && ms_response_secondary)
        ms_secondary_id_busy[rs_rid] <= 1'b0;
    end
  end
  if (BoomBankedStore) begin : g_read_refill_mshrs
    rapt_l2_mshr_frontend #(
        .NumMshrs(BoomMshrs),
        .NumEntries(BoomSecondaryEntries),
        .SetBits(IndexBits),
        .TagBits(TagBits),
        .PayloadBits(SecondaryPayloadBits)
    ) u_secondary_reads (
        .clock,
        .reset,
        .request_valid(ms_secondary_request_valid),
        .request_ready(ms_secondary_request_ready),
        .request_prio(3'b001),
        .request_set(axi_s.araddr[IndexMsb:IndexLsb]),
        .request_tag(TagBits'(rapt_pkg::canonical_addr(axi_s.araddr) >> TagLsb)),
        .request_payload({
          axi_s.arburst, axi_s.arlen, axi_s.arcache, axi_s.arsize, axi_s.araddr, axi_s.arid
        }),
        .mshr_valid(ms_sched_valid),
        .mshr_set(ms_sched_set),
        .mshr_tag(ms_sched_tag),
        .mshr_block_b('0),
        .mshr_block_c('0),
        .mshr_nest_b('0),
        .mshr_nest_c('0),
        .schedule_request(ms_secondary_schedule_request),
        .schedule_resources_ready('1),
        .schedule_reload('1),
        .allocate_valid(ms_secondary_allocate_valid),
        .allocate_index(),
        .schedule_valid(),
        .schedule_index(ms_secondary_slot),
        .schedule_onehot(ms_secondary_schedule_onehot),
        .schedule_stalled(ms_secondary_schedule_stalled),
        .reload_valid(ms_secondary_reload_valid),
        .reload_from_request(),
        .reload_needs_directory(ms_secondary_reload_needs_directory),
        .reload_tag(ms_secondary_reload_tag),
        .reload_payload(ms_secondary_reload_payload),
        .secondary_push_ready(),
        .secondary_queue_valid(ms_secondary_queue_valid)
    );
    rapt_l2_refill_mshrs #(
        .XLEN(XLEN),
        .ID_W(ID_W),
        .LineBytes(64),
        .NumMshrs(BoomMshrs)
    ) u_refills (
        .clock,
        .reset,
        .alloc_valid(ms_alloc_valid),
        .alloc_ready(ms_alloc_ready),
        .alloc_reload(ms_alloc_reload),
        .alloc_slot(ms_alloc_slot),
        .retry_valid(ms_refill_retry),
        .retry_slot(ms_refill_retry_slot),
        .alloc_addr(r_addr),
        .alloc_inner_id(r_id),
        .alloc_inner_len(r_len),
        .alloc_inner_size(r_size),
        .alloc_inner_burst(r_burst),
        .alloc_cache(r_cache),
        .outer_arvalid(ms_arvalid),
        .outer_arready(ms_arready),
        .outer_araddr(ms_araddr),
        .outer_arid(ms_arid),
        .outer_arlen(ms_arlen),
        .outer_arsize(ms_arsize),
        .outer_arburst(ms_arburst),
        .outer_arcache(ms_arcache),
        .outer_rvalid(ms_sinkd_valid),
        .outer_rready(ms_rready),
        .outer_store_ready(boom_bank_sinkd_ready),
        .outer_rid(axi_m.rid),
        .outer_rbeat(ms_rbeat),
        .outer_rdata(axi_m.rdata),
        .outer_rresp(axi_m.rresp),
        .outer_rlast(axi_m.rlast),
        .slot_valid(ms_slot_valid),
        .slot_done(ms_slot_done),
        .slot_critical_ready(ms_critical_ready),
        .slot_beat_valid(ms_beat_valid),
        .slot_resp(ms_slot_resp),
        .retire_valid(ms_retire_valid),
        .retire_slot(ms_collector_slot),
        .retire_beat_valid(),
        .retire_line(ms_retire_line),
        .retire_resp(ms_retire_resp),
        .retire_addr(ms_retire_addr),
        .retire_inner_id(ms_retire_id),
        .retire_inner_len(ms_retire_len),
        .retire_inner_size(ms_retire_size),
        .retire_inner_burst(ms_retire_burst),
        .retire_cache(ms_retire_cache)
    );
  end else begin : g_no_read_refill_mshrs
    assign ms_slot_valid = '0;
    assign ms_slot_done = '0;
    assign ms_critical_ready = '0;
    for (genvar slot = 0; slot < BoomMshrs; slot++) begin : g_no_refill_beats
      assign ms_beat_valid[slot] = '0;
    end
    for (genvar slot = 0; slot < BoomMshrs; slot++) begin : g_no_slot_resp
      assign ms_slot_resp[slot] = '0;
    end
    assign ms_alloc_ready = 1'b0;
    assign ms_arvalid = 1'b0;
    assign ms_araddr = '0;
    assign ms_arid = '0;
    assign ms_arlen = '0;
    assign ms_arsize = '0;
    assign ms_arburst = '0;
    assign ms_arcache = '0;
    assign ms_rready = 1'b0;
    assign ms_rbeat = '0;
    assign ms_retire_line = '0;
    assign ms_retire_resp = '0;
    assign ms_retire_addr = '0;
    assign ms_retire_id = '0;
    assign ms_retire_len = '0;
    assign ms_retire_size = '0;
    assign ms_retire_burst = '0;
    assign ms_retire_cache = '0;
    assign ms_secondary_request_ready = 1'b0;
    assign ms_secondary_allocate_valid = 1'b0;
    assign ms_secondary_reload_valid = 1'b0;
    assign ms_secondary_reload_needs_directory = 1'b0;
    assign ms_secondary_slot = '0;
    assign ms_secondary_queue_valid = '0;
    assign ms_secondary_reload_tag = '0;
    assign ms_secondary_reload_payload = '0;
    assign ms_secondary_schedule_onehot = '0;
    assign ms_secondary_schedule_stalled = '0;
  end

`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset && BoomBankedStore) begin
      assert (!ms_secondary_allocate_valid);
      if (ms_secondary_send) begin
        assert (ms_slot_done[int'(ms_secondary_slot)]);
        assert (ms_secondary_reload_tag == ms_sched_tag[int'(ms_secondary_slot)]);
        assert (ms_secondary_reload_addr[XLEN-1:OffsetBits]
                == ms_line_addr[int'(ms_secondary_slot)][XLEN-1:OffsetBits]);
        assert (ms_secondary_id_busy[ms_secondary_reload_payload[0+:ID_W]]);
      end
    end
  end
`endif

  // ---------------------------------------------------------------------
  // Slave side R driver
  // ---------------------------------------------------------------------
  assign axi_s.rvalid = rs_rvalid;
  assign axi_s.rdata  = rs_rdata;
  assign axi_s.rlast  = rs_rlast;
  assign axi_s.rresp  = rs_rresp;
  assign axi_s.rid    = rs_rid;

  logic r_hit_beat_fire;
  logic [XLEN-1:0] r_next_addr;
  logic boom_queued_miss_or_unknown;
  logic [IndexBits-1:0] install_idx;
  logic [TagBits-1:0] install_tag;
  assign r_next_addr = advance_read_addr(r_addr, r_size, r_burst, r_wrap_mask);
  logic [IndexBits-1:0] data_sram_raddr;
  assign r_hit_beat_fire = (rs == R_HIT) && r_hit_q && (!rs_rvalid || axi_s.rready);
  always_comb begin
    dir_demand_read_valid = 1'b0;
    dir_read_set = r_idx_q;
    dir_read_tag = r_tag_q;
    if (BoomBankedStore) begin
      if (rs == R_IDLE && axi_s.arvalid && axi_s.arready && ar_cache_lookup
          && !ms_secondary_accept) begin
        dir_demand_read_valid = 1'b1;
        dir_read_set = axi_s.araddr[IndexMsb:IndexLsb];
        dir_read_tag = TagBits'(rapt_pkg::canonical_addr(axi_s.araddr) >> TagLsb);
      end else if (ms_replay_issue && !ms_replay_use_metadata) begin
        dir_demand_read_valid = 1'b1;
        dir_read_set = ms_replay_payload[ID_W+IndexLsb+:IndexBits];
        dir_read_tag = TagBits'(rapt_pkg::canonical_addr(ms_replay_payload[ID_W+:XLEN]) >> TagLsb);
      end else if (rs == R_HIT_DATA && r_selected_resident && !l2_sram_wblock
                   && (!rs_rvalid || axi_s.rready) && r_len != 8'd0
                   && !same_line(
              r_addr, r_next_addr
          )) begin
        // Keep the held metadata across beats in the same line, as SourceD
        // does. A crossing burst needs the next line's directory lookup.
        dir_demand_read_valid = 1'b1;
        dir_read_set = r_next_addr[IndexMsb:IndexLsb];
        dir_read_tag = TagBits'(rapt_pkg::canonical_addr(r_next_addr) >> TagLsb);
      end else if (rs == R_INSTALL_READ && !l2_sram_wblock) begin
        dir_demand_read_valid = 1'b1;
        dir_read_set = install_idx;
        dir_read_tag = install_tag;
      end
      if (!dir_demand_read_valid && dir_error_lookup_request) begin
        dir_read_set = write_error_idx;
        dir_read_tag = write_error_tag;
      end else if (!dir_demand_read_valid && release_lookup_fire && !release_nested_candidate) begin
        dir_read_set = release_head_addr[IndexMsb:IndexLsb];
        dir_read_tag = TagBits'(rapt_pkg::canonical_addr(release_head_addr) >> TagLsb);
      end else if (!dir_demand_read_valid && dir_aw_read_fire) begin
        dir_read_set = axi_s.awaddr[IndexMsb:IndexLsb];
        dir_read_tag = TagBits'(rapt_pkg::canonical_addr(axi_s.awaddr) >> TagLsb);
      end else if (!dir_demand_read_valid && dir_burst_read_valid) begin
        dir_read_set = burst_allocate ? burst_start[IndexMsb:IndexLsb]
                                      : burst_addr[IndexMsb:IndexLsb];
        dir_read_tag =
            TagBits'(rapt_pkg::canonical_addr(burst_allocate ? burst_start : burst_addr) >> TagLsb);
      end else if (!dir_demand_read_valid && dir_burst_alloc_read_fire) begin
        dir_read_set = axi_s.awaddr[IndexMsb:IndexLsb];
        dir_read_tag = TagBits'(rapt_pkg::canonical_addr(axi_s.awaddr) >> TagLsb);
      end
    end
  end
  assign dir_read_valid = dir_demand_read_valid || dir_error_lookup_request
      || (release_lookup_fire && !release_nested_candidate) || dir_aw_read_fire
      || dir_burst_read_valid || dir_burst_alloc_read_fire;
  assign data_sram_raddr =
      ms_replay_issue ? ms_replay_payload[ID_W+IndexLsb+:IndexBits]
      : (rs == R_IDLE && axi_s.arvalid && axi_s.arready
          && ar_cache_lookup) ? axi_s.araddr[IndexMsb:IndexLsb] :
      (r_hit_beat_fire && (r_len != 8'd0)) ? r_next_addr[IndexMsb:IndexLsb] : r_idx_q;

  // ---------------------------------------------------------------------
  // AR acceptance: only when read FSM idle.
  // ---------------------------------------------------------------------
  // An early-restarted refill can return to IDLE before its registered
  // install pulse writes SRAM. A new lookup needs a real read edge.
  logic ms_ar_common_ready;
  // A secondary of an existing, different-set MSHR only writes its A queue.
  // It can enter while C owns the directory.
  assign ms_secondary_release_admit = BoomBankedStore && release_head_valid
      && ms_secondary_match
      && axi_s.araddr[IndexMsb:IndexLsb] != release_head_addr[IndexMsb:IndexLsb];
  logic ms_primary_release_admit;
  // Once C's lookup has completed, its data beats use the bank port, so an
  // independent cacheable primary can read the directory and start a fill.
  assign ms_primary_release_admit = BoomBankedStore && release_head_valid
      && release_state == REL_DATA
      && axi_s.araddr[IndexMsb:IndexLsb] != release_head_addr[IndexMsb:IndexLsb]
      && cacheable_line(
      axi_s.araddr
  ) && |axi_s.arcache[3:2];
  assign ms_ar_common_ready = wipe_done && dir_ready && (rs == R_IDLE) && !cache_install
      && !boom_bank_line_busy
      && !ms_source_active
      && (!release_pending || ms_secondary_release_admit || ms_primary_release_admit)
      && (!BoomBankedStore || dir_read_ready)
      && !ms_early_send
      && !ms_replay_pending && !ms_replay_active
      && !cbo_busy && !burst_active && !(BoomBankedStore && dir_error_pending)
      && !forward_cache_pending
      && !forward_scalar_pending
      && !(BoomBankedStore && l1d_writeback_pending_i)
      && !(axi_s.awvalid && (BoomBankedStore || axi_s.awlen != 0))
      && !(BoomBankedStore && boom_queued_miss_or_unknown);
  assign ms_secondary_request_valid = BoomBankedStore && axi_s.arvalid
      && ms_ar_common_ready && (!ms_done_any || ms_secondary_release_admit)
      && ms_secondary_match && !ms_id_conflict
      && cacheable_line(
      axi_s.araddr
  ) && |axi_s.arcache[3:2];
  assign axi_s.arready = ms_ar_common_ready && (!ms_done_any || ms_secondary_release_admit)
      && (ms_secondary_match ? ms_secondary_request_valid && ms_secondary_request_ready
                             : !ms_ar_conflict && !ms_id_conflict
                                 && (!BoomBankedStore || !cacheable_line(
      axi_s.araddr
  ) || !(|axi_s.arcache[3:2]) || ms_free));

  // ---------------------------------------------------------------------
  // Master-side AR (issued during R_MISS_AR or R_BYPASS_AR).
  // ---------------------------------------------------------------------
  logic            m_arvalid;
  logic [XLEN-1:0] m_araddr;
  logic [     7:0] m_arlen;
  logic [     2:0] m_arsize;
  logic [     1:0] m_arburst;
  logic [     3:0] m_arcache;

  assign ms_arready = axi_m.arready && !m_arvalid;
  assign axi_m.arvalid = m_arvalid || ms_arvalid;
  assign axi_m.araddr = m_arvalid ? m_araddr : ms_araddr;
  assign axi_m.arid = m_arvalid ? m_arid : ms_arid;
  assign axi_m.arlen = m_arvalid ? m_arlen : ms_arlen;
  assign axi_m.arsize = m_arvalid ? m_arsize : ms_arsize;
  assign axi_m.arburst = m_arvalid ? m_arburst : ms_arburst;
  assign axi_m.arcache = m_arvalid ? m_arcache : ms_arcache;

  // A blocking partial Put refill writes each accepted outer beat through
  // SinkD, so a same-bank higher-priority access may backpressure AXI R.
  // Bypass reads use the single upstream holding register instead.
  // A blocking last beat raises cache_install on the next edge. Wait for the
  // one-entry directory write queue to drain so that install cannot be lost
  // behind an unrelated MSHR metadata commit.
  assign blocking_last_dir_ready = !BoomBankedStore || !axi_m.rlast
      || (dir_write_ready && !dir_write_valid);
  assign axi_m.rready = ms_sinkd_valid ? ms_rready
      : (rs == R_MISS_R && axi_m.rid == m_arid
         && blocking_last_dir_ready
         && (!blocking_refill_sinkd_valid || boom_bank_sinkd_ready))
          || ((rs == R_BYPASS_R) && (!rs_rvalid || axi_s.rready));

  // ---------------------------------------------------------------------
  // Cache write port (drive on fill completion)
  // ---------------------------------------------------------------------
  // ---------------------------------------------------------------------
  // Write buffer
  // ---------------------------------------------------------------------
  // Decouples upstream AW/W capture from the downstream drain. A buffered
  // store hit can complete locally; a store miss waits for its refill and
  // a forwarded write waits for the real downstream B when not posted.
  //
  // Stores from rapt_bus are single-beat (axi.awlen==0), so each buffer
  // entry holds the whole transaction. A small B-id FIFO records the
  // upstream id ordering independently of the downstream drain pointer.
  // A BOOM-layout write miss holds its B entry until the refill installs.
  //
  // BOOM provisions 40 put lists and 40 put beats for its default 40-cycle
  // memory latency. Raptor's buffered AXI writes are single-beat, so one
  // entry consumes one list and one beat. Keep the smaller legacy cache at
  // two entries; the BOOM geometry gets 40 AW/W slots and 40 ordered B slots.
  //
  // Future extensions (left as TODO comments below):
  //   - Write coalescing: on AW enqueue, scan buffer for same-line entries
  //     and merge wstrb into existing entry (saves a downstream beat).
  //   - Read MSHR: mirror this structure on the read side (multiple
  //     outstanding fills), today `r_*` is a single-entry placeholder.
  //   - Coalesce consecutive L1D write-back words in a single line entry.
  localparam int WbufDepth = BoomBankedStore ? 40 : 2;
  localparam int WbufPtrW  = $clog2(WbufDepth);
  localparam int WbufCntW  = $clog2(WbufDepth + 1);
  typedef struct packed {
    logic                busy;            // slot in use (AW captured, not yet freed)
    logic                has_w;           // W beat captured -> slot drainable
    logic [XLEN-1:0]     addr;
    logic [ID_W-1:0]     id;
    logic [2:0]          size;
    logic [7:0]          len;             // 0 for single-beat stores from rapt_bus
    logic [1:0]          burst;
    logic [3:0]          cache;
    logic [XLEN-1:0]     wdata;
    logic [XLEN/8-1:0]   wstrb;
    logic                wlast;
    logic [WbufPtrW-1:0] put_list;
    logic                posted;
    logic                forward_scalar;
    logic                local_hit;
    logic                local_miss;
    logic                lookup_ready;
    logic                lookup_hit;
    logic [WayBits-1:0]  lookup_way;
    logic [TagBits-1:0]  lookup_tag;
    logic [1:0]          lookup_state;
    logic                lookup_dirty;
    logic                lookup_clients;
    logic [WbufPtrW-1:0] rsp_slot;
  } wbuf_ent_t;

  wbuf_ent_t wbuf[WbufDepth];
  logic [WbufPtrW-1:0] aw_wptr;  // next AW capture slot
  logic [WbufPtrW-1:0] w_wptr;  // next W capture slot (trails aw_wptr)
  logic [WbufPtrW-1:0] d_rptr;  // drain head slot
  logic put_push_ready, put_pop_valid, burst_put_pop_valid, burst_forward_pop_valid;
  logic put_claim_fire;
  logic put_list_free;
  logic [WbufPtrW-1:0] put_list_alloc, put_push_list, put_pop_list, burst_put_list;
  logic [WbufDepth-1:0] put_list_claimed;
  logic [XLEN-1:0] put_pop_data, drain_wdata;
  logic [XLEN/8-1:0] put_pop_mask, drain_wstrb;
  logic put_pop_last, drain_wlast;
  logic [WbufDepth-1:0] put_list_valid;
  logic [ WbufPtrW-1:0] dir_aw_slot_q;
  logic w_lookup_now, w_lookup_ready, w_lookup_hit;
  logic [WayBits-1:0] w_lookup_way;

  always_ff @(posedge clock) begin
    if (reset) begin
      dir_result_for_aw_q <= 1'b0;
      dir_result_for_error_q <= 1'b0;
      dir_result_for_burst_q <= 1'b0;
      dir_aw_slot_q <= '0;
    end else if (dir_read_valid && dir_read_ready) begin
      dir_result_for_aw_q <= dir_aw_read_fire;
      dir_result_for_error_q <= dir_error_lookup_request;
      dir_result_for_burst_q <= dir_burst_read_valid || dir_burst_alloc_read_fire;
      if (dir_aw_read_fire) dir_aw_slot_q <= aw_wptr;
    end else begin
      dir_result_for_aw_q <= 1'b0;
      dir_result_for_error_q <= 1'b0;
      dir_result_for_burst_q <= 1'b0;
    end
  end
  assign w_lookup_now = BoomBankedStore && dir_result_valid && dir_result_for_aw_q
      && dir_aw_slot_q == w_wptr;
  assign w_lookup_ready = wbuf[w_wptr].lookup_ready || w_lookup_now;
  assign w_lookup_hit = w_lookup_now ? dir_result_hit : wbuf[w_wptr].lookup_hit;
  assign w_lookup_way = w_lookup_now ? dir_result_way : wbuf[w_wptr].lookup_way;

  // BOOM SinkA claims the lowest free list on the first data beat. AXI AW can
  // precede W, so the descriptor does not claim a list until W is accepted.
  always_comb begin
    put_list_free  = 1'b0;
    put_list_alloc = '0;
    for (int list = WbufDepth - 1; list >= 0; list--) begin
      if (!put_list_claimed[list]) begin
        put_list_free  = 1'b1;
        put_list_alloc = WbufPtrW'(list);
      end
    end
  end
  assign put_push_list = burst_active
      ? (burst_input_started ? burst_put_list : put_list_alloc) : put_list_alloc;
  assign put_claim_fire = BoomBankedStore && axi_s.wvalid && axi_s.wready
      && (!burst_active || !burst_input_started);
  always_ff @(posedge clock) begin
    if (reset) put_list_claimed <= '0;
    else if (BoomBankedStore) begin
      if (put_pop_valid && put_pop_last) put_list_claimed[put_pop_list] <= 1'b0;
      if (put_claim_fire) put_list_claimed[put_list_alloc] <= 1'b1;
    end
  end

  if (BoomBankedStore) begin : g_put_buffer
    rapt_l2_put_buffer #(
        .Xlen(XLEN),
        .NumLists(WbufDepth),
        .NumBeats(40)
    ) u_put_buffer (
        .clock,
        .reset,
        .push_valid(axi_s.wvalid && axi_s.wready),
        .push_ready(put_push_ready),
        .push_list (put_push_list),
        .push_data (axi_s.wdata),
        .push_mask (axi_s.wstrb),
        .push_last (axi_s.wlast),
        .pop_valid (put_pop_valid),
        .pop_list  (put_pop_list),
        .pop_data  (put_pop_data),
        .pop_mask  (put_pop_mask),
        .pop_last  (put_pop_last),
        .list_valid(put_list_valid)
    );
  end else begin : g_no_put_buffer
    assign put_push_ready = 1'b1;
    assign put_pop_data   = '0;
    assign put_pop_mask   = '0;
    assign put_pop_last   = 1'b0;
    assign put_list_valid = '0;
  end
  assign drain_wdata = BoomBankedStore ? put_pop_data : wbuf[d_rptr].wdata;
  assign drain_wstrb = BoomBankedStore ? put_pop_mask : wbuf[d_rptr].wstrb;
  assign drain_wlast = BoomBankedStore ? put_pop_last : wbuf[d_rptr].wlast;

  // Posted-B id FIFO (one id per W beat captured; consumed on upstream bready).
  logic [ID_W-1:0] b_id_q[WbufDepth];
  logic [1:0] b_resp_q[WbufDepth];
  logic b_ready_q[WbufDepth];
  logic [WbufPtrW-1:0] b_wptr;
  logic [WbufPtrW-1:0] b_rptr;
  logic [WbufPtrW-1:0] burst_rsp_slot;
  logic [WbufPtrW-1:0] forward_log_rsp_slot;
  logic [WbufCntW-1:0] b_count;
  logic bq_full;
  logic [WbufDepth-1:0] forward_b_pending;
  logic [WbufDepth-1:0] forward_b_candidate, forward_b_after_head;
  logic forward_b_match;
  logic [WbufPtrW-1:0] forward_b_slot;
  assign bq_full = (b_count == WbufCntW'(WbufDepth));

  // Outer B may return after a later forwarded burst has taken the active
  // slot. Compare fixed slots in parallel, then choose the lowest matching
  // index at or after b_rptr, wrapping to the lowest index if needed. This
  // preserves the oldest matching slot without a rotating array read mux.
  for (genvar slot = 0; slot < WbufDepth; slot++) begin : g_forward_b_candidate
    assign forward_b_candidate[slot] = forward_b_pending[slot] && b_id_q[slot] == axi_m.bid;
    if (slot == (1 << WbufPtrW) - 1) begin : g_last_encodable_slot
      // Every pointer value is at or before the largest encodable slot.
      assign forward_b_after_head[slot] = forward_b_candidate[slot];
    end else begin : g_compare_head
      assign forward_b_after_head[slot] = forward_b_candidate[slot] && WbufPtrW'(slot) >= b_rptr;
    end
  end
  always_comb begin
    forward_b_match = 1'b0;
    forward_b_slot  = '0;
    for (int slot = WbufDepth - 1; slot >= 0; slot--) begin
      if (forward_b_after_head[slot]) begin
        forward_b_match = 1'b1;
        forward_b_slot  = WbufPtrW'(slot);
      end
    end
    if (!forward_b_match) begin
      for (int slot = WbufDepth - 1; slot >= 0; slot--) begin
        if (forward_b_candidate[slot]) begin
          forward_b_match = 1'b1;
          forward_b_slot  = WbufPtrW'(slot);
        end
      end
    end
  end
  assign forward_replay_b_match = forward_b_match && forward_cache_pending
      && forward_b_slot == forward_log_rsp_slot && axi_m.bresp == 2'b00;
  assign forward_log_wdata.addr = ForwardLogAddrBits'(rapt_pkg::canonical_addr(burst_addr));
  assign forward_log_wdata.way = burst_lookup_way;
  assign forward_log_wdata.clients = burst_lookup_clients;
  assign forward_log_wdata.data = axi_s.wdata;
  assign forward_log_wdata.mask = axi_s.wstrb;
  always_ff @(posedge clock) begin
    if (forward_log_push) forward_log_mem[forward_log_count[7:0]] <= forward_log_wdata;
    if (forward_replay_state == F_FETCH) forward_log_rdata <= forward_log_mem[forward_replay_index];
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      forward_cache_pending <= 1'b0;
      forward_log_count <= '0;
      forward_log_rsp_slot <= '0;
      forward_replay_index <= '0;
      forward_replay_probed_valid <= 1'b0;
      forward_replay_probed_line <= '0;
      forward_replay_state <= F_IDLE;
    end else begin
      if (axi_s.awvalid && axi_s.awready && axi_s.awlen != 0 && !burst_alloc_needs_read)
        forward_log_count <= '0;
      if (forward_log_push) begin
        forward_cache_pending <= 1'b1;
        forward_log_count <= forward_log_count + 1'b1;
      end
      if (burst_write_fire && axi_s.wlast && (forward_cache_pending || forward_log_push))
        forward_log_rsp_slot <= b_wptr;
      unique case (forward_replay_state)
        F_IDLE:
        if (axi_m.bvalid && forward_replay_b_match) begin
          forward_replay_index <= '0;
          forward_replay_probed_valid <= 1'b0;
          forward_replay_state <= F_FETCH;
        end
        F_FETCH: forward_replay_state <= F_APPLY;
        F_PROBE:
        if (forward_replay_probe_request && probe_ready_i) begin
          forward_replay_probed_valid <= 1'b1;
          forward_replay_probed_line <= forward_log_rdata.addr[ForwardLogAddrBits-1:OffsetBits];
          forward_replay_state <= F_APPLY;
        end
        F_APPLY:
        if (forward_log_rdata.clients && !forward_replay_line_probed)
          forward_replay_state <= F_PROBE;
        else if (forward_replay_commit) begin
          if ({1'b0, forward_replay_index} + 9'd1 == forward_log_count)
            forward_replay_state <= F_DONE;
          else begin
            forward_replay_index <= forward_replay_index + 1'b1;
            forward_replay_state <= F_FETCH;
          end
        end
        F_DONE:
        if (axi_m.bvalid && axi_m.bready && forward_replay_b_match) begin
          forward_cache_pending <= 1'b0;
          forward_log_count <= '0;
          forward_replay_probed_valid <= 1'b0;
          forward_replay_state <= F_IDLE;
        end
        default: forward_replay_state <= F_IDLE;
      endcase
      if (axi_m.bvalid && axi_m.bready && forward_b_match && forward_cache_pending
          && forward_b_slot == forward_log_rsp_slot && axi_m.bresp != 2'b00) begin
        forward_cache_pending <= 1'b0;
        forward_log_count <= '0;
        forward_replay_probed_valid <= 1'b0;
        forward_replay_state <= F_IDLE;
      end
    end
  end
`ifdef RAPT_ASSERT_EN
  always_ff @(posedge clock) begin
    if (!reset && forward_log_push)
      assert (forward_log_count < 9'(ForwardLogDepth))
      else $fatal(1, "L2 forwarded hit journal exceeded the AXI burst limit");
  end
`endif
`ifdef RAPT_ASSERT_EN
  always_ff @(posedge clock) begin : p_forward_b_oldest
    int unsigned slot;
    logic reference_match;
    logic [WbufPtrW-1:0] reference_slot;
    if (!reset) begin
      reference_match = 1'b0;
      reference_slot  = '0;
      for (int offset = 0; offset < WbufDepth; offset++) begin
        slot = int'(b_rptr) + offset;
        if (slot >= WbufDepth) slot -= WbufDepth;
        if (!reference_match && forward_b_pending[slot] && b_id_q[slot] == axi_m.bid) begin
          reference_match = 1'b1;
          reference_slot  = WbufPtrW'(slot);
        end
      end
      assert (forward_b_match == reference_match
              && (!reference_match || forward_b_slot == reference_slot))
      else $fatal(1, "L2 forwarded B response did not select oldest matching slot");
    end
  end
`endif

  // Any-busy: used to serialize reads vs all in-flight writes (AXI memory
  // models may reorder AR vs same- or other-line AW).
  logic read_bypass_in_progress;
  logic [WbufDepth-1:0] wbuf_busy, wbuf_miss_or_unknown, wbuf_forward_scalar;
  for (genvar slot = 0; slot < WbufDepth; slot++) begin : g_wbuf_status
    assign wbuf_busy[slot] = wbuf[slot].busy;
    assign wbuf_miss_or_unknown[slot] = wbuf[slot].busy
        && (!wbuf[slot].lookup_ready || !wbuf[slot].lookup_hit);
    assign wbuf_forward_scalar[slot] = wbuf[slot].busy && wbuf[slot].forward_scalar;
  end
  assign any_write_in_flight = burst_active || |wbuf_busy || |forward_b_pending;
  assign boom_queued_miss_or_unknown = |wbuf_miss_or_unknown;
  assign forward_scalar_pending = |wbuf_forward_scalar;
  assign forward_scalar_head = wbuf_forward_scalar[d_rptr] && wbuf[d_rptr].has_w;
  assign read_bypass_in_progress = (rs == R_BYPASS_WAIT) || (rs == R_BYPASS_AR)
                                 || (rs == R_BYPASS_R);

  // Snoop hit-merge: fires when a W beat is captured into wbuf[w_wptr].
  // The AW directory result is held in that slot if W arrives later.
  logic [IndexBits-1:0] w_idx_q;
  logic [TagBits-1:0] w_tag_q;
  logic w_hit_q;
  logic [WayBits-1:0] w_hit_way;
  logic [L2_LINE_LEN-1:0] w_word_now;
  logic w_full_strobe;
  logic w_cache_word_write;
  logic release_word_request;
  logic bank_priority_word_valid;
  logic [IndexBits-1:0] bank_priority_set;
  logic [WayBits-1:0] bank_priority_way;
  logic [L2_LINE_LEN-1:0] bank_priority_word;
  logic bank_write_word_valid;
  logic bank_write_word_ready;
  logic burst_put_word_valid, store_merge_word_valid;
  logic [IndexBits-1:0] bank_write_set;
  logic [WayBits-1:0] bank_write_way;
  logic [L2_LINE_LEN-1:0] bank_write_word;
  assign w_snoop_addr = wbuf[w_wptr].addr;
  assign w_idx_q = w_snoop_addr[IndexMsb:IndexLsb];
  assign w_tag_q = TagBits'(rapt_pkg::canonical_addr(w_snoop_addr) >> TagLsb);
  always_comb begin
    w_hit_q   = 1'b0;
    w_hit_way = '0;
    if (BoomBankedStore) begin
      w_hit_way = w_lookup_way;
      w_hit_q   = w_lookup_ready && w_lookup_hit;
    end else begin
      for (int way = 0; way < L2_N_WAYS; way++) begin
        if (line_valid[way][w_idx_q] && line_tag[way][w_idx_q] == w_tag_q) begin
          w_hit_q   = 1'b1;
          w_hit_way = WayBits'(way);
        end
      end
    end
  end
  assign w_word_now = w_snoop_addr[WordOffsetMsb:WordOffsetLsb];
  assign w_full_strobe = &axi_s.wstrb;
  assign w_cache_word_write = (w_hit_update || burst_direct_hit_pop
      || forward_scalar_write_request || forward_replay_request)
      && (BoomBankedStore || w_full_strobe);
  assign probe_release_ready_o = BoomBankedStore && probe_release_valid_i
      && probe_valid_o && same_line(
      probe_release_addr_i, probe_addr_o
  ) && !release_word_request;
  assign probe_release_fire = probe_release_valid_i && probe_release_ready_o;
  assign bank_priority_word_valid = release_word_fire || probe_release_fire;
  assign bank_priority_set = release_word_fire ? release_head_addr[IndexMsb:IndexLsb]
      : probe_release_addr_i[IndexMsb:IndexLsb];
  assign bank_priority_way = release_word_fire ? release_way_q
      : cbo_state == C_PROBE ? cbo_way
      : forward_replay_state == F_PROBE ? forward_log_rdata.way
      : forward_scalar_probe_request ? error_lookup_way_q : victim_way_q;
  assign bank_priority_word = release_word_fire ? release_word
      : probe_release_addr_i[WordOffsetMsb:WordOffsetLsb];
  assign burst_put_word_valid = BoomBankedStore && rs == R_BURST_PUT_WRITE
      && (burst_all_full || |burst_mask_buf[r_fill_cnt]);
  assign store_merge_word_valid = BoomBankedStore && rs == R_STORE_MERGE_WRITE;
  assign bank_write_word_valid = w_cache_word_write || burst_put_word_valid
      || store_merge_word_valid;
  assign bank_write_set = burst_put_word_valid || store_merge_word_valid ? r_idx_q
      : forward_replay_request ? forward_log_rdata.addr[IndexMsb:IndexLsb]
      : forward_scalar_write_request ? wbuf[d_rptr].addr[IndexMsb:IndexLsb]
      : burst_direct_hit ? burst_start[IndexMsb:IndexLsb]
      : burst_active && !burst_allocate ? burst_addr[IndexMsb:IndexLsb] : w_idx_q;
  assign bank_write_way = burst_put_word_valid || store_merge_word_valid ? r_selected_way
      : forward_replay_request ? forward_log_rdata.way
      : forward_scalar_write_request ? error_lookup_way_q
      : burst_active ? burst_lookup_way : w_hit_way;
  assign bank_write_word = store_merge_word_valid ? r_word
      : burst_put_word_valid ? r_fill_cnt
      : forward_replay_request ? forward_log_rdata.addr[WordOffsetMsb:WordOffsetLsb]
      : forward_scalar_write_request ? wbuf[d_rptr].addr[WordOffsetMsb:WordOffsetLsb]
      : burst_direct_hit ? burst_fill_count
      : burst_active && !burst_allocate ? burst_addr[WordOffsetMsb:WordOffsetLsb] : w_word_now;
`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset && BoomBankedStore && w_cache_word_write)
      assert (bank_write_word_ready)
      else $error("accepted L2 store lost its data-bank write to SinkC");
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) r_lookup_killed <= 1'b0;
    else if ((dir_demand_read_valid && dir_read_ready)
             || (ms_replay_issue && ms_replay_use_metadata))
      r_lookup_killed <= 1'b0;
    else if (dir_error_inv && same_line(wbuf[d_rptr].addr, r_addr))
      // A directory result may be held while the data bank is read or the
      // upstream R channel stalls. Do not use it after its line is invalid.
      r_lookup_killed <= 1'b1;
  end

  // The BOOM-layout store has four banks selected by line chunk. Its
  // read-ready contract permits a hit read alongside a write to another
  // bank; the legacy word banks serialize full-word store updates.
  //   * cache_install fires while the read FSM sits in R_INSTALL_WAIT --
  //     the read port is idle, no conflict.
  //   * w_hit_update can fire mid-R_HIT (store drain concurrent with an
  //     unrelated read burst). The write then wins the port and the read
  //     address register is clobbered; R_HIT stalls for exactly one cycle
  //     (see l2_sram_wblock below) while the read address is re-latched.
  assign l2_sram_wblock = BoomBankedStore
                          ? (rs == R_EVICT_READ ? !boom_bank_sourcec_ready : !boom_bank_read_ready)
                          : cache_install || w_cache_word_write;

  generate
    if (BoomBankedStore) begin : g_boom_banked_store
      logic [511:0] read_line_data, install_line_data;
      logic [63:0] priority_data, store_data, sink_d_data;
      logic [63:0] source_c_data;
      logic [7:0] priority_mask, store_mask, sink_d_mask;
      logic bank_read;
      assign bank_read = (rs == R_HIT && r_hit_q || rs == R_INSTALL_READ
                          || rs == R_STORE_MERGE_READ
                          || rs == R_BURST_HIT_READ
                          || rs == R_BURST_HIT_MERGE
                                 && r_fill_cnt != L2_LINE_LEN'(LineSize - 1)
                          || cbo_state == C_READ || ms_source_read_request);
      if (XLEN == 64) begin : g_sourcec_64
        assign boom_bank_sourcec_word = source_c_data;
      end else begin : g_sourcec_32
        assign boom_bank_sourcec_word = evict_word[0] ? source_c_data[63:32] : source_c_data[31:0];
      end
      for (genvar chunk = 0; chunk < 8; chunk++) begin : g_install_chunk
        if (XLEN == 64) begin : g_64bit_beat
          assign install_line_data[chunk*64+:64] = r_burst_fill && burst_all_full
              ? burst_line_buf[chunk] : r_line_buf[chunk];
        end else begin : g_32bit_beat
          assign install_line_data[chunk*64+:64] = r_burst_fill && burst_all_full
              ? {burst_line_buf[chunk*2+1], burst_line_buf[chunk*2]}
              : {r_line_buf[chunk*2+1], r_line_buf[chunk*2]};
        end
      end
      if (XLEN == 64) begin : g_64bit_store
        assign priority_data = release_word_fire ? release_head_data : probe_release_data_i;
        assign priority_mask = 8'hff;
        assign store_data = store_merge_word_valid ? r_store_merge_data
            : burst_put_word_valid ? (burst_all_full ? burst_line_buf[r_fill_cnt]
                                                     : r_line_buf[r_fill_cnt])
            : forward_replay_request ? forward_log_rdata.data
            : forward_scalar_write_request ? wbuf[d_rptr].wdata
            : burst_direct_hit ? put_pop_data : axi_s.wdata;
        assign store_mask = store_merge_word_valid || burst_put_word_valid ? 8'hff
            : forward_replay_request ? forward_log_rdata.mask
            : forward_scalar_write_request ? wbuf[d_rptr].wstrb
            : burst_direct_hit ? put_pop_mask : axi_s.wstrb;
        assign sink_d_data = axi_m.rdata;
        assign sink_d_mask = 8'hff;
      end else begin : g_32bit_store
        assign priority_data = release_word_fire ? {2{release_head_data}}
            : {2{probe_release_data_i}};
        assign priority_mask = bank_priority_word[0] ? 8'hf0 : 8'h0f;
        assign store_data = {2{store_merge_word_valid ? r_store_merge_data
                                  : burst_put_word_valid ? (burst_all_full ? burst_line_buf[r_fill_cnt]
                                                                             : r_line_buf[r_fill_cnt])
                                  : forward_replay_request ? forward_log_rdata.data
                                  : forward_scalar_write_request ? wbuf[d_rptr].wdata
                                  : burst_direct_hit ? put_pop_data : axi_s.wdata}};
        assign store_mask = bank_write_word[0]
            ? {(store_merge_word_valid || burst_put_word_valid ? 4'hf
                 : forward_replay_request ? forward_log_rdata.mask
                 : forward_scalar_write_request ? wbuf[d_rptr].wstrb
                 : burst_direct_hit ? put_pop_mask : axi_s.wstrb), 4'b0}
            : {4'b0, (store_merge_word_valid || burst_put_word_valid ? 4'hf
                     : forward_replay_request ? forward_log_rdata.mask
                     : forward_scalar_write_request ? wbuf[d_rptr].wstrb
                     : burst_direct_hit ? put_pop_mask : axi_s.wstrb)};
        assign sink_d_data = {2{axi_m.rdata}};
        assign sink_d_mask = bank_sinkd_word[0] ? 8'hf0 : 8'h0f;
      end
      rapt_l2_data_array u_data_array (
          .clock,
          .reset,
          .read_valid(bank_read),
          .read_all_chunks(1'b0),
          .read_ready(boom_bank_read_ready),
          .read_set(ms_source_read_request ? ms_source_set
                    : cbo_state == C_READ ? cbo_active_set
                    : rs == R_INSTALL_READ ? install_idx : r_idx_q),
          .read_way(ms_source_read_request ? ms_source_way
                    : cbo_state == C_READ ? cbo_way
                    : rs == R_INSTALL_READ ? install_way
                    : rs == R_STORE_MERGE_READ || rs == R_BURST_HIT_READ
                        || rs == R_BURST_HIT_MERGE ? r_selected_way
                    : rs == R_EVICT_READ ? victim_way_q : r_hit_way),
          .read_chunk(ms_source_read_request ? ms_source_chunk
                    : 3'((cbo_state == C_READ ? int'(cbo_word)
                          : rs == R_EVICT_READ ? int'(evict_word)
                          : rs == R_BURST_HIT_MERGE ? int'(r_fill_cnt) + 1
                          : rs == R_BURST_HIT_READ ? int'(r_fill_cnt) : int'(r_word))
                         / (64 / XLEN))),
          .read_result_valid(boom_bank_read_result_valid),
          .read_line_data,
          .source_c_read_valid(rs == R_EVICT_READ),
          .source_c_read_ready(boom_bank_sourcec_ready),
          .source_c_read_set(r_idx_q),
          .source_c_read_way(victim_way_q),
          .source_c_read_chunk(3'(int'(evict_word) / (64 / XLEN))),
          .source_c_result_valid(),
          .source_c_read_data(source_c_data),
          .sink_d_write_valid(bank_sinkd_valid),
          .sink_d_write_ready(boom_bank_sinkd_ready),
          .sink_d_write_set(bank_sinkd_set),
          .sink_d_write_way(bank_sinkd_way),
          .sink_d_write_chunk(3'(int'(bank_sinkd_word) / (64 / XLEN))),
          .sink_d_write_data(sink_d_data),
          .sink_d_write_mask(sink_d_mask),
          .write_line_valid(cache_install && !install_streamed),
          .write_line_busy(boom_bank_line_busy),
          .write_line_set(install_idx),
          .write_line_way(install_way),
          .write_line_data(install_line_data),
          .priority_write_valid(bank_priority_word_valid),
          .priority_write_set(bank_priority_set),
          .priority_write_way(bank_priority_way),
          .priority_write_chunk(3'(int'(bank_priority_word) / (64 / XLEN))),
          .priority_write_data(priority_data),
          .priority_write_mask(priority_mask),
          .write_word_valid(bank_write_word_valid),
          .write_word_ready(bank_write_word_ready),
          .write_word_set(bank_write_set),
          .write_word_way(bank_write_way),
          .write_word_chunk(3'(int'(bank_write_word) / (64 / XLEN))),
          .write_word_data(store_data),
          .write_word_mask(store_mask)
      );
      for (genvar way = 0; way < L2_N_WAYS; way++) begin : g_read_way
        for (genvar word = 0; word < LineSize; word++) begin : g_read_word
          localparam int Chunk = word / (64 / XLEN);
          if (XLEN == 64) begin : g_64bit_beat
            assign line_data_r[way][word] = read_line_data[Chunk*64+:64];
          end else begin : g_32bit_beat
            if (word % 2 == 0) begin : g_low_half
              assign line_data_r[way][word] = read_line_data[Chunk*64+:32];
            end else begin : g_high_half
              assign line_data_r[way][word] = read_line_data[Chunk*64+32+:32];
            end
          end
        end
      end
    end else begin : g_legacy_banked_store
      assign boom_bank_read_ready = 1'b1;
      assign boom_bank_read_result_valid = 1'b0;
      assign boom_bank_sourcec_ready = 1'b1;
      assign boom_bank_sinkd_ready = 1'b1;
      assign boom_bank_sourcec_word = '0;
      assign boom_bank_line_busy = 1'b0;
      assign bank_write_word_ready = 1'b1;
      for (genvar gw = 0; gw < L2_N_WAYS; gw++) begin : gen_data_way
        for (genvar gi = 0; gi < LineSize; gi++) begin : gen_data_bank
          logic bank_store_wen;
          logic bank_wen;
          assign bank_store_wen = w_hit_update && w_full_strobe && (w_hit_way == WayBits'(gw))
                                && (w_word_now == L2_LINE_LEN'(gi));
          assign bank_wen = (cache_install && install_way == WayBits'(gw)) || bank_store_wen;
          rapt_sram_1rw #(
              .ADDR_WIDTH(L2_LEN),
              .DATA_WIDTH(XLEN),
              .INST_ID(200 + gw * LineSize + gi),
              .USE_BWE(0)
          ) u_data_sram (
              .clock(clock),
              .en   (1'b1),
              .wen  (bank_wen),
              .addr (bank_wen ? (cache_install ? install_idx : w_idx_q)
                              : data_sram_raddr),
              .rdata(line_data_r[gw][gi]),
              .wdata(cache_install ? r_line_buf[gi] : axi_s.wdata),
              .bwe  ({(XLEN/8){1'b1}})
          );
        end
      end
    end
  endgenerate

  // Drain FSM placed before the read FSM because read miss-issue
  // serializes against write activity to avoid AR/AW ordering races.
  typedef enum logic [1:0] {
    W_IDLE,
    W_AW,    // legacy slot -- unused with combinational AW drive; kept for clarity
    W_W,
    W_B
  } state_w_t;

  state_w_t ws;
  assign burst_direct_hit = BoomBankedStore && burst_active && burst_allocate
      && burst_lookup_ready && burst_lookup_hit && burst_lookup_state[1]
      && !burst_lookup_clients;
  assign burst_pop_next_addr = advance_read_addr(
      burst_pop_addr, burst_size, burst_kind, burst_wrap_mask
  );
  // BOOM's non-flowing Put list can empty between incoming W beats. Keep the
  // list claimed until its last beat is popped. Stop at each line boundary
  // until that segment commits, then re-read the next line's directory entry.
  assign burst_put_pop_valid = BoomBankedStore && burst_active && burst_allocate
      && burst_input_started && !burst_w_done && put_list_valid[burst_put_list]
      && (rs == R_BURST_ERROR
          || (!burst_segment_ready && burst_lookup_ready
              && (!burst_direct_hit || bank_write_word_ready)));
  assign burst_direct_hit_pop = burst_put_pop_valid && burst_direct_hit && rs != R_BURST_ERROR;
  assign burst_forward_pop_valid = BoomBankedStore && burst_active && !burst_allocate
      && !burst_aw_pending && !burst_w_done && burst_input_started
      && put_list_valid[burst_put_list] && axi_m.wvalid && axi_m.wready;
  assign put_pop_list = burst_put_pop_valid || burst_forward_pop_valid
      ? burst_put_list : wbuf[d_rptr].put_list;
  assign put_pop_valid = burst_put_pop_valid || burst_forward_pop_valid
      || (BoomBankedStore && !burst_active && wbuf[d_rptr].busy && wbuf[d_rptr].has_w
          && ((ws == W_IDLE && (rs == R_STORE_DONE || rs == R_STORE_ERROR
                              || wbuf[d_rptr].local_hit))
              || (ws == W_B && axi_m.bvalid && axi_m.bready)));
  typedef enum logic [1:0] {
    E_IDLE,
    E_RESULT,
    E_WRITE
  } error_lookup_state_t;
  error_lookup_state_t error_lookup_state;
  logic error_lookup_hit_q;
  logic error_lookup_clients_q;
  logic write_response_error;
  assign write_response_error = ws == W_B && axi_m.bvalid && axi_m.bready
      && rs != R_EVICT_B && cbo_state != C_B && axi_m.bresp != 2'b00;
  assign write_error_idx = wbuf[d_rptr].addr[IndexMsb:IndexLsb];
  assign write_error_tag = TagBits'(rapt_pkg::canonical_addr(wbuf[d_rptr].addr) >> TagLsb);
  assign dir_error_pending = BoomBankedStore && ws == W_B && axi_m.bvalid
      && ((axi_m.bresp != 2'b00 && !forward_scalar_head)
          || (axi_m.bresp == 2'b00 && forward_scalar_head));
  assign dir_error_lookup_request = dir_error_pending && error_lookup_state == E_IDLE
      && !dir_demand_read_valid && dir_read_ready && !cache_install;
  always_ff @(posedge clock) begin
    if (reset) begin
      error_lookup_state <= E_IDLE;
      error_lookup_hit_q <= 1'b0;
      error_lookup_way_q <= '0;
      error_lookup_clients_q <= 1'b0;
    end else begin
      unique case (error_lookup_state)
        E_IDLE:  if (dir_error_lookup_request) error_lookup_state <= E_RESULT;
        E_RESULT:
        if (dir_result_valid && dir_result_for_error_q) begin
          error_lookup_hit_q <= dir_result_hit;
          error_lookup_way_q <= dir_result_way;
          error_lookup_clients_q <= dir_result_clients;
          error_lookup_state <= E_WRITE;
        end
        E_WRITE: if (axi_m.bvalid && axi_m.bready) error_lookup_state <= E_IDLE;
        default: error_lookup_state <= E_IDLE;
      endcase
    end
  end
  always_comb begin
    if (BoomBankedStore) begin
      dir_error_hit = error_lookup_hit_q;
      dir_error_way = error_lookup_way_q;
    end else begin
      dir_error_hit = 1'b0;
      dir_error_way = '0;
      for (int way = 0; way < L2_N_WAYS; way++) begin
        if (line_valid[way][write_error_idx]
            && line_tag[way][write_error_idx] == write_error_tag) begin
          dir_error_hit = 1'b1;
          dir_error_way = WayBits'(way);
        end
      end
    end
  end
  assign dir_error_inv = BoomBankedStore && write_response_error && dir_error_hit
      && !forward_scalar_head;
  // AXI non-bufferable cacheable scalar stores must wait for the real B.
  // Keep older dirty bytes intact if that B fails; on success, apply the
  // saved W beat to the line found by the fresh directory lookup.
  // A D-client owner must release the old copy before the saved W beat can
  // change L2, even though the outer write has already completed.
  assign forward_scalar_probe_request = forward_scalar_head && ws == W_B
      && axi_m.bvalid && axi_m.bresp == 2'b00
      && error_lookup_state == E_WRITE && error_lookup_hit_q && error_lookup_clients_q
      && !forward_scalar_probe_done && rs == R_IDLE && !rs_rvalid
      && !cache_install && !ms_busy && cbo_state == C_IDLE
      && release_state == REL_IDLE && !release_pending && !burst_active;
  always_ff @(posedge clock) begin
    if (reset) forward_scalar_probe_done <= 1'b0;
    else if (ws == W_B && axi_m.bvalid && axi_m.bready && forward_scalar_head)
      forward_scalar_probe_done <= 1'b0;
    else if (forward_scalar_probe_request && probe_ready_i) forward_scalar_probe_done <= 1'b1;
  end
  assign forward_scalar_write_request = forward_scalar_head && ws == W_B
      && axi_m.bvalid && axi_m.bresp == 2'b00
      && error_lookup_state == E_WRITE && error_lookup_hit_q
      && (!error_lookup_clients_q || forward_scalar_probe_done)
      && rs == R_IDLE && !rs_rvalid && !cache_install && !ms_busy
      && cbo_state == C_IDLE && !release_pending && release_state == REL_IDLE && !burst_active
      && !boom_bank_line_busy && dir_write_ready;
  assign forward_scalar_commit = forward_scalar_write_request && bank_write_word_ready;
  assign forward_replay_request = forward_replay_state == F_APPLY
      && axi_m.bvalid && forward_replay_b_match
      && (!forward_log_rdata.clients || forward_replay_line_probed)
      && rs == R_IDLE && !rs_rvalid && !cache_install && !ms_busy
      && cbo_state == C_IDLE && !release_pending && release_state == REL_IDLE && !burst_active
      && !boom_bank_line_busy && dir_write_ready;
  assign forward_replay_commit = forward_replay_request && bank_write_word_ready;
  assign forward_scalar_release_preempt = forward_scalar_head && ws == W_B
      && axi_m.bvalid && axi_m.bresp == 2'b00 && error_lookup_state == E_WRITE;
  // A forwarded burst has no local bank writes until its outer B. Once a
  // previous W lookup finishes, C may borrow the directory between W beats.
  assign release_forward_active_preempt = burst_active && !burst_allocate
      && !burst_lookup_pending;
  assign hit_probe_active = rs == R_HIT_PROBE || rs == R_HIT_PROBE_COMMIT;
  assign release_probe_preempt = rs == R_EVICT_PROBE || hit_probe_active || cbo_state == C_PROBE;
  assign release_lookup_candidate = BoomBankedStore && release_state == REL_IDLE
      && release_head_valid && wipe_done && dir_ready && dir_read_ready
      && !release_same_line_pending
      && (rs == R_IDLE || rs == R_EVICT_PROBE || hit_probe_active)
      && (cbo_state == C_IDLE || rs == R_IDLE && cbo_state == C_PROBE)
      && (!rs_rvalid || release_probe_preempt)
      && !cache_install && !boom_bank_line_busy
      // A forwarded resident-hit burst holds outer B until its journal
      // replays. L1D can be waiting for this ReleaseAck before it can answer
      // the journal's Probe, so C may use the directory once W has drained.
      && ((!any_write_in_flight && b_count == 0)
          || (forward_cache_pending && !burst_active && !(|wbuf_busy)
              && |forward_b_pending)
          || release_forward_active_preempt
          || forward_scalar_release_preempt
          || release_probe_preempt)
      && (!dir_error_pending || forward_scalar_release_preempt);
  // C's first lookup blocks new primary AR and AW; an independent secondary
  // may only enter its queue. The other lookup sources are excluded by the
  // read/burst/error state terms above. Avoid feeding their ready signals
  // back through the scheduler into this C request.
  assign release_lookup_fire = release_lookup_candidate
      && ms_secondary_schedule_onehot[BoomMshrs-1];
  // SinkC has priority over line installs and resident store writes. Different
  // SRAM banks can write on the same edge; a displaced install bank retries.
  assign release_word_request = release_state == REL_DATA && release_head_has_data
      && release_head_word_valid && release_head_mask
      && (!release_nested_q
          || ms_beat_valid[int'(release_nested_slot_q)][release_word]);
  assign release_word_fire = release_word_request;
  assign release_word_step = release_state == REL_DATA
      && release_head_word_valid && (!release_head_mask || release_word_fire);
  assign release_dir_write_candidate = release_state == REL_DIRECTORY
      && release_head_complete && dir_write_ready && !cache_install && !dir_error_inv && !w_hit_update
      && !burst_hit_update && !cbo_exact_invalidate && !dir_client_mark
      && (!release_nested_q
          || (ms_slot_done[int'(release_nested_slot_q)]
              && ms_slot_resp[int'(release_nested_slot_q)] == 2'b00));
  assign release_dir_write_fire = release_dir_write_candidate
      && ms_secondary_schedule_onehot[BoomMshrs-1];
  assign release_nested_retry = BoomBankedStore && release_nested_q
      && ms_slot_done[int'(release_nested_slot_q)]
      && ms_slot_resp[int'(release_nested_slot_q)] != 2'b00;
  assign ms_refill_retry = release_nested_retry || ms_failed_early_retry;
  assign ms_refill_retry_slot = release_nested_retry ? release_nested_slot_q
      : ms_failed_early_retry_slot;
  always_ff @(posedge clock) begin
    if (reset) begin
      release_state <= REL_IDLE;
      release_word <= '0;
      release_way_q <= '0;
      release_dir_state_q <= '0;
      release_dir_dirty_q <= 1'b0;
      release_nested_q <= 1'b0;
      release_nested_slot_q <= '0;
    end else if (release_nested_retry) begin
      // SinkD may have overwritten earlier C words during this refill. Keep
      // the Release buffer until Ack and replay every C word over the retry.
      release_word  <= '0;
      release_state <= release_head_has_data ? REL_DATA : REL_DIRECTORY;
    end else begin
      unique case (release_state)
        REL_IDLE:
        if (release_lookup_fire) begin
          release_nested_q <= release_nested_candidate;
          if (release_nested_candidate) begin
            release_nested_slot_q <= release_nested_slot;
            release_way_q <= ms_way[int'(release_nested_slot)];
            release_dir_state_q <= 2'b11;
            release_dir_dirty_q <= 1'b0;
            release_word <= '0;
            release_state <= release_head_has_data ? REL_DATA : REL_DIRECTORY;
          end else release_state <= REL_LOOKUP;
        end
        REL_LOOKUP:
        if (dir_result_valid) begin
          if (dir_result_hit) begin
            release_way_q <= dir_result_way;
            release_dir_state_q <= dir_result_state;
            release_dir_dirty_q <= dir_result_dirty;
            release_word <= '0;
            release_state <= release_head_has_data ? REL_DATA : REL_DIRECTORY;
          end
        end
        REL_DATA:
        if (release_word_step) begin
          if (&release_word) release_state <= REL_DIRECTORY;
          else release_word <= release_word + 1'b1;
        end
        REL_DIRECTORY:
        if (release_dir_write_fire) begin
          release_nested_q <= 1'b0;
          release_state <= REL_IDLE;
        end
        default: release_state <= REL_IDLE;
      endcase
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset && release_state == REL_LOOKUP && dir_result_valid)
      assert (dir_result_hit)
      else $error("L1D released a line absent from inclusive L2");
    if (!reset && release_lookup_fire && !release_nested_candidate)
      assert (!(dir_demand_read_valid || dir_error_lookup_request || dir_aw_read_fire
                || dir_burst_read_valid || dir_burst_alloc_read_fire))
      else $error("reserved C lookup collided with another directory read");
    if (!reset && release_dir_write_fire && release_nested_q)
      assert (ms_slot_valid[int'(release_nested_slot_q)]
              && ms_slot_done[int'(release_nested_slot_q)]
              && !ms_installed[int'(release_nested_slot_q)])
      else $error("nested C Release lost its completed refill way");
  end
`endif
  assign cbo_exact_invalidate = BoomBankedStore && cbo_state == C_CLEAR
      && !cbo_active_broad && cbo_match;
  // A D-side read may hit a line installed earlier by an I-side read or a
  // store. Record its ownership before returning data to the L1D.
  assign dir_client_mark = BoomBankedStore && rs == R_HIT && r_hit_q && d_client_read_id(
      r_id
  ) && |r_cache[3:2] && !dir_lookup_clients && !r_client_marked && !cache_install && !dir_error_inv
      && !w_hit_update && !burst_hit_update && !cbo_exact_invalidate && !l2_sram_wblock;
  assign hit_probe_commit = BoomBankedStore && rs == R_HIT_PROBE_COMMIT
      && !release_pending && !cache_install && !dir_error_inv && !w_hit_update
      && !burst_hit_update && !cbo_exact_invalidate && dir_write_ready;
  assign burst_direct_commit = burst_direct_hit && burst_segment_ready && rs == R_IDLE
      && !ms_busy && !rs_rvalid && !cache_install && dir_write_ready
      && !dir_error_inv && !release_dir_write_fire && !cbo_exact_invalidate;
  assign dir_write_valid = BoomBankedStore
      && (release_dir_write_fire || hit_probe_commit || cache_install || ms_direct_complete
          || blocking_refill_invalidate || dir_error_inv
          || w_hit_update || burst_direct_commit || forward_scalar_commit
          || forward_replay_commit
          || cbo_exact_invalidate || dir_client_mark || ms_alloc_invalidate);
  assign dir_write_set = release_dir_write_fire ? release_head_addr[IndexMsb:IndexLsb]
      : hit_probe_commit ? r_idx_q
      : cache_install ? install_idx
      : ms_direct_complete ? ms_set[int'(ms_complete_slot)]
      : blocking_refill_invalidate ? r_idx_q
      : dir_error_inv ? write_error_idx
      : forward_replay_commit ? forward_log_rdata.addr[IndexMsb:IndexLsb]
      : forward_scalar_commit ? wbuf[d_rptr].addr[IndexMsb:IndexLsb]
      : cbo_exact_invalidate ? cbo_active_set
      : burst_direct_commit ? burst_start[IndexMsb:IndexLsb]
      : dir_client_mark || ms_alloc_invalidate ? r_idx_q : bank_write_set;
  assign dir_write_way = release_dir_write_fire ? release_way_q
      : hit_probe_commit ? victim_way_q
      : cache_install ? install_way
      : ms_direct_complete ? ms_way[int'(ms_complete_slot)]
      : blocking_refill_invalidate ? victim_way_q
      : dir_error_inv ? dir_error_way
      : forward_replay_commit ? forward_log_rdata.way
      : forward_scalar_commit ? error_lookup_way_q
      : cbo_exact_invalidate ? cbo_way
      : burst_direct_commit ? burst_lookup_way
      : dir_client_mark || ms_alloc_invalidate ? dir_lookup_way : bank_write_way;
  assign dir_write_tag = release_dir_write_fire ? TagBits'(rapt_pkg::canonical_addr(
      release_head_addr
  ) >> TagLsb) :
      hit_probe_commit ? r_tag_q : cache_install ? install_tag : ms_direct_complete ? TagBits'(rapt_pkg::canonical_addr(
      ms_line_addr[int'(ms_complete_slot)]
  ) >> TagLsb) : blocking_refill_invalidate ? victim_tag_q : dir_error_inv ? write_error_tag :
      cbo_exact_invalidate ? TagBits'(cbo_active_tag) : forward_replay_commit ?
      forward_log_rdata.addr[TagLsb+:TagBits] : forward_scalar_commit ? write_error_tag :
      dir_client_mark ? r_tag_q : burst_direct_commit ? TagBits'(rapt_pkg::canonical_addr(
      burst_start
  ) >> TagLsb) : ms_alloc_invalidate ? dir_lookup_tag : w_tag_q;
  assign dir_write_dirty = release_dir_write_fire
      ? release_dir_dirty_q || release_head_has_data
      : hit_probe_commit ? victim_dirty_q || dir_lookup_dirty
      : ms_direct_complete || ms_alloc_invalidate || blocking_refill_invalidate ? 1'b0
      : dir_client_mark ? dir_lookup_dirty
      : cache_install_dirty || w_hit_update || burst_direct_commit
          || forward_scalar_commit || forward_replay_commit;
  assign dir_write_state = release_dir_write_fire
      ? (release_dir_state_q == 2'b01 ? 2'b01 : 2'b11)
      : dir_error_inv || cbo_exact_invalidate || ms_alloc_invalidate
          || blocking_refill_invalidate ? 2'b00
      : dir_write_clients ? 2'b10 : 2'b11;
  // Only L1D is a probe-capable BOOM client. Its ordinary read ID is 2;
  // MSHR refills use IDs 8..11. Preserve ownership on local store hits.
  assign dir_write_clients = release_dir_write_fire ? 1'b0
      : hit_probe_commit ? 1'b0
      : cache_install ? (!r_burst_fill && d_client_read_id(r_id))
      : ms_direct_complete ? d_client_read_id(
      ms_id[int'(ms_complete_slot)]
  ) :
      dir_error_inv || cbo_exact_invalidate || ms_alloc_invalidate || blocking_refill_invalidate ||
      burst_direct_commit ? 1'b0 : dir_client_mark ? 1'b1 : forward_replay_commit ? 1'b0 :
      forward_scalar_commit ? 1'b0 : w_hit_update && d_client_read_id(
      wbuf[w_wptr].id
  ) ? 1'b1 : w_lookup_now ? dir_result_clients : wbuf[w_wptr].lookup_clients;
  assign dir_clear_set = burst_active ? burst_addr[IndexMsb:IndexLsb]
      : BoomBankedStore ? cbo_active_set : cbo_clear_set;
  assign dir_clear_valid = BoomBankedStore && cbo_state == C_CLEAR && cbo_active_broad;

  // ---------------------------------------------------------------------
  // Read FSM
  // ---------------------------------------------------------------------
  always_ff @(posedge clock) begin
    if (reset) begin
      rs                    <= R_IDLE;
      m_arvalid             <= 1'b0;
      rs_rvalid             <= 1'b0;
      rs_rlast              <= 1'b0;
      rs_rresp              <= 2'b00;
      rs_rid                <= '0;
      rs_rdata              <= '0;
      ms_response_secondary <= 1'b0;
      r_id                  <= '0;
      r_addr                <= '0;
      r_len                 <= '0;
      r_size                <= '0;
      r_burst               <= '0;
      r_wrap_mask           <= '0;
      r_cache               <= '0;
      r_word                <= '0;
      r_fill_cnt            <= '0;
      evict_word            <= '0;
      r_resp                <= 2'b00;
      r_up_done             <= 1'b0;
      r_store_fill          <= 1'b0;
      r_store_merge_data    <= '0;
      r_burst_fill          <= 1'b0;
      cache_install         <= 1'b0;
      install_streamed      <= 1'b0;
      cache_install_dirty   <= 1'b0;
      install_idx           <= '0;
      install_tag           <= '0;
      install_way           <= '0;
      victim_way_q          <= '0;
      victim_tag_q          <= '0;
      victim_state_q        <= '0;
      victim_dirty_q        <= 1'b0;
      victim_clients_q      <= 1'b0;
      r_selected_way        <= '0;
      r_client_marked       <= 1'b0;
      r_response_secondary  <= 1'b0;
      wipe_set              <= '0;
      wipe_done             <= BoomBankedStore || (L2_N_WAYS * NSets <= 4000);
      if (!BoomBankedStore && L2_N_WAYS * NSets <= 4000) begin
        for (int w = 0; w < L2_N_WAYS; w++) begin
          for (int s = 0; s < NSets; s++) line_valid[w][s] <= 1'b0;
        end
      end
    end else begin
      if (probe_release_fire && (rs == R_EVICT_PROBE || rs == R_HIT_PROBE)) victim_dirty_q <= 1'b1;
      // A large directory uses the same one-set-per-cycle reset wipe as the
      // BOOM inclusive cache. Requests remain blocked until every valid bit
      // has been initialized; data and tags are valid-gated and need no reset.
      if (!BoomBankedStore && !wipe_done) begin
        for (int way = 0; way < L2_N_WAYS; way++) line_valid[way][wipe_set] <= 1'b0;
        wipe_set <= wipe_set + 1'b1;
        if (wipe_set == IndexBits'(NSets - 1)) wipe_done <= 1'b1;
      end
      // Default deassert of pulses
      cache_install <= 1'b0;
      if (ms_complete_valid) install_streamed <= 1'b1;
      else if (rs == R_IDLE && !cache_install && !boom_bank_line_busy) install_streamed <= 1'b0;
      // R-channel handshake: clear rvalid on accepted beat
      if (rs_rvalid && axi_s.rready) begin
        rs_rvalid <= 1'b0;
        rs_rlast <= 1'b0;
        ms_response_secondary <= 1'b0;
      end
      // AR-channel handshake: clear m_arvalid when accepted
      if (m_arvalid && axi_m.arready) begin
        m_arvalid <= 1'b0;
      end
      if (ms_early_send && ms_early_overlap_state) begin
        rs_rvalid <= 1'b1;
        rs_rdata <= ms_retire_line[int'(ms_word[int'(ms_early_slot)])*XLEN+:XLEN];
        rs_rresp <= ms_retire_resp;
        rs_rid <= ms_id[int'(ms_early_slot)];
        rs_rlast <= 1'b1;
        ms_response_secondary <= ms_primary_secondary[int'(ms_early_slot)];
      end
      if (ms_source_response_send && ms_early_overlap_state) begin
        rs_rvalid <= 1'b1;
        rs_rdata <= ms_source_data;
        rs_rresp <= 2'b00;
        rs_rid <= ms_source_id;
        rs_rlast <= ms_source_len == 8'd0;
        ms_response_secondary <= ms_source_primary_secondary;
      end

      unique case (rs)
        // -----------------------------------------------------------------
        R_IDLE: begin
          if (ms_source_response_send) begin
            rs_rvalid <= 1'b1;
            rs_rdata <= ms_source_data;
            rs_rresp <= 2'b00;
            rs_rid <= ms_source_id;
            rs_rlast <= ms_source_len == 8'd0;
            ms_response_secondary <= ms_source_primary_secondary;
          end else if (ms_early_send) begin
            rs_rvalid <= 1'b1;
            rs_rdata <= ms_retire_line[int'(ms_word[int'(ms_early_slot)])*XLEN+:XLEN];
            rs_rresp <= ms_retire_resp;
            rs_rid <= ms_id[int'(ms_early_slot)];
            rs_rlast <= 1'b1;
            ms_response_secondary <= ms_primary_secondary[int'(ms_early_slot)];
          end else if (ms_late_response_issue) begin
            // A successful ordinary refill was installed during another
            // miss's blocking phase. Read its banked data only after the
            // shared response path becomes available.
            r_store_fill <= 1'b0;
            r_burst_fill <= 1'b0;
            r_client_marked <= 1'b0;
            r_up_done <= 1'b0;
            r_id <= ms_retire_id;
            r_addr <= ms_retire_addr;
            r_len <= ms_retire_len;
            r_size <= ms_retire_size;
            r_burst <= ms_retire_burst;
            r_wrap_mask <= read_wrap_mask(ms_retire_len, ms_retire_size);
            r_cache <= ms_retire_cache;
            r_response_secondary <= ms_primary_secondary[int'(ms_late_response_slot)];
            r_word <= ms_retire_addr[WordOffsetMsb:WordOffsetLsb];
            r_resp <= 2'b00;
            install_idx <= ms_retire_addr[IndexMsb:IndexLsb];
            install_tag <= TagBits'(rapt_pkg::canonical_addr(ms_retire_addr) >> TagLsb);
            install_way <= ms_way[int'(ms_late_response_slot)];
            rs <= R_INSTALL_READ;
          end else if (ms_secondary_send) begin
            if (ms_retire_resp != 2'b00
                && ms_secondary_reload_payload[SecondaryLenLsb+:8] != 8'd0) begin
              r_id <= ms_secondary_reload_payload[0+:ID_W];
              r_len <= ms_secondary_reload_payload[SecondaryLenLsb+:8];
              r_resp <= ms_retire_resp;
              r_response_secondary <= 1'b1;
              rs <= R_ERROR;
            end else begin
              rs_rvalid <= 1'b1;
              rs_rdata <= ms_retire_line[int'(ms_secondary_reload_addr[WordOffsetMsb:
                                            WordOffsetLsb])*XLEN+:XLEN];
              rs_rresp <= ms_retire_resp;
              rs_rid <= ms_secondary_reload_payload[0+:ID_W];
              rs_rlast <= 1'b1;
              ms_response_secondary <= 1'b1;
            end
          end else if (ms_secondary_capture) begin
            // Save a queued request requiring shared-FSM service. Equal
            // tags reuse current MSHR metadata; other tags read the directory.
          end else if (ms_complete_valid) begin
            // Complete one independent clean fill through the existing
            // install/readback path. The context remains set-interlocked
            // until this edge; AR admission stays closed during install.
            r_store_fill <= 1'b0;
            r_burst_fill <= 1'b0;
            r_client_marked <= 1'b0;
            r_up_done <= 1'b0;
            r_id <= ms_retire_id;
            r_addr <= ms_retire_addr;
            r_len <= ms_retire_len;
            r_size <= ms_retire_size;
            r_burst <= ms_retire_burst;
            r_wrap_mask <= read_wrap_mask(ms_retire_len, ms_retire_size);
            r_cache <= ms_retire_cache;
            r_response_secondary <= ms_primary_secondary[int'(ms_complete_slot)];
            r_word <= ms_retire_addr[WordOffsetMsb:WordOffsetLsb];
            r_resp <= ms_retire_resp;
            install_idx <= ms_retire_addr[IndexMsb:IndexLsb];
            install_tag <= TagBits'(rapt_pkg::canonical_addr(ms_retire_addr) >> TagLsb);
            install_way <= ms_way[int'(ms_complete_slot)];
            cache_install_dirty <= 1'b0;
            for (int word = 0; word < LineSize; word++)
            r_line_buf[word] <= ms_retire_line[word*XLEN+:XLEN];
            if (ms_retire_resp == 2'b00) begin
              cache_install <= 1'b1;
              rs <= ms_early_sent[int'(ms_complete_slot)] ? R_MSHR_EARLY_INSTALL : R_INSTALL_WAIT;
            end else rs <= ms_early_sent[int'(ms_complete_slot)] ? R_IDLE : R_ERROR;
          end else if (ms_replay_issue) begin
            r_store_fill <= 1'b0;
            r_burst_fill <= 1'b0;
            r_client_marked <= 1'b0;
            r_response_secondary <= 1'b1;
            r_up_done <= 1'b0;
            r_id <= ms_replay_payload[0+:ID_W];
            r_addr <= ms_replay_payload[ID_W+:XLEN];
            r_len <= ms_replay_payload[SecondaryLenLsb+:8];
            r_size <= ms_replay_payload[ID_W+XLEN+:3];
            r_burst <= ms_replay_payload[SecondaryBurstLsb+:2];
            r_wrap_mask <= read_wrap_mask(
                ms_replay_payload[SecondaryLenLsb+:8], ms_replay_payload[ID_W+XLEN+:3]
            );
            r_cache <= ms_replay_payload[ID_W+XLEN+3+:4];
            r_word <= ms_replay_payload[ID_W+WordOffsetLsb+:L2_LINE_LEN];
            r_resp <= 2'b00;
            rs <= R_HIT;
          end else if (ms_retire_valid) begin
            // Release an installed owner once every secondary list drains.
          end else if (ms_secondary_accept) begin
            // The live MSHR owns this line. Its A-channel secondary queue
            // retains the address and ID until the completed fill replies.
          end else if (axi_s.arvalid && axi_s.arready) begin
            r_store_fill <= 1'b0;
            r_burst_fill <= 1'b0;
            r_client_marked <= 1'b0;
            r_response_secondary <= 1'b0;
            r_id    <= axi_s.arid;
            r_addr  <= axi_s.araddr;
            r_len   <= axi_s.arlen;
            r_size  <= axi_s.arsize;
            r_burst <= axi_s.arburst;
            r_wrap_mask <= read_wrap_mask(axi_s.arlen, axi_s.arsize);
            r_cache <= axi_s.arcache;
            r_word  <= axi_s.araddr[WordOffsetMsb:WordOffsetLsb];
            r_resp  <= 2'b00;
            if (ar_cache_lookup) begin
              // Lookup is combinational on r_addr_next; but since we
              // sample on the same edge we must wait one cycle for
              // r_addr to be latched, then decide. Use a transient state:
              rs <= R_HIT;
            end else begin
              // Forward AR straight through.
              if (ms_busy || any_write_in_flight || (axi_s.awvalid && axi_s.awready)) begin
                rs <= R_BYPASS_WAIT;
              end else begin
                m_arvalid <= 1'b1;
                m_araddr  <= axi_s.araddr;
                m_arid    <= axi_s.arid;
                m_arlen   <= axi_s.arlen;
                m_arsize  <= axi_s.arsize;
                m_arburst <= axi_s.arburst;
                m_arcache <= axi_s.arcache;
                rs <= R_BYPASS_AR;
              end
            end
          end else if (!ms_busy && burst_active && burst_allocate && burst_segment_ready
                       && burst_lookup_ready && !rs_rvalid && !cache_install) begin
            // A resident line without a client has already accepted each
            // Put beat through the SourceD bank-write port. Its metadata
            // write completes the burst without another line install.
            if (burst_direct_hit) begin
              if (burst_direct_commit) rs <= R_BURST_DONE;
            end else begin
              // A complete PutFullData line needs no old outer data. Short
              // line-local bursts and masked writes merge with a resident
              // line or a refill before replacing it.
              r_store_fill <= 1'b0;
              r_burst_fill <= 1'b1;
              r_addr <= burst_start;
              r_id <= burst_id;
              r_cache <= burst_cache;
              r_word <= '0;
              r_fill_cnt <= '0;
              r_resp <= 2'b00;
              r_up_done <= 1'b0;
              victim_way_q <= burst_lookup_way;
              victim_tag_q <= burst_lookup_tag;
              victim_state_q <= burst_lookup_state;
              victim_dirty_q <= burst_lookup_dirty;
              victim_clients_q <= burst_lookup_clients;
              m_araddr <= {burst_start[XLEN-1:OffsetBits], {OffsetBits{1'b0}}};
              m_arid <= burst_id;
              m_arlen <= 8'(LineSize - 1);
              m_arsize <= 3'($clog2(WordBytes));
              m_arcache <= burst_cache;
              m_arburst <= 2'b01;
              if (burst_lookup_clients && burst_lookup_state != 2'b00) begin
                rs <= R_EVICT_PROBE;
              end else if (burst_lookup_hit) begin
                if (burst_all_full) begin
                  r_selected_way <= burst_lookup_way;
                  rs <= R_BURST_PUT_WRITE;
                end else begin
                  r_selected_way <= burst_lookup_way;
                  rs <= R_BURST_HIT_READ;
                end
              end else if (burst_lookup_dirty && burst_lookup_state != 2'b00) begin
                evict_word <= '0;
                rs <= R_EVICT_AW;
              end else if (burst_all_full) begin
                r_selected_way <= burst_lookup_way;
                rs <= R_BURST_PUT_WRITE;
              end else begin
                rs <= R_MISS_INVALIDATE;
              end
            end
          end else if (BoomBankedStore && !ms_busy && ws == W_IDLE && wbuf[d_rptr].busy
                       && wbuf[d_rptr].has_w && wbuf[d_rptr].local_miss
                       && wbuf[d_rptr].lookup_ready && !rs_rvalid && !cache_install) begin
            // The buffered store owns this miss. Reuse the read refill and
            // dirty-victim writeback states, but send no upstream R beats.
            r_store_fill <= 1'b1;
            r_burst_fill <= 1'b0;
            r_addr <= wbuf[d_rptr].addr;
            r_id <= wbuf[d_rptr].id;
            r_cache <= wbuf[d_rptr].cache;
            r_word <= wbuf[d_rptr].addr[WordOffsetMsb:WordOffsetLsb];
            r_fill_cnt <= '0;
            r_resp <= 2'b00;
            r_up_done <= 1'b0;
            victim_way_q <= wbuf[d_rptr].lookup_way;
            victim_tag_q <= wbuf[d_rptr].lookup_tag;
            victim_state_q <= wbuf[d_rptr].lookup_state;
            victim_dirty_q <= wbuf[d_rptr].lookup_dirty;
            victim_clients_q <= wbuf[d_rptr].lookup_clients;
            m_araddr <= {wbuf[d_rptr].addr[XLEN-1:OffsetBits], {OffsetBits{1'b0}}};
            m_arid <= wbuf[d_rptr].id;
            m_arlen <= 8'(LineSize - 1);
            m_arsize <= 3'($clog2(WordBytes));
            m_arcache <= wbuf[d_rptr].cache;
            m_arburst <= 2'b01;
            if (wbuf[d_rptr].lookup_clients && wbuf[d_rptr].lookup_state != 2'b00) begin
              rs <= R_EVICT_PROBE;
            end else if (wbuf[d_rptr].lookup_dirty && wbuf[d_rptr].lookup_state != 2'b00) begin
              evict_word <= '0;
              rs <= R_EVICT_AW;
            end else begin
              rs <= R_MISS_INVALIDATE;
            end
          end
        end

        // -----------------------------------------------------------------
        // Resolve hit / miss against the (now-latched) request.
        R_HIT: begin
          if (dir_client_mark && !dir_write_ready) begin
            // The one-entry directory write queue must accept ownership
            // before the L1D can observe the hit response.
          end else if (l2_sram_wblock) begin
            // A store-hit snoop write took the single SRAM port this cycle
            // and clobbered the read address register. Hold the burst for
            // one cycle so data_sram_raddr is re-latched and line_data_r
            // is fresh again before the next beat is delivered.
            rs <= R_HIT;
          end else if (r_hit_q && BoomBankedStore) begin
            // The BOOM bank row includes the selected way. Read it after
            // the directory lookup, then return data on the next cycle.
            r_selected_way <= r_hit_way;
            if (dir_lookup_clients && !d_client_read_id(r_id)) begin
              victim_way_q <= r_hit_way;
              victim_tag_q <= r_tag_q;
              victim_state_q <= dir_lookup_state;
              victim_dirty_q <= dir_lookup_dirty;
              victim_clients_q <= 1'b1;
              rs <= R_HIT_PROBE;
            end else begin
              if (dir_client_mark && dir_write_ready) r_client_marked <= 1'b1;
              rs <= R_HIT_DATA;
            end
          end else if (r_hit_q) begin
            // Drive next beat from cache. May take multiple cycles for
            // a burst -- we hold this state until the burst completes.
            if (!rs_rvalid || axi_s.rready) begin
              rs_rvalid <= 1'b1;
              rs_rdata  <= line_data_r[r_hit_way][r_word];
              rs_rresp  <= 2'b00;
              rs_rid    <= r_id;
              rs_rlast  <= (r_len == 8'd0);
              // Advance address / counters
              if (r_len == 8'd0) begin
                rs <= R_IDLE;
              end else begin
                r_len  <= r_len - 8'd1;
                // AXI beat size is independent of the SRAM word width.
                // RV64 instruction reads can request two 32-bit beats from
                // the same 64-bit word. FIXED bursts retain their address.
                r_word <= r_next_addr[WordOffsetMsb:WordOffsetLsb];
                r_addr <= r_next_addr;
              end
            end
          end else if (BoomBankedStore && release_pending
                       && (dir_lookup_clients || dir_lookup_dirty)) begin
            // A dirty-victim writeback or L1D probe would contend with the
            // C transaction. Keep this different-set replay's directory
            // result until ReleaseAck, then enter the blocking miss path.
          end else begin
            // Miss: issue line-aligned fill burst.
            //
            // Read-after-write coherence: AXI does not order AR vs an
            // outstanding/incoming AW/W to the same line. Stall the
            // miss issue while ANY write is in the posted write buffer
            // (or arriving this cycle) to avoid memory-level reordering.
            //
            // We cover three races:
            //  1) An AW already captured in the buffer (any slot busy).
            //  2) AW is being accepted THIS cycle (axi_s.awvalid).
            //  3) Any write activity at all (worst-case fallback): the
            //     bus-level model may reorder AR vs AW for different
            //     addresses too, so be conservative.
            if (!(|r_cache[3:2])) begin
              // No-allocate reads use resident data on a hit, but bypass
              // the cache on a miss without evicting or allocating a line.
              rs <= R_BYPASS_WAIT;
            end else if (any_write_in_flight || (axi_s.awvalid && axi_s.awready)) begin
              // hold in R_HIT; re-evaluate next cycle
            end else if (BoomBankedStore && !dir_lookup_clients && !dir_lookup_dirty) begin
              // Clean victim: admit the miss to one of BOOM's five ordinary
              // refill slots. The directory still interlocks its set until
              // the completed line is installed and returned upstream.
              if (ms_alloc_invalidate) begin
                victim_way_q <= dir_lookup_way;
                rs <= R_IDLE;
              end
            end else begin
              r_fill_cnt <= '0;
              r_resp     <= 2'b00;
              r_up_done  <= 1'b0;
              if (BoomBankedStore) begin
                // Keep the old entry before refill replaces its way. A
                // write-back/probe sequence needs its tag, state and owners.
                victim_way_q <= dir_lookup_way;
                victim_tag_q <= dir_lookup_tag;
                victim_state_q <= dir_lookup_state;
                victim_dirty_q <= dir_lookup_dirty;
                victim_clients_q <= dir_lookup_clients;
              end else if (L2_N_WAYS == 1) victim_way_q <= '0;
              else victim_way_q <= WayBits'(victim_lfsr[9:0] >> (10 - WayBits));
              m_araddr <= {r_addr[XLEN-1:OffsetBits], {OffsetBits{1'b0}}};
              // A dirty-victim or client-probe miss uses one of BOOM's five
              // normal outer IDs. An installed replay reuses its own slot.
              m_arid    <= BoomBankedStore
                  ? ID_W'(ms_replay_active ? ms_replay_slot : ms_free_slot) : r_id;
              m_arlen <= 8'(LineSize - 1);
              m_arsize <= 3'($clog2(WordBytes));
              m_arcache <= r_cache;
              m_arburst <= 2'b01;  // INCR
              if (BoomBankedStore && dir_lookup_clients && dir_lookup_state != 2'b00) begin
                rs <= R_EVICT_PROBE;
              end else if (BoomBankedStore && dir_lookup_dirty && dir_lookup_state != 2'b00) begin
                evict_word <= '0;
                rs <= R_EVICT_AW;
              end else begin
                if (BoomBankedStore) rs <= R_MISS_INVALIDATE;
                else begin
                  m_arvalid <= 1'b1;
                  rs <= R_MISS_AR;
                end
              end
            end
          end
        end

        // -----------------------------------------------------------------
        R_HIT_PROBE: begin
          if (!release_pending && (!victim_clients_q || probe_ready_i)) rs <= R_HIT_PROBE_COMMIT;
        end

        R_HIT_PROBE_COMMIT: begin
          if (hit_probe_commit) rs <= R_HIT;
        end

        R_HIT_DATA: begin
          if (l2_sram_wblock || !r_selected_resident) begin
            // Recheck the tag after an overlapping store invalidation and
            // refresh the single-port bank output after a write conflict.
            rs <= R_HIT;
          end else if (!rs_rvalid || axi_s.rready) begin
            rs_rvalid <= 1'b1;
            rs_rdata  <= line_data_r[r_selected_way][r_word];
            rs_rresp  <= 2'b00;
            rs_rid    <= r_id;
            rs_rlast  <= (r_len == 8'd0);
            if (r_response_secondary) ms_response_secondary <= 1'b1;
            if (r_len == 8'd0) rs <= R_IDLE;
            else begin
              r_len  <= r_len - 8'd1;
              r_word <= r_next_addr[WordOffsetMsb:WordOffsetLsb];
              r_addr <= r_next_addr;
              if (!same_line(r_addr, r_next_addr)) r_client_marked <= 1'b0;
              rs <= R_HIT;
            end
          end
        end

        // -----------------------------------------------------------------
        R_MISS_INVALIDATE: begin
          // The victim must become invisible before SinkD writes refill
          // beats into its banks. A failed outer read leaves this way Invalid.
          if (dir_write_ready) begin
            m_arvalid <= 1'b1;
            rs <= R_MISS_AR;
          end
        end

        R_MISS_AR: begin
          if (!m_arvalid) begin
            rs <= R_MISS_R;
          end
        end

        R_EVICT_PROBE: begin
          // Inner C has priority over the ordinary Probe. The owner may be
          // finishing its voluntary Release before it can answer Probe.
          if (!release_pending && (!victim_clients_q || probe_ready_i)) begin
            if (r_burst_fill && burst_lookup_hit) begin
              if (burst_all_full) begin
                if (BoomBankedStore) begin
                  r_selected_way <= victim_way_q;
                  r_fill_cnt <= '0;
                  rs <= R_BURST_PUT_WRITE;
                end else begin
                  cache_install <= 1'b1;
                  cache_install_dirty <= 1'b1;
                  install_idx <= r_idx_q;
                  install_tag <= r_tag_q;
                  install_way <= victim_way_q;
                  rs <= R_INSTALL_WAIT;
                end
              end else begin
                r_selected_way <= victim_way_q;
                rs <= R_BURST_HIT_READ;
              end
            end else if (victim_dirty_q && victim_state_q != 2'b00) begin
              evict_word <= '0;
              rs <= R_EVICT_AW;
            end else if (r_burst_fill && burst_all_full) begin
              r_selected_way <= victim_way_q;
              r_fill_cnt <= '0;
              rs <= R_BURST_PUT_WRITE;
            end else begin
              if (BoomBankedStore) rs <= R_MISS_INVALIDATE;
              else begin
                m_arvalid <= 1'b1;
                rs <= R_MISS_AR;
              end
            end
          end
        end

        R_EVICT_AW: begin
          if (axi_m.awvalid && axi_m.awready) rs <= R_EVICT_READ;
        end

        R_EVICT_READ: begin
          if (!l2_sram_wblock) rs <= R_EVICT_W;
        end

        R_EVICT_W: begin
          if (axi_m.wvalid && axi_m.wready) begin
            if (evict_word == L2_LINE_LEN'(LineSize - 1)) rs <= R_EVICT_B;
            else begin
              evict_word <= evict_word + 1'b1;
              rs <= R_EVICT_READ;
            end
          end
        end

        R_EVICT_B: begin
          if (axi_m.bvalid && axi_m.bready) begin
            if (axi_m.bresp == 2'b00) begin
              if (r_burst_fill && burst_all_full) begin
                r_selected_way <= victim_way_q;
                r_fill_cnt <= '0;
                rs <= R_BURST_PUT_WRITE;
              end else begin
                if (BoomBankedStore) rs <= R_MISS_INVALIDATE;
                else begin
                  m_arvalid <= 1'b1;
                  rs <= R_MISS_AR;
                end
              end
            end else begin
              r_resp <= axi_m.bresp;
              rs <= r_burst_fill ? R_BURST_ERROR : r_store_fill ? R_STORE_ERROR : R_ERROR;
            end
          end
        end

        R_STORE_MERGE_READ: begin
          // The raw refill is in the bank. Read only the touched word while
          // the selected directory way remains Invalid.
          if (!l2_sram_wblock) rs <= R_STORE_MERGE_LATCH;
        end

        R_STORE_MERGE_LATCH: begin
          // Hold merged data if a higher-priority bank client stalls SourceD.
          r_store_merge_data <= merge_store_word(
              line_data_r[r_selected_way][r_word], drain_wdata, drain_wstrb
          );
          rs <= R_STORE_MERGE_WRITE;
        end

        R_STORE_MERGE_WRITE: begin
          if (bank_write_word_ready) begin
            cache_install <= 1'b1;
            install_streamed <= 1'b1;
            cache_install_dirty <= 1'b1;
            install_idx <= r_idx_q;
            install_tag <= r_tag_q;
            install_way <= r_selected_way;
            rs <= R_INSTALL_WAIT;
          end
        end

        R_BURST_HIT_READ: begin
          if (!l2_sram_wblock) rs <= R_BURST_HIT_MERGE;
        end

        R_BURST_HIT_MERGE: begin
          // Consume the previous synchronous read while issuing the next
          // beat. A higher-priority access stalls only that next bank read;
          // the consumed beat is already held in the SRAM output register.
          r_line_buf[r_fill_cnt] <= merge_store_word(
              line_data_r[r_selected_way][r_fill_cnt],
              burst_line_buf[r_fill_cnt],
              burst_mask_buf[r_fill_cnt]
          );
          if (r_fill_cnt == L2_LINE_LEN'(LineSize - 1)) begin
            if (BoomBankedStore) begin
              r_fill_cnt <= '0;
              rs <= R_BURST_PUT_WRITE;
            end else begin
              cache_install <= 1'b1;
              cache_install_dirty <= 1'b1;
              install_idx <= r_idx_q;
              install_tag <= r_tag_q;
              install_way <= r_selected_way;
              rs <= R_INSTALL_WAIT;
            end
          end else begin
            r_fill_cnt <= r_fill_cnt + 1'b1;
            if (l2_sram_wblock) rs <= R_BURST_HIT_READ;
          end
        end

        R_BURST_PUT_WRITE: begin
          // SourceD-write retires all full-Put beats or only chunks touched
          // by a partial Put. The bank port may stall behind higher priority
          // SinkC, SourceC, or SinkD traffic.
          if (!burst_put_word_valid || bank_write_word_ready) begin
            if (r_fill_cnt == L2_LINE_LEN'(LineSize - 1)) begin
              cache_install <= 1'b1;
              install_streamed <= 1'b1;
              cache_install_dirty <= 1'b1;
              install_idx <= r_idx_q;
              install_tag <= r_tag_q;
              install_way <= r_selected_way;
              rs <= R_INSTALL_WAIT;
            end else r_fill_cnt <= r_fill_cnt + 1'b1;
          end
        end

        // -----------------------------------------------------------------
        R_MISS_R: begin
          // Collect fill beats. Early-restart: forward the wanted word
          // (the beat indexed by r_word) the cycle it arrives, so the
          // upstream single-beat load completes before line install.
          // One-shot, gated to r_len==0 (L1D miss = single-beat).
          if (axi_m.rvalid && axi_m.rready && axi_m.rid == m_arid) begin
            if (!blocking_refill_streamed)
              r_line_buf[r_fill_cnt] <= r_store_fill && r_fill_cnt == r_word ? merge_store_word(
                  axi_m.rdata, drain_wdata, drain_wstrb
              ) : axi_m.rdata;
            if (axi_m.rresp != 2'b00) r_resp <= axi_m.rresp;
            r_fill_cnt <= r_fill_cnt + 1'b1;

            if (!r_store_fill && !r_burst_fill && !r_up_done && (r_len == 8'd0)
                && (r_fill_cnt == r_word)
                && (axi_m.rresp == 2'b00) && (r_resp == 2'b00)
                && (!rs_rvalid || axi_s.rready)) begin
              rs_rvalid <= 1'b1;
              rs_rdata  <= axi_m.rdata;
              rs_rresp  <= 2'b00;
              rs_rid    <= r_id;
              rs_rlast  <= 1'b1;
              if (r_response_secondary) ms_response_secondary <= 1'b1;
              r_up_done <= 1'b1;
            end

            if (axi_m.rlast) begin
              // SinkD writes every blocking refill beat before the directory
              // becomes valid. A blocking Put then merges its masked words.
              if (axi_m.rresp == 2'b00 && r_resp == 2'b00) begin
                if (blocking_refill_streamed) begin
                  r_selected_way <= victim_way_q;
                  r_fill_cnt <= '0;
                  if (!r_store_fill && !r_burst_fill) begin
                    cache_install <= 1'b1;
                    install_streamed <= 1'b1;
                    install_idx <= r_idx_q;
                    install_tag <= r_tag_q;
                    install_way <= victim_way_q;
                    cache_install_dirty <= 1'b0;
                  end
                end else begin
                  cache_install <= 1'b1;
                  install_idx <= r_idx_q;
                  install_tag <= r_tag_q;
                  install_way <= victim_way_q;
                  cache_install_dirty <= r_store_fill || r_burst_fill;
                end
              end
              if (r_burst_fill) begin
                rs <= (axi_m.rresp != 2'b00 || r_resp != 2'b00) ? R_BURST_ERROR
                    : blocking_refill_streamed ? R_BURST_HIT_READ : R_INSTALL_WAIT;
              end else if (r_store_fill) begin
                rs <= (axi_m.rresp != 2'b00 || r_resp != 2'b00) ? R_STORE_ERROR
                    : blocking_refill_streamed ? R_STORE_MERGE_READ : R_INSTALL_WAIT;
              end else if (r_up_done
                  || ((r_len == 8'd0) && (r_fill_cnt == r_word)
                      && (axi_m.rresp == 2'b00) && (r_resp == 2'b00)
                      && (!rs_rvalid || axi_s.rready))) begin
                rs <= R_IDLE;
              end else if (axi_m.rresp != 2'b00 || r_resp != 2'b00) begin
                // The refill has drained, but no line was installed. Going
                // through R_HIT here would miss again and retry forever.
                // Complete the remaining upstream beats with the saved error.
                rs <= R_ERROR;
              end else begin
                rs <= R_INSTALL_WAIT;  // allow SRAM install/read to settle
              end
            end
          end
        end

        // -----------------------------------------------------------------
        R_INSTALL_WAIT: begin
          // Wait for any remaining buffered line writes; a streamed Put has
          // already committed its selected bank beats before directory update.
          if (!cache_install && !boom_bank_line_busy)
            rs <= r_burst_fill ? R_BURST_DONE : r_store_fill ? R_STORE_DONE : R_INSTALL_READ;
        end

        R_MSHR_EARLY_INSTALL: begin
          // The critical word was already returned. Commit the completed
          // line and release the read FSM without another upstream beat.
          if (!cache_install && !boom_bank_line_busy) rs <= R_IDLE;
        end

        R_STORE_DONE: rs <= R_IDLE;

        R_STORE_ERROR: rs <= R_IDLE;

        R_BURST_DONE: rs <= R_IDLE;

        // AXI requires every W beat through WLAST even when an earlier
        // line segment failed. The Put list drains without installing data.
        R_BURST_ERROR: if (burst_w_done) rs <= R_IDLE;

        R_INSTALL_READ: begin
          // The SRAM has a synchronous read port. After the install write,
          // allow one read edge to refresh line_data_r before R_HIT consumes
          // it on the following edge.
          if (BoomBankedStore) begin
            if (!l2_sram_wblock) begin
              r_selected_way <= install_way;
              rs <= R_HIT_DATA;
            end
          end else rs <= R_HIT;
        end

        R_ERROR: begin
          if (!rs_rvalid || axi_s.rready) begin
            rs_rvalid <= 1'b1;
            rs_rdata  <= '0;
            rs_rresp  <= r_resp;
            rs_rid    <= r_id;
            rs_rlast  <= (r_len == 8'd0);
            if (r_response_secondary) ms_response_secondary <= 1'b1;
            if (r_len == 8'd0) rs <= R_IDLE;
            else r_len <= r_len - 8'd1;
          end
        end

        // -----------------------------------------------------------------
        R_BYPASS_WAIT: begin
          if (!ms_busy && !any_write_in_flight) begin
            m_arvalid <= 1'b1;
            m_araddr  <= r_addr;
            m_arid    <= r_id;
            m_arlen   <= r_len;
            m_arsize  <= r_size;
            m_arburst <= r_burst;
            m_arcache <= r_cache;
            rs <= R_BYPASS_AR;
          end
        end

        // -----------------------------------------------------------------
        R_BYPASS_AR: begin
          if (!m_arvalid) rs <= R_BYPASS_R;
        end

        // -----------------------------------------------------------------
        R_BYPASS_R: begin
          // Forward downstream R beats to upstream verbatim.
          if (axi_m.rvalid && (!rs_rvalid || axi_s.rready)) begin
            rs_rvalid <= 1'b1;
            rs_rdata  <= axi_m.rdata;
            rs_rresp  <= axi_m.rresp;
            rs_rid    <= axi_m.rid;
            rs_rlast  <= axi_m.rlast;
            if (axi_m.rlast) rs <= R_IDLE;
          end
        end

        default: rs <= R_IDLE;
      endcase

      // Forward nested C metadata to the ordinary request's saved victim,
      // as BOOM's nested writeback does. A clean L2 victim can become dirty
      // when its owner returns modified data during Probe pre-emption.
      if (BoomBankedStore && (rs == R_EVICT_PROBE || hit_probe_active) && release_dir_write_fire
          && release_head_addr[IndexMsb:IndexLsb] == r_idx_q
          && TagBits'(rapt_pkg::canonical_addr(
              release_head_addr
          ) >> TagLsb) == victim_tag_q) begin
        victim_clients_q <= 1'b0;
        victim_dirty_q <= release_dir_dirty_q || release_head_has_data;
        victim_state_q <= dir_write_state;
      end

      // ---------------------------------------------------------------
      // Cache install (write port on fill completion)
      // ---------------------------------------------------------------
      if (!BoomBankedStore && cache_install) begin
        line_valid[install_way][install_idx] <= 1'b1;
        line_tag[install_way][install_idx]   <= install_tag;
      end

      // ---------------------------------------------------------------
      // Hit update. BOOM's bank uses byte enables and tracks dirty metadata;
      // smaller legacy configurations still invalidate on partial stores.
      // ---------------------------------------------------------------
      if (!BoomBankedStore && w_hit_update && !w_full_strobe) begin
        line_valid[w_hit_way][w_idx_q] <= 1'b0;
      end
      // Snoop updates precede the downstream response. A failed full-word
      // write must not leave its value cached after software observes B.
      // Typed writes also invalidate aliases: an error can have partial effects.
      // Do not invalidate a different tag installed at the same index now.
      if (!BoomBankedStore && write_response_error) begin
        for (int way = 0; way < L2_N_WAYS; way++) begin
          if ((cache_install && install_idx == write_error_idx
                   && install_way == WayBits'(way) && install_tag == write_error_tag)
              || (line_valid[way][write_error_idx]
                  && line_tag[way][write_error_idx] == write_error_tag))
            line_valid[way][write_error_idx] <= 1'b0;
        end
      end
      // Burst writes invalidate each touched physical set. Reads are held
      // until the real B, so no partially written block can be observed here.
      if (!BoomBankedStore && burst_write_fire) begin
        for (int way = 0; way < L2_N_WAYS; way++)
        line_valid[way][burst_addr[IndexMsb:IndexLsb]] <= 1'b0;
      end
      if (!BoomBankedStore && cbo_apply) begin
        if (L2_N_WAYS * NSets <= 4000) begin
          for (int set_idx = 0; set_idx < NSets; set_idx++)
          if (cbo_pending[set_idx] || cbo_mask[set_idx]) begin
            for (int way = 0; way < L2_N_WAYS; way++) line_valid[way][set_idx] <= 1'b0;
          end
        end else begin
          for (int way = 0; way < L2_N_WAYS; way++) line_valid[way][cbo_clear_set] <= 1'b0;
        end
      end
    end
  end

  // =====================================================================
  // WRITE PATH (BOOM write-back hits/misses; forwarded uncached and bursts)
  // =====================================================================
  // Write buffer: capture upstream AW/W into wbuf[]. BOOM-layout hits can
  // return B after the local bank write; misses wait for refill/install.
  // Forwarded transactions drain to memory and retain their AXI response.

  // ---- Snoop hit/update (fires same cycle as W capture) ----
  always_comb begin
    w_hit_update = 1'b0;
    if (!burst_active && axi_s.wvalid && axi_s.wready
        && (!BoomBankedStore || wbuf[w_wptr].posted) && cacheable(
            w_snoop_addr
        ) && |wbuf[w_wptr].cache[3:2] && w_hit_q) begin
      w_hit_update = 1'b1;
    end
  end

  // ---- Upstream (slave) handshakes ----
  // AW: accept when the target wbuf slot is empty AND not a same-line
  // race against an in-flight fill (AR/AW reordering hazard).
  logic l2_fill_in_progress;
  logic l2_aw_same_line;
  assign l2_fill_in_progress = (rs == R_EVICT_PROBE) || (rs == R_MISS_INVALIDATE)
      || (rs == R_MISS_AR) || (rs == R_MISS_R) || (rs == R_STORE_MERGE_READ)
      || (rs == R_STORE_MERGE_LATCH) || (rs == R_STORE_MERGE_WRITE);
  assign l2_aw_same_line = (axi_s.awaddr[XLEN-1:OffsetBits] == r_addr[XLEN-1:OffsetBits]);
  assign dir_aw_needs_read = BoomBankedStore && axi_s.awvalid && axi_s.awlen == 0 && cacheable_line(
      axi_s.awaddr
  ) && |axi_s.awcache[3:2];
  assign burst_aw_last_addr = axi_s.awaddr + (XLEN'(axi_s.awlen) << axi_s.awsize);
  assign burst_aw_span = (XLEN'(axi_s.awlen) + XLEN'(1)) << axi_s.awsize;
  assign burst_aw_wrap_base = axi_s.awaddr & ~(burst_aw_span - XLEN'(1));
  assign burst_aw_wrap_last = burst_aw_wrap_base + burst_aw_span - XLEN'(1);
  assign burst_alloc_needs_read = BoomBankedStore && axi_s.awvalid
      && axi_s.awlen != 8'd0
      && axi_s.awcache[0] && |axi_s.awcache[3:2] && cacheable_line(
      axi_s.awaddr
  ) && (source_read_shape(
      axi_s.awaddr, axi_s.awlen, axi_s.awsize, axi_s.awburst
  ) || (axi_s.awburst == 2'b01 && axi_s.awsize <= 3'($clog2(
      WordBytes
  )) && burst_aw_last_addr >= axi_s.awaddr && cacheable_line(
      burst_aw_last_addr
  )) || (axi_s.awburst == 2'b10 && axi_s.awsize <= 3'($clog2(
      WordBytes
  )) && (axi_s.awlen == 8'd1 || axi_s.awlen == 8'd3 || axi_s.awlen == 8'd7 ||
         axi_s.awlen == 8'd15) && (axi_s.awaddr & ((XLEN'(1) << axi_s.awsize) - XLEN'(1))) == '0 &&
      burst_aw_wrap_last >= burst_aw_wrap_base && cacheable_line(
      burst_aw_wrap_base
  ) && cacheable_line(
      burst_aw_wrap_last
  )));
  assign axi_s.awready = wipe_done && dir_ready && !ms_busy && !release_pending
      && !boom_bank_line_busy
      && !forward_cache_pending
      && !forward_scalar_pending
      && (!cbo_busy || (cbo_state == C_IDLE && l1d_writeback_pending_i)) && !burst_active
      && !(rs == R_EVICT_PROBE || rs == R_EVICT_AW || rs == R_EVICT_READ
          || rs == R_EVICT_W || rs == R_EVICT_B)
      && !(BoomBankedStore && (boom_queued_miss_or_unknown || rs != R_IDLE || rs_rvalid))
      && !(BoomBankedStore && dir_error_pending)
      && !(dir_aw_needs_read && (!dir_read_ready || dir_demand_read_valid))
      && !(burst_alloc_needs_read && (!dir_read_ready || dir_demand_read_valid))
      && (axi_s.awlen != 0
          ? (!burst_active && !(|wbuf_busy)
              && (!burst_alloc_needs_read || !(|forward_b_pending))
              && !bq_full && rs == R_IDLE && !rs_rvalid && !cache_install)
          : (!wbuf[aw_wptr].busy && !(|forward_b_pending)
              && !bq_full && !read_bypass_in_progress
              && !(l2_fill_in_progress && l2_aw_same_line)));
  assign dir_aw_read_fire = dir_aw_needs_read && axi_s.awready;
  assign dir_burst_alloc_read_fire = burst_alloc_needs_read && axi_s.awready;

  // W: accept when the W-target slot has an AW captured but no W yet.
  // (For single-beat stores w_wptr always points at the right slot.)
  logic wbuf_w_pending;
  assign wbuf_w_pending = wbuf[w_wptr].busy && !wbuf[w_wptr].has_w;
  assign burst_lookup_required = BoomBankedStore && burst_active && !burst_allocate
      && cacheable_line(
      burst_addr
  ) && |burst_cache[3:2];
  assign dir_burst_read_valid = BoomBankedStore && burst_active
      && (burst_allocate ? rs == R_IDLE && !burst_segment_ready
                         : burst_lookup_required && !burst_input_done && axi_s.wvalid)
      && (burst_allocate || !release_pending)
      && !burst_lookup_ready && !burst_lookup_pending
      && !cache_install && !dir_error_pending && !dir_demand_read_valid
      && !dir_aw_read_fire && !dir_error_lookup_request;
  assign burst_forward_ready = !burst_lookup_required
      || (burst_lookup_ready && (!burst_lookup_hit || dir_write_ready));
  assign axi_s.wready = burst_active
      ? (!bq_full && !boom_bank_line_busy && (burst_allocate || !release_pending)
         && (BoomBankedStore
             ? !burst_input_done && put_push_ready
                 && (burst_input_started || put_list_free)
                 && (burst_allocate ? burst_lookup_ready
                     : burst_forward_ready
                         && (!burst_lookup_required || !burst_lookup_hit
                             || bank_write_word_ready))
             : !burst_aw_pending && !burst_w_done && axi_m.wready && burst_forward_ready))
      : wbuf_w_pending && !bq_full && put_push_ready && (!BoomBankedStore || put_list_free)
          && !forward_scalar_head
          && !cache_install && !boom_bank_line_busy
          && (!BoomBankedStore || w_lookup_ready)
          && !(BoomBankedStore && (l2_fill_in_progress || dir_error_pending
              || rs == R_EVICT_PROBE || rs == R_EVICT_AW || rs == R_EVICT_READ
              || rs == R_EVICT_W || rs == R_EVICT_B))
          && (!BoomBankedStore || !w_hit_q || dir_write_ready)
          && (!BoomBankedStore || !w_hit_q || bank_write_word_ready);

  // B: BOOM-layout store misses wait for installation, and non-cacheable
  // writes wait for the real downstream B so CSR/MMIO stays ordered.
  assign axi_s.bvalid = (b_count != 0) && b_ready_q[b_rptr];
  assign axi_s.bid = b_id_q[b_rptr];
  assign axi_s.bresp = b_resp_q[b_rptr];

  // ---- Downstream (master) drives ----
  // AW/W issued combinationally from the drain head. axi_m.awvalid is
  // gated on ws==W_IDLE (no AW in flight) AND head ready.
  assign axi_m.awvalid = cbo_state == C_AW || (rs == R_EVICT_AW) || (burst_active ? (burst_aw_pending && !burst_allocate)
      : (ws == W_IDLE) && wbuf[d_rptr].busy && wbuf[d_rptr].has_w
          && !wbuf[d_rptr].local_hit && !wbuf[d_rptr].local_miss);
  assign axi_m.awaddr = cbo_state == C_AW
      ? XLEN'({cbo_tag, cbo_active_set, {OffsetBits{1'b0}}})
      : rs == R_EVICT_AW
      ? XLEN'({victim_tag_q, r_idx_q, {OffsetBits{1'b0}}})
      : burst_active ? burst_start : wbuf[d_rptr].addr;
  assign axi_m.awid = cbo_state == C_AW ? '0
      : rs == R_EVICT_AW ? r_id : burst_active ? burst_id : wbuf[d_rptr].id;
  assign axi_m.awlen = cbo_state == C_AW || rs == R_EVICT_AW ? 8'(LineSize - 1)
      : burst_active ? burst_len : wbuf[d_rptr].len;
  assign axi_m.awsize = cbo_state == C_AW || rs == R_EVICT_AW ? 3'($clog2(
      WordBytes
  )) : burst_active ? burst_size : wbuf[d_rptr].size;
  assign axi_m.awburst = cbo_state == C_AW || rs == R_EVICT_AW ? 2'b01
      : burst_active ? burst_kind : wbuf[d_rptr].burst;
  assign axi_m.awcache = cbo_state == C_AW ? 4'hf
      : rs == R_EVICT_AW ? r_cache
      : burst_active ? burst_cache : wbuf[d_rptr].cache;
  // BOOM-layout forwarded and allocated bursts both enter the shared Put
  // pool. Forwarded beats drain to AXI after AW; allocated beats drain into
  // the line merge buffer. A forwarded resident line is also updated through
  // the byte-masked bank port, and its B is the real outer response.
  // Smaller legacy configurations retain direct AXI W streaming.
  assign axi_m.wvalid = cbo_state == C_W || rs == R_EVICT_W || (burst_active
      ? (!burst_allocate && !burst_aw_pending && !burst_w_done
          && (BoomBankedStore ? burst_input_started && put_list_valid[burst_put_list]
                              : axi_s.wvalid && burst_forward_ready)) : ws == W_W);
  assign axi_m.wdata = cbo_state == C_W ? line_data_r[cbo_way][cbo_word]
      : rs == R_EVICT_W ? (BoomBankedStore ? boom_bank_sourcec_word
                                           : line_data_r[victim_way_q][evict_word])
      : burst_active ? (BoomBankedStore ? put_pop_data : axi_s.wdata) : drain_wdata;
  assign axi_m.wstrb = cbo_state == C_W || rs == R_EVICT_W ? '1
      : burst_active ? (BoomBankedStore ? put_pop_mask : axi_s.wstrb) : drain_wstrb;
  assign axi_m.wlast = cbo_state == C_W ? cbo_word == L2_LINE_LEN'(LineSize - 1)
      : rs == R_EVICT_W ? evict_word == L2_LINE_LEN'(LineSize - 1)
      : burst_active ? (BoomBankedStore ? put_pop_last : axi_s.wlast) : drain_wlast;
  assign axi_m.bready = cbo_state == C_B || rs == R_EVICT_B
      || (forward_b_match && (!forward_replay_b_match || forward_replay_state == F_DONE)) || (burst_active
      ? (!burst_allocate && !burst_aw_pending && burst_w_done)
      : ws == W_B && (forward_scalar_head
          ? (axi_m.bresp != 2'b00
              || (error_lookup_state == E_WRITE
                  && (!error_lookup_hit_q || forward_scalar_commit)))
          : !(dir_error_pending
              && (error_lookup_state != E_WRITE || cache_install
                  || (dir_error_hit && !dir_write_ready)))));
  assign burst_write_fire = burst_active && axi_s.wvalid && axi_s.wready;
  assign burst_hit_update = burst_write_fire && !burst_allocate
      && burst_lookup_required && burst_lookup_hit;
  assign forward_log_push = burst_hit_update;

  assign cbo_candidate = (BoomBankedStore ? |cbo_pending : cbo_busy)
      && cbo_state == C_IDLE && rs == R_IDLE
      && !ms_busy && !rs_rvalid && !cache_install
      && !release_pending
      && !l1d_writeback_pending_i
      && !any_write_in_flight && b_count == 0;
  assign cbo_apply = BoomBankedStore
      ? cbo_state == C_CLEAR && (cbo_active_broad ? dir_clear_ready
                              : !cbo_match || dir_write_ready)
      : cbo_candidate && dir_clear_ready;
  always_ff @(posedge clock) begin
    if (reset) begin
      cbo_pending <= '0;
      cbo_pending_broad <= '0;
      cbo_state <= C_IDLE;
      cbo_active_set <= '0;
      cbo_active_tag <= '0;
      cbo_active_broad <= 1'b0;
      cbo_active_requeue <= 1'b0;
      cbo_match <= 1'b0;
      cbo_probe_dirty <= 1'b0;
      cbo_way <= '0;
      cbo_word <= '0;
      cbo_entries_q <= '0;
      burst_active <= 0;
      burst_aw_pending <= 0;
      burst_input_started <= 0;
      burst_input_done <= 0;
      burst_w_done <= 0;
      burst_allocate <= 1'b0;
      burst_all_full <= 1'b0;
      burst_segment_ready <= 1'b0;
      burst_fill_count <= '0;
      burst_lookup_pending <= 1'b0;
      burst_lookup_ready <= 1'b0;
      burst_lookup_hit <= 1'b0;
      burst_lookup_way <= '0;
      burst_lookup_tag <= '0;
      burst_lookup_state <= '0;
      burst_lookup_dirty <= 1'b0;
      burst_lookup_clients <= 1'b0;
    end else begin
      if (BoomBankedStore) begin
        // The first pending request retains its exact physical tag. A second
        // request for the same set coalesces conservatively into a set scan;
        // a request arriving during the active scan is replayed afterward.
        if (cbo_inval_i) begin
          if (!cbo_pending[cbo_request_set]) begin
            cbo_pending[cbo_request_set] <= 1'b1;
            cbo_pending_tag[cbo_request_set] <= cbo_request_tag;
            cbo_pending_broad[cbo_request_set] <= 1'b0;
          end else if (cbo_pending_tag[cbo_request_set] != cbo_request_tag)
            cbo_pending_broad[cbo_request_set] <= 1'b1;
          if (cbo_state != C_IDLE && cbo_request_set == cbo_active_set) cbo_active_requeue <= 1'b1;
        end
        if (cbo_apply) begin
          cbo_active_requeue <= 1'b0;
          if (cbo_active_requeue || cbo_mask[cbo_active_set]) begin
            cbo_pending[cbo_active_set] <= 1'b1;
            cbo_pending_broad[cbo_active_set] <= 1'b1;
          end else begin
            cbo_pending[cbo_active_set] <= 1'b0;
            cbo_pending_broad[cbo_active_set] <= 1'b0;
          end
        end
        unique case (cbo_state)
          C_IDLE:
          if (cbo_candidate) begin
            cbo_active_set   <= cbo_clear_set;
            cbo_active_tag   <= cbo_pending_tag[cbo_clear_set];
            cbo_active_broad <= cbo_pending_broad[cbo_clear_set];
            if (cbo_inval_i && cbo_request_set == cbo_clear_set) cbo_active_requeue <= 1'b1;
            cbo_match <= 1'b0;
            cbo_state <= C_SCAN;
          end
          C_SCAN: if (dir_scan_ready) cbo_state <= C_SCAN_RESULT;
          C_SCAN_RESULT:
          if (dir_scan_result_valid) begin
            cbo_entries_q <= dir_scan_entries;
            cbo_way <= '0;
            cbo_state <= C_PICK;
          end
          C_PICK: begin
            if (cbo_entry[20:19] != 2'b00 && (cbo_active_broad || cbo_tag == cbo_active_tag)) begin
              if (!cbo_active_broad) cbo_match <= 1'b1;
              if (cbo_entry[18]) begin
                cbo_probe_dirty <= 1'b0;
                cbo_state <= C_PROBE;
              end else if (cbo_entry[21]) begin
                cbo_word  <= '0;
                cbo_state <= C_AW;
              end else if (!cbo_active_broad || cbo_way == WayBits'(L2_N_WAYS - 1))
                cbo_state <= C_CLEAR;
              else cbo_way <= cbo_way + 1'b1;
            end else if (cbo_way == WayBits'(L2_N_WAYS - 1)) cbo_state <= C_CLEAR;
            else cbo_way <= cbo_way + 1'b1;
          end
          C_PROBE:
          if (!release_pending && (!cbo_entry[18] || probe_ready_i)) begin
            if (cbo_entry[21] || cbo_probe_dirty) begin
              cbo_word  <= '0;
              cbo_state <= C_AW;
            end else if (!cbo_active_broad || cbo_way == WayBits'(L2_N_WAYS - 1))
              cbo_state <= C_CLEAR;
            else begin
              cbo_way   <= cbo_way + 1'b1;
              cbo_state <= C_PICK;
            end
          end
          C_AW: if (axi_m.awvalid && axi_m.awready) cbo_state <= C_READ;
          C_READ: if (!l2_sram_wblock) cbo_state <= C_W;
          C_W:
          if (axi_m.wvalid && axi_m.wready) begin
            if (cbo_word == L2_LINE_LEN'(LineSize - 1)) cbo_state <= C_B;
            else begin
              cbo_word  <= cbo_word + 1'b1;
              cbo_state <= C_READ;
            end
          end
          C_B:
          if (axi_m.bvalid && axi_m.bready) begin
            if (axi_m.bresp != 2'b00) cbo_state <= C_ERROR;
            else if (!cbo_active_broad || cbo_way == WayBits'(L2_N_WAYS - 1)) cbo_state <= C_CLEAR;
            else begin
              cbo_way   <= cbo_way + 1'b1;
              cbo_state <= C_PICK;
            end
          end
          C_CLEAR: if (cbo_apply) cbo_state <= C_IDLE;
          C_ERROR: cbo_state <= C_ERROR;
          default: cbo_state <= C_IDLE;
        endcase
        if (probe_release_fire && cbo_state == C_PROBE) cbo_probe_dirty <= 1'b1;
        // A C Release may update any resident way while the control request
        // waits for Probe. Refresh the saved scan, including later ways of a
        // broad CBO, so released dirty data is written back before clearing.
        if (cbo_state == C_PROBE && release_dir_write_fire
            && release_head_addr[IndexMsb:IndexLsb] == cbo_active_set) begin
          for (int way = 0; way < L2_N_WAYS; way++) begin
            if (cbo_entries_q[way*22+19+:2] != 2'b00
                && cbo_entries_q[way*22+:18]
                   == 18'(rapt_pkg::canonical_addr(
                    release_head_addr
                ) >> TagLsb)) begin
              cbo_entries_q[way*22+21] <= release_dir_dirty_q || release_head_has_data;
              cbo_entries_q[way*22+18] <= 1'b0;
              cbo_entries_q[way*22+19+:2] <= dir_write_state;
            end
          end
        end
      end else if (L2_N_WAYS * NSets <= 4000)
        cbo_pending <= cbo_apply ? '0 : cbo_pending | cbo_mask;
      else begin
        cbo_pending <= cbo_pending | cbo_mask;
        if (cbo_apply) cbo_pending[cbo_clear_set] <= 1'b0;
      end
      if (axi_s.awvalid && axi_s.awready && axi_s.awlen != 0) begin
        burst_active <= 1;
        burst_aw_pending <= !burst_alloc_needs_read;
        burst_input_started <= 0;
        burst_input_done <= 0;
        burst_w_done <= 0;
        burst_allocate <= burst_alloc_needs_read;
        burst_all_full <= burst_alloc_needs_read
            && axi_s.awburst == 2'b01
            && axi_s.awsize == 3'($clog2(
            WordBytes
        )) && axi_s.awaddr[OffsetBits-1:0] == '0;
        burst_segment_ready <= 1'b0;
        burst_fill_count <= burst_alloc_needs_read ? axi_s.awaddr[WordOffsetMsb:WordOffsetLsb] : '0;
        for (int word = 0; word < LineSize; word++) burst_mask_buf[word] <= '0;
        burst_start <= axi_s.awaddr;
        burst_addr <= axi_s.awaddr;
        burst_pop_addr <= axi_s.awaddr;
        burst_wrap_mask <= read_wrap_mask(axi_s.awlen, axi_s.awsize);
        burst_id <= axi_s.awid;
        burst_len <= axi_s.awlen;
        burst_size <= axi_s.awsize;
        burst_kind <= axi_s.awburst;
        burst_cache <= axi_s.awcache;
        burst_lookup_pending <= burst_alloc_needs_read;
        burst_lookup_ready <= 1'b0;
      end
      if (dir_burst_read_valid && dir_read_ready) burst_lookup_pending <= 1'b1;
      if (dir_result_valid && dir_result_for_burst_q) begin
        burst_lookup_pending <= 1'b0;
        burst_lookup_ready <= 1'b1;
        burst_lookup_hit <= dir_result_hit;
        burst_lookup_way <= dir_result_way;
        burst_lookup_tag <= dir_result_tag;
        burst_lookup_state <= dir_result_state;
        burst_lookup_dirty <= dir_result_dirty;
        burst_lookup_clients <= dir_result_clients;
      end
      if (burst_active && axi_m.awvalid && axi_m.awready) burst_aw_pending <= 0;
      if (burst_write_fire) begin
        if (BoomBankedStore && !burst_input_started) begin
          burst_put_list <= put_list_alloc;
          burst_input_started <= 1'b1;
        end
        if (!burst_allocate) burst_lookup_ready <= 1'b0;
        if (axi_s.wlast) begin
          if (BoomBankedStore) burst_input_done <= 1'b1;
          else burst_w_done <= 1'b1;
        end
        if (burst_kind == 2'b01)
          burst_addr <= (burst_addr & ~((XLEN'(1) << burst_size) - 1)) + (XLEN'(1) << burst_size);
        else if (burst_kind == 2'b10)
          burst_addr <= advance_read_addr(burst_addr, burst_size, burst_kind, burst_wrap_mask);
      end
      if (burst_put_pop_valid) begin
        if (rs != R_BURST_ERROR && !burst_direct_hit) begin
          burst_line_buf[burst_fill_count] <= merge_store_word(
              burst_line_buf[burst_fill_count], put_pop_data, put_pop_mask
          );
          burst_mask_buf[burst_fill_count] <= burst_mask_buf[burst_fill_count] | put_pop_mask;
        end
        burst_pop_addr   <= burst_pop_next_addr;
        burst_fill_count <= burst_pop_next_addr[WordOffsetMsb:WordOffsetLsb];
        if (!(&put_pop_mask) || (put_pop_last && same_line(burst_pop_addr, burst_pop_next_addr)))
          burst_all_full <= 1'b0;
        if (rs != R_BURST_ERROR && (put_pop_last || !same_line(
                burst_pop_addr, burst_pop_next_addr
            )))
          burst_segment_ready <= 1'b1;
        if (put_pop_last) burst_w_done <= 1'b1;
      end
      if (burst_active && burst_allocate && rs == R_BURST_DONE && !burst_w_done) begin
        burst_start <= burst_pop_addr;
        burst_lookup_ready <= 1'b0;
        burst_segment_ready <= 1'b0;
        burst_all_full <= burst_kind == 2'b01 && burst_size == 3'($clog2(
            WordBytes
        )) && burst_pop_addr[OffsetBits-1:0] == '0;
        for (int word = 0; word < LineSize; word++) burst_mask_buf[word] <= '0;
      end
      if (burst_forward_pop_valid && put_pop_last) burst_w_done <= 1'b1;
      if (burst_active
          && ((burst_allocate && (rs == R_BURST_DONE || rs == R_BURST_ERROR)
               && burst_w_done)
              || (!burst_allocate && (BoomBankedStore
                  ? burst_forward_pop_valid && put_pop_last
                  : !burst_aw_pending && burst_w_done && axi_m.bvalid && axi_m.bready))))
        burst_active <= 0;
    end
  end

  // ---- Combined capture + drain FSM ----
  always_ff @(posedge clock) begin
    if (reset) begin
      ws                <= W_IDLE;
      aw_wptr           <= '0;
      w_wptr            <= '0;
      d_rptr            <= '0;
      b_wptr            <= '0;
      b_rptr            <= '0;
      burst_rsp_slot    <= '0;
      b_count           <= '0;
      forward_b_pending <= '0;
      for (int i = 0; i < WbufDepth; i++) begin
        // wbuf payload is gated by busy/has_w (axi_m.awvalid) and the
        // b_* response registers by b_count (axi_s.bvalid); allocation
        // rewrites every payload field, so only the control bits reset.
        wbuf[i].busy <= 1'b0;
        wbuf[i].has_w <= 1'b0;
        wbuf[i].posted <= 1'b0;
        wbuf[i].forward_scalar <= 1'b0;
        wbuf[i].local_hit <= 1'b0;
        wbuf[i].local_miss <= 1'b0;
        wbuf[i].lookup_ready <= 1'b0;
      end
    end else begin
      if (burst_active && burst_allocate && (rs == R_BURST_DONE || rs == R_BURST_ERROR)
          && burst_w_done) begin
        b_ready_q[burst_rsp_slot] <= 1'b1;
        b_resp_q[burst_rsp_slot]  <= rs == R_BURST_ERROR ? r_resp : 2'b00;
      end
      if (BoomBankedStore && burst_forward_pop_valid && put_pop_last)
        forward_b_pending[burst_rsp_slot] <= 1'b1;
      if (forward_b_match && axi_m.bvalid && axi_m.bready) begin
        forward_b_pending[forward_b_slot] <= 1'b0;
        b_ready_q[forward_b_slot] <= 1'b1;
        b_resp_q[forward_b_slot] <= axi_m.bresp;
      end else if (!BoomBankedStore && burst_active && !burst_allocate
                   && !burst_aw_pending && burst_w_done && axi_m.bvalid && axi_m.bready) begin
        b_ready_q[burst_rsp_slot] <= 1'b1;
        b_resp_q[burst_rsp_slot]  <= axi_m.bresp;
      end
      if (BoomBankedStore && dir_result_valid && dir_result_for_aw_q) begin
        wbuf[dir_aw_slot_q].lookup_ready <= 1'b1;
        wbuf[dir_aw_slot_q].lookup_hit <= dir_result_hit;
        wbuf[dir_aw_slot_q].lookup_way <= dir_result_way;
        wbuf[dir_aw_slot_q].lookup_tag <= dir_result_tag;
        wbuf[dir_aw_slot_q].lookup_state <= dir_result_state;
        wbuf[dir_aw_slot_q].lookup_dirty <= dir_result_dirty;
        wbuf[dir_aw_slot_q].lookup_clients <= dir_result_clients;
      end
      // AW can precede W by many cycles. A fill may replace the saved way,
      // or an earlier store/error may invalidate the saved line. Apply this
      // after result capture so a same-cycle stale result cannot revive it.
      if (BoomBankedStore) begin
        for (int i = 0; i < WbufDepth; i++) begin
          if (wbuf[i].busy && !wbuf[i].has_w
              && ((cache_install
                   && wbuf[i].addr[IndexMsb:IndexLsb] == install_idx
                   && (dir_result_valid && dir_result_for_aw_q
                       && dir_aw_slot_q == WbufPtrW'(i) ? dir_result_way : wbuf[i].lookup_way)
                          == install_way)
                  || (dir_error_inv && same_line(
                  wbuf[i].addr, wbuf[d_rptr].addr
              ))))
            wbuf[i].lookup_hit <= 1'b0;
        end
      end
      // ---- Drain side (free a slot when downstream B returns) ----
      unique case (ws)
        W_IDLE: begin
          if (rs == R_STORE_DONE || rs == R_STORE_ERROR) begin
            b_ready_q[wbuf[d_rptr].rsp_slot] <= 1'b1;
            b_resp_q[wbuf[d_rptr].rsp_slot] <= rs == R_STORE_DONE ? 2'b00 : r_resp;
            wbuf[d_rptr].busy <= 1'b0;
            wbuf[d_rptr].has_w <= 1'b0;
            d_rptr <= (d_rptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (d_rptr + 1'b1);
          end else if (!burst_active && wbuf[d_rptr].busy && wbuf[d_rptr].has_w
              && wbuf[d_rptr].local_hit) begin
            if (!wbuf[d_rptr].posted) begin
              b_ready_q[wbuf[d_rptr].rsp_slot] <= 1'b1;
              b_resp_q[wbuf[d_rptr].rsp_slot]  <= 2'b00;
            end
            wbuf[d_rptr].busy <= 1'b0;
            wbuf[d_rptr].has_w <= 1'b0;
            d_rptr <= (d_rptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (d_rptr + 1'b1);
          end else if (!burst_active && rs != R_EVICT_AW && cbo_state != C_AW
                       && axi_m.awvalid && axi_m.awready)
            ws <= W_W;
        end
        W_W: begin
          if (axi_m.wready) ws <= W_B;
        end
        W_B: begin
          if (axi_m.bvalid && axi_m.bready) begin
            if (!wbuf[d_rptr].posted) begin
              b_ready_q[wbuf[d_rptr].rsp_slot] <= 1'b1;
              b_resp_q[wbuf[d_rptr].rsp_slot]  <= axi_m.bresp;
            end
            wbuf[d_rptr].busy  <= 1'b0;
            wbuf[d_rptr].has_w <= 1'b0;
            d_rptr             <= (d_rptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (d_rptr + 1'b1);
            ws                 <= W_IDLE;
          end
        end
        default: ws <= W_IDLE;
      endcase

      // ---- AW capture (slave) ----
      // Order matters: AW capture is after drain-free so that on the
      // wraparound cycle (drain freeing slot S while a new AW also
      // targets slot S because aw_wptr == d_rptr), the AW capture wins
      // and the slot is immediately re-used. NBA semantics preserved.
      if (axi_s.awvalid && axi_s.awready && axi_s.awlen == 0) begin
        wbuf[aw_wptr].busy <= 1'b1;
        wbuf[aw_wptr].has_w <= 1'b0;
        wbuf[aw_wptr].addr <= axi_s.awaddr;
        wbuf[aw_wptr].id <= axi_s.awid;
        wbuf[aw_wptr].size <= axi_s.awsize;
        wbuf[aw_wptr].len <= axi_s.awlen;
        wbuf[aw_wptr].burst <= axi_s.awburst;
        wbuf[aw_wptr].cache <= axi_s.awcache;
        wbuf[aw_wptr].posted <= cacheable(axi_s.awaddr) && axi_s.awcache[0] && |axi_s.awcache[3:2];
        wbuf[aw_wptr].forward_scalar <= BoomBankedStore && !axi_s.awcache[0]
            && |axi_s.awcache[3:2] && cacheable_line(
            axi_s.awaddr
        );
        wbuf[aw_wptr].local_hit <= 1'b0;
        wbuf[aw_wptr].local_miss <= 1'b0;
        wbuf[aw_wptr].lookup_ready <= !dir_aw_read_fire;
        wbuf[aw_wptr].lookup_hit <= 1'b0;
        wbuf[aw_wptr].lookup_way <= '0;
        wbuf[aw_wptr].lookup_tag <= '0;
        wbuf[aw_wptr].lookup_state <= '0;
        wbuf[aw_wptr].lookup_dirty <= 1'b0;
        wbuf[aw_wptr].lookup_clients <= 1'b0;
        // TODO(coalesce): if wbuf[*] has a busy entry to the same line
        // with !has_drained_yet, we could merge wstrb into it and skip
        // the enqueue. Saves a downstream beat for adjacent stores.
        aw_wptr <= (aw_wptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (aw_wptr + 1'b1);
      end

      // ---- W capture (slave) ----
      if (!burst_active && axi_s.wvalid && axi_s.wready) begin
        if (BoomBankedStore) wbuf[w_wptr].put_list <= put_list_alloc;
        wbuf[w_wptr].wdata <= axi_s.wdata;
        wbuf[w_wptr].wstrb <= axi_s.wstrb;
        wbuf[w_wptr].wlast <= axi_s.wlast;
        wbuf[w_wptr].local_hit <= BoomBankedStore && w_hit_update && wbuf[w_wptr].posted;
        wbuf[w_wptr].local_miss <= BoomBankedStore && wbuf[w_wptr].posted && cacheable_line(
            w_snoop_addr
        ) && !w_hit_update;
        if (axi_s.wlast) begin
          wbuf[w_wptr].has_w <= 1'b1;
          wbuf[w_wptr].rsp_slot <= b_wptr;
          w_wptr <= (w_wptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (w_wptr + 1'b1);
          // Enqueue upstream B in write order. A BOOM-layout miss waits for
          // the refill; forwarded non-cacheable writes wait for downstream B.
          b_id_q[b_wptr] <= wbuf[w_wptr].id;
          b_resp_q[b_wptr] <= 2'b00;
          b_ready_q[b_wptr] <= wbuf[w_wptr].posted && !(BoomBankedStore && cacheable_line(
              w_snoop_addr
          ) && !w_hit_update);
          b_wptr <= (b_wptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (b_wptr + 1'b1);
        end
      end

      if (burst_write_fire && axi_s.wlast) begin
        burst_rsp_slot <= b_wptr;
        b_id_q[b_wptr] <= burst_id;
        b_resp_q[b_wptr] <= 2'b00;
        b_ready_q[b_wptr] <= 1'b0;
        b_wptr <= (b_wptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (b_wptr + 1'b1);
      end

      // ---- Upstream B consume ----
      if (axi_s.bvalid && axi_s.bready) begin
        b_ready_q[b_rptr] <= 1'b0;
        b_resp_q[b_rptr] <= 2'b00;
        b_rptr <= (b_rptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (b_rptr + 1'b1);
      end

      // ---- B credit counter ----
      // Net delta: +1 on W-beat last capture, -1 on upstream B handshake.
      b_count <= b_count
                 + WbufCntW'((axi_s.wvalid && axi_s.wready && axi_s.wlast) ? 1 : 0)
                 - WbufCntW'((axi_s.bvalid && axi_s.bready) ? 1 : 0);
    end
  end

`endif  // RAPT_L2_ACTIVE

  // Scope the helper define to this module so it does not leak into other
  // translation-unit files in single-unit Verilator/Yosys compilation.
`ifdef RAPT_L2_ACTIVE
  `undef RAPT_L2_ACTIVE
`endif

endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
