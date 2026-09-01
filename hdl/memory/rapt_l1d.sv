`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

/* verilator lint_off PINCONNECTEMPTY */
module rapt_l1d #(
    parameter int L1D_LINE_LEN = `RAPT_L1D_LINE_LEN,
    parameter int unsigned L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
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
    pmp_update_if.in pmp_update,
    exu_l1d_if.slave exu_l1d,
    rou_cmu_if.in rou_cmu,

    input reset
);
  pmp_state_if pmp_state ();

  rapt_pmp_state pmp_state_regs (
      .clock,
      .reset,
      .update(pmp_update),
      .state(pmp_state)
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
  localparam unsigned L1dOffsetBits = $clog2(XLEN / 8);  // 2 for RV32, 3 for RV64
  localparam unsigned L1dTagW = XLEN - L1D_LEN - L1D_LINE_LEN - L1dOffsetBits;
  localparam unsigned L1dWayW = L1D_N_WAYS > 1 ? $clog2(L1D_N_WAYS) : 1;
  logic [L1D_LINE_SIZE-1:0] l1d_valid[L1D_N_WAYS][L1D_SIZE];
  logic [L1dTagW-1:0] l1d_tag[L1D_N_WAYS][L1D_SIZE];
  logic [L1D_SIZE-1:0] fence_clear_set;
  logic fence_clear_busy;

  assign fence_clear_busy = cmu_bcast.fence_time || |fence_clear_set;

  // Wide subarray configuration for L1D data SRAMs (128-bit target, matching L1I).
  // Clamp the subarray to the line when a cache line is narrower than 128 bits
  // (e.g. small config: L1D_LINE_LEN=1 -> 2 words < 4 words on RV32) so that
  // D_SUBARRAY_COUNT stays >= 1. SLANG (yosys-slang, used by the STA flow) is
  // stricter than Verilator and rejects zero-sized unpacked arrays.
  // L1D_LINE_SIZE is a narrow packed parameter because it also sizes arrays;
  // use an explicit integer mirror for arithmetic with int localparams.
  localparam int unsigned L1dLineWords = int'(L1D_LINE_SIZE);
  localparam int D_SUBARRAY_WORDS_MAX = 16 / (XLEN / 8);  // 4 (RV32) / 2 (RV64)
  localparam int D_SUBARRAY_WORDS =
      (L1dLineWords < D_SUBARRAY_WORDS_MAX) ? L1dLineWords : D_SUBARRAY_WORDS_MAX;
  localparam int D_SUBARRAY_BYTES = D_SUBARRAY_WORDS * (XLEN / 8);  // <= 16 (128 bits)
  localparam int D_SUBARRAY_COUNT = L1dLineWords / D_SUBARRAY_WORDS;
  // Raw subarray read data. With the single-port SRAM the read address is
  // registered INSIDE the macro; the parent drives the address
  // combinationally and consumes rdata the following cycle.
  logic [D_SUBARRAY_BYTES*8-1:0] d_sa_rdata[L1D_N_WAYS][D_SUBARRAY_COUNT];
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
  // PLRU signals (only used for >2-way; suppressed for 2-way)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [L1D_N_WAYS-1:0] d_victim_way;
  logic [L1D_N_WAYS-1:0] d_hit_way_onehot;
  logic                  d_lru_write_en;
  /* verilator lint_on UNUSEDSIGNAL */

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
  assign load_speculate = (l1d_state == IDLE && lsu_l1d.rvalid
      && !cmu_bcast.flush_pipe && !fence_clear_busy);

`ifdef RAPT_LSU_HUM
  // Hit-under-miss B channel arm (full logic further below): in LD_D the
  // SRAM read port is idle, steer it to the B request's set this cycle and
  // tag-compare next cycle.  Declared here so the sram_raddr mux can see it.
  logic b_arm_ok;
  logic [L1D_LEN-1:0] b_idx_in;
`endif

`ifdef RAPT_RV64
  localparam logic [7:0] FullStoreWstrb = `RAPT_SD_WSTRB;
`else
  localparam logic [7:0] FullStoreWstrb = `RAPT_SW_WSTRB;
`endif
  assign partial_store_rmw = !l1d_rmw && !l1d_update
      && (l1d_state == IDLE)  // Only in IDLE; PTWAIT/LD_D would steal read port
      && !load_speculate  // load speculation uses SRAM read port
      && lsu_l1d.wvalid && l1d_bus.wready && cacheable_w && hit_w
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

  // Data SRAM: wide subarrays (128-bit), single shared read/write port.
  // 4 subarrays per way replaces per-word banks, reducing SRAM instance count
  // from 32 to 8 (for 2-way), proportionally cutting address fanout.
  //
  // Single-port arbitration (rapt_sram_1rw):
  //   * Writes (l1d_update: fill / full-store / RMW write-back) take the port:
  //     wen=1, addr=l1d_idx. The shared read-address tracker is invalidated
  //     because only the written way/subarray accepts that address.
  //   * Reads (load speculate / RMW old-word fetch) use the port when no
  //     write is active: wen=0, addr=sram_raddr. The address is registered
  //     inside the SRAM at posedge K and data is consumed at cycle K+1.
  logic [XLEN-1:0] data_bank_rdata[L1D_N_WAYS][L1D_LINE_SIZE];
  logic sram_read_valid_r;
  logic [L1D_LEN-1:0] sram_read_idx_r;

  // A write only enables its target way/subarray, leaving the other SRAM
  // instances on their previous addresses. Mark that cycle invalid globally;
  // only a normal read makes every data SRAM agree on one index again.
  always_ff @(posedge clock) begin
    if (reset) begin
      sram_read_valid_r <= 1'b0;
    end else if (l1d_update) begin
      sram_read_valid_r <= 1'b0;
    end else begin
      sram_read_valid_r <= 1'b1;
      sram_read_idx_r <= sram_raddr;
    end
  end

  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_way
      for (genvar sa = 0; sa < D_SUBARRAY_COUNT; sa++) begin : gen_sa
        localparam int SA_BASE = sa * D_SUBARRAY_WORDS;
        // BWE: write only the target word within the subarray
        logic [D_SUBARRAY_BYTES-1:0] d_sa_bwe;
        always_comb begin
          d_sa_bwe = '0;
          if (l1d_update && (l1d_way == L1dWayW'(w))) begin
            for (int wi = 0; wi < D_SUBARRAY_WORDS; wi++) begin
              if (l1d_off == L1D_LINE_LEN'(SA_BASE + wi))
                d_sa_bwe[wi*(XLEN/8)+:(XLEN/8)] = {(XLEN / 8) {1'b1}};
            end
          end
        end
        // Write data: replicate l1d_data_u to subarray width
        logic [D_SUBARRAY_BYTES*8-1:0] d_sa_wdata;
        always_comb begin
          d_sa_wdata = '0;
          for (int wi = 0; wi < D_SUBARRAY_WORDS; wi++) begin
            d_sa_wdata[wi*XLEN+:XLEN] = l1d_data_u;
          end
        end
        logic d_sa_wen;
        assign d_sa_wen = |d_sa_bwe;
        rapt_sram_1rw #(
            .ADDR_WIDTH(L1D_LEN),
            .DATA_WIDTH(D_SUBARRAY_BYTES * 8),
            .USE_BWE(1)
        ) u_data_sram (
            .clock(clock),
            .en   (d_sa_wen || !l1d_update),
            .wen  (d_sa_wen),
            .addr (d_sa_wen ? l1d_idx : sram_raddr),
            .rdata(d_sa_rdata[w][sa]),
            .wdata(d_sa_wdata),
            .bwe  (d_sa_bwe)
        );
        // Reconstruct per-word data from the last accepted SRAM read.
        for (genvar wi = 0; wi < D_SUBARRAY_WORDS; wi++) begin : gen_word
          assign data_bank_rdata[w][SA_BASE+wi] = d_sa_rdata[w][sa][(wi+1)*XLEN-1:wi*XLEN];
        end
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
    for (int i = 0; i < XLEN / 8; i++) begin
      rmw_bit_mask[i*8+:8] = {8{rmw_byte_mask[i]}};
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

  rapt_tlb #(
      .XLEN(XLEN)
  ) u_dtlb (
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

  rapt_tlb #(
      .XLEN(XLEN)
  ) u_dstlb (
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
  logic store_tlb_miss;
  assign store_tlb_miss = exu_l1d.mmu_en && exu_l1d.valid && !stlb_hit && !mis_align_store;
  assign ptw_vaddr = store_tlb_miss ? exu_l1d.vaddr : lsu_l1d.raddr;

  logic load_tlb_miss;
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
      .kill(cmu_bcast.fence_time || cmu_bcast.flush_pipe),
      .vaddr(ptw_vaddr),
      .satp_ppn(csr_bcast.satp_ppn),
      .mmu_en(mmu_en),
      .sbe(csr_bcast.sbe),
      .req_store(store_tlb_miss),
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

  // tag_hit: combinational tag match in LD_A (per-word tags in registers, no SRAM latency)
  //
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
  // load_hit_way kept for debug visibility; AND-OR mux replaces it for data selection
  /* verilator lint_off UNUSEDSIGNAL */
  logic [L1dWayW-1:0] load_hit_way;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    load_hit_way = '0;
    for (int w = int'(L1D_N_WAYS) - 1; w >= 0; w--)
    if (way_tag_hit[addr_offset][w]) load_hit_way = L1dWayW'(w);
  end

  // PLRU instantiation for >2-way caches
  generate
    if (L1D_N_WAYS > 2) begin : gen_dplru
      // Per-way line-valid: a way is "valid" for PLRU if any word in the line is valid
      logic [L1D_N_WAYS-1:0] d_way_line_valid;
      for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_lv
        assign d_way_line_valid[w] = |l1d_valid[w][addr_idx];
      end

      // One-hot hit way for PLRU update
      always_comb begin
        d_hit_way_onehot = '0;
        for (int w = 0; w < int'(L1D_N_WAYS); w++)
        if (way_tag_hit[addr_offset][w]) d_hit_way_onehot[w] = 1'b1;
      end
      // LRU write enable: on load hit or when a fill completes (l1d_update with valid_u)
      assign d_lru_write_en = ((l1d_state == LD_A) && tag_hit) || (l1d_update && l1d_valid_u);

      rapt_plru #(
          .NUMWAYS(L1D_N_WAYS),
          .SETLEN(L1D_LEN),
          .NSETS(L1D_SIZE)
      ) u_dplru (
          .clock(clock),
          .reset(reset),
          .cache_en(1'b1),
          .hit_way(d_hit_way_onehot),
          .valid_way(d_way_line_valid),
          .victim_way(d_victim_way),
          .cache_set(addr_idx),
          .lru_write_en(d_lru_write_en),
          .paddr_set(addr_idx),
          .invalidate_cache(cmu_bcast.fence_time),
          .invalidate_flush(1'b0)
      );
    end else begin : gen_no_dplru
      assign d_victim_way = '1;
      assign d_hit_way_onehot = '0;
      assign d_lru_write_en = 1'b0;
    end
  endgenerate

  // A load may consume SRAM data only when every way/subarray completed a
  // read for its index. Writes invalidate that shared correspondence; LD_A
  // then holds the request while the following free cycle re-reads it.
  logic l1d_sram_busy;
  assign l1d_sram_busy = l1d_update
                       || !sram_read_valid_r
                       || (sram_read_idx_r != addr_idx);
  assign tag_hit = (l1d_state == LD_A)
    && !l1d_sram_busy
    && tag_hit_vec[addr_offset];
  // data_hit: SRAM data ready in LD_A: the speculative read in the preceding
  // IDLE (or PTW-wait) cycle guarantees data_bank_rdata is valid on LD_A entry.
  assign data_hit = (l1d_state == LD_A) && tag_hit;
  // AND-OR mux: each way gates its data with its hit, then all ways OR.
  // Replaces the priority-encoder → indexed-mux chain.
  logic [XLEN-1:0] way_data_masked[L1D_N_WAYS];
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_ao_load
      assign way_data_masked[w] = way_tag_hit[addr_offset][w]
        ? data_bank_rdata[w][addr_offset] : '0;
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
  logic [L1dTagW-1:0] b_tag;
  logic [L1D_LEN-1:0] b_idx;
  logic [L1D_LINE_LEN-1:0] b_off;
  assign b_tag = b_addr_r[XLEN-1:L1D_LEN+L1D_LINE_LEN+L1dOffsetBits];
  assign b_idx = b_addr_r[L1D_LEN+L1D_LINE_LEN+L1dOffsetBits-1:L1D_LINE_LEN+L1dOffsetBits];
  assign b_off = b_addr_r[L1D_LINE_LEN+L1dOffsetBits-1:L1dOffsetBits];

  logic [L1D_N_WAYS-1:0] b_way_hit;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_b_tag_cmp
      assign b_way_hit[w] = (l1d_tag[w][b_idx] == b_tag) & l1d_valid[w][b_idx][b_off];
    end
  endgenerate

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
    for (int w = int'(L1D_N_WAYS) - 1; w >= 0; w--)
    if (way_whit[waddr_offset][w]) store_hit_way = L1dWayW'(w);
  end
  // Fill way selection for store miss (full-word write-allocate)
  logic [L1dWayW-1:0] store_fill_way;
  // Fill way selection for load miss
  logic [L1dWayW-1:0] ld_fill_way;
  generate
    if (L1D_N_WAYS == 2) begin : gen_fill_2way
      // Duplicate-tag prevention: if the tag already exists in a way, reuse it.
      logic ld_tag_dup0, ld_tag_dup1;
      assign ld_tag_dup0 = (|l1d_valid[0][addr_idx]) && way_tag_match[0];
      assign ld_tag_dup1 = (|l1d_valid[1][addr_idx]) && way_tag_match[1];
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
    end else if (L1D_N_WAYS > 2) begin : gen_fill_plru
      // Generic N-way: duplicate-tag > invalid at target offset > PLRU victim
      always_comb begin
        store_fill_way = '0;
        ld_fill_way     = '0;
        // Store side
        for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
          if ((|l1d_valid[w][waddr_idx]) && way_wtag_match[w]) store_fill_way = L1dWayW'(w);
        end
        if (store_fill_way == '0 && !(|way_wtag_match)) begin
          for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
            if (!l1d_valid[w][waddr_idx][waddr_offset]) begin
              store_fill_way = L1dWayW'(w);
              break;
            end
          end
        end
        // All ways have the target word valid (no invalid to pick): use PLRU victim
        if (store_fill_way == '0 && !(|way_wtag_match)) begin
          for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
            if (d_victim_way[w]) store_fill_way = L1dWayW'(w);
          end
        end
        // Load side
        for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
          if ((|l1d_valid[w][addr_idx]) && way_tag_match[w]) ld_fill_way = L1dWayW'(w);
        end
        if (ld_fill_way == '0 && !(|way_tag_match)) begin
          for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
            if (!l1d_valid[w][addr_idx][addr_offset]) begin
              ld_fill_way = L1dWayW'(w);
              break;
            end
          end
        end
        // All ways have the target word valid (no invalid to pick): use PLRU victim
        if (ld_fill_way == '0 && !(|way_tag_match)) begin
          for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
            if (d_victim_way[w]) ld_fill_way = L1dWayW'(w);
          end
        end
      end
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
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_load (
      .addr   (l1d_addr),
      .size_m1(load_size_m1),
      .priv   (eff_priv),
      .op_r   (1'b1),
      .op_w   (1'b0),
      .op_x   (1'b0),
      .pmp_raw_addr   (pmp_state.pmp_raw_addr),
      .pmp_napot_mask (pmp_state.pmp_napot_mask),
      .pmp_cfg_r      (pmp_state.pmp_cfg_r),
      .pmp_cfg_w      (pmp_state.pmp_cfg_w),
      .pmp_cfg_x      (pmp_state.pmp_cfg_x),
      .pmp_cfg_l      (pmp_state.pmp_cfg_l),
      .pmp_mode_off   (pmp_state.pmp_mode_off),
      .pmp_mode_tor   (pmp_state.pmp_mode_tor),
      .pmp_mode_na4   (pmp_state.pmp_mode_na4),
      .pmp_mode_napot (pmp_state.pmp_mode_napot),
      .fault  (pmp_load_fault),
      .fault_lo_o()
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
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_store_mmu (
      .addr   (exu_l1d.paddr),
      .size_m1(store_size_m1),
      .priv   (eff_priv),
      .op_r   (1'b0),
      .op_w   (1'b1),
      .op_x   (1'b0),
      .pmp_raw_addr   (pmp_state.pmp_raw_addr),
      .pmp_napot_mask (pmp_state.pmp_napot_mask),
      .pmp_cfg_r      (pmp_state.pmp_cfg_r),
      .pmp_cfg_w      (pmp_state.pmp_cfg_w),
      .pmp_cfg_x      (pmp_state.pmp_cfg_x),
      .pmp_cfg_l      (pmp_state.pmp_cfg_l),
      .pmp_mode_off   (pmp_state.pmp_mode_off),
      .pmp_mode_tor   (pmp_state.pmp_mode_tor),
      .pmp_mode_na4   (pmp_state.pmp_mode_na4),
      .pmp_mode_napot (pmp_state.pmp_mode_napot),
      .fault  (pmp_store_fault_mmu),
      .fault_lo_o()
  );
  // P3: PMA pre-check on the translated store PA. Mirrors load_unmapped_fault
  // -- stops a store to a region with no bus slave from issuing on AXI and
  // hanging the LSU. Bare-mode stores get the same check at the IOQ.
  logic store_unmapped_fault_mmu;
  assign store_unmapped_fault_mmu = !rapt_pkg::addr_mapped(exu_l1d.paddr);

  // --- Sv32/Sv39 PTE permission check (data access: load/store, not fetch) ---
  // pte bits (rapt_tlb layout): [0]=R [1]=W [2]=X [3]=U [4]=G [5]=A [6]=D.
  // Bit [4]=G (global) does not affect data fault and is not consumed below.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic pte_fault_data(input logic [6:0] pte, input logic is_store,
                                          input logic [1:0] priv_eff, input logic sum_i,
                                          input logic mxr_i);
    logic r, w, x, u, a, d;
    logic can_read;
    logic fault;
    r = pte[0];
    w = pte[1];
    x = pte[2];
    u = pte[3];
    a = pte[5];
    d = pte[6];
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
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_ptw (
      .addr   (ptw_araddr),
      .size_m1(4'd3),
      .priv   (eff_priv),
      .op_r   (1'b1),
      .op_w   (1'b0),
      .op_x   (1'b0),
      .pmp_raw_addr   (pmp_state.pmp_raw_addr),
      .pmp_napot_mask (pmp_state.pmp_napot_mask),
      .pmp_cfg_r      (pmp_state.pmp_cfg_r),
      .pmp_cfg_w      (pmp_state.pmp_cfg_w),
      .pmp_cfg_x      (pmp_state.pmp_cfg_x),
      .pmp_cfg_l      (pmp_state.pmp_cfg_l),
      .pmp_mode_off   (pmp_state.pmp_mode_off),
      .pmp_mode_tor   (pmp_state.pmp_mode_tor),
      .pmp_mode_na4   (pmp_state.pmp_mode_na4),
      .pmp_mode_napot (pmp_state.pmp_mode_napot),
      .fault  (pmp_ptw_fault),
      .fault_lo_o()
  );

  // Misaligned accesses are split by the LSU's MA-split FSM into two aligned
  // beats (load: ma_state_t in MA_HI; store: state_store == LS_S_HI_V) before
  // they reach this L1D, so we never see a true misaligned cache request.
  // The early STLB-lookup path (exu_l1d) does observe the original misaligned
  // virtual address, but the page-translation only depends on VPN bits and is
  // unaffected by the low alignment bits, so suppressing the misalign trap
  // here is safe for any access that does not cross a page boundary. (The
  // very rare cross-page case would need a second TLB walk and is not yet
  // handled -- Linux's misaligned memcpy stays within a page.)
  assign mis_align_load  = 1'b0;
  assign mis_align_store = 1'b0;

  // read channel: PTW takes priority over cache miss reads
  assign l1d_bus.arvalid = ptw_arvalid
    ? !pmp_ptw_fault
    : (l1d_state == LD_A)
      && !tag_hit
      && !l1d_sram_busy
      && !(pmp_load_fault || load_unmapped_fault)
      && (cacheable_r || lsu_l1d.ordered)
      && !cmu_bcast.flush_pipe;
  assign l1d_bus.araddr = ptw_arvalid ? ptw_araddr : l1d_addr;
  assign l1d_bus.rstrb = (cacheable_r || ptw_arvalid) ? 8'($unsigned({XLEN/8{1'b1}})) : rstrb;
  assign l1d_bus.ar_ptw = ptw_arvalid;

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
  assign l1d_bus.aw_ptw = ptw_awvalid;
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

  assign ptw_wready = ptw_wvalid && l1d_bus.ptw_wready;
  // Gate lsu wready while an RMW is in its merge-write phase: the SET block
  // below runs the `if (l1d_rmw)` branch this cycle, which means an incoming
  // store would not be consumed by the `else if (lsu_l1d.wvalid ...)` branch
  // and would be silently dropped if wready had fired. Stalling the store
  // for one cycle lets the merge-write complete and the next-cycle SET will
  // re-evaluate the new store.
  assign lsu_l1d.wready = !ptw_wvalid && l1d_bus.wready && !l1d_rmw && !fence_clear_busy;

  // store address translation: stlb_hit uses TLB, otherwise wait for PTW
  assign store_paddr = XLEN'({ptw_result_ptag, exu_l1d.vaddr[11:0]});
  assign exu_l1d.paddr = stlb_hit
    ? XLEN'({dstlb_ptag, exu_l1d.vaddr[11:0]})
    : store_paddr;
  assign exu_l1d.trap = (l1d_state == TRAP) && (rec_addr == exu_l1d.vaddr);
  assign exu_l1d.cause = cause;
  assign exu_l1d.reservation = reservation;
  assign exu_l1d.reservation_valid = reservation_valid;
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
      l1d_state <= IDLE;
      for (int w = 0; w < int'(L1D_N_WAYS); w++)
      for (int i = 0; i < int'(L1D_SIZE); i++) l1d_valid[w][i] <= '0;
      fence_clear_set <= '0;
      l1d_update <= 0;
      l1d_inv_all_ways <= 0;
      l1d_rmw    <= 0;
      d_replace_bit <= '0;
      ld_fill_way_r <= '0;
      l1d_way <= '0;

      reservation <= 'h0;
      reservation_valid <= 1'b0;
      l1d_atomic_lock <= 1'b0;
      load_killed <= 1'b0;
    end else begin
      fence_clear_set <= {L1D_SIZE{cmu_bcast.fence_time}};
      if (exu_l1d.reservation_clear) begin
        reservation_valid <= 1'b0;
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
          load_killed <= 1'b0;
          l1d_atomic_lock <= 1'b0;
          if (!cmu_bcast.flush_pipe && !fence_clear_busy) begin
            if (mmu_en) begin
              // Store TLB lookup (priority)
              if (exu_l1d.mmu_en && exu_l1d.valid) begin
                // if (exu_l1d.vaddr == XLEN'('h800c1eac)) begin
                //   $display("[L1D_TARGET] state=IDLE hit=%0d pte=%h pf=%0d busy=%0d",
                //            stlb_hit, dstlb_pte, pf_store_tlb, ptw_busy);
                // end
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
                  l1d_atomic_lock <= lsu_l1d.atomic_lock;
                  l1d_state <= LD_A;
                end else if (!ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr <= lsu_l1d.raddr;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
                  l1d_atomic_lock <= lsu_l1d.atomic_lock;
                  stlb_mmu <= 'b0;
                  l1d_state <= PTWAIT;
                end
              end
            end else begin
              if (lsu_l1d.rvalid) begin
                l1d_addr <= lsu_l1d.raddr;
                rec_addr <= lsu_l1d.raddr;
                l1d_ralu  <= lsu_l1d.ralu;
                l1d_atomic_lock <= lsu_l1d.atomic_lock;
                l1d_state <= LD_A;
              end
            end
          end
        end
        PTWAIT: begin
          // if (rec_addr == XLEN'('h800c1eac) && (ptw_done || ptw_fault)) begin
          //   $display("[L1D_TARGET] state=PTWAIT done=%0d fault=%0d ptag=%h pte=%h pf=%0d",
          //            ptw_done, ptw_fault, ptw_result_ptag, ptw_result_pte, pf_store_ptw);
          // end
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
              cause <= 'hd;  // load page fault
            end
            l1d_state <= TRAP;
          end
        end
        TRAP: begin
          l1d_state <= IDLE;
        end
        LD_A: begin
          if (cmu_bcast.flush_pipe) begin
            l1d_addr <= '0;
            l1d_state <= IDLE;
          end else if (!cacheable_r && !lsu_l1d.ordered) begin
            l1d_state <= LD_A;
          end else if (pmp_load_fault || load_unmapped_fault) begin
            // PMP denies load at this physical address for eff_priv,
            // or the address is unmapped (bus error -> access fault).
            cause <= `RAPT_CAUSE_LOAD_ACC_FAULT;
            l1d_state <= TRAP;
          end else if (l1d_atomic_lock) begin
            if (tag_hit) begin
              reservation <= l1d_addr;
              reservation_valid <= 1'b1;
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
            if (l1d_bus.rerr) begin
              cause     <= `RAPT_CAUSE_LOAD_ACC_FAULT;
              l1d_state <= TRAP;
            end else begin
              l1d_state <= IDLE;
              if (l1d_atomic_lock && !load_killed && !cmu_bcast.flush_pipe) begin
                reservation <= l1d_addr;
                reservation_valid <= 1'b1;
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
      if (|fence_clear_set) begin
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
            if (w != int'(l1d_way) && l1d_tag[w][l1d_idx] == l1d_tag_u) begin
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

      for (int w = 0; w < int'(L1D_N_WAYS); w++) begin
        for (int i = 0; i < int'(L1D_SIZE); i++) begin
          if (fence_clear_set[i]) l1d_valid[w][i] <= '0;
        end
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
        // Treat misaligned full-width store as partial: cache must not be
        // updated as if the natural-aligned word/dword was fully written,
        // because the BUS shifts wstrb/wdata by waddr_lo.
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
        if (lsu_l1d.rvalid && l1d_bus.rvalid) begin
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
  `RAPT_SVA_NEXT(
      clock, reset, L1D_LR_HIT_ESTABLISHES_RESERVATION,
      (l1d_state == LD_A) && tag_hit && l1d_atomic_lock && !cmu_bcast.flush_pipe && !exu_l1d.reservation_clear,
      reservation_valid && reservation == $past(l1d_addr))
  `RAPT_SVA_NEXT(
      clock, reset, L1D_LR_RESPONSE_ESTABLISHES_RESERVATION,
      (l1d_state == LD_D) && l1d_bus.rvalid && !l1d_bus.rerr && l1d_atomic_lock && !load_killed && !cmu_bcast.flush_pipe && !exu_l1d.reservation_clear,
      reservation_valid && reservation == $past(l1d_addr))
  `RAPT_SVA_NEXT(
      clock, reset, L1D_KILLED_LR_RESPONSE_NO_NEW_RESERVATION,
      (l1d_state == LD_D) && l1d_bus.rvalid && l1d_atomic_lock && !reservation_valid && (load_killed || cmu_bcast.flush_pipe),
      !reservation_valid)
endmodule
/* verilator lint_on PINCONNECTEMPTY */
