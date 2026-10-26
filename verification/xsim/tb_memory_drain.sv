`include "rapt.svh"

module tb_memory_drain;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic request_i = 0, stores_empty_i = 1, memory_idle_i = 1, writeback_idle_i = 1;
  wire drain_o, done_o;
  rapt_memory_drain dut (.*);
  int completed = 0, cancelled = 0;
  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  task automatic expect_phase(input bit drain, done);
    assert (drain_o == drain && done_o == done)
    else $fatal(1, "drain protocol got=%b%b expected=%b%b", drain_o, done_o, drain, done);
  endtask
  task automatic release_request;
    request_i = 0;
    tick();
    expect_phase(0, 0);
  endtask
  initial begin
    repeat (2) tick();
    reset = 0;
    tick();
    expect_phase(0, 0);
    // An already quiet memory cannot acknowledge combinationally. A request
    // must first enter the active drain phase and then observe quiescence.
    request_i = 1;
    #1;
    expect_phase(0, 0);
    tick();
    expect_phase(1, 0);
    tick();
    expect_phase(0, 1);
    completed++;
    // Completion belongs to this transaction. Subsequent external activity
    // cannot withdraw it while the owner waits to retire.
    stores_empty_i = 0;
    memory_idle_i = 0;
    writeback_idle_i = 0;
    repeat (4) begin
      tick();
      expect_phase(0, 1);
    end
    release_request();
    // Independently delay the last older SQ store, a late refill installation,
    // and dirty/posted-write completion. Every condition must be satisfied.
    for (int delayed = 0; delayed < 3; delayed++) begin
      stores_empty_i = delayed != 0;
      memory_idle_i = delayed != 1;
      writeback_idle_i = delayed != 2;
      request_i = 1;
      repeat (8) begin
        tick();
        expect_phase(1, 0);
      end
      stores_empty_i = 1;
      memory_idle_i = 1;
      writeback_idle_i = 1;
      #1;
      expect_phase(1, 0);
      tick();
      expect_phase(0, 1);
      completed++;
      release_request();
    end
    // Cancellation wins over a coincident idle observation, and a retry owns
    // a fresh transaction rather than inheriting the discarded completion.
    for (int iteration = 0; iteration < 100; iteration++) begin
      memory_idle_i = 0;
      request_i = 1;
      tick();
      expect_phase(1, 0);
      memory_idle_i = 1;
      release_request();
      cancelled++;
      request_i = 1;
      tick();
      expect_phase(1, 0);
      tick();
      expect_phase(0, 1);
      completed++;
      release_request();
    end
    request_i = 1;
    tick();
    expect_phase(1, 0);
    reset = 1;
    tick();
    expect_phase(0, 0);
    reset = 0;
    tick();
    expect_phase(1, 0);
    tick();
    expect_phase(0, 1);
    reset = 1;
    tick();
    expect_phase(0, 0);
    $display("PASS: drain request/completion completed=%0d cancelled=%0d", completed, cancelled);
    $finish;
  end
endmodule
