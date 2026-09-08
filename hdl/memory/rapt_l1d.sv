`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

/* verilator lint_off PINCONNECTEMPTY */
module rapt_l1d #(
    parameter int L1D_LINE_LEN = `RAPT_L1D_LINE_LEN,
    parameter int unsigned L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
    parameter int L1D_LEN = `RAPT_L1D_LEN,
    parameter int unsigned L1D_SIZE = 2 ** L1D_LEN,
    parameter int XLEN = `RAPT_XLEN,
    parameter unsigned L1D_N_WAYS = `RAPT_L1D_N_WAYS
) (
    input clock,
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
    rou_cmu_if.in rou_cmu,

    input reset
);
  pmp_state_if pmp_state ();

  rapt_pmp_state pmp_state_regs (
      .clock(clock),
      .reset(reset),
      .update(pmp_update),
      .state(pmp_state)
  );

  typedef enum logic [2:0] {
    IDLE   = 3'b000,
    PTWAIT = 3'b100,  // waiting for PTW to complete
    TRAP   = 3'b101,
    LD_CHECK = 3'b011,
    LD_A   = 3'b001,
    LD_D   = 3'b010
  } l1d_state_t;

  l1d_state_t l1d_state;

  logic [XLEN-1:0] l1d_addr;
  logic [1:0] l1d_pbmt;
  logic l1d_orig_misaligned;
  logic l1d_check_valid;
  logic [2:0] l1d_check_offset;
  logic [3:0] l1d_check_size_m1;
  logic [3:0] l1d_orig_size_m1;
  logic load_io_size_fault, store_io_size_fault;
  assign load_io_size_fault = l1d_orig_misaligned
      && (l1d_pbmt == 2'b10 || rapt_pkg::addr_device(l1d_addr));
  assign store_io_size_fault = exu_l1d.misaligned
      && (exu_l1d.pbmt == 2'b10 || rapt_pkg::addr_device(exu_l1d.paddr));
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
  localparam unsigned L1dOffsetBits = $clog2(XLEN / 8);  // 2 for RV32, 3 for RV64
  localparam unsigned L1dTagW = XLEN - L1D_LEN - L1D_LINE_LEN - L1dOffsetBits;
  localparam unsigned L1dWayW = L1D_N_WAYS > 1 ? $clog2(L1D_N_WAYS) : 1;
  logic [L1D_SIZE-1:0] fence_clear_set;
  logic fence_clear_busy;

  assign fence_clear_busy = cmu_bcast.fence_time || |fence_clear_set;

  logic [7:0] rstrb;

  logic [L1dTagW-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic [L1D_LINE_LEN-1:0] addr_offset;
  logic tag_hit;   // tag comparison result (combinational, from register arrays)
  logic data_hit;  // SRAM data ready after 1-cycle read latency
  logic [XLEN-1:0] l1d_data;
  logic cacheable_r;
  logic cacheable_w;

  logic [L1dTagW-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic [L1D_LINE_LEN-1:0] waddr_offset;
  logic hit_w;

  logic mmu_en;
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
  logic l1d_atomic_lock;
  logic [3:0] reservation_size_m1;
  logic lr_interfered;
  logic external_hits_reservation, external_hits_lr;
  function automatic logic external_overlap(input logic [XLEN-1:0] first,
                                            input logic [3:0] size_m1);
    return external_write_valid_i
        && {1'b0, external_write_first_i} <= ({1'b0, first} + (XLEN+1)'(size_m1))
        && external_write_last_i >= first;
  endfunction
  assign external_hits_reservation = reservation_valid
      && external_overlap(reservation, reservation_size_m1);
  // Translation has not produced a PA during PTWAIT. Poison that in-flight
  // LR conservatively; subsequent hot-TLB attempts use physical overlap.
  assign external_hits_lr = l1d_atomic_lock
      && ((l1d_state == PTWAIT && external_write_valid_i)
        || ((l1d_state == LD_CHECK || l1d_state == LD_A || l1d_state == LD_D)
          && external_overlap(l1d_addr, l1d_ralu[1:0] == 2'b11 ? 4'd7 : 4'd3)));


  // PTW instance signals
  logic ptw_req;
  /* verilator lint_off UNUSEDSIGNAL */
  logic ptw_busy;
  logic load_killed;
  /* verilator lint_on UNUSEDSIGNAL */
  logic ptw_done, ptw_fault;
  logic ptw_arvalid;
  logic [XLEN-1:0] ptw_araddr;
  logic ptw_awvalid;
  logic [XLEN-1:0] ptw_awaddr;
  logic ptw_wvalid;
  logic [XLEN-1:0] ptw_wdata;
  logic [7:0] ptw_wstrb;
  logic ptw_wready;
  logic [XLEN-1:0] ptw_vaddr;
  logic [XLEN-1:10] ptw_result_ptag;
  logic [XLEN-1:12] ptw_result_vtag;
  logic [6:0] ptw_result_pte;

  // mis-alignment check
  logic mis_align_load;
  logic mis_align_store;

  logic l1d_update;
  logic [XLEN-1:0] l1d_data_u;
  logic l1d_valid_u;
  // When set together with valid_u==0, the update commit invalidates the
  // selected (idx, off) word in EVERY way (broadcast invalidate).  Used for
  // partial stores so that any duplicate-tag legacy line cannot keep stale
  // data in a non-`store_hit_way` slot.
  logic l1d_inv_all_ways;
  logic [L1dTagW-1:0] l1d_tag_u;
  logic [L1D_LEN-1:0] l1d_idx;
  logic [L1D_LINE_LEN-1:0] l1d_off;
  logic [L1dWayW-1:0] l1d_way;           // which way for pending l1d_update
  logic [L1dWayW-1:0] ld_fill_way_r;     // registered fill way for load miss
  logic [L1D_SIZE-1:0] d_replace_bit;      // random replacement toggle per set (used for 2-way only)

  assign lsu_l1d.idle = l1d_state == IDLE && !ptw_busy && !l1d_update
      && !fence_clear_busy && !lsu_l1d.rvalid && !lsu_l1d.rvalid_b
      && !lsu_l1d.wvalid && !exu_l1d.valid;

  // Read-Modify-Write (RMW) for partial store cache updates.
  // When a partial store (SB/SH, or SW in RV64) hits in cache, instead of
  // invalidating, we read the old SRAM word, merge in the new bytes, and
  // write back the full merged word. This takes 2 cycles:
  //   Cycle N:   detect hit, steer sram_raddr to store's set, register store info
  //   Cycle N+1: SRAM data available, compute merge, set l1d_update for write
  logic l1d_rmw;
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
      && !cmu_bcast.flush_pipe && !fence_clear_busy);

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

  localparam logic [7:0] FullStoreWstrb = 8'({XLEN / 8{1'b1}});
  assign partial_store_rmw = !l1d_rmw && !l1d_update
      && (l1d_state == IDLE)  // Only in IDLE; PTWAIT/LD_D would steal read port
      && !load_speculate  // load speculation uses SRAM read port
      && lsu_l1d.wvalid && l1d_bus.wready && !l1d_bus.werr && cacheable_w && hit_w
      && (lsu_l1d.walu != FullStoreWstrb);  // partial-store RMW: SRAM read port is free in IDLE, capture the
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
  assign sram_raddr = partial_store_rmw ? waddr_idx
      : load_speculate
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits]
      : sram_raddr_fallback;

  // Data-array ownership includes SRAM geometry and read-valid tracking.
  logic [XLEN-1:0] data_bank_rdata[L1D_N_WAYS][L1D_LINE_SIZE];
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
      .write_valid(l1d_update),
      .write_addr(l1d_idx),
      .write_word(l1d_off),
      .write_way(l1d_way),
      .write_data(l1d_data_u),
      .read_valid(sram_read_valid_r),
      .read_index(sram_read_idx_r),
      .read_data(data_bank_rdata)
  );

  // Partial store RMW merge logic: byte-lane merge of old SRAM data with new store data
  logic [XLEN/8-1:0] rmw_byte_mask;
  logic [XLEN-1:0] rmw_bit_mask;
  logic [XLEN-1:0] rmw_data_shifted;
  logic [XLEN-1:0] rmw_merged_data;

  assign rmw_byte_mask = l1d_rmw_walu[XLEN/8-1:0] << l1d_rmw_waddr_lo;
  always_comb begin
    for (int i = 0; i < XLEN / 8; i++) begin
      rmw_bit_mask[i*8+:8] = {8{rmw_byte_mask[i]}};
    end
  end
  assign rmw_data_shifted = l1d_rmw_wdata << (l1d_rmw_waddr_lo * 8);
  assign rmw_merged_data = (data_bank_rdata[l1d_way][l1d_off] & ~rmw_bit_mask)
                         | (rmw_data_shifted & rmw_bit_mask);

  assign mmu_en = csr_bcast.dmmu_en;

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
      .lookup_asid(csr_bcast.satp_asid),
      .hit(tlb_hit),
      .ptag(dtlb_ptag),
      .pte_flags(dtlb_pte),
      .pbmt(dtlb_pbmt),
      .fill_valid(dtlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid),
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
      .lookup_asid(csr_bcast.satp_asid),
      .hit(stlb_hit),
      .ptag(dstlb_ptag),
      .pte_flags(dstlb_pte),
      .pbmt(dstlb_pbmt),
      .fill_valid(dstlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid),
      .fill_pbmt(ptw_result_pbmt),
      .fill_pte(ptw_result_pte)
  );

  // Shared PTW: serves both load and store TLB misses
  logic store_tlb_miss;
  assign store_tlb_miss = exu_l1d.mmu_en && exu_l1d.valid && !stlb_hit && !mis_align_store;
  assign ptw_vaddr = store_tlb_miss ? exu_l1d.vaddr : lsu_l1d.raddr;

  logic load_tlb_miss;
  logic ptw_read_error;
  assign ptw_read_error = l1d_bus.ptw_rvalid && l1d_bus.ptw_rerr;
  assign load_tlb_miss = lsu_l1d.rvalid && !tlb_hit && !mis_align_load
                       && !(exu_l1d.mmu_en && exu_l1d.valid);
  assign ptw_req = (l1d_state == IDLE) && mmu_en && !cmu_bcast.flush_pipe
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
      .mmu_en(mmu_en),
      .pbmte(csr_bcast.menvcfg_pbmte),
      .sbe(csr_bcast.sbe),
      // CBO management checks A but not D; make the Svade walker treat it as
      // a non-store while the requester applies the CMO R-or-W permission.
      .req_store(store_tlb_miss && !exu_l1d.cmo_mgmt),
      .bus_arvalid(ptw_arvalid),
      .bus_araddr(ptw_araddr),
      .bus_arready(l1d_bus.rready),
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

  assign addr_tag = l1d_addr[XLEN-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign addr_idx = l1d_addr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign addr_offset = l1d_addr[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];

  logic [L1D_N_WAYS-1:0] load_way_hit;
  logic [L1dWayW-1:0] store_hit_way, store_fill_way, ld_fill_way;
  rapt_l1d_tags #(
      .L1D_LEN(L1D_LEN),
      .L1D_LINE_LEN(L1D_LINE_LEN),
      .L1D_SIZE(L1D_SIZE),
      .L1D_LINE_SIZE(L1D_LINE_SIZE),
      .L1D_N_WAYS(L1D_N_WAYS),
      .L1dTagW(L1dTagW)
  ) u_tags (
      .clock(clock),
      .reset(reset),
      .fence_time(cmu_bcast.fence_time),
      .clear_set(fence_clear_set),
      .addr_idx(addr_idx),
      .addr_offset(addr_offset),
      .addr_tag(addr_tag),
      .waddr_idx(waddr_idx),
      .waddr_offset(waddr_offset),
      .waddr_tag(waddr_tag),
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
      .store_replace(d_replace_bit[waddr_idx]),
      .load_way_hit(load_way_hit),
      .hit_w(hit_w),
      .store_hit_way(store_hit_way),
      .store_fill_way(store_fill_way),
      .ld_fill_way(ld_fill_way),
      .l1d_update(l1d_update),
      .l1d_valid_u(l1d_valid_u),
      .l1d_inv_all_ways(l1d_inv_all_ways),
      .l1d_tag_u(l1d_tag_u),
      .l1d_idx(l1d_idx),
      .l1d_off(l1d_off),
      .l1d_way(l1d_way)
  );

  // A load may consume SRAM data only when every way/subarray completed a
  // read for its index. Writes invalidate that shared correspondence; LD_A
  // then holds the request while the following free cycle re-reads it.
  logic l1d_sram_busy;
  assign l1d_sram_busy = l1d_update
                       || !sram_read_valid_r
                       || (sram_read_idx_r != addr_idx);
  assign tag_hit = (l1d_state == LD_A)
    && cacheable_r
    && !l1d_sram_busy
    && |load_way_hit;
  // data_hit: SRAM data ready in LD_A: the speculative read in the preceding
  // IDLE (or PTW-wait) cycle guarantees data_bank_rdata is valid on LD_A entry.
  assign data_hit = (l1d_state == LD_A) && tag_hit;
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
  //  While the A channel waits on a miss refill (LD_D), the SRAM read port
  //  is idle (A's data comes straight from the bus).  Serve a best-effort
  //  second load on it: cycle N steers the read port to B's set (b_armed),
  //  cycle N+1 does the tag compare and completes on a clean hit.  A B load
  //  that misses / collides simply never completes here and retries via A
  //  later, which owns all trap/PMP/PTW handling.  Bare mode only
  //  (!mmu_en): under MMU the B vaddr is untranslated, so it is not served.
  //
  //  Data hazards: any cycle with l1d_update / l1d_rmw active (fill or
  //  merge write in flight) kills the B attempt because the data SRAM read
  //  address is not available to that request.
  // ==========================================================================
`ifdef RAPT_LSU_HUM
  logic b_armed;
  logic [XLEN-1:0] b_addr_r;
  assign b_idx_in = lsu_l1d.raddr_b[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign b_arm_ok = (l1d_state == LD_D) && lsu_l1d.rvalid_b && !mmu_en
                  && !l1d_rmw && !l1d_update
                  && rapt_pkg::addr_cacheable(lsu_l1d.raddr_b)
                  && !cmu_bcast.flush_pipe;

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
  assign b_tag = b_addr_r[XLEN-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign b_idx = b_addr_r[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign b_off = b_addr_r[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];

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
                         && !l1d_rmw && !l1d_update
                         && !cmu_bcast.flush_pipe;
  assign lsu_l1d.rdata_b = b_data;
`else
  assign lsu_l1d.rready_b = 1'b0;
  assign lsu_l1d.rdata_b  = '0;
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_hum_b;
  assign _unused_hum_b = lsu_l1d.rvalid_b ^ (^lsu_l1d.raddr_b) ^ (^lsu_l1d.ralu_b);
  /* verilator lint_on UNUSEDSIGNAL */
`endif

  assign waddr_tag = lsu_l1d.waddr[XLEN-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign waddr_idx = lsu_l1d.waddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign waddr_offset = lsu_l1d.waddr[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];

  assign cacheable_r = rapt_pkg::addr_cacheable(l1d_addr) && l1d_pbmt == 2'b00;
  assign cacheable_w = rapt_pkg::addr_cacheable(lsu_l1d.waddr) && lsu_l1d.wpbmt == 2'b00;

  // Access policy is combinational; this controller owns fault timing.
  logic pmp_load_fault, load_unmapped_fault;
  logic load_region_unmapped_fault;
  // LR never forwards from SQ. Check its translated physical address before
  // either a cache-hit response or an external read can establish reservation.
  assign load_unmapped_fault = load_region_unmapped_fault || !rapt_pkg::addr_device_width_capable(
      l1d_addr + (l1d_check_valid ? XLEN'(l1d_check_offset) : XLEN'(0)),
      l1d_check_valid ? l1d_orig_size_m1 : ((4'd1 << l1d_ralu[1:0]) - 4'd1)
  ) || (l1d_atomic_lock && !rapt_pkg::addr_atomic_capable(
      l1d_addr, l1d_ralu[1:0] == 2'b11 ? 4'd7 : 4'd3
  ));
  logic pmp_store_fault_mmu, store_unmapped_fault_mmu, pmp_ptw_fault;
  logic pf_load_tlb, pf_store_tlb, pf_load_ptw, pf_store_ptw;
  rapt_l1d_access #(
      .XLEN(XLEN)
  ) u_access (
      .csr_bcast(csr_bcast),
      .pmp_state(pmp_state),
      .load_addr(l1d_addr + (l1d_check_valid ? XLEN'(l1d_check_offset) : XLEN'(0))),
      .store_addr(exu_l1d.paddr),
      .ptw_addr(ptw_araddr),
      .load_size_m1(l1d_check_valid ? l1d_check_size_m1
          : ((4'd1 << l1d_ralu[1:0]) - 4'd1)),
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
  assign mis_align_load  = 1'b0;
  assign mis_align_store = 1'b0;

  // read channel: PTW takes priority over cache miss reads
  assign l1d_bus.arvalid = ptw_arvalid
    ? !pmp_ptw_fault
    : (l1d_state == LD_A)
      && !tag_hit
      && !l1d_sram_busy
      && (cacheable_r || lsu_l1d.ordered)
      && !cmu_bcast.flush_pipe;
  assign l1d_bus.araddr = ptw_arvalid ? ptw_araddr : l1d_addr;
  assign l1d_bus.rstrb = (cacheable_r || ptw_arvalid) ? 8'($unsigned({XLEN/8{1'b1}})) : rstrb;
  assign l1d_bus.ar_ptw = ptw_arvalid;
  assign l1d_bus.rpbmt = ptw_arvalid ? 2'b00 : l1d_pbmt;

  assign lsu_l1d.rdata = data_hit ? l1d_data : l1d_bus.rdata;
  // Difftest skip propagation for MMIO loads: cache-hit loads (data_hit=1) are
  // by construction cacheable (and thus non-MMIO), so they don't need to skip
  // the reference model. For misses that go to bus, mirror the bus-side mmio
  // bit so the commit-time DPI can skip REF on the owning instruction.
  assign lsu_l1d.difftest_skip = (data_hit || lsu_l1d.trap) ? 1'b0 : l1d_bus.difftest_skip;
  assign lsu_l1d.trap = (l1d_state == TRAP) && !rec_store && (rec_addr == lsu_l1d.raddr)
      && !load_killed && !cmu_bcast.flush_pipe;
  assign lsu_l1d.cause = cause;
  // LD_A is reached only after LD_CHECK accepted the complete access.
  // Keep live permission decoding out of the ready/fast-wakeup path.
  assign lsu_l1d.rready = !load_killed && !cmu_bcast.flush_pipe && ((lsu_l1d.rvalid && lsu_l1d.trap)
      || (data_hit
        && lsu_l1d.rvalid
        && rec_addr == lsu_l1d.raddr)
      || ((l1d_state == LD_D)
          && (lsu_l1d.rvalid)
          && (l1d_bus.rvalid)
          && !l1d_bus.rerr
          && (rec_addr == lsu_l1d.raddr)));

  // write channel
  assign l1d_bus.awvalid = ptw_awvalid ? 1'b1 : lsu_l1d.wvalid;
  assign l1d_bus.awaddr = ptw_awvalid ? ptw_awaddr : lsu_l1d.waddr;
  assign l1d_bus.aw_ptw = ptw_awvalid;
  assign l1d_bus.wpbmt = ptw_awvalid ? 2'b00 : lsu_l1d.wpbmt;
  assign l1d_bus.wstrb = ptw_wvalid ? ptw_wstrb : lsu_l1d.walu;
  assign l1d_bus.wvalid = ptw_wvalid ? 1'b1 : lsu_l1d.wvalid;
  assign l1d_bus.wdata = ptw_wvalid ? ptw_wdata : lsu_l1d.wdata;

  assign ptw_wready = ptw_wvalid && l1d_bus.ptw_wready;
  // Gate lsu wready while an RMW is in its merge-write phase: the SET block
  // below runs the `if (l1d_rmw)` branch this cycle, which means an incoming
  // store would not be consumed by the `else if (lsu_l1d.wvalid ...)` branch
  // and would be silently dropped if wready had fired. Stalling the store
  // for one cycle lets the merge-write complete and the next-cycle SET will
  // re-evaluate the new store.
  assign lsu_l1d.wready = !ptw_wvalid && l1d_bus.wready && !l1d_rmw && !fence_clear_busy;
  assign lsu_l1d.werr = lsu_l1d.wready && l1d_bus.werr;

  // store address translation: stlb_hit uses TLB, otherwise wait for PTW
  assign store_paddr = XLEN'({ptw_result_ptag, exu_l1d.vaddr[11:0]});
  assign exu_l1d.paddr = stlb_hit
    ? XLEN'({dstlb_ptag, exu_l1d.vaddr[11:0]})
    : store_paddr;
  assign exu_l1d.pbmt = exu_l1d.mmu_en
    ? (stlb_hit ? dstlb_pbmt : ptw_result_pbmt) : 2'b00;
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
      rec_store <= 1'b0;
      fence_clear_set <= '0;
      l1d_update <= 0;
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
    end else begin
      fence_clear_set <= {L1D_SIZE{cmu_bcast.fence_time}};
      if (external_hits_reservation) begin
        reservation_valid <= 1'b0;
      end
      unique case (l1d_state)
        IDLE: begin
          load_killed <= 1'b0;
          l1d_atomic_lock <= 1'b0;
          if (!cmu_bcast.flush_pipe && !fence_clear_busy
              && (!lsu_l1d.atomic_lock || !exu_l1d.reservation_blocked)) begin
            if (mmu_en) begin
              // Store TLB lookup (priority)
              if (exu_l1d.mmu_en && exu_l1d.valid) begin
                rec_store <= 1'b1;
                if (mis_align_store) begin
                  cause <= 'h6; // store address mis-aligned
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (stlb_hit && pf_store_tlb) begin
                  // PTE permission denies store.
                  cause <= `RAPT_CAUSE_STORE_PAGE_FAULT;
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (stlb_hit && (pmp_store_fault_mmu || store_unmapped_fault_mmu || store_io_size_fault)) begin
                  // PMP violation on translated store address.
                  cause <= `RAPT_CAUSE_STORE_ACC_FAULT;
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (!stlb_hit && !ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr <= exu_l1d.vaddr;
                  rec_addr <= exu_l1d.vaddr;
                  stlb_mmu <= 'b1;
                  l1d_state <= PTWAIT;
                end
              end else if (lsu_l1d.rvalid) begin
                rec_store <= 1'b0;
                // Load TLB lookup
                if (mis_align_load) begin
                  cause <= 'h4; // load address mis-aligned
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
                  l1d_ralu  <= lsu_l1d.ralu;
                  l1d_orig_misaligned <= lsu_l1d.rmisaligned;
                  l1d_check_valid <= lsu_l1d.rcheck_valid;
                  l1d_check_offset <= lsu_l1d.rcheck_offset;
                  l1d_check_size_m1 <= lsu_l1d.rcheck_size_m1;
                  l1d_orig_size_m1 <= lsu_l1d.rorig_size_m1;
                  l1d_atomic_lock <= lsu_l1d.atomic_lock;
                  l1d_state <= LD_CHECK;
                end else if (!ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr <= lsu_l1d.raddr;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
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
                l1d_addr <= lsu_l1d.raddr;
                l1d_pbmt <= 2'b00;
                rec_addr <= lsu_l1d.raddr;
                l1d_ralu  <= lsu_l1d.ralu;
                l1d_orig_misaligned <= lsu_l1d.rmisaligned;
                l1d_check_valid <= lsu_l1d.rcheck_valid;
                l1d_check_offset <= lsu_l1d.rcheck_offset;
                l1d_check_size_m1 <= lsu_l1d.rcheck_size_m1;
                l1d_orig_size_m1 <= lsu_l1d.rorig_size_m1;
                l1d_atomic_lock <= lsu_l1d.atomic_lock;
                l1d_state <= LD_CHECK;
              end
            end
          end
        end
        PTWAIT: begin
          if (cmu_bcast.flush_pipe) begin
            stlb_mmu <= 'b0;
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
              end else if (pmp_store_fault_mmu || store_unmapped_fault_mmu || store_io_size_fault) begin
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
                l1d_state <= LD_CHECK;
              end
            end
          end else if (ptw_fault) begin
            if (stlb_mmu) begin
              cause <= 'hf; // store page fault
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
          if (cmu_bcast.flush_pipe) begin
            l1d_addr <= '0;
            l1d_state <= IDLE;
          end else if (pmp_load_fault || load_unmapped_fault || load_io_size_fault) begin
            // PMP denies load at this physical address for eff_priv,
            // or the address is unmapped (bus error -> access fault).
            cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
            l1d_state <= TRAP;
          end else begin
            l1d_state <= LD_A;
          end
        end
        LD_A: begin
          if (cmu_bcast.flush_pipe) begin
            l1d_addr <= '0;
            l1d_state <= IDLE;
          end else if (!cacheable_r && !lsu_l1d.ordered) begin
            l1d_state <= LD_A;
          end else if (l1d_atomic_lock) begin
            if (tag_hit) begin
              reservation <= l1d_addr;
              reservation_valid <= !lr_interfered && !external_hits_lr;
              reservation_size_m1 <= l1d_ralu[1:0] == 2'b11 ? 4'd7 : 4'd3;
              l1d_addr  <= '0;
              l1d_state <= IDLE;
            end else begin
              // Only advance on OUR OWN cache-miss AR acceptance. The PTW
              // shares this bus with read priority (see l1d_bus.arvalid mux),
              // so an `l1d_bus.rready` (= AR-capture) pulse while ptw_arvalid
              // is high belongs to the PTW, not this load. Advancing on it
              // would make LD_D consume the PTW's read beat as fill data.
              if (l1d_bus.rready && !ptw_arvalid) begin
                l1d_state <= LD_D;
                ld_fill_way_r <= ld_fill_way;
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
            if (l1d_bus.rready && !ptw_arvalid) begin
              l1d_state <= LD_D;
              ld_fill_way_r <= ld_fill_way;
            end
          end
        end
        LD_D: begin
          if (cmu_bcast.flush_pipe) begin
            load_killed <= 1'b1;
          end
          if (l1d_bus.rvalid) begin
            // Bus error on the response beat -> load access-fault. Gated
            // on `rvalid` (the same condition that consumes the beat), so
            // transient `rerr` in unrelated cycles is ignored.
            if (load_killed || cmu_bcast.flush_pipe) begin
              // Accepted reads still drain after cancellation, including an
              // error response. They must not fault a newer same-VA owner.
              l1d_state <= IDLE;
            end else if (l1d_bus.rerr) begin
              cause     <= `RAPT_CAUSE_LOAD_ACC_FAULT;
              l1d_state <= TRAP;
            end else begin
              l1d_state <= IDLE;
              if (l1d_atomic_lock && !load_killed && !cmu_bcast.flush_pipe) begin
                reservation <= l1d_addr;
                reservation_valid <= !lr_interfered && !external_hits_lr;
                reservation_size_m1 <= l1d_ralu[1:0] == 2'b11 ? 4'd7 : 4'd3;
              end
            end
          end
        end
        default: begin
          l1d_addr <= '0;
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
      if (|fence_clear_set) begin
        l1d_rmw <= 0;
      end else if (l1d_update) begin
        // u_tags consumes the same pending update on this edge.
        l1d_update <= 0;
        l1d_inv_all_ways <= 0;
      end


      // l1d_update SET: request a new SRAM + tag/valid write next cycle.
      // Textually last so its NBA to l1d_update wins over the CLEAR above.
      if (l1d_rmw) begin
        // RMW phase 2: SRAM data available from previous cycle read,
        // compute byte-lane merge and schedule the write-back.
        l1d_rmw <= 0;
        l1d_update <= 1'b1;
        l1d_data_u <= rmw_merged_data;
        l1d_valid_u <= 1'b1;
        // l1d_idx, l1d_off, l1d_tag_u already set at RMW trigger
      end else if (lsu_l1d.wvalid && lsu_l1d.wready && l1d_bus.werr) begin
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
      end else if (lsu_l1d.wvalid && l1d_bus.wready && cacheable_w) begin
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
      end else if (l1d_state == LD_D) begin
        if (lsu_l1d.rvalid && l1d_bus.rvalid && !l1d_bus.rerr
            && !load_killed && !cmu_bcast.flush_pipe) begin
          if (cacheable_r) begin
            l1d_update <= 1'b1;
            l1d_data_u <= l1d_bus.rdata;
            l1d_valid_u <= 1'b1;
            l1d_tag_u <= addr_tag;
            l1d_idx <= addr_idx;
            l1d_off <= addr_offset;
            l1d_way <= ld_fill_way_r;
            if (L1D_N_WAYS == 2) d_replace_bit[addr_idx] <= ~d_replace_bit[addr_idx];
          end
        end
      end
    end
  end

  `RAPT_SVA_IMPLY(clock, reset, L1D_MMIO_READ_REQUIRES_ORDER,
                  l1d_bus.arvalid && !l1d_bus.ar_ptw && !cacheable_r, lsu_l1d.ordered)
  `RAPT_SVA_IMPLY(clock, reset, L1D_FLUSH_BLOCKS_NEW_READ, cmu_bcast.flush_pipe, !l1d_bus.arvalid)
  `RAPT_SVA_IMPLY(clock, reset, L1D_PERMISSION_STAGE_BLOCKS_ACCESS, l1d_state == LD_CHECK,
                  !lsu_l1d.rready && !(l1d_bus.arvalid && !l1d_bus.ar_ptw))
  `RAPT_SVA_NEXT(
      clock, reset, L1D_PERMISSION_STAGE_DENIED,
      l1d_state == LD_CHECK && !cmu_bcast.flush_pipe && (pmp_load_fault || load_unmapped_fault || load_io_size_fault),
      l1d_state == TRAP)
  `RAPT_SVA_NEXT(
      clock, reset, L1D_LR_HIT_ESTABLISHES_RESERVATION,
      (l1d_state == LD_A) && tag_hit && l1d_atomic_lock && !cmu_bcast.flush_pipe && !exu_l1d.reservation_clear && !external_hits_lr && !lr_interfered,
      reservation_valid && reservation == $past(l1d_addr))
  `RAPT_SVA_NEXT(
      clock, reset, L1D_LR_RESPONSE_ESTABLISHES_RESERVATION,
      (l1d_state == LD_D) && l1d_bus.rvalid && !l1d_bus.rerr && l1d_atomic_lock && !load_killed && !cmu_bcast.flush_pipe && !exu_l1d.reservation_clear && !external_hits_lr && !lr_interfered,
      reservation_valid && reservation == $past(l1d_addr))
  `RAPT_SVA_NEXT(
      clock, reset, L1D_KILLED_LR_RESPONSE_NO_NEW_RESERVATION,
      (l1d_state == LD_D) && l1d_bus.rvalid && l1d_atomic_lock && !reservation_valid && (load_killed || cmu_bcast.flush_pipe),
      !reservation_valid)
endmodule
/* verilator lint_on PINCONNECTEMPTY */
