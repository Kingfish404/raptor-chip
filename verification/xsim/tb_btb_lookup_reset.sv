`include "rapt.svh"

module tb_btb_lookup_reset;
  localparam int PcW = `RAPT_PC_BITS_OF(`RAPT_XLEN);
  localparam logic [PcW-1:1] TargetA = (PcW - 1)'('h10000020);
  localparam logic [PcW-1:1] TargetB = (PcW - 1)'('h10000040);
  localparam logic [PcW-1:1] TargetC = (PcW - 1)'('h10000060);

  logic clock = 0, reset = 1, init = 0, ren = 0;
  logic [2:0] raddr = 0, waddr = 0;
  logic [6:0] rtag = 0, wd_tag = 0;
  logic [PcW-1:1] rd_target, wd_target = 0;
  logic [1:0] rd_type, wd_type = 0;
  logic rd_tag_match, wen_entry = 0, wen_type = 0;
  int checks = 0;

  rapt_bpu_btb #(
      .DEPTH(8),
      .XLEN(`RAPT_XLEN)
  ) dut (
      .*
  );

  task automatic step;
    #1;
    clock = 1;
    #1;
    clock = 0;
    #1;
    checks++;
    if ($isunknown(dut.lru)) $fatal(1, "unknown LRU after step %0d", checks);
  endtask

  task automatic miss(input string label);
    if (rd_tag_match !== 1'b0) $fatal(1, "%s: unqualified hit %b", label, rd_tag_match);
  endtask

  task automatic hit(input logic [PcW-1:1] target, input logic [1:0] kind);
    if (rd_tag_match !== 1'b1 || rd_target !== target || rd_type !== kind)
      $fatal(
          1,
          "hit/target/type mismatch step=%0d hit=%b target=%h type=%b",
          checks,
          rd_tag_match,
          rd_target,
          rd_type
      );
  endtask

  task automatic no_forward;
    if (dut.g_way_storage[0].target_forward_valid_q !== 1'b0
        || dut.g_way_storage[1].target_forward_valid_q !== 1'b0)
      $fatal(1, "forwarding without a captured lookup step=%0d", checks);
  endtask

  initial begin
    // Exercise a real reset; no predictor state or payload is seeded by the TB.
    repeat (3) begin
      step();
      miss("reset");
      no_forward();
    end
    reset = 0;
    repeat (6) begin
      step();
      miss("idle before first lookup");
    end

    // Training is legal before any lookup. It must populate storage without
    // consulting an uninitialized held address or publishing a prediction.
    wd_target = TargetA;
    wd_type = 1;
    wen_entry = 1;
    wen_type = 1;
    step();
    miss("training before first lookup");
    no_forward();
    wen_entry = 0;
    wen_type = 0;
    step();
    miss("held before first lookup");
    no_forward();
    if (dut.lru !== 8'h01) $fatal(1, "first training victim/LRU mismatch");

    ren = 1;
    step();
    hit(TargetA, 1);
    ren = 0;
    step();
    hit(TargetA, 1);

    // A stalled lookup survives a write to a different set and then observes
    // a write to its own set through the forwarding path.
    waddr = 1;
    wd_tag = 1;
    wd_target = TargetB;
    wd_type = 2;
    wen_entry = 1;
    wen_type = 1;
    step();
    hit(TargetA, 1);
    waddr = 0;
    wd_tag = 0;
    wd_target = TargetC;
    wd_type = 3;
    step();
    hit(TargetC, 3);
    wen_entry = 0;
    wd_type = 2;
    step();
    hit(TargetC, 2);
    wen_type = 0;

    // Bulk init invalidates entries while preserving an already captured
    // lookup. A later held-address write still forwards without another ren.
    init = 1;
    step();
    miss("init");
    no_forward();
    init = 0;
    wd_target = TargetB;
    wd_type = 1;
    wen_entry = 1;
    wen_type = 1;
    step();
    hit(TargetB, 1);

    // Same-set read/write exposes the new payload, regardless of the RAM's
    // read-during-write behavior, and write-entry LRU has priority.
    ren = 1;
    raddr = 0;
    rtag = 2;
    wd_tag = 2;
    wd_target = TargetC;
    wd_type = 3;
    step();
    hit(TargetC, 3);
    if (dut.lru[0] !== 1'b0) $fatal(1, "same-set read/write LRU priority mismatch");

    // Reset discards lookup qualification, even when ren was held high.
    // Training after release again needs a new lookup to publish a result.
    reset = 1;
    step();
    miss("warm reset");
    no_forward();
    reset = 0;
    ren = 0;
    wd_tag = 0;
    wd_target = TargetA;
    wd_type = 2;
    step();
    miss("training after warm reset");
    no_forward();
    wen_entry = 0;
    wen_type = 0;
    rtag = 0;
    ren = 1;
    step();
    hit(TargetA, 2);
    $display(
        "PASS: BTB XLEN=%0d reset/first lookup, early training, held forwarding, RW/init (%0d checks)",
        `RAPT_XLEN, checks);
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "BTB lookup/reset test timeout");
  end
endmodule
