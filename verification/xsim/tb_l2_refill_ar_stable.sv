`include "rapt.svh"
module tb_l2_refill_ar_stable #(
    parameter int XLEN = `RAPT_XLEN
);
  localparam int NumMshrs = XLEN == 64 ? 7 : 5;
  localparam int ID_W = 4;
  localparam int LineWords = 64 / (XLEN / 8);
  localparam int WrapBits = $clog2(16 * (XLEN / 8));
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic alloc_valid = 1'b0;
  logic alloc_ready;
  logic alloc_reload = 1'b0;
  logic [2:0] alloc_slot = '0;
  logic retry_valid = 1'b0;
  logic [2:0] retry_slot = '0;
  logic [XLEN-1:0] alloc_addr = '0;
  logic [ID_W-1:0] alloc_inner_id = '0;
  logic [7:0] alloc_inner_len = '0;
  logic [2:0] alloc_inner_size = '0;
  logic [WrapBits-1:0] alloc_inner_wrap_mask = '0;
  logic [1:0] alloc_inner_burst = 2'b01;
  logic [3:0] alloc_cache = 4'hf;
  logic outer_arvalid;
  logic outer_arready = 1'b1;
  logic [XLEN-1:0] outer_araddr;
  logic [ID_W-1:0] outer_arid;
  logic [7:0] outer_arlen;
  logic [2:0] outer_arsize;
  logic [1:0] outer_arburst;
  logic [3:0] outer_arcache;
  logic outer_rvalid = 1'b0;
  logic outer_rready;
  logic outer_store_ready = 1'b1;
  logic [$clog2(LineWords)-1:0] outer_rbeat;
  logic [ID_W-1:0] outer_rid = '0;
  logic [XLEN-1:0] outer_rdata = '0;
  logic [1:0] outer_rresp = '0;
  logic outer_rlast = 1'b0;
  logic [NumMshrs-1:0] slot_valid;
  logic [NumMshrs-1:0] slot_done;
  logic [NumMshrs-1:0] slot_critical_ready;
  logic [LineWords-1:0] slot_beat_valid[NumMshrs];
  logic [1:0] slot_resp[NumMshrs];
  logic retire_valid = 1'b0;
  logic [2:0] retire_slot = '0;
  logic [LineWords-1:0] retire_beat_valid;
  logic [511:0] retire_line;
  logic [1:0] retire_resp;
  logic [XLEN-1:0] retire_addr;
  logic [ID_W-1:0] retire_inner_id;
  logic [7:0] retire_inner_len;
  logic [2:0] retire_inner_size;
  logic [WrapBits-1:0] retire_inner_wrap_mask;
  logic [1:0] retire_inner_burst;
  logic [3:0] retire_cache;
  logic [NumMshrs-1:0] ar_seen = '0;

  rapt_l2_refill_mshrs #(
      .XLEN    (XLEN),
      .NumMshrs(NumMshrs)
  ) dut (
      .*
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"

  always_ff @(posedge clock) begin
    if (reset) ar_seen <= '0;
    else if (outer_arvalid && outer_arready) ar_seen[outer_arid[2:0]] <= 1'b1;
  end

  // A lower-numbered allocation must not preempt an advertised stalled AR.
  initial begin
    tick(3);
    reset = 1'b0;
    outer_arready = 1'b0;
    alloc_valid = 1'b1;
    alloc_slot = 3'd2;
    alloc_addr = XLEN'('h8000_0080);
    tick(1);
    alloc_valid = 1'b0;
    check(outer_arvalid && outer_arid == 4'd2, "first refill AR missing");
    tick(1);
    alloc_valid = 1'b1;
    alloc_slot = 3'd0;
    alloc_addr = XLEN'('h8000_0000);
    tick(1);
    alloc_valid = 1'b0;
    check(outer_arvalid && outer_arid == 4'd2 && outer_araddr == XLEN'('h8000_0080),
          "stalled refill AR changed when a higher-priority slot was allocated");
    tick(3);
    outer_arready = 1'b1;
    tick(1);
    check(ar_seen[2], "held refill was not accepted first");
    check(outer_arvalid && outer_arid == 4'd0, "pending refill did not follow without a bubble");
    tick(1);
    check(ar_seen[0] && !outer_arvalid, "pending refill was not accepted exactly once");
    $display("PASS: L2 refill AR remains stable under competing allocations RV%0d", XLEN);
    $finish;
  end
endmodule
