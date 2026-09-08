module tb_dispatch_admit;
  import rapt_pkg::*;
  localparam int Width = 4;
  logic reset = 0, flush = 0, halt = 0, serial_in_flight = 0, rob_empty = 1;
  logic recovery_pending = 0;
  logic present[Width], rob_available[Width], serial[Width], endpoint_ready[Width];
  logic eligible[Width], accepted[Width], correct;
  int unsigned count;
  dispatch_stop_t stop_reason;
  int coverage[DispatchStopCount];
  logic [31:0] rng = 32'hbf7605e1;
  rapt_dispatch_admit #(.Width(Width)) dut (.*);
  formal_dispatch_admit #(.Width(Width)) reference_check (.*);
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  task automatic check(input int reason = -1, input int expected_count = -1);
    #1;
    assert (correct)
    else $fatal(1, "admission differs from previous equations or reason contract");
    if (reason >= 0)
      assert (stop_reason == reason)
      else $fatal(1, "reason=%0d expected=%0d", stop_reason, reason);
    if (expected_count >= 0)
      assert (count == expected_count)
      else $fatal(1, "prefix count mismatch");
    coverage[stop_reason]++;
  endtask
  initial begin
    void'($value$plusargs("SEED=%d", rng));
    assert (rng != 0)
    else $fatal(1, "SEED must be nonzero");
    present = '{default: 1};
    rob_available = '{default: 1};
    serial = '{default: 0};
    endpoint_ready = '{default: 1};
    check(DispatchStopWidth, 4);
    present[2] = 0;
    check(DispatchStopEmpty, 2);
    present[2] = 1;
    endpoint_ready[2] = 0;
    check(DispatchStopEndpoint, 2);
    rob_available[2] = 0;
    check(DispatchStopRob, 2);
    serial[2] = 1;
    check(DispatchStopSerialWait, 2);
    serial[2] = 0;
    rob_available[2] = 1;
    endpoint_ready[2] = 1;
    serial[0] = 1;
    check(DispatchStopSerialBoundary, 1);
    rob_empty = 0;
    check(DispatchStopSerialWait, 0);
    serial_in_flight = 1;
    check(DispatchStopSerialBusy, 0);
    recovery_pending = 1;
    check(DispatchStopRecovery, 0);
    halt = 1;
    check(DispatchStopHalt, 0);
    flush = 1;
    check(DispatchStopFlush, 0);
    reset = 1;
    check(DispatchStopReset, 0);
    for (int n = 0; n < 10000; n++) begin
      reset = random_word() % 23 == 0;
      flush = random_word() % 17 == 0;
      halt = random_word() % 19 == 0;
      recovery_pending = random_word() % 11 == 0;
      serial_in_flight = random_word() % 13 == 0;
      rob_empty = random_word() % 2 == 0;
      for (int s = 0; s < Width; s++) begin
        present[s] = random_word() % 4 != 0;
        serial[s] = random_word() % 9 == 0;
        rob_available[s] = random_word() % 5 != 0;
        endpoint_ready[s] = random_word() % 3 != 0;
      end
      check();
    end
    foreach (coverage[r])
    assert (coverage[r] > 0)
    else $fatal(1, "uncovered reason %0d", r);
    $display("PASS: dispatch admission 10012 states, all %0d reasons, prefix and priority",
             DispatchStopCount);
    $finish;
  end
endmodule
