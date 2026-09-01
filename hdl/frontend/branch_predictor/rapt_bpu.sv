`include "rapt.svh"
`include "rapt_if.svh"

`ifdef RAPT_BPU_DIRP_TAGE
`define RAPT_BPU_DIRP_MODULE rapt_bpu_tage
`elsif RAPT_BPU_DIRP_GSHARE
`define RAPT_BPU_DIRP_MODULE rapt_bpu_gshare
`elsif RAPT_BPU_DIRP_BIMODAL
`define RAPT_BPU_DIRP_MODULE rapt_bpu_pht
`else
`define RAPT_BPU_DIRP_MODULE rapt_bpu_static
`endif

/* verilator lint_off UNUSEDPARAM */
module rapt_bpu #(
    parameter int PHT_SIZE = `RAPT_PHT_SIZE,
    parameter int PHT_LEN = $clog2(PHT_SIZE),
    parameter int BTB_SIZE = `RAPT_BTB_SIZE,
    parameter int BTB_WAYS = 2,
    parameter int BTB_LEN = $clog2(BTB_SIZE / BTB_WAYS),
    parameter int BTB_TAG_LEN = 7,
    // GHR_LEN widened to feed TAGE's longest geometric history (64 bits).
    parameter int GHR_LEN = 64,
    // PHR_LEN: path history register (Seznec's TAGE uses an 8-bit PHR
    // formed by shifting in one PC bit per predicted branch). Differentiates
    // contexts that share GHR but reach the branch via different call paths.
    parameter int PHR_LEN = 8,
    parameter int RSB_SIZE = `RAPT_RSB_SIZE,
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_bpu_if.in ifu_bpu,
    idu_bpu_if.in idu_bpu,

    input reset
);
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */
  typedef enum logic [1:0] {
    COND = 'b00,  // Conditional Branch
    DIRE = 'b01,  // Direct Jump
    INDR = 'b10,  // Indirect Jump
    RETU = 'b11   // Return (reserved for future RSB use)
  } inst_t;
  typedef enum logic [1:0] {
    SN = 'b00,  // Strongly Not Taken
    WN = 'b01,  // Weakly Not Taken
    WT = 'b10,  // Weakly Taken
    ST = 'b11   // Strongly Taken
  } pht_t;

  logic [XLEN-1:0] npc;

  // RSB: Return Stack Buffer (maintained for future use; not used for prediction)
  logic [XLEN-1:0] rsb[RSB_SIZE];
  logic [RSB_SIZE-1:0] rsb_v;
  logic [$clog2(RSB_SIZE)-1:0] rsb_cmt_idx;
  logic [$clog2(RSB_SIZE)-1:0] rsb_spec_idx;

  logic [GHR_LEN-1:0] rgshare;
  logic [GHR_LEN-1:0] gshare;
  // Path history registers: shift in one PC bit (PC[1] = first instr-word bit
  // above the 16b-alignment) per predicted / committed branch. `phr` tracks
  // the speculative stream (rewound on flush); `rphr` is the architectural
  // companion of rgshare, both used for re-deriving the TAGE update index/tag.
  logic [PHR_LEN-1:0] phr;
  logic [PHR_LEN-1:0] rphr;
  logic [BTB_LEN-1:0] rbtb_idx;
  logic [BTB_TAG_LEN-1:0] rbtb_tag;
  logic is_b;
  logic btaken;
  logic btb_tag_match;
  logic taken;
  logic rbtaken;

`ifdef RAPT_DUAL_ISSUE
  // Side predictor for a packet's slot-B conditional branch. Unlike the
  // synchronous primary TAGE/BTB path, this table is read combinationally
  // because slot B is only known after the L1I response arrives. The target
  // remains a static branch immediate in IFU, so no second BTB port is needed.
  logic [1:0] slot_b_pht[PHT_SIZE];
  logic [PHT_LEN-1:0] slot_b_pht_idx;
  logic [PHT_LEN-1:0] slot_b_pht_update_idx;
  assign slot_b_pht_idx = ifu_bpu.slot_b_pc[PHT_LEN:1];
  assign slot_b_pht_update_idx = cmu_bcast.rpc[PHT_LEN:1];
  assign ifu_bpu.slot_b_taken = ifu_bpu.slot_b_query && slot_b_pht[slot_b_pht_idx][1];
`endif

  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;

  // Delayed pc_update to gate speculative updates to fresh predictions only
  logic pred_valid;

  /* verilator lint_on UNUSEDSIGNAL */

  // --- PHT and BTB with (* keep_hierarchy *) ---
  // Read addresses computed from nextpc; registered inside sub-modules on
  // pc_update. The keep_hierarchy attribute prevents Yosys from flattening
  // the sub-modules, so the internal read-address registers stay separate
  // from pc_ifu: eliminating the ~2800-fanout critical path.

  logic [BTB_LEN-1:0] fbtb_raddr;
  logic [BTB_TAG_LEN-1:0] fbtb_rtag;
  assign fbtb_raddr = ifu_bpu.nextpc[BTB_LEN-1+1:1] ^ ifu_bpu.nextpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign fbtb_rtag  = ifu_bpu.nextpc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];

  // ---------------- Direction predictor (pluggable) ----------------
  // The conditional-direction predictor is selected at elaboration time via
  // the `RAPT_BPU_DIRP_*` define (see rapt_config.svh). All flavors expose
  // the uniform port set in `rapt_bpu_dirp_if.svh`. BTB / RSB / training
  // logic is shared and lives in this wrapper.
  logic dirp_taken;
  logic dirp_update_mispred;
  logic [GHR_LEN-1:0] dirp_read_ghr;
  logic [PHR_LEN-1:0] dirp_read_phr;
`ifdef RAPT_DUAL_ISSUE
  assign dirp_read_ghr = ifu_bpu.slot_b_pred_valid
    ? {gshare[GHR_LEN-2:0], ifu_bpu.slot_b_taken}
    : gshare;
  assign dirp_read_phr = ifu_bpu.slot_b_pred_valid
    ? {phr[PHR_LEN-2:0], ifu_bpu.slot_b_pc[1]}
    : phr;
`else
  assign dirp_read_ghr = gshare;
  assign dirp_read_phr = phr;
`endif
  assign dirp_update_mispred = cmu_bcast.ben && cmu_bcast.flush_pipe;
  // All DIRP flavors share an identical parameter list (XLEN, GHR_LEN,
  // PHR_LEN, DEPTH) and port set (`RAPT_BPU_DIRP_PORTS`), so the only
  // thing the `ifdef` switches is the module name. Keeps the parameter
  // map and port map authoritative in a single place.
  `RAPT_BPU_DIRP_MODULE #(
      .XLEN   (XLEN),
      .GHR_LEN(GHR_LEN),
      .PHR_LEN(PHR_LEN),
      .DEPTH  (PHT_SIZE)
  ) u_dirp (
      .clock         (clock),
      .reset         (reset),
      .ren           (ifu_bpu.pc_update),
      .raddr         (ifu_bpu.nextpc),
      .r_ghr         (dirp_read_ghr),
      .r_phr         (dirp_read_phr),
      .rd_taken      (dirp_taken),
      .update_en     (cmu_bcast.ben),
      .update_pc     (rpc),
      .update_ghr    (rgshare),
      .update_phr    (rphr),
      .update_taken  (rbtaken),
      .update_mispred(dirp_update_mispred),
      .init          (cmu_bcast.fence_time)
  );

  // BTB (synchronous read, separate entry/type writes)
  logic [XLEN-1:1] btb_rd_target;
  logic [1:0] btb_rd_type;
  logic btb_rd_tag_match;

  // BTB write source arbitration: commit-flush has priority over IDU train.
  // Commit-flush is rare and authoritative (carries true direction); IDU train
  // fires alongside an IDU early-resteer (static target derivable from imm).
  logic cmu_wen_entry, cmu_wen_type;
  logic [            1:0] cmu_wd_type;
  logic [       XLEN-1:1] cmu_wd_full;
  logic [    BTB_LEN-1:0] cmu_waddr;
  logic [BTB_TAG_LEN-1:0] cmu_wd_tag;
  assign cmu_wen_entry = cmu_bcast.flush_pipe && (cmu_bcast.jen || cmu_bcast.jren || rbtaken);
  assign cmu_wen_type  = cmu_bcast.jren || cmu_bcast.jen || (cmu_bcast.ben && rbtaken);
  // RETU encoding for returns enables RSB-based target prediction (see
  // npc/rsb_top_addr mux below). Non-ret jalr stays INDR.
  assign cmu_wd_type   = cmu_bcast.ret  ? RETU :
                         cmu_bcast.jren ? INDR :
                         cmu_bcast.jen  ? DIRE : COND;
  assign cmu_wd_full   = cpc[XLEN-1:1];
  assign cmu_waddr     = rbtb_idx;
  assign cmu_wd_tag    = rbtb_tag;

  // IDU training pulse: derive matching index/tag from train_pc.
  logic                   idu_wen;
  logic [    BTB_LEN-1:0] idu_waddr;
  logic [BTB_TAG_LEN-1:0] idu_wd_tag;
  assign idu_wen    = idu_bpu.train_en;
  assign idu_waddr  = idu_bpu.train_pc[BTB_LEN-1+1:1] ^ idu_bpu.train_pc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign idu_wd_tag = idu_bpu.train_pc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];

  // Final mux: priority = commit-flush entry write > IDU train > commit
  // type-only refresh. Rationale:
  //   - cmu_wen_entry only fires on commit-flush (true mispredict) -- must win;
  //     it carries authoritative target/type to replace a stale entry.
  //   - cmu_wen_type alone is just "refresh type of an existing matching
  //     entry" on every committed control op; the entry was allocated with
  //     the correct type, so dropping a refresh is a no-op.
  //   - IDU train carries fresh target/tag/type for a new (or aliased) entry;
  //     it should preempt the type-only refresh.
  logic wen_entry_mux, wen_type_mux;
  logic [    BTB_LEN-1:0] waddr_mux;
  logic [       XLEN-1:1] wd_target_mux;
  logic [BTB_TAG_LEN-1:0] wd_tag_mux;
  logic [            1:0] wd_type_mux;
  logic                   idu_grant;
  assign idu_grant     = idu_wen && !cmu_wen_entry;
  assign wen_entry_mux = cmu_wen_entry || idu_grant;
  assign wen_type_mux  = (cmu_wen_type && !idu_grant) || idu_grant;
  assign waddr_mux     = cmu_wen_entry ? cmu_waddr : idu_grant ? idu_waddr : cmu_waddr;
  assign wd_target_mux = cmu_wen_entry ? cmu_wd_full : idu_bpu.train_target[XLEN-1:1];
  assign wd_tag_mux    = cmu_wen_entry ? cmu_wd_tag : idu_grant ? idu_wd_tag : cmu_wd_tag;
  assign wd_type_mux   = cmu_wen_entry ? cmu_wd_type : idu_grant ? idu_bpu.train_type : cmu_wd_type;

  rapt_bpu_btb #(
      .DEPTH(BTB_SIZE / BTB_WAYS),
      .WAYS(BTB_WAYS),
      .TAG_LEN(BTB_TAG_LEN),
      .XLEN(XLEN)
  ) u_btb (
      .clock(clock),
      .reset(reset),
      .ren(ifu_bpu.pc_update),
      .raddr(fbtb_raddr),
      .rtag(fbtb_rtag),
      .rd_target(btb_rd_target),
      .rd_type(btb_rd_type),
      .rd_tag_match(btb_rd_tag_match),
      // JALR entry creation: write target+tag+valid on JALR flush (bug fix: baseline
      // only wrote entries for JAL and taken-branches, leaving JALR without BTB entries)
      .wen_entry(wen_entry_mux),
      .waddr(waddr_mux),
      .wd_target(wd_target_mux),
      .wd_tag(wd_tag_mux),
      .wen_type(wen_type_mux),
      .wd_type(wd_type_mux),
      .init(cmu_bcast.fence_time)
  );

  // Prediction logic: all inputs are registered sub-module outputs,
  // NO combinational dependency on pc_ifu/fpc.
  assign is_b = (btb_rd_type == COND);
  assign btaken = (btb_rd_type == COND && dirp_taken);
  assign btb_tag_match = btb_rd_tag_match;
  assign taken = (btb_tag_match && ((btb_rd_type != COND) || btaken));

  // ---------------- RSB-based return prediction ----------------
  // When BTB tags this PC as RETU (set by commit of a ret), override the
  // BTB target with the RSB top entry. RSB pushes happen at commit
  // (`cmu_bcast.call`); speculative pops happen on predicted-return below.
  // Misprediction rewinds rsb_spec_idx to the committed pointer.
  logic [$clog2(RSB_SIZE)-1:0] rsb_top_idx;
  logic                        pred_is_ret;
  logic                        pred_rsb_v;
  logic [           XLEN-1:0]  rsb_top_addr;
  assign rsb_top_idx  = rsb_spec_idx - 1'b1;
  assign pred_is_ret  = btb_tag_match && (btb_rd_type == RETU);
  assign pred_rsb_v   = pred_is_ret && rsb_v[rsb_top_idx];
  assign rsb_top_addr = rsb[rsb_top_idx];
  assign npc          = pred_rsb_v ? rsb_top_addr : {btb_rd_target, 1'b0};

  // Commit-path index computation
  assign rbtb_idx = rpc[BTB_LEN-1+1:1] ^ rpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign rbtb_tag = rpc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];

  assign ifu_bpu.taken = taken;
  assign ifu_bpu.npc = npc;

`ifdef RAPT_DUAL_ISSUE
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.fence_time) begin
      for (int i = 0; i < PHT_SIZE; i++) slot_b_pht[i] <= WN;
    end else if (cmu_bcast.ben) begin
      if (rbtaken) begin
        if (slot_b_pht[slot_b_pht_update_idx] != ST)
          slot_b_pht[slot_b_pht_update_idx] <= slot_b_pht[slot_b_pht_update_idx] + 1'b1;
      end else begin
        if (slot_b_pht[slot_b_pht_update_idx] != SN)
          slot_b_pht[slot_b_pht_update_idx] <= slot_b_pht[slot_b_pht_update_idx] - 1'b1;
      end
    end
  end
`endif

  assign rpc = cmu_bcast.rpc;
  assign rbtaken = cmu_bcast.btaken;
  assign cpc = cmu_bcast.cpc;

  // Return address for RSB push (call PC + instruction length).
  // Architectural (commit-side) push value retained for documentation /
  // future asserts; the actual RSB data is now written by the IDU
  // speculative-push channel below.
  logic [XLEN-1:0] rsb_push_addr;
  assign rsb_push_addr = rpc + (cmu_bcast.rvc ? XLEN'(2) : XLEN'(4));
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_rsb_cmt_push_addr;
  assign _unused_rsb_cmt_push_addr = |rsb_push_addr;
  /* verilator lint_on UNUSEDSIGNAL */

  // Next committed RSB index (accounts for this cycle's commit)
  logic [$clog2(RSB_SIZE)-1:0] next_rsb_cmt_idx;
  assign next_rsb_cmt_idx = cmu_bcast.call ? (rsb_cmt_idx + 1'b1) :
                             cmu_bcast.ret  ? (rsb_cmt_idx - 1'b1) :
                             rsb_cmt_idx;

  // Speculative push/pop bookkeeping
  logic spec_push;
  logic spec_pop;
  logic [$clog2(RSB_SIZE)-1:0] rsb_push_idx;
  assign spec_push    = idu_bpu.push_en;
  assign spec_pop     = pred_valid && pred_rsb_v;
  // When both push and pop fire in the same cycle, pop first so the push
  // overwrites the popped slot (net spec_idx unchanged).
  assign rsb_push_idx = spec_pop ? (rsb_spec_idx - 1'b1) : rsb_spec_idx;

  always_ff @(posedge clock) begin
    if (reset) begin
      rsb_cmt_idx  <= '0;
      rsb_spec_idx <= '0;
      rsb_v        <= '0;
      gshare       <= '0;
      rgshare      <= '0;
      phr          <= '0;
      rphr         <= '0;
      pred_valid   <= 0;
    end else if (!cmu_bcast.fence_time) begin
      pred_valid <= ifu_bpu.pc_update;

      // --- Architectural RSB pointer tracking (used as flush rewind point) ---
      rsb_cmt_idx <= next_rsb_cmt_idx;

      // --- Speculative RSB data + valid (IDU-driven push) ---
      if (spec_push) begin
        rsb[rsb_push_idx]   <= idu_bpu.push_addr;
        rsb_v[rsb_push_idx] <= 1'b1;
      end

      // --- Speculative RSB pointer ---
      // Flush has priority; otherwise update from push/pop deltas.
      if (cmu_bcast.flush_pipe) begin
        rsb_spec_idx <= next_rsb_cmt_idx;
      end else begin
        unique case ({
          spec_push, spec_pop
        })
          2'b10:   rsb_spec_idx <= rsb_spec_idx + 1'b1;
          2'b01:   rsb_spec_idx <= rsb_spec_idx - 1'b1;
          default: rsb_spec_idx <= rsb_spec_idx;  // 00 or 11
        endcase
      end

      // --- GHR update (preserved for future gshare with larger PHT) ---
`ifdef RAPT_DUAL_ISSUE
      if (cmu_bcast.flush_pipe) begin
        gshare <= {rgshare[GHR_LEN-2:0], rbtaken};
        // PHR rewinds to architectural value plus this committed branch's PC bit.
        phr <= {rphr[PHR_LEN-2:0], rpc[1]};
      end else if (ifu_bpu.slot_b_pred_valid) begin
        gshare <= {gshare[GHR_LEN-2:0], ifu_bpu.slot_b_taken};
        phr <= {phr[PHR_LEN-2:0], ifu_bpu.slot_b_pc[1]};
      end else if (pred_valid && is_b && btb_tag_match) begin
        gshare <= {gshare[GHR_LEN-2:0], btaken};
        // Shift in PC bit on each speculative COND prediction.
        phr <= {phr[PHR_LEN-2:0], ifu_bpu.pc[1]};
      end
`else
      if (cmu_bcast.flush_pipe) begin
        gshare <= {rgshare[GHR_LEN-2:0], rbtaken};
        // PHR rewinds to architectural value plus this committed branch's PC bit.
        phr <= {rphr[PHR_LEN-2:0], rpc[1]};
      end else if (pred_valid && is_b && btb_tag_match) begin
        gshare <= {gshare[GHR_LEN-2:0], btaken};
        // Shift in PC bit on each speculative COND prediction.
        phr <= {phr[PHR_LEN-2:0], ifu_bpu.pc[1]};
      end
`endif
      if (cmu_bcast.ben) begin
        rgshare <= {rgshare[GHR_LEN-2:0], rbtaken};
        rphr    <= {rphr[PHR_LEN-2:0], rpc[1]};
      end
    end
  end

endmodule

`undef RAPT_BPU_DIRP_MODULE
