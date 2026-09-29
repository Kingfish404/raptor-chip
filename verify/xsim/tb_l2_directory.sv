module tb_l2_directory;
  logic clock = 0;
  logic reset = 1;
  logic ready;
  logic read_valid = 0, read_ready;
  logic [9:0] read_set = 0;
  logic [17:0] read_tag = 0;
  logic result_valid, result_hit;
  logic [2:0] result_way;
  logic [17:0] result_tag;
  logic result_clients;
  logic [1:0] result_state;
  logic result_dirty;
  logic scan_valid = 0, scan_ready, scan_result_valid;
  logic [9:0] scan_set = 0;
  logic [8*22-1:0] scan_entries;
  logic clear_valid = 0, clear_ready;
  logic [9:0] clear_set = 0;
  logic write_valid = 0, write_ready;
  logic [9:0] write_set = 0;
  logic [2:0] write_way = 0;
  logic [17:0] write_tag = 0;
  logic write_clients = 0;
  logic [1:0] write_state = 0;
  logic write_dirty = 0;

  rapt_l2_directory dut (.*);
  always #5 clock = ~clock;

  task automatic write_entry(input logic [2:0] way, input logic [17:0] tag, input logic [1:0] state,
                             input logic dirty);
    @(negedge clock);
    write_valid = 1;
    write_set = 2;
    write_way = way;
    write_tag = tag;
    write_clients = 1;
    write_state = state;
    write_dirty = dirty;
    if (!write_ready) $fatal(1, "directory write not ready");
    @(negedge clock);
    write_valid = 0;
  endtask

  task automatic read_entry(input logic [17:0] tag, input bit hit, input logic [2:0] way);
    @(negedge clock);
    read_valid = 1;
    read_set = 2;
    read_tag = tag;
    if (!read_ready) $fatal(1, "directory read not ready");
    @(negedge clock);
    read_valid = 0;
    if (!result_valid || result_hit != hit) $fatal(1, "directory hit mismatch");
    if (hit && (result_way != way || result_tag != tag || !result_clients))
      $fatal(1, "directory hit payload mismatch");
  endtask

  initial begin
    repeat (2) @(negedge clock);
    reset = 0;
    for (int warmup = 0; warmup < 1088 && !ready; warmup++) @(negedge clock);
    if (!ready) $fatal(1, "directory reset wipe did not complete");
    if ($bits(dut.g_way[7].u_directory.rdata) != 22)
      $fatal(1, "BOOM directory entry must be 22 bits");
    // BOOM's 16-bit Fibonacci LFSR advances on every directory read. Its
    // low ten bits select eight equal-width victim ranges after the edge.
    for (int trial = 0; trial < 10; trial++) begin
      int expected_way;
      case (trial)
        6: expected_way = 1;
        7: expected_way = 2;
        8: expected_way = 4;
        default: expected_way = 0;
      endcase
      @(negedge clock);
      read_valid = 1;
      read_set = 2;
      read_tag = 18'h30000 + 18'(trial);
      if (!read_ready) $fatal(1, "victim lookup not ready");
      @(negedge clock);
      read_valid = 0;
      if (!result_valid || result_hit || result_way != 3'(expected_way))
        $fatal(1, "BOOM victim sequence mismatch at read %0d", trial);
    end
    write_entry(3, 18'h12345, 2'b11, 1);
    write_entry(5, 18'h12346, 2'b01, 0);
    read_entry(18'h12345, 1, 3);
    if (!result_dirty || result_state != 2'b11) $fatal(1, "dirty/state mismatch");
    read_entry(18'h12346, 1, 5);
    if (result_dirty || result_state != 2'b01) $fatal(1, "clean/state mismatch");
    read_entry(18'h12347, 0, 0);
    // A maintenance scan exposes every way in one registered SRAM read,
    // including a queued write to the same set.
    scan_set = 2;
    scan_valid = 1;
    if (!scan_ready) $fatal(1, "directory scan not ready");
    @(negedge clock);
    scan_valid = 0;
    if (!scan_result_valid || scan_entries[3*22+:18] != 18'h12345
        || scan_entries[5*22+:18] != 18'h12346)
      $fatal(1, "directory scan lost resident ways");
    write_entry(7, 18'h12348, 2'b11, 1);
    scan_valid = 1;
    scan_set = 2;
    if (!scan_ready) $fatal(1, "queued-write scan not ready");
    @(negedge clock);
    scan_valid = 0;
    if (!scan_result_valid || scan_entries[7*22+:18] != 18'h12348 || !scan_entries[7*22+21])
      $fatal(1, "directory scan failed to bypass queued metadata");
    // Read before the queued write reaches SRAM. The one-entry bypass must
    // return the pending metadata instead of the stale way contents.
    read_valid = 1;
    read_set = 2;
    read_tag = 18'h12348;
    #1;
    if (write_ready || !read_ready) $fatal(1, "directory queue arbitration mismatch");
    @(negedge clock);
    read_valid = 0;
    if (!result_valid || !result_hit || result_way != 7 || !result_dirty)
      $fatal(1, "queued directory write was not bypassed");
    @(negedge clock);
    read_entry(18'h12348, 1, 7);
    // BOOM's directory read contract also observes a newly accepted write
    // when both requests reach the directory on the same clock edge.
    while (!write_ready) @(negedge clock);
    write_valid = 1;
    write_set = 2;
    write_way = 6;
    write_tag = 18'h12349;
    write_clients = 1;
    write_state = 2'b10;
    write_dirty = 1;
    read_valid = 1;
    read_set = 2;
    read_tag = 18'h12349;
    @(negedge clock);
    write_valid = 0;
    read_valid = 0;
    if (!result_valid || !result_hit || result_way != 6 || result_state != 2'b10 || !result_dirty)
      $fatal(1, "same-cycle directory write was not bypassed");
    @(negedge clock);
    write_entry(5, 18'h12346, 2'b00, 0);
    // A queued invalidation must quash the stale SRAM hit immediately.
    read_valid = 1;
    read_set = 2;
    read_tag = 18'h12346;
    @(negedge clock);
    read_valid = 0;
    if (!result_valid || result_hit || result_way != 5 || result_state != 2'b00)
      $fatal(1, "queued invalidation did not preserve BOOM replacement way");
    @(negedge clock);
    write_entry(3, 18'h12345, 2'b00, 0);
    read_entry(18'h12345, 0, 0);
    // A whole-set clear must wait for the pending single-way write, then
    // invalidate every way atomically before a new lookup can proceed.
    write_entry(2, 18'h12350, 2'b11, 1);
    clear_valid = 1;
    clear_set = 2;
    #1;
    if (clear_ready || read_ready || write_ready)
      $fatal(1, "directory clear did not wait for the queued write");
    @(negedge clock);
    if (!clear_ready) $fatal(1, "directory clear remained blocked after write drain");
    @(negedge clock);
    clear_valid = 0;
    read_entry(18'h12346, 0, 0);
    read_entry(18'h12348, 0, 0);
    read_entry(18'h12349, 0, 0);
    read_entry(18'h12350, 0, 0);
    $display("PASS: BOOM L2 directory wipe, metadata and whole-set clear");
    $finish;
  end
endmodule
