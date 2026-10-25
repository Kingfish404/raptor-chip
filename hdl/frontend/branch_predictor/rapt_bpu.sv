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
    parameter int BTB_TAG_LEN = 7,
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
    input logic execute_recover = 1'b0,
    input logic preserve_fetch = 1'b0,
    input logic [`RAPT_PC_BITS_OF(XLEN)-1:1] decode_target_q = '0,
    input logic [GHR_LEN-1:0] execute_ghr = '0,
    input logic [PHR_LEN-1:0] execute_phr = '0,
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
  assign ifu_bpu.aux_taken = ifu_bpu.aux_query && dirp_aux_taken;
`endif

  logic [PcW-1:0] rpc;
  logic [PcW-1:0] cpc;

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

  // IDU training pulse: derive matching index/tag from train_pc.
  logic                   idu_wen;
  logic [    BTB_LEN-1:0] idu_waddr;
  logic [BTB_TAG_LEN-1:0] idu_wd_tag;
  logic idu_wen_q;
  logic [PcW-1:1] idu_target_q;
  logic [1:0] idu_type_q;
  // Decode training follows its registered redirect. Store only the BTB key,
  // not another full PC, and let an older recovery cancel the pending write.
  assign idu_wen = idu_wen_q && !cmu_bcast.flush_pipe && !execute_recover;
  always_ff @(posedge clock) begin
    idu_wen_q <= idu_bpu.train_en && !reset;
    idu_waddr <= idu_bpu.train_pc[BTB_LEN:1] ^ idu_bpu.train_pc[2*BTB_LEN:BTB_LEN+1];
    idu_wd_tag <= idu_bpu.train_pc[BTB_LEN+BTB_TAG_LEN:BTB_LEN+1];
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
  logic wen_entry_mux, wen_type_mux;
  logic [    BTB_LEN-1:0] waddr_mux;
  logic [       PcW-1:1] wd_target_mux;
  logic [BTB_TAG_LEN-1:0] wd_tag_mux;
  logic [            1:0] wd_type_mux;
  logic                   idu_grant;
  assign idu_grant     = idu_wen && !cmu_wen_entry;
  assign wen_entry_mux = cmu_wen_entry || idu_grant;
  assign wen_type_mux  = cmu_wen_type || idu_grant;
  // idu_grant already excludes a commit entry write.
  assign waddr_mux     = idu_grant ? idu_waddr : cmu_waddr;
  assign wd_target_mux = cmu_wen_entry ? cmu_wd_full : idu_target_q;
  assign wd_tag_mux    = idu_grant ? idu_wd_tag : cmu_wd_tag;
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
      .waddr(waddr_mux),
      .wd_target(wd_target_mux),
      .wd_tag(wd_tag_mux),
      .wen_type(wen_type_mux),
      .wd_type(wd_type_mux),
      .init((`RAPT_SFENCE_KEEP_STATE < 3 && cmu_bcast.fence_time))
  );

  // Prediction logic: all inputs are registered sub-module outputs,
  // NO combinational dependency on pc_ifu/fpc.
  assign btb_tag_match = btb_rd_tag_match;
  assign taken = btb_tag_match && ((btb_rd_type != COND) || dirp_taken);

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
