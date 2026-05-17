`include "rapt.svh"
`include "rapt_bpu_dirp_if.svh"

// TAGE direction predictor: bimodal base + 3 tagged tables with geometric
// history lengths. Replaces the gshare PHT for branch direction prediction.
//
// Reference: ChampSim/gem5-style TAGE (Seznec & Michaud, JILP 2006) scaled
// down to the default config budget (~6 kbit). Parameters are loosely
// aligned with `nsim/gsim/dse-config.json` branch_predictor.tage section,
// scaled down from gem5's reference (5 tables, 9/8/8/8/8 log sizes).
//
// Entry per tagged table: { tag, ctr (signed 3-bit), u (1-bit) }.
// Provider = longest-history tagged table whose tag matches; else bimodal.
// Allocation: on mispredict, allocate an entry in a longer-history table
// with u==0 starting from the next-longer table; if none available within
// the search window, decrement u of all candidates (graceful aging).
//
// Folded history: combinationally XOR the GHR into IDX_LEN / TAG_LEN bits.
// For a 64-bit GHR this collapses to <=6 levels of XOR, which fits in the
// existing single-cycle prediction window.
(* keep_hierarchy *)
module rapt_bpu_tage #(
    parameter int XLEN    = `RAPT_XLEN,
    parameter int GHR_LEN = 64,
    parameter int PHR_LEN = 8,
    // DEPTH: unified DIRP knob (bimodal/gshare PHT size). TAGE ignores it
    // and sizes its own bimodal base via BIM_LEN; declared so all DIRP
    // flavors share a single instantiation signature in rapt_bpu.sv.
    /* verilator lint_off UNUSEDPARAM */
    parameter int DEPTH   = `RAPT_PHT_SIZE,
    /* verilator lint_on UNUSEDPARAM */
    parameter int BIM_LEN = 8,
    parameter int IDX_LEN = 7
) (
    `RAPT_BPU_DIRP_PORTS
);
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */
  // Synchronous prediction read: address+GHR registered on `ren`; output
  // valid on the next cycle, combinational on the registered state.
  // Commit-time update (one branch per cycle).
  // ---------------- Parameters ----------------
  localparam int BimSize = 1 << BIM_LEN;  // 256
  localparam int TabSize = 1 << IDX_LEN;  // 128

  // Tagged tables: tag widths and history lengths (geometric)
  localparam int TagLen1 = 7;
  localparam int TagLen2 = 7;
  localparam int TagLen3 = 8;
  localparam int Hist1 = 8;
  localparam int Hist2 = 16;
  localparam int Hist3 = 64;

  // Signed 3-bit direction counter: range [-4, 3], taken iff ctr >= 0.
  localparam int CtrBits = 3;
  localparam logic signed [CtrBits-1:0] CtrMax = 3'sd3;
  localparam logic signed [CtrBits-1:0] CtrMin = -3'sd4;
  localparam logic signed [CtrBits-1:0] CtrInitT = 3'sd0;  // weakly taken
  localparam logic signed [CtrBits-1:0] CtrInitN = -3'sd1;  // weakly not-taken

  // u-bit graceful aging period. Aligned with gem5's log_u_reset_period=12
  // (clear u every 2^12=4096 update events). With 1-bit u, "alternating MSB/
  // LSB reset" degenerates to a periodic full-clear.
  localparam int UResetLog = 12;

  // use_alt_on_na: when the longest matching tagged-table provider has a
  // weakly-correct counter (|ctr| <= WEAK_THR), fall back to the alt-pred
  // (next-shorter tagged hit, else bimodal). UseAltBits is a signed
  // confidence counter; positive means "trust alt over provider for weak".
  localparam int UseAltBits = 4;
  localparam logic signed [UseAltBits-1:0] UseAltMax = 4'sd7;
  localparam logic signed [UseAltBits-1:0] UseAltMin = -4'sd8;

  // ---------------- Storage ----------------
  // Bimodal base (2-bit saturating counter; MSB = taken)
  logic        [        1:0] bim     [BimSize];

  // Tagged table 1
  logic        [TagLen1-1:0] t1_tag  [TabSize];
  logic signed [CtrBits-1:0] t1_ctr  [TabSize];
  logic                      t1_u    [TabSize];
  logic                      t1_valid[TabSize];

  // Tagged table 2
  logic        [TagLen2-1:0] t2_tag  [TabSize];
  logic signed [CtrBits-1:0] t2_ctr  [TabSize];
  logic                      t2_u    [TabSize];
  logic                      t2_valid[TabSize];

  // Tagged table 3
  logic        [TagLen3-1:0] t3_tag  [TabSize];
  logic signed [CtrBits-1:0] t3_ctr  [TabSize];
  logic                      t3_u    [TabSize];
  logic                      t3_valid[TabSize];

  // ---------------- Folded-history helpers ----------------
  // Combinationally fold the low `HIST` bits of `ghr` into `W` bits via XOR.
  // Yosys/Verilator unroll cleanly for fixed parameters.
  function automatic logic [6:0] fold_h1_idx(input logic [GHR_LEN-1:0] g);
    logic [6:0] r;
    r = '0;
    for (int i = 0; i < Hist1; i++) r[i%IDX_LEN] = r[i%IDX_LEN] ^ g[i];
    return r;
  endfunction
  function automatic logic [TagLen1-1:0] fold_h1_tag(input logic [GHR_LEN-1:0] g);
    logic [TagLen1-1:0] r;
    r = '0;
    for (int i = 0; i < Hist1; i++) r[i%TagLen1] = r[i%TagLen1] ^ g[i];
    return r;
  endfunction
  function automatic logic [6:0] fold_h2_idx(input logic [GHR_LEN-1:0] g);
    logic [6:0] r;
    r = '0;
    for (int i = 0; i < Hist2; i++) r[i%IDX_LEN] = r[i%IDX_LEN] ^ g[i];
    return r;
  endfunction
  function automatic logic [TagLen2-1:0] fold_h2_tag(input logic [GHR_LEN-1:0] g);
    logic [TagLen2-1:0] r;
    r = '0;
    for (int i = 0; i < Hist2; i++) r[i%TagLen2] = r[i%TagLen2] ^ g[i];
    return r;
  endfunction
  function automatic logic [6:0] fold_h3_idx(input logic [GHR_LEN-1:0] g);
    logic [6:0] r;
    r = '0;
    for (int i = 0; i < Hist3; i++) r[i%IDX_LEN] = r[i%IDX_LEN] ^ g[i];
    return r;
  endfunction
  function automatic logic [TagLen3-1:0] fold_h3_tag(input logic [GHR_LEN-1:0] g);
    logic [TagLen3-1:0] r;
    r = '0;
    for (int i = 0; i < Hist3; i++) r[i%TagLen3] = r[i%TagLen3] ^ g[i];
    return r;
  endfunction

  // Path-history fold: XOR the PHR bits into a width-W vector. Cheap (<= 8
  // XOR levels). Mixed into both idx and tag of every tagged table.
  function automatic logic [IDX_LEN-1:0] fold_phr_idx(input logic [PHR_LEN-1:0] p);
    logic [IDX_LEN-1:0] r;
    r = '0;
    for (int i = 0; i < PHR_LEN; i++) r[i%IDX_LEN] = r[i%IDX_LEN] ^ p[i];
    return r;
  endfunction
  function automatic logic [TagLen1-1:0] fold_phr_t1_tag(input logic [PHR_LEN-1:0] p);
    logic [TagLen1-1:0] r;
    r = '0;
    for (int i = 0; i < PHR_LEN; i++) r[i%TagLen1] = r[i%TagLen1] ^ p[i];
    return r;
  endfunction
  function automatic logic [TagLen2-1:0] fold_phr_t2_tag(input logic [PHR_LEN-1:0] p);
    logic [TagLen2-1:0] r;
    r = '0;
    for (int i = 0; i < PHR_LEN; i++) r[i%TagLen2] = r[i%TagLen2] ^ p[i];
    return r;
  endfunction
  function automatic logic [TagLen3-1:0] fold_phr_t3_tag(input logic [PHR_LEN-1:0] p);
    logic [TagLen3-1:0] r;
    r = '0;
    for (int i = 0; i < PHR_LEN; i++) r[i%TagLen3] = r[i%TagLen3] ^ p[i];
    return r;
  endfunction

  // ---------------- Index/Tag derivation ----------------
  // PC-only base index for bimodal
  function automatic logic [BIM_LEN-1:0] bim_idx(input logic [XLEN-1:0] pc);
    return pc[BIM_LEN-1+1:1];
  endfunction
  // Tagged: idx = PC_low(IDX_LEN) XOR folded_ghr XOR folded_phr
  function automatic logic [IDX_LEN-1:0] t1_idx(
      input logic [XLEN-1:0] pc, input logic [GHR_LEN-1:0] g, input logic [PHR_LEN-1:0] p);
    return pc[IDX_LEN-1+1:1] ^ fold_h1_idx(g) ^ fold_phr_idx(p);
  endfunction
  function automatic logic [TagLen1-1:0] t1_tag_of(
      input logic [XLEN-1:0] pc, input logic [GHR_LEN-1:0] g, input logic [PHR_LEN-1:0] p);
    return pc[IDX_LEN+TagLen1:IDX_LEN+1] ^ fold_h1_tag(g) ^ fold_phr_t1_tag(p);
  endfunction
  function automatic logic [IDX_LEN-1:0] t2_idx(
      input logic [XLEN-1:0] pc, input logic [GHR_LEN-1:0] g, input logic [PHR_LEN-1:0] p);
    return pc[IDX_LEN-1+1:1] ^ fold_h2_idx(g) ^ fold_phr_idx(p);
  endfunction
  function automatic logic [TagLen2-1:0] t2_tag_of(
      input logic [XLEN-1:0] pc, input logic [GHR_LEN-1:0] g, input logic [PHR_LEN-1:0] p);
    return pc[IDX_LEN+TagLen2:IDX_LEN+1] ^ fold_h2_tag(g) ^ fold_phr_t2_tag(p);
  endfunction
  function automatic logic [IDX_LEN-1:0] t3_idx(
      input logic [XLEN-1:0] pc, input logic [GHR_LEN-1:0] g, input logic [PHR_LEN-1:0] p);
    return pc[IDX_LEN-1+1:1] ^ fold_h3_idx(g) ^ fold_phr_idx(p);
  endfunction
  function automatic logic [TagLen3-1:0] t3_tag_of(
      input logic [XLEN-1:0] pc, input logic [GHR_LEN-1:0] g, input logic [PHR_LEN-1:0] p);
    return pc[IDX_LEN+TagLen3:IDX_LEN+1] ^ fold_h3_tag(g) ^ fold_phr_t3_tag(p);
  endfunction

  // ---------------- Read path (synchronous) ----------------
  // Register raddr / r_ghr / r_phr on `ren`, then read combinationally next
  // cycle.
  logic [   XLEN-1:0] r_pc_q;
  logic [GHR_LEN-1:0] r_ghr_q;
  logic [PHR_LEN-1:0] r_phr_q;

  always_ff @(posedge clock) begin
    if (reset || init) begin
      r_pc_q  <= '0;
      r_ghr_q <= '0;
      r_phr_q <= '0;
    end else if (ren) begin
      r_pc_q  <= raddr;
      r_ghr_q <= r_ghr;
      r_phr_q <= r_phr;
    end
  end

  // Combinational prediction from registered state
  logic [BIM_LEN-1:0] rd_bim_idx;
  logic [IDX_LEN-1:0] rd_t1_idx, rd_t2_idx, rd_t3_idx;
  logic [TagLen1-1:0] rd_t1_tag;
  logic [TagLen2-1:0] rd_t2_tag;
  logic [TagLen3-1:0] rd_t3_tag;
  logic hit1, hit2, hit3;
  logic bim_taken, t1_taken, t2_taken, t3_taken;

  assign rd_bim_idx = bim_idx(r_pc_q);
  assign rd_t1_idx = t1_idx(r_pc_q, r_ghr_q, r_phr_q);
  assign rd_t2_idx = t2_idx(r_pc_q, r_ghr_q, r_phr_q);
  assign rd_t3_idx = t3_idx(r_pc_q, r_ghr_q, r_phr_q);
  assign rd_t1_tag = t1_tag_of(r_pc_q, r_ghr_q, r_phr_q);
  assign rd_t2_tag = t2_tag_of(r_pc_q, r_ghr_q, r_phr_q);
  assign rd_t3_tag = t3_tag_of(r_pc_q, r_ghr_q, r_phr_q);

  assign hit1 = t1_valid[rd_t1_idx] && (t1_tag[rd_t1_idx] == rd_t1_tag);
  assign hit2 = t2_valid[rd_t2_idx] && (t2_tag[rd_t2_idx] == rd_t2_tag);
  assign hit3 = t3_valid[rd_t3_idx] && (t3_tag[rd_t3_idx] == rd_t3_tag);

  assign bim_taken = bim[rd_bim_idx][1];
  assign t1_taken = ~t1_ctr[rd_t1_idx][CtrBits-1];  // sign bit 0 => >=0 => taken
  assign t2_taken = ~t2_ctr[rd_t2_idx][CtrBits-1];
  assign t3_taken = ~t3_ctr[rd_t3_idx][CtrBits-1];

  // Provider = longest matching table; else bimodal.
  // use_alt_on_na: when provider ctr is weakly correct (|ctr| <= 1, i.e. ctr
  // is 0 or -1 with 3-bit signed encoding) and the global confidence counter
  // says alt has historically been better, return alt-pred.
  logic                         provider_weak;
  logic                         provider_pred;
  logic                         alt_pred;
  logic signed [   CtrBits-1:0] prov_ctr;
  logic signed [UseAltBits-1:0] use_alt_ctr;

  always_comb begin : provider_select
    if (hit3) begin
      prov_ctr      = t3_ctr[rd_t3_idx];
      provider_pred = t3_taken;
      alt_pred      = hit2 ? t2_taken : hit1 ? t1_taken : bim_taken;
    end else if (hit2) begin
      prov_ctr      = t2_ctr[rd_t2_idx];
      provider_pred = t2_taken;
      alt_pred      = hit1 ? t1_taken : bim_taken;
    end else if (hit1) begin
      prov_ctr      = t1_ctr[rd_t1_idx];
      provider_pred = t1_taken;
      alt_pred      = bim_taken;
    end else begin
      prov_ctr      = '0;
      provider_pred = bim_taken;
      alt_pred      = bim_taken;
    end
  end
  // "Weak" = ctr in {-1, 0}. With CtrBits=3 signed, those are the two
  // values closest to the decision boundary (sign bit flip).
  assign provider_weak = (prov_ctr == 3'sd0) || (prov_ctr == -3'sd1);

  wire any_tagged_hit = hit1 || hit2 || hit3;
  assign rd_taken = (any_tagged_hit && provider_weak && (use_alt_ctr >= 0))
                  ? alt_pred : provider_pred;

  // ---------------- Update path (commit) ----------------
  logic [BIM_LEN-1:0] up_bim_idx;
  logic [IDX_LEN-1:0] up_t1_idx, up_t2_idx, up_t3_idx;
  logic [TagLen1-1:0] up_t1_tag;
  logic [TagLen2-1:0] up_t2_tag;
  logic [TagLen3-1:0] up_t3_tag;
  logic up_hit1, up_hit2, up_hit3;
  logic [1:0] up_provider;  // 0=bim, 1=t1, 2=t2, 3=t3 (provider rank)

  assign up_bim_idx = bim_idx(update_pc);
  assign up_t1_idx = t1_idx(update_pc, update_ghr, update_phr);
  assign up_t2_idx = t2_idx(update_pc, update_ghr, update_phr);
  assign up_t3_idx = t3_idx(update_pc, update_ghr, update_phr);
  assign up_t1_tag = t1_tag_of(update_pc, update_ghr, update_phr);
  assign up_t2_tag = t2_tag_of(update_pc, update_ghr, update_phr);
  assign up_t3_tag = t3_tag_of(update_pc, update_ghr, update_phr);

  assign up_hit1 = t1_valid[up_t1_idx] && (t1_tag[up_t1_idx] == up_t1_tag);
  assign up_hit2 = t2_valid[up_t2_idx] && (t2_tag[up_t2_idx] == up_t2_tag);
  assign up_hit3 = t3_valid[up_t3_idx] && (t3_tag[up_t3_idx] == up_t3_tag);

  assign up_provider = up_hit3 ? 2'd3 : up_hit2 ? 2'd2 : up_hit1 ? 2'd1 : 2'd0;

  // Provider / alt predictions at update side (re-derived; latency-free since
  // it's just XOR + array read with the registered commit signals).
  logic                      up_provider_taken;
  logic                      up_alt_taken;
  logic signed [CtrBits-1:0] up_prov_ctr;
  logic                      up_provider_weak;
  always_comb begin : up_provider_select
    if (up_hit3) begin
      up_prov_ctr = t3_ctr[up_t3_idx];
      up_provider_taken = ~t3_ctr[up_t3_idx][CtrBits-1];
      up_alt_taken      = up_hit2 ? ~t2_ctr[up_t2_idx][CtrBits-1]
                        : up_hit1 ? ~t1_ctr[up_t1_idx][CtrBits-1]
                                  : bim[up_bim_idx][1];
    end else if (up_hit2) begin
      up_prov_ctr       = t2_ctr[up_t2_idx];
      up_provider_taken = ~t2_ctr[up_t2_idx][CtrBits-1];
      up_alt_taken      = up_hit1 ? ~t1_ctr[up_t1_idx][CtrBits-1] : bim[up_bim_idx][1];
    end else if (up_hit1) begin
      up_prov_ctr       = t1_ctr[up_t1_idx];
      up_provider_taken = ~t1_ctr[up_t1_idx][CtrBits-1];
      up_alt_taken      = bim[up_bim_idx][1];
    end else begin
      up_prov_ctr       = '0;
      up_provider_taken = bim[up_bim_idx][1];
      up_alt_taken      = bim[up_bim_idx][1];
    end
  end
  assign up_provider_weak = (up_prov_ctr == 3'sd0) || (up_prov_ctr == -3'sd1);

  // u-bit aging counter (graceful aging fires periodically AND when allocation
  // fails). Use the unused low bits as a free-running counter.
  logic [UResetLog:0] u_age_cnt;
  logic               u_clear_pulse;
  assign u_clear_pulse = u_age_cnt[UResetLog];

  // Saturating update helper for signed counters
  function automatic logic signed [CtrBits-1:0] ctr_update(input logic signed [CtrBits-1:0] c,
                                                           input logic taken);
    if (taken) return (c == CtrMax) ? CtrMax : c + 1;
    else return (c == CtrMin) ? CtrMin : c - 1;
  endfunction

  // Bimodal saturating counter
  function automatic logic [1:0] bim_update(input logic [1:0] c, input logic taken);
    if (taken) return (c == 2'b11) ? 2'b11 : c + 1;
    else return (c == 2'b00) ? 2'b00 : c - 1;
  endfunction

  // Allocation candidates: tables with rank > provider that have u==0.
  // Try smallest-rank candidate first (a common simplification of TAGE
  // policy: ideally random, but smallest-rank works well empirically).
  logic alloc_t1_ok, alloc_t2_ok, alloc_t3_ok;
  logic do_alloc;
  assign alloc_t1_ok = (up_provider < 2'd1) && (t1_u[up_t1_idx] == 1'b0);
  assign alloc_t2_ok = (up_provider < 2'd2) && (t2_u[up_t2_idx] == 1'b0);
  assign alloc_t3_ok = (up_provider < 2'd3) && (t3_u[up_t3_idx] == 1'b0);
  assign do_alloc    = update_en && update_mispred;

  // ---------------- Sequential writes ----------------
  always_ff @(posedge clock) begin
    if (reset || init) begin
      for (int i = 0; i < BimSize; i++) bim[i] <= 2'b01;
      for (int i = 0; i < TabSize; i++) begin
        t1_tag[i]   <= '0;
        t1_ctr[i]   <= '0;
        t1_u[i]     <= 1'b0;
        t1_valid[i] <= 1'b0;
        t2_tag[i]   <= '0;
        t2_ctr[i]   <= '0;
        t2_u[i]     <= 1'b0;
        t2_valid[i] <= 1'b0;
        t3_tag[i]   <= '0;
        t3_ctr[i]   <= '0;
        t3_u[i]     <= 1'b0;
        t3_valid[i] <= 1'b0;
      end
      u_age_cnt   <= '0;
      use_alt_ctr <= '0;
    end else begin
      if (update_en) begin
        // Aging counter ticks per update event (not per clock), matching
        // gem5's "every 2^log_u_reset_period updates" semantics.
        u_age_cnt <= u_age_cnt + 1'b1;
        if (u_clear_pulse) begin
          for (int i = 0; i < TabSize; i++) begin
            t1_u[i] <= 1'b0;
            t2_u[i] <= 1'b0;
            t3_u[i] <= 1'b0;
          end
          u_age_cnt <= '0;
        end

        // -- Direction counter update on the provider --
        // Always update bimodal: it absorbs cold cases and serves as alt-pred.
        // For tagged hits, additionally update the matched-tag entry's counter.
        if (up_provider == 2'd0) begin
          bim[up_bim_idx] <= bim_update(bim[up_bim_idx], update_taken);
        end
        if (up_hit1) t1_ctr[up_t1_idx] <= ctr_update(t1_ctr[up_t1_idx], update_taken);
        if (up_hit2) t2_ctr[up_t2_idx] <= ctr_update(t2_ctr[up_t2_idx], update_taken);
        if (up_hit3) t3_ctr[up_t3_idx] <= ctr_update(t3_ctr[up_t3_idx], update_taken);

        // -- use_alt_on_na update: only when the provider is weak AND
        //    provider/alt disagree. Increment when alt was correct, decrement
        //    when provider was correct. Saturating signed counter.
        if ((up_hit1 || up_hit2 || up_hit3) && up_provider_weak &&
            (up_provider_taken != up_alt_taken)) begin
          if (up_alt_taken == update_taken) begin
            if (use_alt_ctr != UseAltMax) use_alt_ctr <= use_alt_ctr + 1;
          end else begin
            if (use_alt_ctr != UseAltMin) use_alt_ctr <= use_alt_ctr - 1;
          end
        end

        // -- u-bit update: provider was "useful" when its direction
        //    differed from bimodal alt-pred and matched the actual outcome.
        if (up_hit1 && (up_provider == 2'd1) && (t1_taken_at(
                up_t1_idx
            ) != bim_taken_at(
                up_bim_idx
            )) && (t1_taken_at(
                up_t1_idx
            ) == update_taken))
          t1_u[up_t1_idx] <= 1'b1;
        if (up_hit2 && (up_provider == 2'd2) && (t2_taken_at(
                up_t2_idx
            ) != bim_taken_at(
                up_bim_idx
            )) && (t2_taken_at(
                up_t2_idx
            ) == update_taken))
          t2_u[up_t2_idx] <= 1'b1;
        if (up_hit3 && (up_provider == 2'd3) && (t3_taken_at(
                up_t3_idx
            ) != bim_taken_at(
                up_bim_idx
            )) && (t3_taken_at(
                up_t3_idx
            ) == update_taken))
          t3_u[up_t3_idx] <= 1'b1;

        // -- Allocation on mispredict --
        if (do_alloc) begin
          if (alloc_t1_ok) begin
            t1_tag[up_t1_idx]   <= up_t1_tag;
            t1_ctr[up_t1_idx]   <= update_taken ? CtrInitT : CtrInitN;
            t1_u[up_t1_idx]     <= 1'b0;
            t1_valid[up_t1_idx] <= 1'b1;
          end else if (alloc_t2_ok) begin
            t2_tag[up_t2_idx]   <= up_t2_tag;
            t2_ctr[up_t2_idx]   <= update_taken ? CtrInitT : CtrInitN;
            t2_u[up_t2_idx]     <= 1'b0;
            t2_valid[up_t2_idx] <= 1'b1;
          end else if (alloc_t3_ok) begin
            t3_tag[up_t3_idx]   <= up_t3_tag;
            t3_ctr[up_t3_idx]   <= update_taken ? CtrInitT : CtrInitN;
            t3_u[up_t3_idx]     <= 1'b0;
            t3_valid[up_t3_idx] <= 1'b1;
          end else begin
            // No allocation possible: decrement u in eligible tables to free slots.
            if (up_provider < 2'd1) t1_u[up_t1_idx] <= 1'b0;
            if (up_provider < 2'd2) t2_u[up_t2_idx] <= 1'b0;
            if (up_provider < 2'd3) t3_u[up_t3_idx] <= 1'b0;
          end
        end
      end
    end
  end

  // Helper accessors used in u-bit update (compute taken from current array
  // value; references resolve before the `always_ff` write).
  function automatic logic t1_taken_at(input logic [IDX_LEN-1:0] i);
    return ~t1_ctr[i][CtrBits-1];
  endfunction
  function automatic logic t2_taken_at(input logic [IDX_LEN-1:0] i);
    return ~t2_ctr[i][CtrBits-1];
  endfunction
  function automatic logic t3_taken_at(input logic [IDX_LEN-1:0] i);
    return ~t3_ctr[i][CtrBits-1];
  endfunction
  function automatic logic bim_taken_at(input logic [BIM_LEN-1:0] i);
    return bim[i][1];
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */
endmodule
