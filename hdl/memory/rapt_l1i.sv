`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

`ifndef RAPT_L1I_REFILL_WORDS
`define RAPT_L1I_REFILL_WORDS 8
`endif

/* verilator lint_off PINCONNECTEMPTY */
module rapt_l1i #(
    parameter int XLEN = `RAPT_XLEN,
  parameter unsigned IFQ_SIZE = `RAPT_L1I_REFILL_WORDS,
    parameter int L1I_LINE_LEN = `RAPT_L1I_LINE_LEN,
  parameter int unsigned L1I_LINE_SIZE = 2 ** L1I_LINE_LEN,
    parameter int L1I_LEN = `RAPT_L1I_LEN,
    parameter unsigned L1I_N_WAYS = `RAPT_L1I_N_WAYS
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_l1i_if.slave  ifu_l1i,
    l1i_bus_if.master l1i_bus,

    csr_bcast_if.in csr_bcast,
    pmp_state_if.in pmp_state,

    input reset
);
  typedef enum logic [2:0] {
    IDLE   = 3'b000,
    PTWAIT = 3'b100,  // waiting for PTW to complete
    TRAP   = 3'b101,
    RD_A   = 3'b001,  // re-check hit after PTW/MMU
    RD_0   = 3'b010,
    RD_1   = 3'b110,
    FINA   = 3'b111
  } l1i_state_t;

  l1i_state_t l1i_state;

  localparam int unsigned LineWords = int'(L1I_LINE_SIZE);
  // Never permit a refill to cross the configured cache-line boundary. This
  // keeps VFLAGS experiments safe for the 16B small/formal presets too.
  localparam int unsigned RefillWords = (`RAPT_L1I_REFILL_WORDS < LineWords)
                                     ? `RAPT_L1I_REFILL_WORDS : LineWords;
  localparam int unsigned RefillIdxW = (RefillWords <= 1) ? 1 : $clog2(RefillWords);
  localparam int unsigned RefillBytes = RefillWords * 4;
  logic [RefillIdxW-1:0] l1i_fill_issue_idx;

  // Simulation PMU probes. Registered alongside the IFU's probes so C++ can
  // attribute no-response cycles without relying on a post-update FSM state.
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_l1i_refill_active;
  logic pmu_l1i_sram_warmup;
  logic pmu_l1i_tag_miss;
  logic pmu_l1i_nextword_miss;
  logic pmu_l1i_refill_start_line_miss;
  logic pmu_l1i_refill_start_current_hole;
  logic pmu_l1i_refill_start_next_line_miss;
  logic pmu_l1i_refill_start_next_hole;
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off UNUSEDSIGNAL */
  logic raddr_valid;
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] vaddr;
  logic invalid_l1i;

  logic is_c;
  logic [15:0] inst_lo, inst_hi;
  logic [XLEN-1:0] pc_ifu_next;
  logic [XLEN-1:0] l1i_addr;
  logic [XLEN-1:0] rec_addr;
  logic [XLEN-1:0] rec_tval;
  logic [XLEN-1:0] fetch_addr;
  // Cache size/tag parameters and per-way line-level tag arrays.
  localparam unsigned L1iSize = 2 ** L1I_LEN;
  localparam unsigned L1iTagW = XLEN - L1I_LEN - L1I_LINE_LEN - 2;  // 2 = $clog2(4), word size
  localparam unsigned L1iWayW = L1I_N_WAYS > 1 ? $clog2(L1I_N_WAYS) : 1;
  logic [L1I_LINE_SIZE-1:0] l1i_valid[L1I_N_WAYS][L1iSize];

  // Per-way data SRAM bank signals.
  logic [31:0] data_bank_rdata[L1I_N_WAYS][L1I_LINE_SIZE];
  logic [L1I_LEN-1:0] data_bank_raddr[L1I_LINE_SIZE];  // shared across ways

  // Per-way tag mirrors: one copy for the current line, one for pc+4.
  logic [L1iTagW-1:0] tag_rdata_curr[L1I_N_WAYS];
  logic [L1iTagW-1:0] tag_rdata_next4[L1I_N_WAYS];
  logic [L1I_N_WAYS-1:0] tag_valid_curr, tag_valid_next4;
  logic [L1I_N_WAYS-1:0] fill_tag_match;
  logic [L1I_LINE_SIZE-1:0] fill_word_mask;

  // Way hit logic
  logic [L1I_N_WAYS-1:0] way_hit, way_hit_next;
  logic [L1I_N_WAYS-1:0] way_tag_match, way_tag_match_next;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [L1iWayW-1:0] hit_way_sel, hit_next_way_sel;
  /* verilator lint_on UNUSEDSIGNAL */

  // Replacement: PLRU for >2 ways, toggle for 2-way
  logic [L1iSize-1:0] replace_bit;
  logic [L1iWayW-1:0] fill_way_r;
  logic [L1iWayW-1:0] fill_way_calc, fill_way_next_calc;
  // PLRU signals (only used for >2-way; suppressed for 2-way)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [L1I_N_WAYS-1:0] victim_way;
  logic [L1I_N_WAYS-1:0] hit_way_onehot;
  logic                  lru_write_en;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [L1iTagW-1:0] addr_tag;
  logic [L1I_LEN-1:0] addr_idx;
  logic [L1I_LINE_LEN-1:0] addr_offset;

  logic [L1iTagW-1:0] addr_tag_next;
  logic [L1I_LEN-1:0] addr_idx_next;
  logic [L1I_LINE_LEN-1:0] addr_offset_next;

  logic [L1iTagW-1:0] addr_tag_next4;

  logic [L1iTagW-1:0] tag_fetch;
  logic [L1I_LEN-1:0] idx_fetch;
  logic [L1I_LINE_LEN-1:0] offset_fetch;

  logic hit, hit_next;
  logic ifu_sdram_arburst;
  logic fetch_addr_valid;
  logic wait_invalid;

  // A predicted target can hide the synchronous data-SRAM latency by using
  // the next read slot. This is bare-mode only: under translation L1I owns
  // physical-address formation, so an IFU virtual target is not a valid SRAM
  // hint. The read is side-effect-free and never allocates or requests data.
  logic target_read_ahead;
  logic [L1I_LEN-1:0] sram_read_idx;
  logic [L1I_LEN-1:0] sram_read_idx_next;
  logic [L1I_LEN-1:0] sram_read_idx_next4;
  logic [L1I_LINE_LEN-1:0] sram_read_offset;
  logic [L1I_LINE_LEN-1:0] sram_read_offset_next;
  logic sram_read_half;

  logic mmu_en;
  logic tlb_hit;
  logic [XLEN-1:10] itlb_ptag;
  logic [6:0] itlb_pte;
  logic [11:0] tlb_offset;

  logic [XLEN-1:0] cause;

  logic [$clog2(IFQ_SIZE)-1:0] ifq_head;
  logic [$clog2(IFQ_SIZE)-1:0] ifq_tail;
  logic [IFQ_SIZE-1:0] ifq_valid;
  logic [XLEN-1:0] ifq_raddr[IFQ_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */

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
  logic [XLEN-1:10] ptw_result_ptag;
  logic [XLEN-1:12] ptw_result_vtag;
  logic [6:0] ptw_result_pte;
  logic pmp_iptw_fault;  // forward-declared; driven by u_pmp_iptw below

  logic l1i_fill_en;
  logic l1i_tag_valid_set;
  logic cache_ar_accept;
  logic l1i_tag_inv;
  logic ifq_push_en;
  logic ifq_clear_en;

  assign mmu_en = csr_bcast.immu_en;
  assign pc_ifu = mmu_en ? XLEN'({itlb_ptag, tlb_offset}) : ifu_l1i.pc;
  assign invalid_l1i = ifu_l1i.invalid;
  assign pc_ifu_next = pc_ifu + 2;

  // +4 lookahead: when the fetch stride is +4 (32-bit insn or dual C-pair),
  // the SRAM bank that will be needed next cycle is the one for pc+4, not
  // pc+2.  Pre-reading this address in idle banks eliminates the 1-cycle
  // SRAM-ready bubble that otherwise occurs at every cache-line crossing.
  // Only the index/tag bits of pc_ifu_next4 are consumed; the byte-offset
  // bits feed nothing because the SRAM banks are word-aligned by construction.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] pc_ifu_next4;
  logic [XLEN-1:0] pc_ifu_next6;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [L1I_LEN-1:0] addr_idx_next4;

  // --- PMP check on fetch physical address (instruction access-fault) ---
  // `pc_ifu` already multiplexes between the bare PC and the MMU-translated
  // physical address (post-TLB-hit), so we can pass it directly.  The FSM
  // only samples `pmp_fetch_fault` in states where `pc_ifu` is meaningful
  // (bare mode: always; MMU: after tlb_hit).
  logic pmp_fetch_fault_lo;
  logic pmp_fetch_pmp_fault;
  logic pmp_fetch_fault;

  assign pc_ifu_next4 = pc_ifu + 4;
  assign pc_ifu_next6 = pc_ifu + 6;
  assign addr_idx_next4 = pc_ifu_next4[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];

  assign tlb_offset = ifu_l1i.pc[11:0];

  assign addr_tag = pc_ifu[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign addr_idx = pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  assign addr_offset = pc_ifu[L1I_LINE_LEN+2-1:2];

  assign addr_tag_next = pc_ifu_next[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign addr_idx_next = pc_ifu_next[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  assign addr_offset_next = pc_ifu_next[L1I_LINE_LEN+2-1:2];
  assign addr_tag_next4 = pc_ifu_next4[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];

  assign fetch_addr = ifq_raddr[ifq_tail];
  assign tag_fetch = fetch_addr[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign offset_fetch = fetch_addr[L1I_LINE_LEN+2-1:2];
  assign idx_fetch = fetch_addr[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];

  assign fetch_addr_valid = csr_bcast.immu_en || rapt_pkg::addr_cacheable(pc_ifu);
  assign raddr_valid = csr_bcast.immu_en || rapt_pkg::addr_cacheable(l1i_addr);
  assign target_read_ahead = ifu_l1i.prefetch_valid && !mmu_en
                          && !invalid_l1i && !wait_invalid
                          && rapt_pkg::addr_cacheable(ifu_l1i.prefetch_pc);
  assign sram_read_idx = target_read_ahead
                       ? ifu_l1i.prefetch_pc[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2]
                       : pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  assign sram_read_offset = target_read_ahead
                          ? ifu_l1i.prefetch_pc[L1I_LINE_LEN+1:2]
                          : pc_ifu[L1I_LINE_LEN+1:2];
  assign sram_read_half = target_read_ahead ? ifu_l1i.prefetch_pc[1] : pc_ifu[1];
  // +2 crosses into the next word only from an upper-halfword PC; +4
  // always advances one word. Carry into the set index occurs at line end.
  assign sram_read_offset_next = sram_read_offset + L1I_LINE_LEN'(sram_read_half);
  assign sram_read_idx_next = sram_read_idx
                             + L1I_LEN'(sram_read_half && (&sram_read_offset));
  assign sram_read_idx_next4 = sram_read_idx + L1I_LEN'(&sram_read_offset);

  // Pipeline tracking: valid address was presented in previous cycle
  logic addr_valid_r;
  always_ff @(posedge clock) begin
    if (reset) addr_valid_r <= 1'b0;
    else addr_valid_r <= fetch_addr_valid && !invalid_l1i && !wait_invalid
                        && (l1i_state == IDLE || l1i_state == RD_A || l1i_state == FINA);
  end

  // --- L1I Tag Comparison (N-way set-associative, line-level tags) ---
  generate
    for (genvar w = 0; w < L1I_N_WAYS; w++) begin : gen_way_hit
      assign way_tag_match[w] = tag_valid_curr[w] && (tag_rdata_curr[w] == addr_tag);
      assign way_tag_match_next[w] = (pc_ifu[1] ? tag_valid_next4[w] : tag_valid_curr[w])
        && ((pc_ifu[1] ? tag_rdata_next4[w] : tag_rdata_curr[w]) == addr_tag_next);
      assign way_hit[w] = way_tag_match[w] && l1i_valid[w][addr_idx][addr_offset];
      assign way_hit_next[w] = way_tag_match_next[w]
        && l1i_valid[w][addr_idx_next][addr_offset_next];
    end
  endgenerate
  always_comb begin
    hit_way_sel = '0;
    for (int w = int'(L1I_N_WAYS) - 1; w >= 0; w--) if (way_hit[w]) hit_way_sel = L1iWayW'(w);
    hit_next_way_sel = '0;
    for (int w = int'(L1I_N_WAYS) - 1; w >= 0; w--)
    if (way_hit_next[w]) hit_next_way_sel = L1iWayW'(w);
  end
  // Fill way: prefer duplicate-tag way, then invalid way, then PLRU/toggle victim.
  // For 2-way: simple toggle. For >2-way: tree-based PLRU.
  generate
    if (L1I_N_WAYS == 2) begin : gen_fill_2way
      assign fill_way_calc = way_tag_match[0] ? 1'b0
        : way_tag_match[1] ? 1'b1
        : !tag_valid_curr[0] ? 1'b0
        : !tag_valid_curr[1] ? 1'b1
        : replace_bit[addr_idx];
      assign fill_way_next_calc = way_tag_match_next[0] ? 1'b0
        : way_tag_match_next[1] ? 1'b1
        : !(pc_ifu[1] ? tag_valid_next4[0] : tag_valid_curr[0]) ? 1'b0
        : !(pc_ifu[1] ? tag_valid_next4[1] : tag_valid_curr[1]) ? 1'b1
        : replace_bit[addr_idx_next];
    end else if (L1I_N_WAYS > 2) begin : gen_fill_plru
      // Generic: duplicate-tag > invalid > PLRU victim
      always_comb begin
        fill_way_calc = '0;
        // Check duplicate tag first
        for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
          if (way_tag_match[w]) fill_way_calc = L1iWayW'(w);
        end
        // Then invalid
        if (fill_way_calc == '0 && !(|way_tag_match)) begin
          for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
            if (!tag_valid_curr[w]) begin
              fill_way_calc = L1iWayW'(w);
              break;
            end
          end
        end
        // Fallback: PLRU victim (one-hot to binary)
        if (fill_way_calc == '0 && !(|way_tag_match) && &tag_valid_curr) begin
          for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
            if (victim_way[w]) fill_way_calc = L1iWayW'(w);
          end
        end
      end
      // next calc: same logic but using next tag signals
      always_comb begin
        fill_way_next_calc = '0;
        for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
          if (way_tag_match_next[w]) fill_way_next_calc = L1iWayW'(w);
        end
        if (fill_way_next_calc == '0 && !(|way_tag_match_next)) begin
          for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
            if (!(pc_ifu[1] ? tag_valid_next4[w] : tag_valid_curr[w])) begin
              fill_way_next_calc = L1iWayW'(w);
              break;
            end
          end
        end
        if (fill_way_next_calc == '0 && !(|way_tag_match_next)
            && &{(pc_ifu[1] ? tag_valid_next4 : tag_valid_curr)}) begin
          for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
            if (victim_way[w]) fill_way_next_calc = L1iWayW'(w);
          end
        end
      end
    end else begin : gen_fill_dm
      assign fill_way_calc = '0;
      assign fill_way_next_calc = '0;
    end
  endgenerate

  assign hit = (!invalid_l1i && !wait_invalid)
    && (mmu_en ? tlb_hit : 1'b1)
    && (l1i_state == IDLE || rec_addr == ifu_l1i.pc)
    && |way_hit;
  assign hit_next = (!invalid_l1i && !wait_invalid) && (mmu_en ? tlb_hit : 1'b1) && |way_hit_next;

  // Bus mux: PTW takes priority over cache fill
  assign l1i_bus.araddr = ptw_arvalid
    ? ptw_araddr
    : ifu_sdram_arburst
      ? ((l1i_state == RD_0) ? (l1i_addr & ~'h4) : (l1i_addr | 'h4))
      : (RefillWords == 2)
        ? ((l1i_state == RD_0) ? (l1i_addr & ~'h4) : (l1i_addr | 'h4))
        : ((l1i_addr & ~XLEN'(RefillBytes - 1))
           + (XLEN'(l1i_fill_issue_idx) << 2));
  assign l1i_bus.arvalid = ptw_arvalid
    ? !pmp_iptw_fault
    : raddr_valid && ((ifu_sdram_arburst || (RefillWords == 2))
      ? (l1i_state == RD_0 || (!ifu_sdram_arburst && l1i_state == RD_1))
      : (l1i_state == RD_0));
  assign l1i_bus.ar_ptw = ptw_arvalid;

  assign ifu_sdram_arburst = (`RAPT_I_SDRAM_ARBURST)
    && (l1i_addr >= 'ha0000000)
    && (l1i_addr <= 'hc0000000);
  assign l1i_bus.arburst = ifu_sdram_arburst;
  assign l1i_bus.awvalid = ptw_awvalid;
  assign l1i_bus.awaddr  = ptw_awaddr;
  assign l1i_bus.wvalid  = ptw_wvalid;
  assign l1i_bus.wdata   = ptw_wdata;
  assign l1i_bus.wstrb   = ptw_wstrb;
  assign l1i_bus.aw_ptw  = 1'b1;

  // Cache refills and IPTW reads have distinct AXI IDs. A cache response may
  // therefore complete while the walker is busy and must still be consumed.
  assign l1i_fill_en = l1i_bus.rvalid && ifq_valid[ifq_tail];
  assign l1i_tag_valid_set = l1i_fill_en && (ifq_valid[0] == 0);
  assign l1i_tag_inv = (invalid_l1i || wait_invalid) && (l1i_state == IDLE);
  assign fill_word_mask = {{L1I_LINE_SIZE - 1{1'b0}}, 1'b1} << offset_fetch;
  assign cache_ar_accept = l1i_bus.rready && !ptw_arvalid;
  assign ifq_push_en = ((l1i_state == RD_0) && cache_ar_accept && !l1i_bus.rerr)
    || ((l1i_state == RD_1) && (ifu_sdram_arburst || cache_ar_accept)
        && !(cache_ar_accept && l1i_bus.rerr));
  assign ifq_clear_en = ((l1i_state == RD_0) && cache_ar_accept && l1i_bus.rerr)
    || ((l1i_state == RD_1) && cache_ar_accept && l1i_bus.rerr)
    || ((l1i_state == FINA) && !raddr_valid);

`ifdef RAPT_RV64
  logic [31:0] l1i_fill_data;
  assign l1i_fill_data = fetch_addr[2] ? l1i_bus.rdata[63:32] : l1i_bus.rdata[31:0];
`else
  logic [31:0] l1i_fill_data;
  assign l1i_fill_data = l1i_bus.rdata[31:0];
`endif

  // --- ITLB ---
  rapt_tlb #(
      .XLEN(XLEN)
  ) u_itlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(ifu_l1i.pc[XLEN-1:12]),
      .lookup_asid(csr_bcast.satp_asid),
      .hit(tlb_hit),
      .ptag(itlb_ptag),
      .pte_flags(itlb_pte),
      .fill_valid((l1i_state == PTWAIT) && ptw_done),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid),
      .fill_pte(ptw_result_pte)
  );

  // --- PTW ---
  rapt_ptw #(
      .XLEN(XLEN)
  ) u_iptw (
      .clock(clock),
      .reset(reset),
      .req_valid(ptw_req),
      .kill(cmu_bcast.fence_time || cmu_bcast.flush_pipe),
      .vaddr(ifu_l1i.pc),
      .satp_ppn(csr_bcast.satp_ppn),
      .mmu_en(mmu_en),
      .sbe(csr_bcast.sbe),
      .req_store(1'b0),
      .bus_arvalid(ptw_arvalid),
      .bus_araddr(ptw_araddr),
      .bus_arready(l1i_bus.rready),
      .bus_rvalid(l1i_bus.ptw_rvalid),
      .bus_rdata(l1i_bus.rdata),
      .bus_awvalid(ptw_awvalid),
      .bus_awaddr(ptw_awaddr),
      .bus_wvalid(ptw_wvalid),
      .bus_wdata(ptw_wdata),
      .bus_wstrb(ptw_wstrb),
      .bus_wready(l1i_bus.ptw_wready),
      .bus_werr(l1i_bus.ptw_werr),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptw_result_ptag),
      .result_vtag(ptw_result_vtag),
      .result_pte(ptw_result_pte),
      .busy(ptw_busy)
  );

  // Sv32/Sv39 fetch permission check: execute must be allowed for current priv.
  // itlb_pte = {D,A,G,U,X,W,R}; only X/U/A bits influence fetch fault.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic pte_fault_fetch(input logic [6:0] pte, input logic [1:0] priv_i);
  /* verilator lint_on UNUSEDSIGNAL */
    logic x, u, a;
    logic fault;
    x = pte[2];
    u = pte[3];
    a = pte[5];
    fault = 1'b0;
    if (!x) fault = 1'b1;
    if (!a) fault = 1'b1;
    if (priv_i == `RAPT_PRIV_U && !u) fault = 1'b1;
    if (priv_i == `RAPT_PRIV_S && u) fault = 1'b1;  // no SUM on fetch
    return fault;
  endfunction

  logic pf_fetch_tlb, pf_fetch_ptw;
  assign pf_fetch_tlb = tlb_hit && pte_fault_fetch(itlb_pte, csr_bcast.priv);
  assign pf_fetch_ptw = pte_fault_fetch(ptw_result_pte, csr_bcast.priv);

  // --- PMP check on PTW memory (PTE) reads for instruction translation ---
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_iptw (
      .addr          (ptw_araddr),
      .size_m1       (4'd3),
      .priv          (csr_bcast.priv),
      .op_r          (1'b1),
      .op_w          (1'b0),
      .op_x          (1'b0),
      .pmp_raw_addr  (pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r     (pmp_state.pmp_cfg_r),
      .pmp_cfg_w     (pmp_state.pmp_cfg_w),
      .pmp_cfg_x     (pmp_state.pmp_cfg_x),
      .pmp_cfg_l     (pmp_state.pmp_cfg_l),
      .pmp_mode_off  (pmp_state.pmp_mode_off),
      .pmp_mode_tor  (pmp_state.pmp_mode_tor),
      .pmp_mode_na4  (pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault         (pmp_iptw_fault),
      .fault_lo_o    ()
  );

  // SRAM address routing (shared across all ways)
  //
  // Three-tier pre-read strategy for zero-bubble sequential fetch at both
  // +2 and +4 byte strides. On an accepted bare-mode predicted target,
  // `sram_read_pc` selects that target instead of the current sequential PC:
  //   - Bank matching read offset      -> reads read index      (current/target)
  //   - Bank matching read offset +2   -> reads next index (+2 lookahead,
  //                                       needed for 32-bit insn spanning)
  //   - All remaining banks            -> read next4 index (+4 lookahead,
  //                                       covers 32-bit insn stride and
  //                                       dual C-pair stride)
  //
  // When pc is word-aligned the +2 bank falls on the same offset as the
  // current bank, so the second tier collapses and three banks pre-read +4.
  generate
    for (genvar gi = 0; gi < L1I_LINE_SIZE; gi++) begin : gen_addr
      assign data_bank_raddr[gi] =
          (sram_read_offset == L1I_LINE_LEN'(gi))
          ? sram_read_idx
          : (sram_read_offset_next == L1I_LINE_LEN'(gi))
            ? sram_read_idx_next
            : sram_read_idx_next4;
    end
  endgenerate

  // Per-way independent line-level tag memories. The second mirror always
  // tracks the line containing pc+4, which also covers pc+2 when pc[1]==1.
  generate
    for (genvar w = 0; w < L1I_N_WAYS; w++) begin : gen_way_tag
      rapt_l1i_tagmem #(
          .L1I_LEN(L1I_LEN),
          .TAG_W(L1iTagW),
          .L1I_SIZE(L1iSize)
      ) u_tagmem (
          .clock(clock),
          .reset(reset),
          .raddr_curr(addr_idx),
          .rtag_curr(tag_rdata_curr[w]),
          .rvalid_curr(tag_valid_curr[w]),
          .raddr_next4(addr_idx_next4),
          .rtag_next4(tag_rdata_next4[w]),
          .rvalid_next4(tag_valid_next4[w]),
          .wen(l1i_fill_en && (fill_way_r == L1iWayW'(w))),
          .waddr_idx(idx_fetch),
          .wtag(tag_fetch),
          .wtag_match(fill_tag_match[w]),
          .valid_set(l1i_tag_valid_set && (fill_way_r == L1iWayW'(w))),
          .valid_set_idx(idx_fetch),
          .inv(l1i_tag_inv)
      );
    end
  endgenerate

  // PLRU instantiation for >2-way caches
  generate
    if (L1I_N_WAYS > 2) begin : gen_plru
      // One-hot hit way encoding for PLRU update
      always_comb begin
        hit_way_onehot = '0;
        for (int w = 0; w < int'(L1I_N_WAYS); w++)
          if (way_hit[w]) hit_way_onehot[w] = 1'b1;
      end
      assign lru_write_en = hit && (l1i_state == IDLE || l1i_state == RD_A)
                            && (rec_addr == ifu_l1i.pc);

      rapt_plru #(
          .NUMWAYS(L1I_N_WAYS),
          .SETLEN(L1I_LEN),
          .NSETS(L1iSize)
      ) u_plru (
          .clock(clock),
          .reset(reset),
          .cache_en(1'b1),
          .hit_way(hit_way_onehot),
          .valid_way(tag_valid_curr),
          .victim_way(victim_way),
          .cache_set(addr_idx),
          .lru_write_en(lru_write_en),
          .paddr_set(addr_idx),
          .invalidate_cache(invalid_l1i),
          .invalidate_flush(1'b0)
      );
    end else begin : gen_no_plru
      assign victim_way = '1;
      assign hit_way_onehot = '0;
      assign lru_write_en = 1'b0;
    end
  endgenerate

  // Per-way data SRAM banks (single shared read/write port).
  //
  // Refill writes reuse the fetch read port: l1i_fill_en only fires while
  // the FSM is in RD_0/RD_1 (miss refill), when no fetch data is consumed,
  // so the port is free. The write address replaces the read address for
  // that one cycle; fetch reads resume as soon as the fill completes.
  generate
    for (genvar w = 0; w < L1I_N_WAYS; w++) begin : gen_way
      for (genvar gi = 0; gi < L1I_LINE_SIZE; gi++) begin : gen_bank
        logic bank_wen;
        assign bank_wen = l1i_fill_en && (offset_fetch == L1I_LINE_LEN'(gi))
                       && (fill_way_r == L1iWayW'(w));
        rapt_sram_1rw #(
            .ADDR_WIDTH(L1I_LEN),
            .DATA_WIDTH(32)
        ) u_data_sram (
            .clock(clock),
            .en   (1'b1),
            .wen  (bank_wen),
            .addr (bank_wen ? idx_fetch : data_bank_raddr[gi]),
            .rdata(data_bank_rdata[w][gi]),
            .wdata(l1i_fill_data),
            .bwe  ('b0)
        );
      end
    end
  endgenerate

  // Word selection from SRAM banks for instruction output
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] l1i_word_current, l1i_word_next;
  /* verilator lint_on UNUSEDSIGNAL */
  assign l1i_word_current = data_bank_rdata[hit_way_sel][addr_offset];
  assign l1i_word_next = data_bank_rdata[hit_next_way_sel][addr_offset_next];

  assign inst_lo = pc_ifu[1] ? l1i_word_current[31:16] : l1i_word_current[15:0];
  assign inst_hi = pc_ifu[1] ? l1i_word_next[15:0] : l1i_word_current[31:16];
  assign is_c = !(inst_lo[1:0] == 2'b11);

  // SRAM data readiness: per-bank address tracking.
  //
  // Each bank gi drives raddr = addr_idx when addr_offset==gi, else addr_idx_next.
  // Non-current banks pre-read the next set every cycle, so for sequential fetch
  // the target bank has already loaded the right data in the previous cycle
  // (sram_data_ready = 1 with zero bubble). Branches/redirects still incur the
  // one-cycle SRAM latency, as the banks were reading a different index.
  //
  // inst_lo comes from bank[addr_offset]  -> check data_bank_raddr_d1[addr_offset] == addr_idx
  // inst_hi comes from bank[addr_offset_next] -> check data_bank_raddr_d1[addr_offset_next] == addr_idx_next
  //   (skipped when is_c=1, since only inst_lo is needed for 16-bit instructions)
  logic [L1I_LEN-1:0] data_bank_raddr_d1[L1I_N_WAYS][L1I_LINE_SIZE];
  logic data_bank_rvalid_d1[L1I_N_WAYS][L1I_LINE_SIZE];
  logic sram_data_ready;
  always_ff @(posedge clock) begin
    for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
      for (int i = 0; i < int'(L1I_LINE_SIZE); i++) begin
        if (reset) begin
          data_bank_rvalid_d1[w][i] <= 1'b0;
        end else if (l1i_fill_en && (fill_way_r == L1iWayW'(w))
                    && (offset_fetch == L1I_LINE_LEN'(i))) begin
          // A 1RW write leaves rdata unchanged; do not label the held value as
          // the newly filled set. The following read cycle revalidates it.
          data_bank_rvalid_d1[w][i] <= 1'b0;
        end else begin
          data_bank_raddr_d1[w][i] <= data_bank_raddr[i];
          data_bank_rvalid_d1[w][i] <= 1'b1;
        end
      end
    end
  end
  assign sram_data_ready = addr_valid_r
    && data_bank_rvalid_d1[hit_way_sel][addr_offset]
    && (data_bank_raddr_d1[hit_way_sel][addr_offset] == addr_idx)
    && (is_c || (data_bank_rvalid_d1[hit_next_way_sel][addr_offset_next]
                 && data_bank_raddr_d1[hit_next_way_sel][addr_offset_next] == addr_idx_next));

  assign ifu_l1i.inst_n0 = (l1i_state == TRAP) ? 'h00000013 : {{inst_hi}, {inst_lo}};
  assign ifu_l1i.trap = (l1i_state == TRAP && rec_addr == ifu_l1i.pc);
  assign ifu_l1i.cause = cause;
  assign ifu_l1i.tval = rec_tval;
  // PMP must gate cache-hit delivery as well: without this, a hit in IDLE
  // streams the instruction to IFU the same cycle the FSM transitions to
  // TRAP, letting the forbidden fetch execute.
  assign ifu_l1i.valid = l1i_state == TRAP ? rec_addr == ifu_l1i.pc
    : (!pmp_fetch_fault && hit && sram_data_ready && (hit_next || is_c) && !wait_invalid);

`ifdef RAPT_DUAL_ISSUE
  // --- Dual-issue: next-word output for generalized dual-fetch ---
  // When pc[1]=0: bank[addr_offset+1] holds the word at pc+4.
  // When pc[1]=1: bank[addr_offset_next] already has pc+2..pc+5; reuse l1i_word_next.
  logic [L1I_LINE_LEN-1:0] addr_offset_n1;
  logic [L1I_LINE_LEN-1:0] addr_offset_n2;
  logic [L1I_N_WAYS-1:0] way_hit_n1;
  logic [L1I_N_WAYS-1:0] way_hit_n2;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [L1iWayW-1:0] hit_n1_way_sel;
  logic [L1iWayW-1:0] hit_n2_way_sel;
  /* verilator lint_on UNUSEDSIGNAL */
  logic hit_n1;
  logic hit_n2;
  logic [31:0] l1i_word_n1;
  logic [31:0] l1i_word_n2;
  logic sram_n1_ready;
  logic sram_n2_ready;
  logic n2_same_line_as_next4;

  assign addr_offset_n1 = addr_offset + L1I_LINE_LEN'(1);
  assign addr_offset_n2 = addr_offset + L1I_LINE_LEN'(2);

  generate
    for (genvar w = 0; w < L1I_N_WAYS; w++) begin : gen_way_hit_n1
      assign way_hit_n1[w] = tag_valid_next4[w]
        && (tag_rdata_next4[w] == addr_tag_next4)
        && l1i_valid[w][addr_idx_next4][addr_offset_n1];
      assign way_hit_n2[w] = tag_valid_next4[w]
        && (tag_rdata_next4[w] == addr_tag_next4)
        && l1i_valid[w][addr_idx_next4][addr_offset_n2];
    end
  endgenerate

  always_comb begin
    hit_n1_way_sel = '0;
    for (int w = int'(L1I_N_WAYS) - 1; w >= 0; w--) if (way_hit_n1[w]) hit_n1_way_sel = L1iWayW'(w);
    hit_n2_way_sel = '0;
    for (int w = int'(L1I_N_WAYS) - 1; w >= 0; w--) if (way_hit_n2[w]) hit_n2_way_sel = L1iWayW'(w);
  end

  assign hit_n1 = |way_hit_n1;
  assign hit_n2 = |way_hit_n2;
  assign l1i_word_n1 = data_bank_rdata[hit_n1_way_sel][addr_offset_n1];
  assign l1i_word_n2 = data_bank_rdata[hit_n2_way_sel][addr_offset_n2];
  assign sram_n1_ready = addr_valid_r && data_bank_rvalid_d1[hit_n1_way_sel][addr_offset_n1]
                       && (data_bank_raddr_d1[hit_n1_way_sel][addr_offset_n1] == addr_idx_next4);
  assign sram_n2_ready = addr_valid_r && data_bank_rvalid_d1[hit_n2_way_sel][addr_offset_n2]
                       && (data_bank_raddr_d1[hit_n2_way_sel][addr_offset_n2] == addr_idx_next4);
  // The existing extra tag/data mirror is addressed by pc+4. At the one
  // boundary where pc+6 enters a new line, defer the pair until a future
  // third-tag-mirror implementation can prove that line's hit and data.
  assign n2_same_line_as_next4 = pc_ifu_next4[XLEN-1:L1I_LINE_LEN+2]
                              == pc_ifu_next6[XLEN-1:L1I_LINE_LEN+2];

  assign ifu_l1i.inst_n1 = pc_ifu[1] ? l1i_word_next : l1i_word_n1;

  // PMP execute-permission must also gate the dual-issue second instruction.
  // Slot B's first halfword always lives at pc_ifu+4 (sourced from inst_n1).
  // Without this gate, a legal inst_a at pc_ifu followed by a no-X inst_b at
  // pc_ifu+4 (e.g. falling through from jalr->addr-4 into a no-X NA4/TOR
  // region) would let the forbidden fetch execute, because pmp_fetch_fault
  // only covers pc_ifu and pc_ifu+2.  Suppressing inst_n1_valid forces the
  // offending instruction to be re-fetched as the primary fetch next cycle,
  // where the existing TRAP machinery raises a precise instruction-access
  // fault.
  logic pmp_n1_fetch_fault;
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_fetch_n1 (
      .addr          (pc_ifu + XLEN'(4)),
      .size_m1       (4'd1),
      .priv          (csr_bcast.priv),
      .op_r          (1'b0),
      .op_w          (1'b0),
      .op_x          (1'b1),
      .pmp_raw_addr  (pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r     (pmp_state.pmp_cfg_r),
      .pmp_cfg_w     (pmp_state.pmp_cfg_w),
      .pmp_cfg_x     (pmp_state.pmp_cfg_x),
      .pmp_cfg_l     (pmp_state.pmp_cfg_l),
      .pmp_mode_off  (pmp_state.pmp_mode_off),
      .pmp_mode_tor  (pmp_state.pmp_mode_tor),
      .pmp_mode_na4  (pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault         (pmp_n1_fetch_fault),
      .fault_lo_o    ()
  );

  // For an unaligned R32+R32 pair, slot B also consumes the halfword at
  // pc+6. Gate the third-word lookahead with an execute-permission check.
  logic pmp_n2_fetch_fault;
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_fetch_n2 (
      .addr          (pc_ifu + XLEN'(6)),
      .size_m1       (4'd1),
      .priv          (csr_bcast.priv),
      .op_r          (1'b0),
      .op_w          (1'b0),
      .op_x          (1'b1),
      .pmp_raw_addr  (pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r     (pmp_state.pmp_cfg_r),
      .pmp_cfg_w     (pmp_state.pmp_cfg_w),
      .pmp_cfg_x     (pmp_state.pmp_cfg_x),
      .pmp_cfg_l     (pmp_state.pmp_cfg_l),
      .pmp_mode_off  (pmp_state.pmp_mode_off),
      .pmp_mode_tor  (pmp_state.pmp_mode_tor),
      .pmp_mode_na4  (pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault         (pmp_n2_fetch_fault),
      .fault_lo_o    ()
  );

  assign ifu_l1i.inst_n1_valid = !pmp_n1_fetch_fault
    && (pc_ifu[1]
      ? (hit_next && data_bank_rvalid_d1[hit_next_way_sel][addr_offset_next]
         && (data_bank_raddr_d1[hit_next_way_sel][addr_offset_next] == addr_idx_next))
      : (hit_n1 && sram_n1_ready));
  assign ifu_l1i.inst_n2 = l1i_word_n2;
  assign ifu_l1i.inst_n2_valid = !pmp_n2_fetch_fault && n2_same_line_as_next4
                               && hit_n2 && sram_n2_ready;
`endif

  // PTW request: TLB miss in IDLE when MMU enabled and address is nonzero
  assign ptw_req = (l1i_state == IDLE) && mmu_en && !tlb_hit
      && !invalid_l1i && !wait_invalid
      && !cmu_bcast.flush_pipe && !cmu_bcast.flush_redirect
      && !ptw_busy
      && (ifu_l1i.pc != 0);

    // Check the complete instruction with one PMP instance. Before SRAM data is
    // ready, conservatively check four bytes; once decoded, compressed
    // instructions narrow the checked range to two bytes.
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_fetch (
      .addr          (pc_ifu),
      .size_m1       ((sram_data_ready && is_c) ? 4'd1 : 4'd3),
      .priv          (csr_bcast.priv),
      .op_r          (1'b0),
      .op_w          (1'b0),
      .op_x          (1'b1),
      .pmp_raw_addr  (pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r     (pmp_state.pmp_cfg_r),
      .pmp_cfg_w     (pmp_state.pmp_cfg_w),
      .pmp_cfg_x     (pmp_state.pmp_cfg_x),
      .pmp_cfg_l     (pmp_state.pmp_cfg_l),
      .pmp_mode_off  (pmp_state.pmp_mode_off),
      .pmp_mode_tor  (pmp_state.pmp_mode_tor),
      .pmp_mode_na4  (pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault         (pmp_fetch_pmp_fault),
      .fault_lo_o    (pmp_fetch_fault_lo)
  );
  // Also treat fetches from unmapped physical addresses as access faults
  // (matches bus-error semantics required by sail / arch-test PMP tests).
  logic fetch_unmapped_fault;
  assign fetch_unmapped_fault = !rapt_pkg::addr_mapped(pc_ifu);
  assign pmp_fetch_fault = pmp_fetch_pmp_fault || fetch_unmapped_fault;


  always_ff @(posedge clock) begin
    if (reset) begin
      l1i_state <= IDLE;
      ifq_head  <= 0;
      ifq_valid <= 0;
      for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
        for (int i = 0; i < int'(L1iSize); i++) l1i_valid[w][i] <= '0;
      end
      replace_bit <= 0;
      fill_way_r <= 0;
      l1i_fill_issue_idx <= '0;
      ifq_tail <= 0;
      wait_invalid <= 1'b0;
    end else begin

      unique case (l1i_state)
        IDLE: begin
          if (!invalid_l1i && !wait_invalid
              && !cmu_bcast.flush_pipe && !cmu_bcast.flush_redirect) begin
            if (mmu_en) begin
              if (tlb_hit) begin
                if (pf_fetch_tlb) begin
                  rec_addr <= ifu_l1i.pc;
                  rec_tval <= ifu_l1i.pc;
                  cause <= `RAPT_CAUSE_INSTR_PAGE_FAULT;
                  l1i_state <= TRAP;
                end else if (pmp_fetch_fault) begin
                  rec_addr <= ifu_l1i.pc;
                  rec_tval <= (pmp_fetch_fault_lo || fetch_unmapped_fault)
                    ? ifu_l1i.pc : (ifu_l1i.pc + XLEN'(2));
                  cause <= `RAPT_CAUSE_INSTR_ACC_FAULT;
                  l1i_state <= TRAP;
                end else begin
                  rec_addr <= ifu_l1i.pc;
                  if (sram_data_ready) begin
                    if (!hit) begin
                      l1i_addr  <= pc_ifu;
                      l1i_state <= RD_A;
                    end else if (!hit_next) begin
                      l1i_addr   <= pc_ifu_next;
                      l1i_fill_issue_idx <= '0;
                      l1i_state  <= RD_0;
                      fill_way_r <= fill_way_next_calc;
                    end
                  end
                end
              end else begin
                if (ifu_l1i.pc == 0) begin
                  rec_addr <= 0;
                  rec_tval <= 0;
                  cause <= `RAPT_CAUSE_INSTR_ACC_FAULT;
                  l1i_state <= TRAP;
                end else if (!ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1i_addr  <= ifu_l1i.pc;
                  rec_addr  <= ifu_l1i.pc;
                  l1i_state <= PTWAIT;
                end
              end
            end else begin
              if (pmp_fetch_fault) begin
                rec_addr <= ifu_l1i.pc;
                rec_tval <= (pmp_fetch_fault_lo || fetch_unmapped_fault)
                  ? ifu_l1i.pc : (ifu_l1i.pc + XLEN'(2));
                cause <= `RAPT_CAUSE_INSTR_ACC_FAULT;
                l1i_state <= TRAP;
              end else begin
                rec_addr <= ifu_l1i.pc;
                if (sram_data_ready) begin
                  if (!hit) begin
                    l1i_addr   <= pc_ifu;
                      l1i_fill_issue_idx <= '0;
                    l1i_state  <= RD_0;
                    fill_way_r <= fill_way_calc;
                  end else if (!hit_next) begin
                    l1i_addr   <= pc_ifu_next;
                      l1i_fill_issue_idx <= '0;
                    l1i_state  <= RD_0;
                    fill_way_r <= fill_way_next_calc;
                  end
                end
              end
            end
          end
        end
        PTWAIT: begin
          if (cmu_bcast.flush_pipe) begin
            l1i_state <= IDLE;
          end else if (ptw_arvalid && pmp_iptw_fault) begin
            cause <= `RAPT_CAUSE_INSTR_ACC_FAULT;
            rec_tval <= ifu_l1i.pc;
            l1i_state <= TRAP;
          end else if (ptw_done) begin
            if (pf_fetch_ptw) begin
              cause <= `RAPT_CAUSE_INSTR_PAGE_FAULT;
              rec_tval <= ifu_l1i.pc;
              l1i_state <= TRAP;
            end else begin
              // PTW completed: TLB filled by u_itlb, compute physical address
              l1i_addr  <= XLEN'({ptw_result_ptag, tlb_offset});
              l1i_state <= RD_A;
            end
          end else if (ptw_fault) begin
            cause <= `RAPT_CAUSE_INSTR_PAGE_FAULT;
            rec_tval <= ifu_l1i.pc;
            l1i_state <= TRAP;
          end
        end
        TRAP: begin
          l1i_state <= IDLE;
        end
        RD_A: begin
          // Guard: abort if pipeline flush or TLB invalidated (sfence.vma /
          // satp switch): pc_ifu depends on itlb_ptag which is 0 on TLB miss,
          // producing a garbage physical address (e.g. 0x68a).
          if (cmu_bcast.flush_pipe || (mmu_en && !tlb_hit)) begin
            l1i_state <= IDLE;
          end else if (pmp_fetch_fault) begin
            // Post-PTW PMP check: page was translated but target PA is outside
            // any permitted PMP region for the current privilege level.
            rec_addr <= ifu_l1i.pc;
            rec_tval <= (pmp_fetch_fault_lo || fetch_unmapped_fault)
              ? ifu_l1i.pc : (ifu_l1i.pc + XLEN'(2));
            cause <= `RAPT_CAUSE_INSTR_ACC_FAULT;
            l1i_state <= TRAP;
          end else if (sram_data_ready) begin
            if (!hit) begin
              l1i_addr   <= pc_ifu;
              l1i_fill_issue_idx <= '0;
              l1i_state  <= RD_0;
              fill_way_r <= fill_way_calc;
            end else if (!hit_next) begin
              l1i_addr   <= pc_ifu_next;
              l1i_fill_issue_idx <= '0;
              l1i_state  <= RD_0;
              fill_way_r <= fill_way_next_calc;
            end else begin
              l1i_state <= IDLE;
            end
          end
        end
        RD_0: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
          end else if (cache_ar_accept) begin
            // Bus error on the first beat -> fetch access-fault. Gated on the
            // same handshake condition that consumes the beat, so a glitchy /
            // stale `rerr` in any other cycle is ignored.
            if (l1i_bus.rerr) begin
              rec_tval  <= rec_addr;
              cause     <= `RAPT_CAUSE_INSTR_ACC_FAULT;
              l1i_state <= TRAP;
            end else begin
              ifq_head <= ifq_head + 1;
              if (ifu_sdram_arburst || (RefillWords == 2)) begin
                l1i_state <= RD_1;
              end else if (l1i_fill_issue_idx == RefillIdxW'(RefillWords - 1)) begin
                l1i_state <= FINA;
              end else begin
                l1i_fill_issue_idx <= l1i_fill_issue_idx + 1'b1;
              end
            end
          end
        end
        RD_1: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
          end else if (ifu_sdram_arburst || cache_ar_accept) begin
            // Same handshake-gated bus-error check as RD_0. For the burst
            // path (`ifu_sdram_arburst`), the second beat is implicit and
            // any bus error would have been latched on beat 1 in RD_0.
            if (cache_ar_accept && l1i_bus.rerr) begin
              rec_tval  <= rec_addr;
              cause     <= `RAPT_CAUSE_INSTR_ACC_FAULT;
              l1i_state <= TRAP;
            end else begin
              l1i_state <= FINA;

              ifq_head <= ifq_head + 1;
            end
          end
        end
        FINA: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
          end else if (ifq_valid == 0) begin
            l1i_state <= IDLE;
          end
        end
        default begin
          l1i_state <= IDLE;
        end
      endcase
    end

    if (invalid_l1i || wait_invalid) begin
      if (l1i_state == IDLE) begin
        for (int w = 0; w < int'(L1I_N_WAYS); w++) begin
          for (int i = 0; i < int'(L1iSize); i++) l1i_valid[w][i] <= '0;
        end
        wait_invalid <= 0;
      end else begin
        wait_invalid <= 1;
      end
    end
    // Cache line arrival (tag fill handled by SRAM wen).
    if (l1i_fill_en) begin
      l1i_valid[fill_way_r][idx_fetch] <= fill_tag_match[fill_way_r]
        ? (l1i_valid[fill_way_r][idx_fetch] | fill_word_mask)
        : fill_word_mask;
      if (ifq_valid[0] == 0 && L1I_N_WAYS == 2) begin
        replace_bit[idx_fetch] <= ~replace_bit[idx_fetch];
      end
      ifq_tail <= ifq_tail + 1;
    end

    // One static write cone per IFQ entry. A returning response consumes an
    // aliased entry before a same-cycle request can reuse it.
    for (int i = 0; i < int'(IFQ_SIZE); i++) begin
      if (l1i_fill_en && i == int'(ifq_tail)) begin
        ifq_valid[i] <= 1'b0;
      end else if (ifq_clear_en) begin
        ifq_valid[i] <= 1'b0;
      end else if (ifq_push_en && i == int'(ifq_head)) begin
        ifq_valid[i] <= 1'b1;
      end

      if (ifq_push_en && i == int'(ifq_head)) begin
        ifq_raddr[i] <= l1i_bus.araddr;
      end
    end
  end

  // Attribute the same pre-edge L1I conditions observed by IFU. The four
  // causes below are mutually exclusive when the cache is in IDLE; refill is
  // kept separate because it spans the multi-cycle miss/PTW FSM.
  always_ff @(posedge clock) begin
    if (reset) begin
      pmu_l1i_refill_active <= 1'b0;
      pmu_l1i_sram_warmup <= 1'b0;
      pmu_l1i_tag_miss <= 1'b0;
      pmu_l1i_nextword_miss <= 1'b0;
      pmu_l1i_refill_start_line_miss <= 1'b0;
      pmu_l1i_refill_start_current_hole <= 1'b0;
      pmu_l1i_refill_start_next_line_miss <= 1'b0;
      pmu_l1i_refill_start_next_hole <= 1'b0;
    end else begin
      pmu_l1i_refill_active <= (l1i_state == RD_A) || (l1i_state == RD_0)
                            || (l1i_state == RD_1) || (l1i_state == FINA)
                            || (l1i_state == PTWAIT);
      pmu_l1i_sram_warmup <= (l1i_state == IDLE) && fetch_addr_valid
                           && !invalid_l1i && !wait_invalid
                           && (!mmu_en || tlb_hit) && !pmp_fetch_fault
                           && hit && (hit_next || is_c) && !sram_data_ready;
      pmu_l1i_tag_miss <= (l1i_state == IDLE) && fetch_addr_valid
                        && !invalid_l1i && !wait_invalid
                        && (!mmu_en || tlb_hit) && !pmp_fetch_fault
                        && sram_data_ready && !hit;
      pmu_l1i_nextword_miss <= (l1i_state == IDLE) && fetch_addr_valid
                             && !invalid_l1i && !wait_invalid
                             && (!mmu_en || tlb_hit) && !pmp_fetch_fault
                             && sram_data_ready && hit && !is_c && !hit_next;
      // These are the exact two conditions that send the IDLE FSM to RD_0.
      // Split them by whether a matching line tag already exists: a matching
      // tag with an invalid word is a partial-fill sector hole; no matching
      // tag is a cold/conflict line miss.
      pmu_l1i_refill_start_line_miss <= (l1i_state == IDLE) && fetch_addr_valid
                  && !invalid_l1i && !wait_invalid
                  && !cmu_bcast.flush_pipe
                  && (!mmu_en || tlb_hit) && !pmp_fetch_fault
                  && sram_data_ready && !hit && !(|way_tag_match);
      pmu_l1i_refill_start_current_hole <= (l1i_state == IDLE) && fetch_addr_valid
                     && !invalid_l1i && !wait_invalid
                     && !cmu_bcast.flush_pipe
                     && (!mmu_en || tlb_hit) && !pmp_fetch_fault
                     && sram_data_ready && !hit && (|way_tag_match);
      pmu_l1i_refill_start_next_line_miss <= (l1i_state == IDLE) && fetch_addr_valid
                   && !invalid_l1i && !wait_invalid
                   && !cmu_bcast.flush_pipe
                   && (!mmu_en || tlb_hit) && !pmp_fetch_fault
                   && sram_data_ready && hit && !is_c && !hit_next
                   && !(|way_tag_match_next);
      pmu_l1i_refill_start_next_hole <= (l1i_state == IDLE) && fetch_addr_valid
                  && !invalid_l1i && !wait_invalid
                  && !cmu_bcast.flush_pipe
                  && (!mmu_en || tlb_hit) && !pmp_fetch_fault
                  && sram_data_ready && hit && !is_c && !hit_next
                  && (|way_tag_match_next);
    end
  end

  `RAPT_SVA_IMPLY(clock, reset, L1I_REDIRECT_BLOCKS_PTW_REQUEST,
      cmu_bcast.flush_redirect, !ptw_req)

endmodule
/* verilator lint_on PINCONNECTEMPTY */
