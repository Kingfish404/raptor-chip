module tb_l2_mshr_scheduler;
  localparam int NumMshrs  = 7;
  localparam int SetBits   = 10;
  localparam int MshrBits  = 3;
  localparam int QueueBits = 5;
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic request_valid = 1'b0;
  logic request_ready;
  logic [2:0] request_prio = 3'b001;
  logic [SetBits-1:0] request_set = 10'd5;
  logic [17:0] request_tag = 18'd3;
  logic [NumMshrs-1:0] mshr_valid = '0;
  logic [SetBits-1:0] mshr_set[NumMshrs];
  logic [17:0] mshr_tag[NumMshrs];
  logic [NumMshrs-1:0] mshr_block_b = '0;
  logic [NumMshrs-1:0] mshr_block_c = '0;
  logic [NumMshrs-1:0] mshr_nest_b = '0;
  logic [NumMshrs-1:0] mshr_nest_c = '0;
  logic secondary_push_ready = 1'b1;
  logic [3*NumMshrs-1:0] secondary_queue_valid = '0;
  logic [17:0] secondary_head_tag = 18'd3;
  logic secondary_push_valid;
  logic [QueueBits-1:0] secondary_push_index;
  logic secondary_pop_valid;
  logic [QueueBits-1:0] secondary_pop_index;
  logic allocate_valid;
  logic [MshrBits-1:0] allocate_index;
  logic [NumMshrs-1:0] schedule_request = '0;
  logic [NumMshrs-1:0] schedule_resources_ready = '1;
  logic [NumMshrs-1:0] schedule_reload = '0;
  logic schedule_valid;
  logic [MshrBits-1:0] schedule_index;
  logic [NumMshrs-1:0] schedule_onehot;
  logic [NumMshrs-1:0] schedule_stalled;
  logic reload_valid;
  logic reload_from_request;
  logic reload_needs_directory;

  rapt_l2_mshr_scheduler dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  initial begin
    for (int slot = 0; slot < NumMshrs; slot++) begin
      mshr_set[slot] = '0;
      mshr_tag[slot] = '0;
    end
    tick(3);
    reset = 1'b0;
    request_valid = 1'b1;
    #1;
    check(request_ready && allocate_valid && allocate_index == 0,
          "first ordinary miss did not allocate normal MSHR 0");

    mshr_valid[0] = 1'b1;
    mshr_set[0] = request_set;
    mshr_tag[0] = request_tag;
    #1;
    check(request_ready && secondary_push_valid && !allocate_valid && secondary_push_index == 0,
          "same-set A request was not queued to normal MSHR 0");
    secondary_push_ready = 1'b0;
    #1;
    check(!request_ready && secondary_push_valid, "full secondary list did not backpressure A");
    secondary_push_ready = 1'b1;

    request_prio = 3'b010;
    mshr_nest_b[0] = 1'b1;
    #1;
    check(request_ready && allocate_valid && allocate_index == 5,
          "nested B did not select its reserved BC MSHR");
    mshr_valid[6] = 1'b1;
    mshr_set[6] = 10'd9;
    #1;
    check(!request_ready, "nested B ignored a busy C reservation");
    mshr_valid[6] = 1'b0;
    mshr_nest_b = '0;
    mshr_block_b[0] = 1'b1;
    #1;
    check(!request_ready && !secondary_push_valid, "blocked B was incorrectly queued");
    mshr_block_b = '0;

    request_prio = 3'b100;
    mshr_nest_c[0] = 1'b1;
    #1;
    check(request_ready && allocate_valid && allocate_index == 6,
          "nested C did not select its reserved C MSHR");
    mshr_nest_c = '0;
    mshr_valid[5] = 1'b1;
    mshr_set[5] = request_set;
    #1;
    check(request_ready && secondary_push_valid && secondary_push_index == QueueBits'(19),
          "same-set C request did not select the BC queue at C priority");

    request_prio = 3'b001;
    request_set = 10'd8;
    for (int slot = 0; slot < 5; slot++) begin
      mshr_valid[slot] = 1'b1;
      mshr_set[slot] = 10'(slot);
    end
    #1;
    check(!request_ready, "A request consumed a reserved BC/C MSHR");
    request_prio = 3'b010;
    mshr_valid[5] = 1'b0;
    #1;
    check(request_ready && allocate_valid && allocate_index == 5,
          "B request could not use its BC reservation");
    request_prio = 3'b100;
    mshr_valid[5] = 1'b1;
    #1;
    check(request_ready && allocate_valid && allocate_index == 6,
          "C request could not use its C reservation");
    request_valid = 1'b0;

    schedule_request = 7'b0000011;
    #1;
    check(schedule_valid && schedule_onehot == 7'b0000001,
          "round-robin scheduling did not begin at MSHR 0");
    tick(1);
    check(schedule_onehot == 7'b0000010, "round-robin scheduling did not advance");
    tick(1);
    check(schedule_onehot == 7'b0000001, "round-robin scheduling did not wrap");
    schedule_resources_ready[0] = 1'b0;
    #1;
    check(schedule_onehot == 7'b0000010, "unavailable resources were still scheduled");

    // Reserved BC/C handlers pre-empt lower-priority work on the same set.
    schedule_resources_ready = '1;
    mshr_valid = '0;
    mshr_valid[0] = 1'b1;
    mshr_valid[5] = 1'b1;
    mshr_set[0] = 10'd5;
    mshr_set[5] = 10'd5;
    #1;
    check(schedule_stalled[0] && schedule_onehot == 7'b0000010,
          "BC reservation did not interlock ordinary MSHR 0");
    mshr_valid[6] = 1'b1;
    mshr_set[6] = 10'd5;
    #1;
    check(schedule_stalled[5], "C reservation did not interlock BC MSHR");
    mshr_valid[5] = 1'b0;
    mshr_valid[6] = 1'b0;
    schedule_request = 7'b0000001;
    schedule_reload[0] = 1'b1;
    secondary_queue_valid[0] = 1'b1;
    secondary_queue_valid[7] = 1'b1;
    secondary_queue_valid[14] = 1'b1;
    request_valid = 1'b0;
    #1;
    check(reload_valid && secondary_pop_valid && secondary_pop_index == QueueBits'(14),
          "C secondary request was not replayed before B and A");
    secondary_queue_valid[14] = 1'b0;
    #1;
    check(secondary_pop_index == QueueBits'(7), "B secondary request was not replayed before A");
    secondary_queue_valid[7] = 1'b0;
    #1;
    check(secondary_pop_index == QueueBits'(0), "A secondary request was not selected");

    // A newly arrived B request bypasses a queued A request on a reload.
    request_valid = 1'b1;
    request_prio = 3'b010;
    request_set = 10'd5;
    request_tag = 18'd4;
    mshr_tag[0] = 18'd3;
    secondary_push_ready = 1'b0;
    #1;
    check(
        request_ready && reload_valid && reload_from_request && !secondary_pop_valid
              && !secondary_push_valid && reload_needs_directory,
        "higher-priority request did not bypass a full secondary list");
    secondary_queue_valid[7] = 1'b1;
    #1;
    check(!request_ready && !reload_from_request && secondary_pop_valid,
          "new B request bypassed an older queued B request");
    secondary_queue_valid[7] = 1'b0;
    request_valid = 1'b0;
    secondary_head_tag = 18'd6;
    #1;
    check(reload_needs_directory,
          "different-tag queued request did not reserve the directory read");
    request_valid = 1'b1;
    request_set = 10'd8;
    #1;
    check(!request_ready && !allocate_valid,
          "new allocation conflicted with a queued directory reload");

    $display("PASS: BOOM 5+2 MSHR allocation, pre-emption, replay and round-robin selection");
    $finish;
  end
endmodule
