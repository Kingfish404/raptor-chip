`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_bpu #(
    parameter int PHT_SIZE = `YSYX_PHT_SIZE,
    parameter int PHT_LEN = $clog2(PHT_SIZE),
    parameter int BTB_SIZE = `YSYX_BTB_SIZE,
    parameter int BTB_WAYS = 2,
    parameter int BTB_LEN = $clog2(BTB_SIZE / BTB_WAYS),
    parameter int BTB_TAG_LEN = 7,
    parameter int GHR_LEN = 11,
    parameter int RSB_SIZE = `YSYX_RSB_SIZE,
    parameter int XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_bpu_if.in ifu_bpu,

    input reset
);
  /* verilator lint_off UNUSEDSIGNAL */
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
  logic [PHT_LEN-1:0] rpht_idx;
  logic [BTB_LEN-1:0] rbtb_idx;
  logic [BTB_TAG_LEN-1:0] rbtb_tag;
  logic is_b;
  logic btaken;
  logic btb_tag_match;
  logic taken;
  logic rbtaken;

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

  logic [PHT_LEN-1:0] fpht_raddr;
  logic [BTB_LEN-1:0] fbtb_raddr;
  logic [BTB_TAG_LEN-1:0] fbtb_rtag;
  assign fpht_raddr = ifu_bpu.nextpc[PHT_LEN-1+1:1];
  assign fbtb_raddr = ifu_bpu.nextpc[BTB_LEN-1+1:1] ^ ifu_bpu.nextpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign fbtb_rtag  = ifu_bpu.nextpc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];

  // PHT (synchronous read, saturating counter update)
  logic [1:0] pht_rdata;
  ysyx_bpu_pht #(
      .DEPTH(PHT_SIZE)
  ) u_pht (
      .clock(clock),
      .reset(reset),
      .ren(ifu_bpu.pc_update),
      .raddr(fpht_raddr),
      .rdata(pht_rdata),
      .update_en(cmu_bcast.ben),
      .update_taken(rbtaken),
      .update_addr(rpht_idx),
      .init(cmu_bcast.fence_time)
  );

  // BTB (synchronous read, separate entry/type writes)
  logic [XLEN-1:1] btb_rd_target;
  logic [1:0] btb_rd_type;
  logic btb_rd_tag_match;

  logic [1:0] btb_wd_type;
  assign btb_wd_type = cmu_bcast.jren ? INDR : cmu_bcast.jen ? DIRE : COND;

  ysyx_bpu_btb #(
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
      .wen_entry(cmu_bcast.flush_pipe && (cmu_bcast.jen || cmu_bcast.jren || rbtaken)),
      .waddr(rbtb_idx),
      .wd_target(cpc[XLEN-1:1]),
      .wd_tag(rbtb_tag),
      .wen_type(cmu_bcast.jren || cmu_bcast.jen || (cmu_bcast.ben && rbtaken)),
      .wd_type(btb_wd_type),
      .init(cmu_bcast.fence_time)
  );

  // Prediction logic: all inputs are registered sub-module outputs,
  // NO combinational dependency on pc_ifu/fpc.
  assign is_b = (btb_rd_type == COND);
  assign btaken = (btb_rd_type == COND && pht_rdata[1:1]);
  assign btb_tag_match = btb_rd_tag_match;
  assign taken = (btb_tag_match && ((btb_rd_type != COND) || btaken));
  assign npc = {btb_rd_target, 1'b0};

  // Commit-path index computation
  assign rpht_idx = rpc[PHT_LEN-1+1:1];
  assign rbtb_idx = rpc[BTB_LEN-1+1:1] ^ rpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign rbtb_tag = rpc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];

  assign ifu_bpu.taken = taken;
  assign ifu_bpu.npc = npc;

  assign rpc = cmu_bcast.rpc;
  assign rbtaken = cmu_bcast.btaken;
  assign cpc = cmu_bcast.cpc;

  // Return address for RSB push (call PC + instruction length)
  logic [XLEN-1:0] rsb_push_addr;
  assign rsb_push_addr = rpc + (cmu_bcast.rvc ? XLEN'(2) : XLEN'(4));

  // Next committed RSB index (accounts for this cycle's commit)
  logic [$clog2(RSB_SIZE)-1:0] next_rsb_cmt_idx;
  assign next_rsb_cmt_idx = cmu_bcast.call ? (rsb_cmt_idx + 1'b1) :
                             cmu_bcast.ret  ? (rsb_cmt_idx - 1'b1) :
                             rsb_cmt_idx;

  always @(posedge clock) begin
    if (reset) begin
      rsb_cmt_idx  <= '0;
      rsb_spec_idx <= '0;
      rsb_v        <= '0;
      gshare       <= '0;
      rgshare      <= '0;
      pred_valid   <= 0;
    end else if (!cmu_bcast.fence_time) begin
      pred_valid <= ifu_bpu.pc_update;

      // --- Committed RSB data + pointer ---
      if (cmu_bcast.call) begin
        rsb[rsb_cmt_idx]   <= rsb_push_addr;
        rsb_v[rsb_cmt_idx] <= 1'b1;
      end
      rsb_cmt_idx <= next_rsb_cmt_idx;

      // --- Speculative RSB pointer ---
      if (cmu_bcast.flush_pipe) begin
        rsb_spec_idx <= next_rsb_cmt_idx;
      end

      // --- GHR update (preserved for future gshare with larger PHT) ---
      if (cmu_bcast.flush_pipe) begin
        gshare <= {rgshare[GHR_LEN-2:0], rbtaken};
      end else if (pred_valid && is_b && btb_tag_match) begin
        gshare <= {gshare[GHR_LEN-2:0], btaken};
      end
      if (cmu_bcast.ben) begin
        rgshare <= {rgshare[GHR_LEN-2:0], rbtaken};
      end
    end
  end

endmodule
