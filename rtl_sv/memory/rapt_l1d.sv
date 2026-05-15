`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

module rapt_l1d #(
    parameter int L1D_LINE_LEN = `RAPT_L1D_LINE_LEN,
    parameter bit [`RAPT_L1D_LEN:0] L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
    parameter int L1D_LEN = `RAPT_L1D_LEN,
    parameter bit [`RAPT_L1D_LEN:0] L1D_SIZE = 2 ** `RAPT_L1D_LEN,
    parameter int XLEN = `RAPT_XLEN,
    parameter unsigned L1D_N_WAYS = `RAPT_L1D_N_WAYS
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    lsu_l1d_if.slave  lsu_l1d,
    l1d_bus_if.master l1d_bus,

    csr_bcast_if.in csr_bcast,
    exu_l1d_if.slave exu_l1d,
    rou_cmu_if.in rou_cmu,

    input reset
);
  typedef enum logic [2:0] {
    IDLE   = 3'b000,
    PTWAIT = 3'b100,  // waiting for PTW to complete
    TRAP   = 3'b101,
    LD_A   = 3'b001,
    LD_D   = 3'b010
  } l1d_state_t;

  l1d_state_t l1d_state;

  logic [XLEN-1:0] l1d_addr;
  logic [4:0] l1d_ralu;
  logic [XLEN-1:0] rec_addr;

  // Tag and valid arrays (kept as registers for multi-port read and fast bulk invalidation)
  // Per-line tag + per-word valid: one tag per (way, set); each word in a
  // cache line has independent valid tracking so partial fills / invalidates
  // don't require whole-line eviction.  When a new tag is installed in a
  // line (tag mismatch), all valid bits except the new target are cleared.
  localparam unsigned L1dOffsetBits = $clog2(XLEN/8);  // 2 for RV32, 3 for RV64
  localparam unsigned L1dTagW = XLEN - L1D_LEN - L1D_LINE_LEN - L1dOffsetBits;
  localparam unsigned L1dWayW = L1D_N_WAYS > 1 ? $clog2(L1D_N_WAYS) : 1;
  logic [L1D_LINE_SIZE-1:0] l1d_valid[L1D_N_WAYS][L1D_SIZE];
  logic [L1dTagW-1:0] l1d_tag[L1D_N_WAYS][L1D_SIZE];
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

  // PTW instance signals
  logic ptw_req;
  /* verilator lint_off UNUSEDSIGNAL */
  logic ptw_busy;
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
  logic [L1D_SIZE-1:0] d_replace_bit;      // random replacement toggle per set

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
  logic [4:0] l1d_rmw_walu;
  /* verilator lint_on UNUSEDSIGNAL */

  // RMW trigger: partial store that hits in cache, SRAM read port is free.
  // Only allowed in IDLE (with no pending load) to avoid corrupting the
  // speculative SRAM read that feeds the LD_A hit path.  In PTWAIT/LD_D
  // the SRAM read port may be redirected, and if the FSM transitions to
  // LD_A on the same cycle, data_bank_rdata would contain the store's set
  // data instead of the load's: causing silent data corruption.
  logic partial_store_rmw;
  logic load_speculate;
  assign load_speculate = (l1d_state == IDLE && lsu_l1d.rvalid && !cmu_bcast.flush_pipe);
  assign partial_store_rmw = !l1d_rmw && !l1d_update
      && (l1d_state == IDLE)  // Only in IDLE; PTWAIT/LD_D would steal read port
      && !load_speculate      // load speculation uses SRAM read port
      && lsu_l1d.wvalid && l1d_bus.wready && cacheable_w && hit_w
`ifdef RAPT_RV64
      && (lsu_l1d.walu != `RAPT_SD_WSTRB)
`else
      && (lsu_l1d.walu != `RAPT_SW_WSTRB)
`endif
      && 1'b0;  // TODO(linux difftest rmw-bug-72M): re-enable once timing bug is isolated

  // Speculative SRAM read: when IDLE with a pending load, drive the *incoming*
  // virtual index directly instead of waiting for l1d_addr to be registered.
    // Safe because L1D_LEN+L1D_LINE_LEN+L1dOffsetBits < 12 (page offset), so
  // virt_idx == phys_idx (VIPT constraint satisfied). PTW paths are also safe:
  // l1d_addr holds the virtual address during PTW, whose index equals the
  // final physical index.
  logic [L1D_LEN-1:0] sram_raddr;
  assign sram_raddr = partial_store_rmw ? waddr_idx
      : load_speculate
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits]
      : addr_idx;

  // Data SRAM banks: per-way, one bank per word position in cache line
  logic [XLEN-1:0] data_bank_rdata[L1D_N_WAYS][L1D_LINE_SIZE];
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_way
      for (genvar gi = 0; gi < L1D_LINE_SIZE; gi++) begin : gen_data_bank
        rapt_sram_1r1w #(
            .ADDR_WIDTH(L1D_LEN),
            .DATA_WIDTH(XLEN)
        ) u_data_sram (
            .clock(clock),
            .ren  (1'b1),
            .raddr(sram_raddr),
            .rdata(data_bank_rdata[w][gi]),
            .wen  (l1d_update && (l1d_off == L1D_LINE_LEN'(gi)) && (l1d_way == L1dWayW'(w))),
            .waddr(l1d_idx),
            .wdata(l1d_data_u)
        );
      end
    end
  endgenerate

  // Partial store RMW merge logic: byte-lane merge of old SRAM data with new store data
  logic [XLEN/8-1:0] rmw_byte_mask;
  logic [XLEN-1:0] rmw_bit_mask;
  logic [XLEN-1:0] rmw_data_shifted;
  logic [XLEN-1:0] rmw_merged_data;

`ifdef RAPT_RV64
  assign rmw_byte_mask = {3'b0, l1d_rmw_walu[4:0]} << l1d_rmw_waddr_lo;
`else
  assign rmw_byte_mask = l1d_rmw_walu[3:0] << l1d_rmw_waddr_lo;
`endif
  always_comb begin
    for (int i = 0; i < XLEN/8; i++) begin
      rmw_bit_mask[i*8 +: 8] = {8{rmw_byte_mask[i]}};
    end
  end
  assign rmw_data_shifted = l1d_rmw_wdata << (l1d_rmw_waddr_lo * 8);
  assign rmw_merged_data = (data_bank_rdata[l1d_way][l1d_off] & ~rmw_bit_mask)
                         | (rmw_data_shifted & rmw_bit_mask);

  assign mmu_en = csr_bcast.dmmu_en;

  // Load/Store TLB fill: from shared PTW, only while PTWAIT is active
  logic dtlb_fill, dstlb_fill;
  assign dtlb_fill  = (l1d_state == PTWAIT) && ptw_done && !stlb_mmu;
  assign dstlb_fill = (l1d_state == PTWAIT) && ptw_done &&  stlb_mmu;

  rapt_tlb #(.XLEN(XLEN)) u_dtlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(lsu_l1d.raddr[XLEN-1:12]),
      .lookup_asid(csr_bcast.satp_asid),
      .hit(tlb_hit),
      .ptag(dtlb_ptag),
      .pte_flags(dtlb_pte),
      .fill_valid(dtlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid),
      .fill_pte(ptw_result_pte)
  );

  rapt_tlb #(.XLEN(XLEN)) u_dstlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(exu_l1d.vaddr[XLEN-1:12]),
      .lookup_asid(csr_bcast.satp_asid),
      .hit(stlb_hit),
      .ptag(dstlb_ptag),
      .pte_flags(dstlb_pte),
      .fill_valid(dstlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid),
      .fill_pte(ptw_result_pte)
  );

  // Shared PTW: serves both load and store TLB misses
  wire store_tlb_miss = exu_l1d.mmu_en && exu_l1d.valid && !stlb_hit && !mis_align_store;
  assign ptw_vaddr = store_tlb_miss ? exu_l1d.vaddr : lsu_l1d.raddr;

  wire load_tlb_miss = lsu_l1d.rvalid && !tlb_hit && !mis_align_load
      && !(exu_l1d.mmu_en && exu_l1d.valid);
  assign ptw_req = (l1d_state == IDLE) && mmu_en && !cmu_bcast.flush_pipe
      && !ptw_busy
      && (store_tlb_miss || load_tlb_miss);

  rapt_ptw #(.XLEN(XLEN)) u_dptw (
      .clock(clock),
      .reset(reset),
      .req_valid(ptw_req),
      .vaddr(ptw_vaddr),
      .satp_ppn(csr_bcast.satp_ppn),
      .mmu_en(mmu_en),
      .sbe(csr_bcast.sbe),
      .req_store(store_tlb_miss),
      .bus_arvalid(ptw_arvalid),
      .bus_araddr(ptw_araddr),
      .bus_rvalid(l1d_bus.rvalid),
      .bus_rdata(l1d_bus.rdata),
      .bus_awvalid(ptw_awvalid),
      .bus_awaddr(ptw_awaddr),
      .bus_wvalid(ptw_wvalid),
      .bus_wdata(ptw_wdata),
      .bus_wstrb(ptw_wstrb),
      .bus_wready(ptw_wready),
      .bus_werr(l1d_bus.werr),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptw_result_ptag),
      .result_vtag(ptw_result_vtag),
      .result_pte(ptw_result_pte),
      .busy(ptw_busy)
  );

  assign rstrb = (
      ({8{l1d_ralu == `RAPT_ALU_LB__}} & 8'h1)
    | ({8{l1d_ralu == `RAPT_ALU_LBU_}} & 8'h1)
    | ({8{l1d_ralu == `RAPT_ALU_LH__}} & 8'h3)
    | ({8{l1d_ralu == `RAPT_ALU_LHU_}} & 8'h3)
    | ({8{l1d_ralu == `RAPT_ALU_LW__}} & 8'hf)
`ifdef RAPT_RV64
    | ({8{l1d_ralu == `RAPT_ALU_LWU_}} & 8'hf)
    | ({8{l1d_ralu == `RAPT_ALU_LD__}} & 8'hff)
`endif
    );

  assign addr_tag = l1d_addr[XLEN-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign addr_idx = l1d_addr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign addr_offset = l1d_addr[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];

  // tag_hit: combinational tag match in LD_A (per-word tags in registers, no SRAM latency)
  //
  // Guard against SRAM write-first bypass corruption:
  // When l1d_update is processed at posedge K, the SRAM bank write and the
  // concurrent SRAM read (for a load entering LD_A) can hit the same
  // bank+index.  The write-first bypass in rapt_sram_1r1w then returns the
  // store's merge/fill data instead of the load's cached data.  Because the
  // bypass fires at posedge K but l1d_update is cleared at the same posedge
  // (NBA), a combinational check at cycle K+1 (LD_A) would see l1d_update=0
  // and miss the conflict.  We therefore register the conflict condition and
  // check the delayed flag in the LD_A tag_hit calculation.
  //
  // When load_speculate is active, addr_offset still reflects the stale
  // l1d_addr from the previous operation.  Use the incoming load's word
  // offset (from the virtual address: safe due to VIPT: the offset bits
  // lie within the page offset, so virt == phys).
  logic [L1D_LINE_LEN-1:0] sram_rd_offset;
  assign sram_rd_offset = load_speculate
      ? lsu_l1d.raddr[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits]
      : addr_offset;
  // Parallel tag comparison: with per-line tag, compare once per way; then
  // AND with per-word valid bits to yield per-offset hit vectors.
  logic [L1D_N_WAYS-1:0] way_tag_match;
  logic [L1D_N_WAYS-1:0] way_tag_hit [L1D_LINE_SIZE];
  logic [L1D_LINE_SIZE-1:0] tag_hit_vec;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_line_tag_cmp
      assign way_tag_match[w] = (l1d_tag[w][addr_idx] == addr_tag);
    end
    for (genvar gi = 0; gi < L1D_LINE_SIZE; gi++) begin : gen_tag_cmp
      for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_way_cmp
        assign way_tag_hit[gi][w] = l1d_valid[w][addr_idx][gi] & way_tag_match[w];
      end
      assign tag_hit_vec[gi] = |way_tag_hit[gi];
    end
  endgenerate
  logic [L1dWayW-1:0] load_hit_way;
  always_comb begin
    load_hit_way = '0;
    for (int w = int'(L1D_N_WAYS)-1; w >= 0; w--)
      if (way_tag_hit[addr_offset][w]) load_hit_way = L1dWayW'(w);
  end

  logic sram_bypass_r;
  always_ff @(posedge clock) begin
    if (reset) sram_bypass_r <= 1'b0;
    else sram_bypass_r <= l1d_update && (l1d_idx == sram_raddr)
                       && (l1d_off == sram_rd_offset);
  end
  // Same-cycle write-vs-load hazard: when l1d_update fires the SAME cycle
  // a load is in LD_A on the matching line/word, the load's data_bank_rdata
  // reflects the SRAM read latched at LD_A entry (i.e. BEFORE the merged
  // partial-store / full-store / fill write completes), giving stale data.
  // The SRAM module's internal write-first bypass cannot help: the read
  // address was latched the prior cycle when there was no concurrent write.
  // Suppress tag_hit so the load stalls in LD_A; the next cycle l1d_update
  // has cleared, mem[idx] holds the merged value, the SRAM re-read sampled
  // at the LD_A boundary brings in the fresh data, and the load completes.
  //
  // Additionally, l1d_rmw=1 means the SRAM read port is currently serving
  // the partial-store merge (sram_raddr=waddr_idx), so data_bank_rdata in
  // this cycle reflects the STORE's set, not the load's. Stall the load
  // until the RMW chain completes and a normal SRAM read re-fetches at
  // the load's idx.
  //
  // Same-cycle partial_store_rmw concurrent with IDLE->LD_A entry has the
  // same effect: in the next cycle (LD_A), l1d_rmw will be high, so the
  // l1d_rmw stall covers it.
  logic l1d_update_collide;
  assign l1d_update_collide = l1d_update
                           && (l1d_idx == addr_idx)
                           && (l1d_off == addr_offset);
  logic l1d_sram_busy;
  assign l1d_sram_busy = l1d_rmw || l1d_update_collide;
  assign tag_hit = (l1d_state == LD_A)
    && !sram_bypass_r
    && !l1d_sram_busy
    && tag_hit_vec[addr_offset];
  // data_hit: SRAM data ready in LD_A: the speculative read in the preceding
  // IDLE (or PTW-wait) cycle guarantees data_bank_rdata is valid on LD_A entry.
  assign data_hit = (l1d_state == LD_A) && tag_hit;
  assign l1d_data = data_bank_rdata[load_hit_way][addr_offset];

  assign waddr_tag = lsu_l1d.waddr[XLEN-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign waddr_idx = lsu_l1d.waddr[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign waddr_offset = lsu_l1d.waddr[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];
  // Parallel write-side tag comparison (per-line tag)
  logic [L1D_N_WAYS-1:0] way_wtag_match;
  logic [L1D_N_WAYS-1:0] way_whit [L1D_LINE_SIZE];
  logic [L1D_LINE_SIZE-1:0] whit_vec;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_line_wtag_cmp
      assign way_wtag_match[w] = (l1d_tag[w][waddr_idx] == waddr_tag);
    end
    for (genvar gi = 0; gi < L1D_LINE_SIZE; gi++) begin : gen_wtag_cmp
      for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_wway_cmp
        assign way_whit[gi][w] = l1d_valid[w][waddr_idx][gi] & way_wtag_match[w];
      end
      assign whit_vec[gi] = |way_whit[gi];
    end
  endgenerate
  assign hit_w = whit_vec[waddr_offset];
  logic [L1dWayW-1:0] store_hit_way;
  always_comb begin
    store_hit_way = '0;
    for (int w = int'(L1D_N_WAYS)-1; w >= 0; w--)
      if (way_whit[waddr_offset][w]) store_hit_way = L1dWayW'(w);
  end
  // Fill way selection for store miss (full-word write-allocate)
  logic [L1dWayW-1:0] store_fill_way;
  // Fill way selection for load miss
  logic [L1dWayW-1:0] ld_fill_way;
  generate
    if (L1D_N_WAYS > 1) begin : gen_fill_multi
      // Duplicate-tag prevention: if the tag already exists in a way (from a
      // previous fill that was forced-miss by sram_bypass_r), reuse that way
      // instead of allocating a new one.  Without this check, a conservative
      // sram_bypass_r miss creates duplicate tags across ways; a subsequent
      // store updates only one copy, leaving the other stale: and when the
      // updated copy is later evicted, a load hits the stale duplicate.
      // With per-line tags, "tag exists" means any word in the line is valid
      // AND the line's tag matches.
      logic ld_tag_dup0, ld_tag_dup1;
      assign ld_tag_dup0 = (|l1d_valid[0][addr_idx]) && way_tag_match[0];
      assign ld_tag_dup1 = (|l1d_valid[1][addr_idx]) && way_tag_match[1];
      // Same dup-tag check on the store side: without it, a full-word store
      // miss could allocate a new way for a line that already exists in the
      // other way, creating duplicate tags.  Subsequent partial stores then
      // invalidate only one copy, leaving stale data in the other.
      logic st_tag_dup0, st_tag_dup1;
      assign st_tag_dup0 = (|l1d_valid[0][waddr_idx]) && way_wtag_match[0];
      assign st_tag_dup1 = (|l1d_valid[1][waddr_idx]) && way_wtag_match[1];
      assign store_fill_way = st_tag_dup0 ? 1'b0
                            : st_tag_dup1 ? 1'b1
                            : !l1d_valid[0][waddr_idx][waddr_offset] ? 1'b0
                            : !l1d_valid[1][waddr_idx][waddr_offset] ? 1'b1
                            : d_replace_bit[waddr_idx];
      assign ld_fill_way = ld_tag_dup0 ? 1'b0
                         : ld_tag_dup1 ? 1'b1
                         : !l1d_valid[0][addr_idx][addr_offset] ? 1'b0
                         : !l1d_valid[1][addr_idx][addr_offset] ? 1'b1
                         : d_replace_bit[addr_idx];
    end else begin : gen_fill_dm
      assign store_fill_way = '0;
      assign ld_fill_way = '0;
    end
  endgenerate

  assign cacheable_r = rapt_pkg::addr_cacheable(l1d_addr);
  assign cacheable_w = rapt_pkg::addr_cacheable(lsu_l1d.waddr);

  // --- PMP checks for loads and MMU-mode stores ---
  // Effective privilege for load/store obeys MSTATUS.MPRV: when MPRV=1 and
  // current privilege is M, accesses use MPP for PMP checks.
  logic [1:0] eff_priv;
  assign eff_priv = (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv)
                    ? csr_bcast.mpp : csr_bcast.priv;

  // Load PMP: l1d_addr holds the target physical address once we enter LD_A
  // (set in IDLE for bare/TLB-hit, or from ptw_result_ptag after ptw_done).
  // Use the latched `l1d_ralu` for size (lsu_l1d.ralu may already be pointing
  // at the next request once we leave IDLE).  ralu[1:0] encodes transfer
  // size: 0=byte, 1=half, 2=word, 3=double; upper bits select sign/aux op
  // and are not consumed here.
  logic [1:0] eff_ralu;
  assign eff_ralu = (l1d_state == IDLE) ? lsu_l1d.ralu[1:0] : l1d_ralu[1:0];
  logic [3:0] load_size_m1;
  always_comb begin
    unique case (eff_ralu[1:0])
      2'b00:   load_size_m1 = 4'd0;
      2'b01:   load_size_m1 = 4'd1;
      2'b10:   load_size_m1 = 4'd3;
      2'b11:   load_size_m1 = 4'd7;
      default: load_size_m1 = 4'd3;
    endcase
  end
  logic pmp_load_fault;
  rapt_pmp #(.XLEN(XLEN)) u_pmp_load (
      .addr   (l1d_addr),
      .size_m1(load_size_m1),
      .priv   (eff_priv),
      .op_r   (1'b1),
      .op_w   (1'b0),
      .op_x   (1'b0),
      .pmp_napot_mask (csr_bcast.pmp_napot_mask),
      .pmp_napot_base (csr_bcast.pmp_napot_base),
      .pmp_tor_lo     (csr_bcast.pmp_tor_lo),
      .pmp_tor_hi     (csr_bcast.pmp_tor_hi),
      .pmp_cfg_r      (csr_bcast.pmp_cfg_r),
      .pmp_cfg_w      (csr_bcast.pmp_cfg_w),
      .pmp_cfg_x      (csr_bcast.pmp_cfg_x),
      .pmp_cfg_l      (csr_bcast.pmp_cfg_l),
      .pmp_mode_off   (csr_bcast.pmp_mode_off),
      .pmp_mode_tor   (csr_bcast.pmp_mode_tor),
      .pmp_mode_na4   (csr_bcast.pmp_mode_na4),
      .pmp_mode_napot (csr_bcast.pmp_mode_napot),
      .fault  (pmp_load_fault)
  );
  // Treat loads from unmapped physical addresses as access faults (bus error).
  logic load_unmapped_fault;
  assign load_unmapped_fault = !rapt_pkg::addr_mapped(l1d_addr);

  // Store PMP (MMU path): exu_l1d.paddr is the translated physical address
  // (meaningful once stlb_hit or immediately after ptw_done).
  // NOTE: bare-mode stores bypass this interface; their PMP enforcement is
  // handled at the IOQ (see rapt_exu_ioq.sv).
  // walu is the byte-strobe pattern; popcount-1 = size_m1.
  logic [3:0] store_size_m1;
  always_comb begin
    unique case (exu_l1d.walu)
      `RAPT_SB_WSTRB: store_size_m1 = 4'd0;
      `RAPT_SH_WSTRB: store_size_m1 = 4'd1;
      `RAPT_SW_WSTRB: store_size_m1 = 4'd3;
      `RAPT_SD_WSTRB: store_size_m1 = 4'd7;
      default:        store_size_m1 = 4'd3;
    endcase
  end
  logic pmp_store_fault_mmu;
  rapt_pmp #(.XLEN(XLEN)) u_pmp_store_mmu (
      .addr   (exu_l1d.paddr),
      .size_m1(store_size_m1),
      .priv   (eff_priv),
      .op_r   (1'b0),
      .op_w   (1'b1),
      .op_x   (1'b0),
      .pmp_napot_mask (csr_bcast.pmp_napot_mask),
      .pmp_napot_base (csr_bcast.pmp_napot_base),
      .pmp_tor_lo     (csr_bcast.pmp_tor_lo),
      .pmp_tor_hi     (csr_bcast.pmp_tor_hi),
      .pmp_cfg_r      (csr_bcast.pmp_cfg_r),
      .pmp_cfg_w      (csr_bcast.pmp_cfg_w),
      .pmp_cfg_x      (csr_bcast.pmp_cfg_x),
      .pmp_cfg_l      (csr_bcast.pmp_cfg_l),
      .pmp_mode_off   (csr_bcast.pmp_mode_off),
      .pmp_mode_tor   (csr_bcast.pmp_mode_tor),
      .pmp_mode_na4   (csr_bcast.pmp_mode_na4),
      .pmp_mode_napot (csr_bcast.pmp_mode_napot),
      .fault  (pmp_store_fault_mmu)
  );
  // P3: PMA pre-check on the translated store PA. Mirrors load_unmapped_fault
  // — stops a store to a region with no bus slave from issuing on AXI and
  // hanging the LSU. Bare-mode stores get the same check at the IOQ.
  logic store_unmapped_fault_mmu;
  assign store_unmapped_fault_mmu = !rapt_pkg::addr_mapped(exu_l1d.paddr);

  // --- Sv32/Sv39 PTE permission check (data access: load/store, not fetch) ---
  // pte bits (rapt_tlb layout): [0]=R [1]=W [2]=X [3]=U [4]=G [5]=A [6]=D.
  // Bit [4]=G (global) does not affect data fault and is not consumed below.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic pte_fault_data(
      input logic [6:0] pte,
      input logic       is_store,
      input logic [1:0] priv_eff,
      input logic       sum_i,
      input logic       mxr_i
  );
      logic r, w, x, u, a, d;
      logic can_read;
      logic fault;
      r = pte[0]; w = pte[1]; x = pte[2]; u = pte[3];
      a = pte[5]; d = pte[6];
      can_read = r || (mxr_i && x);
      fault = 1'b0;
      // U-bit rules: U-mode requires U=1; S-mode denies U=1 unless SUM.
      if (priv_eff == `RAPT_PRIV_U) begin
        if (!u) fault = 1'b1;
      end else if (priv_eff == `RAPT_PRIV_S) begin
        if (u && !sum_i) fault = 1'b1;
      end
      if (is_store) begin
        if (!w) fault = 1'b1;
        if (!a || !d) fault = 1'b1;
      end else begin
        if (!can_read) fault = 1'b1;
        if (!a) fault = 1'b1;
      end
      return fault;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Perm-fault signals evaluated against currently-visible PTEs.
  logic pf_load_tlb, pf_store_tlb, pf_load_ptw, pf_store_ptw;
  assign pf_load_tlb  = tlb_hit  && pte_fault_data(dtlb_pte,  1'b0, eff_priv,
                                                    csr_bcast.sum, csr_bcast.mxr);
  assign pf_store_tlb = stlb_hit && pte_fault_data(dstlb_pte, 1'b1, eff_priv,
                                                    csr_bcast.sum, csr_bcast.mxr);
  assign pf_load_ptw  = pte_fault_data(ptw_result_pte, 1'b0, eff_priv,
                                        csr_bcast.sum, csr_bcast.mxr);
  assign pf_store_ptw = pte_fault_data(ptw_result_pte, 1'b1, eff_priv,
                                        csr_bcast.sum, csr_bcast.mxr);

  // --- PMP check on PTW memory (PTE) reads ---
  // Per spec, PTW uses M-mode for PMP checks is wrong: it uses the effective
  // privilege of the original access.  Fault is reported as access-fault of
  // same type (load/store) as the triggering access.
  logic pmp_ptw_fault;
  rapt_pmp #(.XLEN(XLEN)) u_pmp_ptw (
      .addr   (ptw_araddr),
      .size_m1(4'd3),
      .priv   (eff_priv),
      .op_r   (1'b1),
      .op_w   (1'b0),
      .op_x   (1'b0),
      .pmp_napot_mask (csr_bcast.pmp_napot_mask),
      .pmp_napot_base (csr_bcast.pmp_napot_base),
      .pmp_tor_lo     (csr_bcast.pmp_tor_lo),
      .pmp_tor_hi     (csr_bcast.pmp_tor_hi),
      .pmp_cfg_r      (csr_bcast.pmp_cfg_r),
      .pmp_cfg_w      (csr_bcast.pmp_cfg_w),
      .pmp_cfg_x      (csr_bcast.pmp_cfg_x),
      .pmp_cfg_l      (csr_bcast.pmp_cfg_l),
      .pmp_mode_off   (csr_bcast.pmp_mode_off),
      .pmp_mode_tor   (csr_bcast.pmp_mode_tor),
      .pmp_mode_na4   (csr_bcast.pmp_mode_na4),
      .pmp_mode_napot (csr_bcast.pmp_mode_napot),
      .fault  (pmp_ptw_fault)
  );

  // Misaligned accesses are split by the LSU's MA-split FSM into two aligned
  // beats (load: ma_state_t in MA_HI; store: state_store == LS_S_HI_V) before
  // they reach this L1D, so we never see a true misaligned cache request.
  // The early STLB-lookup path (exu_l1d) does observe the original misaligned
  // virtual address, but the page-translation only depends on VPN bits and is
  // unaffected by the low alignment bits, so suppressing the misalign trap
  // here is safe for any access that does not cross a page boundary. (The
  // very rare cross-page case would need a second TLB walk and is not yet
  // handled — Linux's misaligned memcpy stays within a page.)
  assign mis_align_load  = 1'b0;
  assign mis_align_store = 1'b0;

  // read channel: PTW takes priority over cache miss reads
  assign l1d_bus.arvalid = ptw_arvalid
    ? !pmp_ptw_fault
    : (l1d_state == LD_A)
      && !tag_hit
      && !(pmp_load_fault || load_unmapped_fault)
      && !cmu_bcast.flush_pipe;
  assign l1d_bus.araddr = ptw_arvalid ? ptw_araddr : l1d_addr;
  assign l1d_bus.rstrb = (cacheable_r || ptw_arvalid) ? 8'($unsigned({XLEN/8{1'b1}})) : rstrb;

  assign lsu_l1d.rdata = data_hit ? l1d_data : l1d_bus.rdata;
  // Difftest skip propagation for MMIO loads: cache-hit loads (data_hit=1) are
  // by construction cacheable (and thus non-MMIO), so they don't need to skip
  // the reference model. For misses that go to bus, mirror the bus-side mmio
  // bit so the commit-time DPI can skip REF on the owning instruction.
  assign lsu_l1d.difftest_skip = data_hit ? 1'b0 : l1d_bus.difftest_skip;
  assign lsu_l1d.trap = (l1d_state == TRAP) && (rec_addr == lsu_l1d.raddr);
  assign lsu_l1d.cause = cause;
  // Gate handshake with PMP fault: otherwise a cache-hit load in LD_A would
  // complete the rready/rdata handshake the same cycle the FSM transitions
  // to TRAP, letting the forbidden data propagate.
  assign lsu_l1d.rready = (l1d_state == TRAP)
      || (data_hit
        && !(pmp_load_fault || load_unmapped_fault)
        && lsu_l1d.rvalid
        && rec_addr == lsu_l1d.raddr)
      || ((l1d_state == LD_D)
          && (lsu_l1d.rvalid)
          && (l1d_bus.rvalid)
          && (rec_addr == lsu_l1d.raddr));

  // write channel
  assign l1d_bus.awvalid = ptw_awvalid ? 1'b1 : lsu_l1d.wvalid;
  assign l1d_bus.awaddr = ptw_awvalid ? ptw_awaddr : lsu_l1d.waddr;
`ifdef RAPT_RV64
  // Decode walu (5-bit store mask) to full 8-bit wstrb for RV64
  // SB: 5'b00001->8'h01, SH: 5'b00011->8'h03, SW: 5'b01111->8'h0f, SD: 5'b11111->8'hff
  assign l1d_bus.wstrb = ptw_wvalid ? ptw_wstrb
    : (lsu_l1d.walu == 5'b11111) ? 8'hff : {3'b0, lsu_l1d.walu[4:0]};
`else
  assign l1d_bus.wstrb = ptw_wvalid ? ptw_wstrb : {4'b0, lsu_l1d.walu[3:0]};
`endif
  assign l1d_bus.wvalid = ptw_wvalid ? 1'b1 : lsu_l1d.wvalid;
  assign l1d_bus.wdata = ptw_wvalid ? ptw_wdata : lsu_l1d.wdata;

  assign ptw_wready = ptw_wvalid && l1d_bus.wready;
  assign lsu_l1d.wready = !ptw_wvalid && l1d_bus.wready;

  // store address translation: stlb_hit uses TLB, otherwise wait for PTW
  assign store_paddr = XLEN'({ptw_result_ptag, exu_l1d.vaddr[11:0]});
  assign exu_l1d.paddr = stlb_hit
    ? XLEN'({dstlb_ptag, exu_l1d.vaddr[11:0]})
    : store_paddr;
  assign exu_l1d.trap = (l1d_state == TRAP) && (rec_addr == exu_l1d.vaddr);
  assign exu_l1d.cause = cause;
  assign exu_l1d.reservation = reservation;
  assign exu_l1d.ready = exu_l1d.valid && ((l1d_state == TRAP)
    || (stlb_hit
      && !mis_align_store
      && !pmp_store_fault_mmu
      && !store_unmapped_fault_mmu && !pf_store_tlb)
    || (stlb_mmu
      && ptw_done
      && !pf_store_ptw
      && !pmp_store_fault_mmu
      && !store_unmapped_fault_mmu));

  always_ff @(posedge clock) begin
    if (reset) begin
      l1d_state  <= IDLE;
      for (int w = 0; w < int'(L1D_N_WAYS); w++)
        for (int i = 0; i < int'(L1D_SIZE); i++) l1d_valid[w][i] <= '0;
      l1d_update <= 0;
      l1d_inv_all_ways <= 0;
      l1d_rmw    <= 0;
      d_replace_bit <= '0;
      ld_fill_way_r <= '0;
      l1d_way <= '0;

      reservation <= 'h0;
    end else begin
      if (rou_cmu.valid_a && rou_cmu.atomic_sc) begin
        reservation <= 'h0;
      end
      // if (l1d_bus.awvalid && csr_bcast.dmmu_en) begin
      //   $display("  [L1D WRITE] addr: %h, data: %h, wstrb: %h",
      //     l1d_bus.awaddr, l1d_bus.wdata, l1d_bus.wstrb);
      // end
      // if (l1d_bus.arvalid && (l1d_state == LD_A) && csr_bcast.dmmu_en) begin
      //   $display("  [L1D READ ] addr: %h", l1d_bus.araddr);
      // end
      unique case (l1d_state)
        IDLE: begin
          if (!cmu_bcast.flush_pipe) begin
            if (mmu_en) begin
              // Store TLB lookup (priority)
              if (exu_l1d.mmu_en && exu_l1d.valid) begin
                if (mis_align_store) begin
                  cause <= 'h6; // store address mis-aligned
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (stlb_hit && pf_store_tlb) begin
                  // PTE permission denies store.
                  cause <= `RAPT_CAUSE_STORE_PAGE_FAULT;
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (stlb_hit && (pmp_store_fault_mmu || store_unmapped_fault_mmu)) begin
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
                  // Pre-compute the physical address; PMP check happens in LD_A.
                  l1d_addr <= XLEN'({dtlb_ptag, lsu_l1d.raddr[11:0]});
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
                  l1d_state <= LD_A;
                end else if (!ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr <= lsu_l1d.raddr;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
                  stlb_mmu <= 'b0;
                  l1d_state <= PTWAIT;
                end
              end
            end else begin
              if (lsu_l1d.rvalid) begin
                l1d_addr <= lsu_l1d.raddr;
                rec_addr <= lsu_l1d.raddr;
                l1d_ralu  <= lsu_l1d.ralu;
                l1d_state <= LD_A;
              end
            end
          end
        end
        PTWAIT: begin
          if (cmu_bcast.flush_pipe) begin
            stlb_mmu <= 'b0;
            l1d_state <= IDLE;
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
              end else if (pmp_store_fault_mmu || store_unmapped_fault_mmu) begin
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
                l1d_state <= LD_A;
              end
            end
          end else if (ptw_fault) begin
            if (stlb_mmu) begin
              cause <= 'hf; // store page fault
              stlb_mmu <= 'b0;
            end else begin
              cause <= 'hd; // load page fault
            end
            l1d_state <= TRAP;
          end
        end
        TRAP: begin
          l1d_state <= IDLE;
        end
        LD_A: begin
          if (pmp_load_fault || load_unmapped_fault) begin
            // PMP denies load at this physical address for eff_priv,
            // or the address is unmapped (bus error -> access fault).
            cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
            l1d_state <= TRAP;
          end else if (lsu_l1d.atomic_lock) begin
            reservation <= l1d_addr;
            if (tag_hit) begin
              l1d_addr  <= '0;
              l1d_state <= IDLE;
            end else begin
              if (l1d_bus.rready) begin
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
            if (l1d_bus.rready) begin
              l1d_state <= LD_D;
              ld_fill_way_r <= ld_fill_way;
            end
          end
        end
        LD_D: begin
          if (l1d_bus.rvalid) begin
            // Bus error on the response beat -> load access-fault. Gated
            // on `rvalid` (the same condition that consumes the beat), so
            // transient `rerr` in unrelated cycles is ignored.
            if (l1d_bus.rerr) begin
              cause     <= `RAPT_CAUSE_LOAD_ACC_FAULT;
              l1d_state <= TRAP;
            end else begin
              l1d_state <= IDLE;
              if (lsu_l1d.atomic_lock) begin
                reservation <= l1d_addr;
              end
            end
          end
        end
        default: begin
          l1d_addr <= '0;
          l1d_state <= IDLE;
        end
      endcase

      // l1d_update CLEAR: consume pending update (write tag/valid registers).
      // Must be textually BEFORE the SET block so that when both fire on the
      // same cycle (e.g. load-fill completes, then store write-through arrives
      // next cycle while l1d_update is still high), the SET's NBA wins and the
      // new update is not lost.
      if (cmu_bcast.fence_time) begin
        for (int w = 0; w < int'(L1D_N_WAYS); w++)
          for (int i = 0; i < int'(L1D_SIZE); i++) l1d_valid[w][i] <= '0;
        l1d_rmw <= 0;
      end else if (l1d_update) begin
        // Per-line tag + per-word valid semantics:
        //   valid_u=1 (install word):
        //     - If incoming tag matches existing line tag: preserve valid bits,
        //       set target bit.
        //     - If tag mismatch (new line install): clear all valid bits and
        //       set only the target bit; overwrite tag.
        //     - Also invalidate the same word in any OTHER way whose tag
        //       matches `l1d_tag_u` to scrub legacy duplicates.
        //   valid_u=0:
        //     - If `l1d_inv_all_ways` (partial-store invalidate): clear the
        //       target word in EVERY way at this index, regardless of tag.
        //     - Else (legacy fallback): clear target bit in `l1d_way` only.
        if (l1d_valid_u) begin
          l1d_tag[l1d_way][l1d_idx] <= l1d_tag_u;
          if (l1d_tag[l1d_way][l1d_idx] == l1d_tag_u) begin
            l1d_valid[l1d_way][l1d_idx][l1d_off] <= 1'b1;
          end else begin
            l1d_valid[l1d_way][l1d_idx] <= (L1D_LINE_SIZE'(1) << l1d_off);
          end
          // Cross-way duplicate scrub on install: when the canonical copy
          // for this tag now lives in `l1d_way`, invalidate the ENTIRE line
          // in every other way that holds the same tag.  Scrubbing only the
          // installed offset is insufficient: legacy duplicate ways may
          // retain stale words at OTHER offsets of the same line, and a
          // later load to those offsets would hit the stale duplicate.
          for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
            if (w != int'(l1d_way)
                && l1d_tag[w][l1d_idx] == l1d_tag_u) begin
              l1d_valid[w][l1d_idx] <= '0;
            end
          end
        end else if (l1d_inv_all_ways) begin
          for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
            l1d_valid[w][l1d_idx][l1d_off] <= 1'b0;
          end
        end else begin
          l1d_valid[l1d_way][l1d_idx][l1d_off] <= 1'b0;
        end
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
      end else if (lsu_l1d.wvalid && l1d_bus.wready && cacheable_w) begin
`ifdef RAPT_RV64
        // Treat misaligned full-width store as partial: cache must not be
        // updated as if the natural-aligned word/dword was fully written,
        // because the BUS shifts wstrb/wdata by waddr_lo.
        if (lsu_l1d.walu == `RAPT_SD_WSTRB
            && lsu_l1d.waddr[L1dOffsetBits-1:0] == '0) begin
`else
        if (lsu_l1d.walu == `RAPT_SW_WSTRB
            && lsu_l1d.waddr[L1dOffsetBits-1:0] == '0) begin
`endif
          l1d_update <= 1'b1;
          l1d_data_u <= lsu_l1d.wdata;
          l1d_valid_u <= 1'b1;
          l1d_tag_u <= waddr_tag;
          l1d_idx <= waddr_idx;
          l1d_off <= waddr_offset;
          l1d_way <= hit_w ? store_hit_way : store_fill_way;
          if (!hit_w) d_replace_bit[waddr_idx] <= ~d_replace_bit[waddr_idx];
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
        if (lsu_l1d.rvalid && l1d_bus.rvalid) begin
          if (cacheable_r) begin
            l1d_update <= 1'b1;
            l1d_data_u <= l1d_bus.rdata;
            l1d_valid_u <= 1'b1;
            l1d_tag_u <= addr_tag;
            l1d_idx <= addr_idx;
            l1d_off <= addr_offset;
            l1d_way <= ld_fill_way_r;
            d_replace_bit[addr_idx] <= ~d_replace_bit[addr_idx];
          end
        end
      end
    end
  end
endmodule
