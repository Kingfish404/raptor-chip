module tb_l2_directory_oneway;
  logic clock = 0;
  logic reset = 1;
  logic ready, read_ready, result_valid, result_hit;
  logic result_way;
  logic [1:0] result_tag;
  logic result_clients;
  logic [1:0] result_state;
  logic result_dirty;
  logic read_valid = 0;
  always #5 clock = ~clock;

  rapt_l2_directory #(
      .SetBits(1),
      .Ways(1),
      .TagBits(2),
      .ClientBits(1)
  ) dut (
      .clock,
      .reset,
      .ready,
      .read_valid,
      .read_ready,
      .read_set(1'b0),
      .read_tag(2'b01),
      .result_valid,
      .result_hit,
      .result_way,
      .result_tag,
      .result_clients,
      .result_state,
      .result_dirty,
      .scan_valid(1'b0),
      .scan_ready(),
      .scan_set(1'b0),
      .scan_result_valid(),
      .scan_entries(),
      .clear_valid(1'b0),
      .clear_ready(),
      .clear_set(1'b0),
      .write_valid(1'b0),
      .write_ready(),
      .write_set(1'b0),
      .write_way(1'b0),
      .write_tag(2'b0),
      .write_clients(1'b0),
      .write_state(2'b0),
      .write_dirty(1'b0)
  );

  initial begin
    repeat (2) @(negedge clock);
    reset = 0;
    wait (ready);
    // The LFSR's bit 9 becomes one after the ninth miss. A one-way
    // directory must still select its sole valid way, index zero.
    for (int trial = 0; trial < 12; trial++) begin
      @(negedge clock);
      read_valid = 1;
      if (!read_ready) $fatal(1, "one-way directory not ready");
      @(negedge clock);
      read_valid = 0;
      if (!result_valid || result_hit || result_way !== 1'b0)
        $fatal(1, "one-way miss chose invalid way %0d at read %0d", result_way, trial);
    end
    $display("PASS: one-way L2 directory victim stays at way zero");
    $finish;
  end
endmodule
