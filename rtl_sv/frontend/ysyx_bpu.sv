`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_bpu #(
    parameter int PHT_SIZE = `YSYX_PHT_SIZE,
    parameter int PHT_LEN = $clog2(PHT_SIZE),
    parameter int BTB_SIZE = `YSYX_BTB_SIZE,
    parameter int BTB_LEN = $clog2(BTB_SIZE),
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
    RETU = 'b11   // Return
  } inst_t;
  typedef enum logic [1:0] {
    SN = 'b00,  // Strongly Not Taken
    WN = 'b01,  // Weakly Not Taken
    WT = 'b10,  // Weakly Taken
    ST = 'b11   // Strongly Taken
  } pht_t;

  logic [XLEN-1:0] fpc;
  logic [XLEN-1:0] npc;

  logic [1:0] pht[PHT_SIZE];
  logic [XLEN-1:1] btb[BTB_SIZE];
  logic [BTB_TAG_LEN-1:0] btb_tag[BTB_SIZE];
  logic [BTB_SIZE-1:0] btb_v;
  inst_t btb_t[BTB_SIZE];
  logic [XLEN-1:0] rsb[RSB_SIZE];
  logic [RSB_SIZE-1:0] rsb_v;
  logic [$clog2(RSB_SIZE)-1:0] rsb_idx;

  logic [GHR_LEN-1:0] rgshare;
  logic [GHR_LEN-1:0] gshare;
  logic [PHT_LEN-1:0] fpht_idx;
  logic [BTB_LEN-1:0] fbtb_idx;
  logic [BTB_TAG_LEN-1:0] fbtb_tag;
  logic [PHT_LEN-1:0] rpht_idx;
  logic [BTB_LEN-1:0] rbtb_idx;
  logic [BTB_TAG_LEN-1:0] rbtb_tag;
  logic is_b;
  logic btaken;
  logic btb_valid;
  logic taken;
  logic rbtaken;

  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;

  /* verilator lint_on UNUSEDSIGNAL */

  assign fpc = ifu_bpu.pc;
  assign is_b = (btb_t[fbtb_idx] == COND);
  assign btaken = (btb_t[fbtb_idx] == COND && pht[fpht_idx][1:1]);
  assign btb_valid = btb_v[fbtb_idx] && (fbtb_tag == btb_tag[fbtb_idx]);
  assign taken = (btb_valid && ((btb_t[fbtb_idx] != COND) || btaken));
  assign npc = {btb[fbtb_idx], 1'b0};

  assign fpht_idx = fpc[PHT_LEN-1+1:1];
  assign rpht_idx = rpc[PHT_LEN-1+1:1];
  // assign fpht_idx = {fpc[PHT_LEN-1+1:1] ^ gshare[PHT_LEN-1:0]};
  // assign rpht_idx = {rpc[PHT_LEN-1+1:1] ^ rgshare[PHT_LEN-1:0]};
  assign fbtb_idx = fpc[BTB_LEN-1+1:1] ^ fpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign fbtb_tag = fpc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];
  assign rbtb_idx = rpc[BTB_LEN-1+1:1] ^ rpc[2*BTB_LEN-1+1:BTB_LEN+1];
  assign rbtb_tag = rpc[BTB_LEN+1+BTB_TAG_LEN-1:BTB_LEN+1];

  assign ifu_bpu.taken = taken;
  assign ifu_bpu.npc = npc;

  assign rpc = cmu_bcast.rpc;
  assign rbtaken = cmu_bcast.btaken;
  assign cpc = cmu_bcast.cpc;

  always @(posedge clock) begin
    if (reset || cmu_bcast.fence_time) begin
      for (int i = 0; i < PHT_SIZE; i++) begin
        pht[i] <= 'b00;
      end
      for (int i = 0; i < BTB_SIZE; i++) begin
        btb_t[i] <= COND;
      end
      btb_v <= 0;
    end else begin
      if (cmu_bcast.flush_pipe) begin
        gshare <= {rgshare[GHR_LEN-2:0], {rbtaken}};
      end else if (is_b && btb_valid) begin
        gshare <= {gshare[GHR_LEN-2:0], {btaken}};
      end
      if (cmu_bcast.flush_pipe) begin
        if (cmu_bcast.jen || rbtaken) begin
          btb_v[rbtb_idx] <= 1;
          btb_tag[rbtb_idx] <= rbtb_tag;
          btb[rbtb_idx] <= cpc[XLEN-1:1];
        end
      end
      if (cmu_bcast.jren) begin
        btb_t[rbtb_idx] <= INDR;
      end else if (cmu_bcast.jen) begin
        btb_t[rbtb_idx] <= DIRE;
      end else if (cmu_bcast.ben && rbtaken) begin
        btb_t[rbtb_idx] <= COND;
      end
      if (cmu_bcast.ben) begin
        rgshare <= {rgshare[GHR_LEN-2:0], {rbtaken}};
        if (rbtaken) begin
          if (pht[rpht_idx] != 'b11) begin
            pht[rpht_idx] <= pht[rpht_idx] + 1;
          end else begin
          end
        end else begin
          if (pht[rpht_idx] != 'b00) begin
            pht[rpht_idx] <= pht[rpht_idx] - 1;
          end else begin
          end
        end
      end
    end
  end

endmodule
