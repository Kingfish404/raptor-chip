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
    RETU = 'b11   // Return / coroutine pop
  } inst_t;
  typedef enum logic [1:0] {
    SN = 'b00,  // Strongly Not Taken
    WN = 'b01,  // Weakly Not Taken
    WT = 'b10,  // Weakly Taken
    ST = 'b11   // Strongly Taken
  } pht_t;

  logic [XLEN-1:0] npc;

  logic [GHR_LEN-1:0] rgshare;
  logic [GHR_LEN-1:0] gshare;
  // Fetch and committed history observations. The history module also retains
  // a decode watermark, so an IDU resteer can discard fetch-only speculation.
  logic [PHR_LEN-1:0] phr;
  logic [PHR_LEN-1:0] rphr;
  logic [BTB_LEN-1:0] rbtb_idx;
  logic [BTB_TAG_LEN-1:0] rbtb_tag;
  logic is_b;
  logic btaken;
  logic btb_tag_match;
  logic taken;
  logic rbtaken;

`ifdef RAPT_FETCH_LOOKAHEAD
  // Side predictor for a packet's non-first conditional branch. Unlike the
  // synchronous primary TAGE/BTB path, this table is read combinationally
  // because its position is only known after the L1I response arrives. The target
  // remains a static branch immediate in IFU, so no second BTB port is needed.
  logic [1:0] aux_pht[PHT_SIZE];
  logic [PHT_LEN-1:0] aux_pht_idx;
  logic [PHT_LEN-1:0] aux_pht_update_idx;
  assign aux_pht_idx = ifu_bpu.aux_pc[PHT_LEN:1];
  assign aux_pht_update_idx = cmu_bcast.rpc[PHT_LEN:1];
  assign ifu_bpu.aux_taken = ifu_bpu.aux_query && aux_pht[aux_pht_idx][1];
`endif

  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;

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
  rapt_predict_history #(
      .GhrBits(GHR_LEN),
      .PhrBits(PHR_LEN)
  ) u_history (
      .clock(clock),
      .reset(reset),
      .clear(cmu_bcast.fence_time),
      .flush(cmu_bcast.flush_pipe || cmu_bcast.sys_resume),
      .decode_recover(idu_bpu.history_recover),
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
      .decode_ghr(),
      .decode_phr(),
      .commit_ghr(rgshare),
      .commit_phr(rphr),
      .query_ghr(dirp_read_ghr),
      .query_phr(dirp_read_phr)
  );
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
  // RETU identifies a return/coroutine target; IDU supplies RAS repair/training.
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

  // Fetch and decode represent different instruction-stream positions. Never
  // override a fetch target with the decode RAS's live top: a preceding return
  // may already have popped it, or a call may not yet have reached decode.
  // Fetch uses its request-aligned BTB result; IDU repairs/trains return targets
  // with its own ordered RAS. A future fetch RAS needs checkpoints + rollback.
  assign npc = {btb_rd_target, 1'b0};

  // Commit-path index computation
  assign rbtb_idx = rpc[BTB_LEN-1+1:1] ^ rpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign rbtb_tag = rpc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];

  assign ifu_bpu.taken = taken;
  assign ifu_bpu.npc = npc;

`ifdef RAPT_FETCH_LOOKAHEAD
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.fence_time) begin
      for (int i = 0; i < PHT_SIZE; i++) aux_pht[i] <= WN;
    end else if (cmu_bcast.ben) begin
      if (rbtaken) begin
        if (aux_pht[aux_pht_update_idx] != ST)
          aux_pht[aux_pht_update_idx] <= aux_pht[aux_pht_update_idx] + 1'b1;
      end else begin
        if (aux_pht[aux_pht_update_idx] != SN)
          aux_pht[aux_pht_update_idx] <= aux_pht[aux_pht_update_idx] - 1'b1;
      end
    end
  end
`endif

  assign rpc = cmu_bcast.rpc;
  assign rbtaken = cmu_bcast.btaken;
  assign cpc = cmu_bcast.cpc;

  // Independent committed data is necessary: pointer-only repair cannot undo
  // a wrong-path push that overwrote a still-live committed return address.
  logic [XLEN-1:0] rsb_push_addr;
  assign rsb_push_addr = rpc + (cmu_bcast.rvc ? XLEN'(2) : XLEN'(4));
  rapt_ras #(
      .Depth(RSB_SIZE),
      .Xlen(XLEN)
  ) u_ras (
      .clock(clock),
      .reset(reset),
      .clear(cmu_bcast.fence_time),
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
