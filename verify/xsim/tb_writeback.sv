module tb_writeback;
  logic clock = 1'b0;
  logic [3:0] done = '0;
  always #5 clock = ~clock;

  for (genvar case_idx = 0; case_idx < 4; case_idx++) begin : g_case
    localparam int Xlen = 32 << (case_idx % 2);
    localparam bit RetryEnabled = case_idx >= 2;
    localparam int Words = 64 / (Xlen / 8);
    logic reset = 1'b1;
    logic capture_valid = 1'b0;
    logic capture_ready;
    logic [Xlen-1:0] capture_addr = Xlen'('h80000000);
    logic [Words-1:0] capture_dirty = '0;
    logic [Words*Xlen-1:0] capture_data = '0;
    logic busy, error, write_valid;
    logic retry = 1'b0;
    logic [Xlen-1:0] write_addr, write_data;
    logic write_ready = 1'b0, write_error = 1'b0;
    logic [Xlen-1:0] held_addr, held_data;

    rapt_l1d_writeback #(
        .Xlen(Xlen),
        .LineWords(Words),
        .AllowRetry(RetryEnabled)
    ) dut (
        .*
    );

    task automatic tick;
      @(posedge clock);
      #1;
    endtask

    initial begin
      tick();
      @(negedge clock);
      reset = 1'b0;
      for (int word_idx = 0; word_idx < Words; word_idx++)
      capture_data[word_idx*Xlen+:Xlen] = Xlen'('h12340000 + word_idx);
      capture_dirty = (Words'(1) << 1) | (Words'(1) << (Words - 1));
      capture_valid = 1'b1;
      tick();
      @(negedge clock);
      capture_valid = 1'b0;
      capture_addr = '0;
      capture_data = '0;
      if (!busy || capture_ready || !write_valid
          || write_addr != Xlen'('h80000000) + Xlen'(Xlen/8)
          || write_data != Xlen'('h12340001))
        $fatal(1, "capture or first dirty word failed");
      held_addr = write_addr;
      held_data = write_data;
      repeat (5) begin
        tick();
        if (write_addr !== held_addr || write_data !== held_data || !write_valid)
          $fatal(1, "write changed under backpressure");
      end
      @(negedge clock);
      write_ready = 1'b1;
      write_error = 1'b1;
      tick();
      if (!error || !busy || write_valid || capture_ready) $fatal(1, "write error lost ownership");
      @(negedge clock);
      write_ready = 1'b0;
      write_error = 1'b0;
      repeat (3) tick();
      if (write_addr !== held_addr || write_data !== held_data)
        $fatal(1, "error discarded payload");
      @(negedge clock);
      retry = 1'b1;
      tick();
      if (!RetryEnabled) begin
        repeat (5) begin
          tick();
          if (!error || !busy || write_valid || capture_ready
              || write_addr !== held_addr || write_data !== held_data)
            $fatal(1, "fail-stop must retain ownership until reset");
        end
        @(negedge clock);
        reset = 1'b1;
        tick();
        if (busy || error || write_valid) $fatal(1, "reset failed to release fail-stop");
      end else begin
        @(negedge clock);
        retry = 1'b0;
        write_ready = 1'b1;
        tick();
        if (!write_valid || write_addr != Xlen'('h80000000) + Xlen'(int'((Words-1)*(Xlen/8)))
          || write_data != Xlen'('h12340000) + Xlen'(Words-1))
          $fatal(1, "dirty mask traversal failed");
        tick();
        if (busy || !capture_ready || write_valid || error) $fatal(1, "drain failed");
        @(negedge clock);
        write_ready = 1'b0;
        capture_dirty = '0;
        capture_valid = 1'b1;
        tick();
        if (busy || write_valid) $fatal(1, "clean capture generated write");
      end
      done[case_idx] = 1'b1;
    end
  end

  initial begin
    wait (&done);
    $display("PASS: RV32/RV64 writeback masks, backpressure, fail-stop and optional retry");
    $finish;
  end
  initial begin
    #2000;
    $fatal(1, "writeback timeout");
  end
endmodule
