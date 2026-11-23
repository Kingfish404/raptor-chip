`include "rapt.svh"
`include "rapt_if.svh"


`ifdef RAPT_BPU_DIRP_TAGE
`define RAPT_BPU_DIRP_MODULE rapt_bpu_tage
`elsif RAPT_BPU_DIRP_GSHARE
`define RAPT_BPU_DIRP_MODULE rapt_bpu_gshare
`elsif RAPT_BPU_DIRP_BIMODAL
`define RAPT_BPU_DIRP_MODULE rapt_bpu_pht
`elsif RAPT_BPU_DIRP_STATIC
`define RAPT_BPU_DIRP_MODULE rapt_bpu_static
`else
// An undefined module rejects missing selections in both synthesis and lint,
// even with nonfatal warnings. Unlike `error, this is also formatter-compatible.
`define RAPT_BPU_DIRP_MODULE rapt_bpu_requires_TAGE_GSHARE_BIMODAL_or_STATIC
`endif

/* verilator lint_off UNUSEDPARAM */
module rapt_bpu #(
    parameter int PHT_SIZE = `RAPT_PHT_SIZE,
    parameter int PHT_LEN = $clog2(PHT_SIZE),
    parameter int BTB_SIZE = `RAPT_BTB_SIZE,
    parameter int BTB_WAYS = `RAPT_BTB_WAYS,
    parameter int BTB_LEN = $clog2(BTB_SIZE / BTB_WAYS),
    parameter int BTB_TAG_LEN = (BTB_SIZE >= 512) ? 9 : 7,
    // GHR_LEN widened to feed TAGE's longest geometric history (64 bits).
    parameter int GHR_LEN = 64,
    // PHR_LEN: path history register (Seznec's TAGE uses an 8-bit PHR
    // formed by shifting in one PC bit per predicted branch). Differentiates
    // contexts that share GHR but reach the branch via different call paths.
    parameter int PHR_LEN = 8,
    parameter int RSB_SIZE = `RAPT_RSB_SIZE,
    parameter int XLEN = `RAPT_XLEN,
    parameter bit SharedDecodeTarget = 1'b0
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_bpu_if.in ifu_bpu,
    idu_bpu_if.in idu_bpu,
    input logic execute_recover,
    input logic preserve_fetch,
    input logic [`RAPT_PC_BITS_OF(XLEN)-1:1] decode_target_q,
    input logic [GHR_LEN-1:0] execute_ghr,
    input logic [PHR_LEN-1:0] execute_phr,
    output logic [GHR_LEN-1:0] snapshot_ghr,
    output logic [PHR_LEN-1:0] snapshot_phr,

    input reset
);
  localparam int PcW = `RAPT_PC_BITS_OF(XLEN);
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */
  typedef enum logic [1:0] {
    COND = 'b00,  // Conditional Branch
    DIRE = 'b01,  // Direct Jump
    INDR = 'b10,  // Indirect Jump
    RETU = 'b11   // Return / coroutine pop
  } inst_t;
  typedef enum logic [1:0] {
    SN = 'b00,  // Strongly Not Taken
    WN = 'b01,  // Weakly Not Taken
    WT = 'b10,  // Weakly Taken
    ST = 'b11   // Strongly Taken
  } pht_t;

  logic [PcW-1:0] npc;

  logic [GHR_LEN-1:0] rgshare;
  logic [GHR_LEN-1:0] gshare;
  // Fetch and committed history observations. The history module also retains
  // a decode watermark, so an IDU resteer can discard fetch-only speculation.
  logic [PHR_LEN-1:0] phr;
  logic [PHR_LEN-1:0] rphr;
  logic [BTB_LEN-1:0] rbtb_idx;
  logic [BTB_TAG_LEN-1:0] rbtb_tag;
  logic btb_tag_match;
  logic taken;
  logic dirp_aux_taken, dirp_request_aux_taken;
  logic rbtaken;

`ifdef RAPT_FETCH_LOOKAHEAD
  // A packet's non-first conditional branch is predicted by TAGE's auxiliary
  // read port (its position is known only after the L1I response arrives).
  // Its target remains a static branch immediate in IFU.
  assign ifu_bpu.aux_index = '0;
  assign ifu_bpu.request_aux_taken = dirp_request_aux_taken;
  logic lp_aux_override, lp_aux_pred_taken;
  assign ifu_bpu.aux_taken = ifu_bpu.aux_query
      && (lp_aux_override ? lp_aux_pred_taken : dirp_aux_taken);
`endif

  logic [PcW-1:0] rpc;
  logic [PcW-1:0] cpc;

  /* verilator lint_on UNUSEDSIGNAL */

  // --- Direction predictor and BTB ---
  // Read addresses are XOR-folded from nextpc and registered inside each
  // sub-module on ren, keeping predictor read indices independent of pc_ifu.

  function automatic logic [BTB_TAG_LEN-1:0] btb_tag_of(input logic [PcW-1:0] pc);
    automatic logic [BTB_TAG_LEN-1:0] folded;
    folded = '0;
    for (int base = BTB_LEN + 1; base < PcW; base += BTB_TAG_LEN) begin
      folded ^= BTB_TAG_LEN'(pc >> base);
    end
    return folded;
  endfunction

  logic [BTB_LEN-1:0] fbtb_raddr;
  logic [BTB_TAG_LEN-1:0] fbtb_rtag;
  assign fbtb_raddr = ifu_bpu.nextpc[BTB_LEN-1+1:1] ^ ifu_bpu.nextpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign fbtb_rtag  = btb_tag_of(ifu_bpu.nextpc);

  // ---------------- Direction predictor (pluggable) ----------------
  // The conditional-direction predictor is selected at elaboration time via
  // the `RAPT_BPU_DIRP_*` define (see rapt_config.svh). All flavors expose
  // the uniform port set in `rapt_bpu_dirp_if.svh`. BTB / RSB / training
  // logic is shared and lives in this wrapper.
  logic dirp_taken;
  logic dirp_update_mispred;
  logic [GHR_LEN-1:0] dirp_read_ghr;
  logic [PHR_LEN-1:0] dirp_read_phr;
  logic [GHR_LEN-1:0] unused_decode_ghr;
  logic [PHR_LEN-1:0] unused_decode_phr;
  rapt_predict_history #(
      .GhrBits(GHR_LEN),
      .PhrBits(PHR_LEN)
  ) u_history (
      .clock(clock),
      .reset(reset),
      .clear((`RAPT_SFENCE_KEEP_STATE < 3 && cmu_bcast.fence_time)),
      .flush(cmu_bcast.flush_pipe && !preserve_fetch),
      .decode_recover(idu_bpu.history_recover),
      .execute_recover(execute_recover),
      .execute_ghr(execute_ghr),
      .execute_phr(execute_phr),
      .fetch_valid(ifu_bpu.history_valid),
      .fetch_taken(ifu_bpu.history_taken),
      .fetch_pc_bit(ifu_bpu.history_pc_bit),
      .decode_valid(idu_bpu.history_valid),
      .decode_taken(idu_bpu.history_taken),
      .decode_pc_bit(idu_bpu.history_pc_bit),
      .commit_valid(cmu_bcast.ben),
      .commit_taken(cmu_bcast.btaken),
      .commit_pc_bit(cmu_bcast.rpc[1]),
      .fetch_ghr(gshare),
      .fetch_phr(phr),
      .decode_ghr(unused_decode_ghr),
      .decode_phr(unused_decode_phr),
      .commit_ghr(rgshare),
      .commit_phr(rphr),
      .query_ghr(dirp_read_ghr),
      .query_phr(dirp_read_phr),
      .snapshot_ghr(snapshot_ghr),
      .snapshot_phr(snapshot_phr)
  );
  assign dirp_update_mispred = cmu_bcast.ben && cmu_bcast.flush_pipe;
  // All DIRP flavors share an identical parameter list (XLEN, GHR_LEN,
  // PHR_LEN, DEPTH) and port set (`RAPT_BPU_DIRP_PORTS`), so the only
  // thing the `ifdef` switches is the module name. Keeps the parameter
  // map and port map authoritative in a single place.
  `RAPT_BPU_DIRP_MODULE #(
`ifdef RAPT_BPU_DIRP_TAGE
`ifdef RAPT_FETCH_LOOKAHEAD
      .AuxPositions(rapt_pkg::DecodeWidth > 1 && !
      `RAPT_FETCH_RESPONSE_STAGE
                    ? 2 * (rapt_pkg::DecodeWidth - 1) : 0),
`endif
`endif
      .XLEN   (XLEN),
      .GHR_LEN(GHR_LEN),
      .PHR_LEN(PHR_LEN),
      .DEPTH  (PHT_SIZE)
  ) u_dirp (
`ifdef RAPT_BPU_DIRP_TAGE
`ifdef RAPT_FETCH_LOOKAHEAD
      .aux_pc(ifu_bpu.aux_pc),
      .aux_position(ifu_bpu.aux_position),
      .request_aux_position(ifu_bpu.request_aux_position),
`else
      .aux_pc('0),
`endif
      .aux_ghr(gshare),
      .aux_phr(phr),
      .aux_taken(dirp_aux_taken),
      .request_aux_taken(dirp_request_aux_taken),
`endif
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
      .init                ((`RAPT_SFENCE_KEEP_STATE < 3 && cmu_bcast.fence_time))
  );

`ifndef RAPT_BPU_DIRP_TAGE
  assign dirp_aux_taken = 1'b0;
  assign dirp_request_aux_taken = 1'b0;
`endif

  // BTB (synchronous read, separate entry/type writes)
  logic [PcW-1:1] btb_rd_target;
  logic [1:0] btb_rd_type;
  logic btb_rd_tag_match;

  // BTB write source arbitration: commit-flush has priority over IDU train.
  // Commit-flush is rare and authoritative (carries true direction); IDU train
  // fires alongside an IDU early-resteer (static target derivable from imm).
  logic cmu_wen_entry, cmu_wen_type;
  logic [            1:0] cmu_wd_type;
  logic [       PcW-1:1] cmu_wd_full;
  logic [    BTB_LEN-1:0] cmu_waddr;
  logic [BTB_TAG_LEN-1:0] cmu_wd_tag;
  assign cmu_wen_entry = cmu_bcast.flush_pipe
      && (cmu_bcast.jen || cmu_bcast.jren || (cmu_bcast.ben && rbtaken));
  `RAPT_SVA_IMPLY(clock, reset, BPU_COMMIT_ENTRY_IS_CONTROL, cmu_wen_entry,
                  cmu_bcast.ben || cmu_bcast.jen || cmu_bcast.jren)
  assign cmu_wen_type  = cmu_bcast.jren || cmu_bcast.jen || (cmu_bcast.ben && rbtaken);
  // RETU identifies a return/coroutine target; IDU supplies RAS repair/training.
  assign cmu_wd_type   = cmu_bcast.ret ? RETU : cmu_bcast.jren ? INDR : cmu_bcast.jen ? DIRE : COND;
  assign cmu_wd_full   = cpc[PcW-1:1];
  assign cmu_waddr     = rbtb_idx;
  assign cmu_wd_tag    = rbtb_tag;

  // IDU training/invalidation pulse: derive matching index/tag from train_pc.
  logic                   idu_wen;
  logic                   idu_inv;
  logic [    BTB_LEN-1:0] idu_waddr;
  logic [BTB_TAG_LEN-1:0] idu_wd_tag;
  logic idu_wen_q;
  logic idu_inv_q;
  logic [PcW-1:1] idu_target_q;
  logic [1:0] idu_type_q;
  // Decode training follows its registered redirect. Store only the BTB key,
  // not another full PC, and let an older recovery cancel the pending write.
  assign idu_wen = idu_wen_q && !cmu_bcast.flush_pipe && !execute_recover;
  assign idu_inv = idu_inv_q && !cmu_bcast.flush_pipe && !execute_recover;
  always_ff @(posedge clock) begin
    idu_wen_q <= idu_bpu.train_en && !reset;
    idu_inv_q <= idu_bpu.invalidate_en && !reset;
    idu_waddr <= idu_bpu.train_pc[BTB_LEN:1] ^ idu_bpu.train_pc[2*BTB_LEN:BTB_LEN+1];
    idu_wd_tag <= btb_tag_of(idu_bpu.train_pc);
    idu_type_q <= idu_bpu.train_type;
  end

  // The composed frontend already stores this target in IDU's redirect
  // register on the training edge. Standalone users retain the local copy.
  if (SharedDecodeTarget) begin : g_shared_decode_target
    assign idu_target_q = decode_target_q;
  end else begin : g_local_decode_target
    always_ff @(posedge clock) idu_target_q <= idu_bpu.train_target[PcW-1:1];
  end

  // Final mux: priority = commit-flush entry write > IDU train > commit
  // type-only refresh. Rationale:
  //   - cmu_wen_entry only fires on commit-flush (true mispredict) -- must win;
  //     it carries authoritative target/type to replace a stale entry.
  //   - cmu_wen_type alone is just "refresh type of an existing matching
  //     entry" on every committed control op; the entry was allocated with
  //     the correct type, so dropping a refresh is a no-op.
  //   - IDU train carries fresh target/tag/type for a new (or aliased) entry;
  //     it should preempt the type-only refresh.
  logic wen_entry_mux, inv_entry_mux, wen_type_mux;
  logic [    BTB_LEN-1:0] waddr_mux;
  logic [       PcW-1:1] wd_target_mux;
  logic [BTB_TAG_LEN-1:0] wd_tag_mux;
  logic [            1:0] wd_type_mux;
  logic                   idu_grant;
  logic                   idu_inv_grant;
  assign idu_grant     = idu_wen && !cmu_wen_entry;
  assign idu_inv_grant = idu_inv && !cmu_wen_entry;
  assign wen_entry_mux = cmu_wen_entry || idu_grant;
  assign inv_entry_mux = idu_inv_grant;
  assign wen_type_mux  = (cmu_wen_type && !idu_inv_grant) || idu_grant;
  // idu_grant / idu_inv_grant already exclude a commit entry write.
  assign waddr_mux     = (idu_grant || idu_inv_grant) ? idu_waddr : cmu_waddr;
  assign wd_target_mux = cmu_wen_entry ? cmu_wd_full : idu_target_q;
  assign wd_tag_mux    = (idu_grant || idu_inv_grant) ? idu_wd_tag : cmu_wd_tag;
  assign wd_type_mux   = idu_grant ? idu_type_q : cmu_wd_type;

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
      .inv_entry(inv_entry_mux),
      .waddr(waddr_mux),
      .wd_target(wd_target_mux),
      .wd_tag(wd_tag_mux),
      .wen_type(wen_type_mux),
      .wd_type(wd_type_mux),
      .init((`RAPT_SFENCE_KEEP_STATE < 3 && cmu_bcast.fence_time))
  );

  // --- Lightweight 32-entry Indirect Target Table (ITT) ---
  // Context-indexed by PC ^ GHR so multi-target switch/vtable JALRs predict
  // accurately without bloating BTB. Synchronous read matches BTB timing.
  localparam int IttEntries = 32;
  localparam int IttIdxBits = $clog2(IttEntries);
  localparam int IttTagBits = 9;
  logic [IttEntries-1:0] itt_valid;
  logic [IttTagBits-1:0] itt_tag[IttEntries];
  logic [PcW-1:1] itt_target[IttEntries];
  logic itt_rd_hit_q;
  logic [PcW-1:1] itt_rd_target_q;
  wire [IttIdxBits-1:0] itt_ridx = ifu_bpu.nextpc[IttIdxBits:1] ^ dirp_read_ghr[IttIdxBits-1:0];
  wire [IttTagBits-1:0] itt_rtag = ifu_bpu.nextpc[IttIdxBits+IttTagBits:IttIdxBits+1]
      ^ dirp_read_ghr[IttIdxBits+IttTagBits-1:IttIdxBits];
  wire [IttIdxBits-1:0] itt_widx = rpc[IttIdxBits:1] ^ rgshare[IttIdxBits-1:0];
  wire [IttTagBits-1:0] itt_wtag = rpc[IttIdxBits+IttTagBits:IttIdxBits+1]
      ^ rgshare[IttIdxBits+IttTagBits-1:IttIdxBits];
  wire bpu_clear = (`RAPT_SFENCE_KEEP_STATE < 3 && cmu_bcast.fence_time);
  always_ff @(posedge clock) begin
    if (reset || bpu_clear) begin
      itt_valid <= '0;
      itt_rd_hit_q <= 1'b0;
      itt_rd_target_q <= '0;
    end else begin
      if (ifu_bpu.pc_update) begin
        itt_rd_hit_q <= itt_valid[itt_ridx] && (itt_tag[itt_ridx] == itt_rtag);
        itt_rd_target_q <= itt_target[itt_ridx];
      end
      if (cmu_bcast.jren && !cmu_bcast.ret) begin
        itt_valid[itt_widx] <= 1'b1;
        itt_tag[itt_widx] <= itt_wtag;
        itt_target[itt_widx] <= cpc[PcW-1:1];
      end
    end
  end

  // --- Checkpointed 32-entry Loop Predictor (4 active speculative slots) ---
  // Tracks backward conditional loop trip counts at commit, with synchronous
  // fetch lookup and exact 3-tier speculative rollback across decode_recover,
  // execute_recover (matched by snapshot_ghr ^ 1), and non-preserved flush.
  localparam int LoopEntries = 32;
  localparam int LoopIdxBits = $clog2(LoopEntries);
  localparam int LoopTagBits = 10;
  localparam int LoopCntBits = 10;
  localparam int ActiveLoops = 4;
  localparam int ActBits     = $clog2(ActiveLoops);
  localparam int F2dDepth    = 16;
  localparam int F2dBits     = $clog2(F2dDepth);
  localparam int CkptDepth   = 16;
  localparam int CkptBits    = $clog2(CkptDepth);

  logic [LoopEntries-1:0] lp_valid;
  logic [LoopTagBits-1:0] lp_tag[LoopEntries];
  logic [LoopCntBits-1:0] lp_trip[LoopEntries];
  logic [1:0] lp_conf[LoopEntries];
  logic [LoopCntBits-1:0] lp_arch_iter[LoopEntries];

  logic [LoopIdxBits-1:0] lp_rd_idx_q;
  logic lp_rd_match_q;
  logic [1:0] lp_rd_conf_q;
  logic [LoopCntBits-1:0] lp_rd_trip_q;
  logic [LoopCntBits-1:0] lp_rd_arch_q;

  logic [ActiveLoops-1:0] act_valid;
  logic [LoopIdxBits-1:0] act_idx[ActiveLoops];
  logic [ActBits-1:0] act_rr_ptr;
  logic [LoopCntBits-1:0] fetch_iter[ActiveLoops];
  logic [LoopCntBits-1:0] decode_iter[ActiveLoops];

  logic [F2dDepth-1:0] f2d_has_loop;
  logic [ActBits-1:0] f2d_slot[F2dDepth];
  logic [F2dBits-1:0] f2d_head, f2d_tail;
  logic [F2dBits:0] f2d_count;

  logic [CkptDepth-1:0] ckpt_valid;
  logic [15:0] ckpt_ghr[CkptDepth];
  logic [LoopCntBits-1:0] ckpt_iter[CkptDepth][ActiveLoops];
  logic [CkptDepth-1:0] ckpt_has_loop;
  logic [ActBits-1:0] ckpt_slot[CkptDepth];
  logic [LoopCntBits-1:0] ckpt_iter_before[CkptDepth];
  logic [CkptBits-1:0] ckpt_wptr;

  wire [LoopIdxBits-1:0] lp_ridx = ifu_bpu.nextpc[LoopIdxBits:1]
      ^ ifu_bpu.nextpc[2*LoopIdxBits:LoopIdxBits+1];
  wire [LoopTagBits-1:0] lp_rtag = ifu_bpu.nextpc[LoopIdxBits+LoopTagBits:LoopIdxBits+1];
  wire [LoopIdxBits-1:0] lp_widx = rpc[LoopIdxBits:1] ^ rpc[2*LoopIdxBits:LoopIdxBits+1];
  wire [LoopTagBits-1:0] lp_wtag = rpc[LoopIdxBits+LoopTagBits:LoopIdxBits+1];
  wire lp_c_hit = lp_valid[lp_widx] && (lp_tag[lp_widx] == lp_wtag);
  wire lp_is_backward = cpc < rpc;
  wire lp_fetch_hit_primary = btb_rd_tag_match && (btb_rd_type == COND) && lp_rd_match_q;

  // Combinational lookup of the exact branch consumed by IFU (primary OR aux)
  wire [LoopIdxBits-1:0] lp_upd_idx = ifu_bpu.history_pc[LoopIdxBits:1];
  wire [LoopTagBits-1:0] lp_upd_tag =
      ifu_bpu.history_pc[LoopTagBits+LoopIdxBits:LoopIdxBits+1];
  wire lp_upd_hit = lp_valid[lp_upd_idx] && (lp_tag[lp_upd_idx] == lp_upd_tag);

  logic lp_upd_act_hit;
  logic [ActBits-1:0] lp_upd_act_slot;
  always_comb begin
    lp_upd_act_hit = 1'b0;
    lp_upd_act_slot = '0;
    for (int a = 0; a < ActiveLoops; a++) begin
      if (act_valid[a] && (act_idx[a] == lp_upd_idx)) begin
        lp_upd_act_hit = 1'b1;
        lp_upd_act_slot = ActBits'(a);
      end
    end
  end

  logic lp_act_hit;
  logic [ActBits-1:0] lp_act_slot;
  logic [LoopCntBits-1:0] lp_cur_iter;
  always_comb begin
    lp_act_hit = 1'b0;
    lp_act_slot = '0;
    for (int a = 0; a < ActiveLoops; a++) begin
      if (act_valid[a] && (act_idx[a] == lp_rd_idx_q)) begin
        lp_act_hit = 1'b1;
        lp_act_slot = ActBits'(a);
      end
    end
    lp_cur_iter = lp_act_hit ? fetch_iter[lp_act_slot] : lp_rd_arch_q;
  end

  // 64-bit GHR TAGE already tracks short loops (<32) accurately; override only
  // long loops (>=32) where GHR saturates.
  wire lp_override = lp_rd_match_q && (lp_rd_conf_q == 2'd3) && (lp_rd_trip_q >= 10'd32);
  wire lp_pred_taken = (lp_cur_iter != lp_rd_trip_q);
  wire cond_taken = lp_override ? lp_pred_taken : dirp_taken;

`ifdef RAPT_FETCH_LOOKAHEAD
  wire [LoopIdxBits-1:0] lp_aux_idx = ifu_bpu.aux_pc[LoopIdxBits:1];
  wire [LoopTagBits-1:0] lp_aux_tag =
      ifu_bpu.aux_pc[LoopTagBits+LoopIdxBits:LoopIdxBits+1];
  wire lp_aux_match = lp_valid[lp_aux_idx] && (lp_tag[lp_aux_idx] == lp_aux_tag);
  logic lp_aux_act_hit;
  logic [ActBits-1:0] lp_aux_act_slot;
  logic [LoopCntBits-1:0] lp_aux_cur_iter;
  always_comb begin
    lp_aux_act_hit = 1'b0;
    lp_aux_act_slot = '0;
    for (int a = 0; a < ActiveLoops; a++) begin
      if (act_valid[a] && (act_idx[a] == lp_aux_idx)) begin
        lp_aux_act_hit = 1'b1;
        lp_aux_act_slot = ActBits'(a);
      end
    end
    lp_aux_cur_iter = lp_aux_act_hit ? fetch_iter[lp_aux_act_slot] : lp_arch_iter[lp_aux_idx];
  end
  assign lp_aux_override = lp_aux_match
      && (lp_conf[lp_aux_idx] == 2'd3) && (lp_trip[lp_aux_idx] >= 10'd32);
  assign lp_aux_pred_taken = (lp_aux_cur_iter != lp_trip[lp_aux_idx]);
`endif

  // Next committed arch_iter value for lp_widx (used on flush restore)
  logic [LoopCntBits-1:0] lp_arch_iter_next_c;
  always_comb begin
    lp_arch_iter_next_c = lp_arch_iter[lp_widx];
    if (cmu_bcast.ben) begin
      if (lp_c_hit) begin
        if (rbtaken) begin
          lp_arch_iter_next_c = (lp_arch_iter[lp_widx] == '1)
              ? lp_arch_iter[lp_widx] : (lp_arch_iter[lp_widx] + LoopCntBits'(1));
        end else begin
          lp_arch_iter_next_c = '0;
        end
      end else if (rbtaken && lp_is_backward) begin
        lp_arch_iter_next_c = LoopCntBits'(1);
      end
    end
  end

  // Combinational next decode_iter (used for checkpoint write and decode_recover)
  logic [LoopCntBits-1:0] decode_iter_next[ActiveLoops];
  wire f2d_pop_valid = idu_bpu.history_valid && (f2d_count != '0);
  wire f2d_pop_has_loop = f2d_pop_valid && f2d_has_loop[f2d_head];
  wire [ActBits-1:0] f2d_pop_slot = f2d_slot[f2d_head];
  always_comb begin
    for (int a = 0; a < ActiveLoops; a++) decode_iter_next[a] = decode_iter[a];
    if (f2d_pop_has_loop) begin
      decode_iter_next[f2d_pop_slot] = idu_bpu.history_taken
          ? ((decode_iter[f2d_pop_slot] == '1)
              ? decode_iter[f2d_pop_slot] : (decode_iter[f2d_pop_slot] + LoopCntBits'(1)))
          : '0;
    end
  end

  // Match execute_recover against checkpoint table (newest match wins)
  wire [15:0] exec_match_ghr = {execute_ghr[15:1], !execute_ghr[0]};
  logic exec_ckpt_hit;
  logic [CkptBits-1:0] exec_ckpt_idx;
  always_comb begin
    exec_ckpt_hit = 1'b0;
    exec_ckpt_idx = '0;
    for (int k = 0; k < CkptDepth; k++) begin
      automatic logic [CkptBits-1:0] idx = ckpt_wptr - CkptBits'(1) - CkptBits'(k);
      if (!exec_ckpt_hit && ckpt_valid[idx] && (ckpt_ghr[idx] == exec_match_ghr)) begin
        exec_ckpt_hit = 1'b1;
        exec_ckpt_idx = idx;
      end
    end
  end

  wire lp_full_flush = cmu_bcast.flush_pipe && !preserve_fetch;
  always_ff @(posedge clock) begin
    if (reset || bpu_clear) begin
      lp_valid <= '0;
      lp_rd_idx_q <= '0;
      lp_rd_match_q <= 1'b0;
      lp_rd_conf_q <= '0;
      lp_rd_trip_q <= '0;
      lp_rd_arch_q <= '0;
      act_valid <= '0;
      act_rr_ptr <= '0;
      f2d_head <= '0;
      f2d_tail <= '0;
      f2d_count <= '0;
      ckpt_valid <= '0;
      ckpt_wptr <= '0;
      for (int a = 0; a < ActiveLoops; a++) begin
        act_idx[a] <= '0;
        fetch_iter[a] <= '0;
        decode_iter[a] <= '0;
      end
    end else begin
      // Synchronous fetch lookup
      if (ifu_bpu.pc_update) begin
        lp_rd_idx_q <= lp_ridx;
        lp_rd_match_q <= lp_valid[lp_ridx] && (lp_tag[lp_ridx] == lp_rtag);
        lp_rd_conf_q <= lp_conf[lp_ridx];
        lp_rd_trip_q <= lp_trip[lp_ridx];
        lp_rd_arch_q <= lp_arch_iter[lp_ridx];
      end

      // Commit training (authoritative architectural loop state)
      if (cmu_bcast.ben) begin
        if (lp_c_hit) begin
          lp_arch_iter[lp_widx] <= lp_arch_iter_next_c;
          if (!rbtaken) begin
            if (lp_arch_iter[lp_widx] >= LoopCntBits'(2)) begin
              if (lp_trip[lp_widx] == lp_arch_iter[lp_widx]) begin
                lp_conf[lp_widx] <= (lp_conf[lp_widx] == 2'd3) ? 2'd3 : (lp_conf[lp_widx] + 2'd1);
              end else begin
                lp_trip[lp_widx] <= lp_arch_iter[lp_widx];
                lp_conf[lp_widx] <= 2'd1;
              end
            end else begin
              lp_conf[lp_widx] <= 2'd0;
            end
          end
        end else if (rbtaken && lp_is_backward) begin
          lp_valid[lp_widx] <= 1'b1;
          lp_tag[lp_widx] <= lp_wtag;
          lp_trip[lp_widx] <= '0;
          lp_conf[lp_widx] <= 2'd0;
          lp_arch_iter[lp_widx] <= LoopCntBits'(1);
        end
      end

      // Speculative state & checkpoint rollback
      if (lp_full_flush) begin
        f2d_head <= '0;
        f2d_tail <= '0;
        f2d_count <= '0;
        ckpt_valid <= '0;
        for (int a = 0; a < ActiveLoops; a++) begin
          automatic
          logic [LoopCntBits-1:0]
          arch_v =
              (cmu_bcast.ben && act_idx[a] == lp_widx)
              ? lp_arch_iter_next_c : lp_arch_iter[act_idx[a]];
          fetch_iter[a] <= arch_v;
          decode_iter[a] <= arch_v;
        end
      end else if (execute_recover) begin
        f2d_head <= '0;
        f2d_tail <= '0;
        f2d_count <= '0;
        if (exec_ckpt_hit) begin
          for (int a = 0; a < ActiveLoops; a++) begin
            automatic logic [LoopCntBits-1:0] rval = ckpt_iter[exec_ckpt_idx][a];
            if (ckpt_has_loop[exec_ckpt_idx] && (ActBits'(a) == ckpt_slot[exec_ckpt_idx])) begin
              rval = execute_ghr[0]
                  ? ((ckpt_iter_before[exec_ckpt_idx] == '1)
                      ? ckpt_iter_before[exec_ckpt_idx]
                      : (ckpt_iter_before[exec_ckpt_idx] + LoopCntBits'(1)))
                  : '0;
            end
            fetch_iter[a] <= rval;
            decode_iter[a] <= rval;
          end
        end else begin
          for (int a = 0; a < ActiveLoops; a++) begin
            automatic
            logic [LoopCntBits-1:0]
            arch_v =
                (cmu_bcast.ben && act_idx[a] == lp_widx)
                ? lp_arch_iter_next_c : lp_arch_iter[act_idx[a]];
            fetch_iter[a] <= arch_v;
            decode_iter[a] <= arch_v;
          end
        end
      end else if (idu_bpu.history_recover) begin
        f2d_head <= '0;
        f2d_tail <= '0;
        f2d_count <= '0;
        for (int a = 0; a < ActiveLoops; a++) begin
          decode_iter[a] <= decode_iter_next[a];
          fetch_iter[a] <= decode_iter_next[a];
        end
        if (idu_bpu.history_valid) begin
          ckpt_valid[ckpt_wptr] <= 1'b1;
          ckpt_ghr[ckpt_wptr] <= snapshot_ghr[15:0];
          for (int a = 0; a < ActiveLoops; a++) ckpt_iter[ckpt_wptr][a] <= decode_iter_next[a];
          ckpt_has_loop[ckpt_wptr] <= f2d_pop_has_loop;
          ckpt_slot[ckpt_wptr] <= f2d_pop_slot;
          ckpt_iter_before[ckpt_wptr] <= decode_iter[f2d_pop_slot];
          ckpt_wptr <= ckpt_wptr + CkptBits'(1);
        end
      end else begin
        automatic logic push_en = ifu_bpu.history_valid && (f2d_count < (F2dBits + 1)'(F2dDepth));
        automatic logic pop_en  = f2d_pop_valid;
        if (pop_en) begin
          f2d_head <= f2d_head + F2dBits'(1);
          for (int a = 0; a < ActiveLoops; a++) decode_iter[a] <= decode_iter_next[a];
        end
        if (push_en) begin
          automatic logic [ActBits-1:0] use_slot = lp_upd_act_hit ? lp_upd_act_slot : act_rr_ptr;
          f2d_has_loop[f2d_tail] <= lp_upd_hit;
          f2d_slot[f2d_tail] <= use_slot;
          f2d_tail <= f2d_tail + F2dBits'(1);
          if (lp_upd_hit) begin
            automatic
            logic [LoopCntBits-1:0]
            base_i = lp_upd_act_hit ? fetch_iter[lp_upd_act_slot] : lp_arch_iter[lp_upd_idx];
            if (!lp_upd_act_hit) begin
              act_valid[use_slot] <= 1'b1;
              act_idx[use_slot] <= lp_upd_idx;
              decode_iter[use_slot] <= lp_arch_iter[lp_upd_idx];
              act_rr_ptr <= act_rr_ptr + ActBits'(1);
            end
            fetch_iter[use_slot] <= ifu_bpu.history_taken
                ? ((base_i == '1) ? base_i : (base_i + LoopCntBits'(1)))
                : '0;
          end
        end
        if (idu_bpu.history_valid) begin
          ckpt_valid[ckpt_wptr] <= 1'b1;
          ckpt_ghr[ckpt_wptr] <= snapshot_ghr[15:0];
          for (int a = 0; a < ActiveLoops; a++) ckpt_iter[ckpt_wptr][a] <= decode_iter_next[a];
          ckpt_has_loop[ckpt_wptr] <= f2d_pop_has_loop;
          ckpt_slot[ckpt_wptr] <= f2d_pop_slot;
          ckpt_iter_before[ckpt_wptr] <= decode_iter[f2d_pop_slot];
          ckpt_wptr <= ckpt_wptr + CkptBits'(1);
        end
        f2d_count <= f2d_count + (F2dBits + 1)'(push_en) - (F2dBits + 1)'(pop_en);
      end
    end
  end

  // Prediction logic: all inputs are registered sub-module outputs,
  // NO combinational dependency on pc_ifu/fpc.
  assign btb_tag_match = btb_rd_tag_match;
  assign taken = btb_tag_match && ((btb_rd_type != COND) || cond_taken);

  // Fetch and decode represent different instruction-stream positions. Never
  // override a fetch target with the decode RAS's live top: a preceding return
  // may already have popped it, or a call may not yet have reached decode.
  // Fetch uses its request-aligned BTB result; IDU repairs/trains return targets
  // with its own ordered RAS. A future fetch RAS needs checkpoints + rollback.
  assign npc = (btb_rd_type == INDR && itt_rd_hit_q)
      ? {itt_rd_target_q, 1'b0} : {btb_rd_target, 1'b0};

  // Commit-path index computation
  assign rbtb_idx = rpc[BTB_LEN-1+1:1] ^ rpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign rbtb_tag = btb_tag_of(rpc);

  assign ifu_bpu.taken = taken;
  assign ifu_bpu.npc = npc;

  assign rpc = cmu_bcast.rpc;
  assign rbtaken = cmu_bcast.btaken;
  assign cpc = cmu_bcast.cpc;

  // Independent committed data is necessary: pointer-only repair cannot undo
  // a wrong-path push that overwrote a still-live committed return address.
  logic [PcW-1:0] rsb_push_addr;
  assign rsb_push_addr = rpc + (cmu_bcast.rvc ? PcW'(2) : PcW'(4));
  rapt_ras #(
      .Depth(RSB_SIZE),
      .Xlen (PcW)
  ) u_ras (
      .clock(clock),
      .reset(reset),
      .clear((`RAPT_SFENCE_KEEP_STATE < 3 && cmu_bcast.fence_time)),
      .flush(cmu_bcast.flush_pipe),
      .spec_push(idu_bpu.push_en),
      .spec_pop(idu_bpu.pop_en),
      .spec_addr(idu_bpu.push_addr),
      .commit_push(cmu_bcast.call),
      .commit_pop(cmu_bcast.ret),
      .commit_addr(rsb_push_addr),
      .top_valid(idu_bpu.ras_valid),
      .top_addr(idu_bpu.ras_addr)
  );

endmodule

`undef RAPT_BPU_DIRP_MODULE
