module tb_l2_secondary_buffer;
`ifdef RAPT_L2_RV32_GEOMETRY
  localparam int NumMshrs   = 5;
  localparam int NumEntries = 35;
`else
  localparam int NumMshrs   = 7;
  localparam int NumEntries = 33;
`endif
  localparam int NumQueues = 3 * NumMshrs;
  localparam int QueueBits = $clog2(NumQueues);
  localparam int LastQueue = NumQueues - 1;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic push_valid = 1'b0;
  logic push_ready;
  logic [QueueBits-1:0] push_index = '0;
  logic [15:0] push_data = '0;
  logic pop_valid = 1'b0;
  logic [QueueBits-1:0] pop_index = '0;
  logic [15:0] pop_data;
  logic [NumQueues-1:0] queue_valid;

  rapt_l2_secondary_buffer #(
      .NumMshrs  (NumMshrs),
      .NumEntries(NumEntries),
      .DataBits  (16)
  ) dut (
      .*
  );

  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic push(input int queue, input logic [15:0] value);
    push_index = QueueBits'(queue);
    push_data  = value;
    push_valid = 1'b1;
    #1;
    check(push_ready, "secondary buffer unexpectedly full");
    tick(1);
    push_valid = 1'b0;
  endtask

  task automatic pop(input int queue, input logic [15:0] expected);
    pop_index = QueueBits'(queue);
    pop_valid = 1'b1;
    #1;
    check(queue_valid[queue] && pop_data == expected, $sformatf(
          "secondary queue %0d returned %h instead of %h", queue, pop_data, expected));
    tick(1);
    pop_valid = 1'b0;
  endtask

  initial begin
    tick(3);
    reset = 1'b0;
    check(queue_valid == '0 && push_ready, "secondary buffer did not reset empty");

    push(0, 16'h0010);
    push(1, 16'h0020);
    push(0, 16'h0011);
    pop(0, 16'h0010);
    pop(1, 16'h0020);
    pop(0, 16'h0011);
    check(queue_valid == '0, "independent virtual queues did not drain");

    push(2, 16'h0030);
    pop_index  = QueueBits'(2);
    pop_valid  = 1'b1;
    push_index = QueueBits'(2);
    push_data  = 16'h0031;
    push_valid = 1'b1;
    #1;
    check(pop_data == 16'h0030 && push_ready, "singleton replacement was not ready");
    tick(1);
    push_valid = 1'b0;
    pop_valid  = 1'b0;
    pop(2, 16'h0031);

    for (int entry = 0; entry < NumEntries; entry++) push(LastQueue, 16'(entry));
    check(!push_ready && queue_valid[LastQueue], "secondary buffer did not fill");
    push_index = QueueBits'(0);
    push_data  = 16'hffff;
    push_valid = 1'b1;
    pop_index  = QueueBits'(LastQueue);
    pop_valid  = 1'b1;
    #1;
    check(!push_ready && pop_data == 16'h0000, "full buffer reused a simultaneously popped entry");
    tick(1);
    push_valid = 1'b0;
    pop_valid  = 1'b0;
    check(push_ready, "pop did not free a secondary entry");
    push(LastQueue, 16'(NumEntries));
    for (int entry = 1; entry <= NumEntries; entry++) pop(LastQueue, 16'(entry));
    check(queue_valid == '0 && push_ready, "secondary buffer did not finish empty");

    $display("PASS: BOOM %0d-MSHR secondary buffer, %0d queues and %0d entries", NumMshrs,
             NumQueues, NumEntries);
    $finish;
  end
endmodule
