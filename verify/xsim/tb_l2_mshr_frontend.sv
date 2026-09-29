module tb_l2_mshr_frontend;
  localparam int NumMshrs = 7;
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic request_valid = 1'b0;
  logic request_ready;
  logic [2:0] request_prio = 3'b001;
  logic [9:0] request_set = 10'd5;
  logic [17:0] request_tag = '0;
  logic [31:0] request_payload = '0;
  logic [NumMshrs-1:0] mshr_valid = '0;
  logic [9:0] mshr_set[NumMshrs];
  logic [17:0] mshr_tag[NumMshrs];
  logic [NumMshrs-1:0] mshr_block_b = '0;
  logic [NumMshrs-1:0] mshr_block_c = '0;
  logic [NumMshrs-1:0] mshr_nest_b = '0;
  logic [NumMshrs-1:0] mshr_nest_c = '0;
  logic [NumMshrs-1:0] schedule_request = '0;
  logic [NumMshrs-1:0] schedule_resources_ready = '1;
  logic [NumMshrs-1:0] schedule_reload = '0;
  logic allocate_valid;
  logic [2:0] allocate_index;
  logic schedule_valid;
  logic [2:0] schedule_index;
  logic [NumMshrs-1:0] schedule_onehot;
  logic [NumMshrs-1:0] schedule_stalled;
  logic reload_valid;
  logic reload_from_request;
  logic reload_needs_directory;
  logic [17:0] reload_tag;
  logic [31:0] reload_payload;
  logic secondary_push_ready;
  logic [3*NumMshrs-1:0] secondary_queue_valid;

  rapt_l2_mshr_frontend #(.PayloadBits(32)) dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic enqueue(input logic [2:0] prio, input logic [17:0] tag,
                         input logic [31:0] payload);
    request_valid = 1'b1;
    request_prio = prio;
    request_tag = tag;
    request_payload = payload;
    #1;
    check(request_ready && !allocate_valid, "secondary request was not admitted");
    tick(1);
  endtask

  task automatic replay(input logic [17:0] tag, input logic [31:0] payload);
    #1;
    check(
        reload_valid && !reload_from_request && reload_needs_directory
              && reload_tag == tag && reload_payload == payload,
        "secondary replay returned the wrong request");
    tick(1);
  endtask

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
          "first primary miss did not allocate MSHR 0");
    mshr_valid[0] = 1'b1;
    mshr_set[0] = request_set;
    mshr_tag[0] = 18'd1;

    enqueue(3'b001, 18'd2, 32'haaaa_0001);
    enqueue(3'b001, 18'd3, 32'haaaa_0002);
    enqueue(3'b010, 18'd4, 32'hbbbb_0001);
    enqueue(3'b100, 18'd5, 32'hcccc_0001);
    request_valid = 1'b0;
    schedule_request[0] = 1'b1;
    schedule_reload[0] = 1'b1;
    replay(18'd5, 32'hcccc_0001);
    replay(18'd4, 32'hbbbb_0001);
    replay(18'd2, 32'haaaa_0001);
    replay(18'd3, 32'haaaa_0002);
    #1;
    check(!reload_valid && secondary_queue_valid == '0, "secondary queues did not drain");

    schedule_request = '0;
    enqueue(3'b001, 18'd6, 32'haaaa_0003);
    request_prio = 3'b010;
    request_tag = 18'd7;
    request_payload = 32'hbbbb_0002;
    schedule_request[0] = 1'b1;
    request_valid = 1'b1;
    #1;
    check(
        request_ready && reload_valid && reload_from_request
              && reload_tag == 18'd7 && reload_payload == 32'hbbbb_0002,
        "B request did not bypass the queued A request");
    tick(1);
    request_valid = 1'b1;
    request_set = 10'd8;
    #1;
    check(!request_ready && !allocate_valid,
          "new primary miss conflicted with the queued A directory read");
    request_valid = 1'b0;
    replay(18'd6, 32'haaaa_0003);
    $display("PASS: BOOM-sized MSHR admission, C/B/A replay and bypass fabric");
    $finish;
  end
endmodule
