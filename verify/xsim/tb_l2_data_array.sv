module tb_l2_data_array;
  logic clock = 0, reset = 1;
  logic read_valid = 0, read_all_chunks = 0, read_ready, read_result_valid;
  logic [9:0] read_set = 0;
  logic [2:0] read_way = 0, read_chunk = 0;
  logic [511:0] read_line_data;
  logic source_c_read_valid = 0, source_c_read_ready, source_c_result_valid;
  logic [9:0] source_c_read_set = 0;
  logic [2:0] source_c_read_way = 0, source_c_read_chunk = 0;
  logic [63:0] source_c_read_data;
  logic sink_d_write_valid = 0, sink_d_write_ready;
  logic [9:0] sink_d_write_set = 0;
  logic [2:0] sink_d_write_way = 0, sink_d_write_chunk = 0;
  logic [63:0] sink_d_write_data = 0;
  logic [ 7:0] sink_d_write_mask = 0;
  logic write_line_valid = 0, write_line_busy;
  logic [9:0] write_line_set = 0;
  logic [2:0] write_line_way = 0;
  logic [511:0] write_line_data = 0;
  logic priority_write_valid = 0;
  logic [9:0] priority_write_set = 0;
  logic [2:0] priority_write_way = 0, priority_write_chunk = 0;
  logic [63:0] priority_write_data = 0;
  logic [ 7:0] priority_write_mask = 0;
  logic write_word_valid = 0, write_word_ready;
  logic [9:0] write_word_set = 0;
  logic [2:0] write_word_way = 0, write_word_chunk = 0;
  logic [63:0] write_word_data = 0;
  logic [ 7:0] write_word_mask = 0;
  logic [511:0] line_a, line_b, expected_a;

  rapt_l2_data_array dut (.*);
  always #5 clock = ~clock;

  function automatic logic [511:0] pattern(input logic [63:0] base);
    logic [511:0] value;
    for (int chunk = 0; chunk < 8; chunk++) value[chunk*64+:64] = base + 64'(chunk);
    return value;
  endfunction

  task automatic install_line(input logic [9:0] set_idx, input logic [2:0] way,
                              input logic [511:0] data);
    @(negedge clock);
    write_line_valid = 1;
    write_line_set   = set_idx;
    write_line_way   = way;
    write_line_data  = data;
    @(negedge clock);
    write_line_valid = 0;
    if (!write_line_busy) $fatal(1, "remaining SinkD beats were not scheduled");
    for (int cycle = 0; cycle < 16 && write_line_busy; cycle++) @(negedge clock);
    if (write_line_busy) $fatal(1, "eight-beat line write did not finish");
  endtask

  task automatic read_word(input logic [9:0] set_idx, input logic [2:0] way,
                           input logic [2:0] chunk, input logic [63:0] expected);
    @(negedge clock);
    read_valid = 1;
    read_all_chunks = 0;
    read_set = set_idx;
    read_way = way;
    read_chunk = chunk;
    #1;
    if (!read_ready) $fatal(1, "scalar read unexpectedly blocked");
    @(negedge clock);
    read_valid = 0;
    if (!read_result_valid || read_line_data[chunk*64+:64] !== expected)
      $fatal(
          1,
          "scalar read mismatch set=%0d way=%0d chunk=%0d got=%h expected=%h",
          set_idx,
          way,
          chunk,
          read_line_data[chunk*64+:64],
          expected
      );
  endtask

  task automatic read_line(input logic [9:0] set_idx, input logic [2:0] way,
                           input logic [511:0] expected);
    @(negedge clock);
    read_valid = 1;
    read_all_chunks = 1;
    read_set = set_idx;
    read_way = way;
    read_chunk = 3'd5;
    #1;
    if (read_ready) $fatal(1, "whole-line read finished before second row");
    @(negedge clock);
    #1;
    if (!read_ready) $fatal(1, "whole-line second row was blocked");
    @(negedge clock);
    read_valid = 0;
    read_all_chunks = 0;
    if (!read_result_valid || read_line_data !== expected)
      $fatal(1, "whole-line read mismatch set=%0d way=%0d", set_idx, way);
  endtask

  initial begin
    line_a = pattern(64'h1200_0000_0000_1000);
    line_b = pattern(64'h3400_0000_0000_2000);
    repeat (2) @(negedge clock);
    reset = 0;
    install_line(10'd0, 3'd3, line_a);
    install_line(10'd1, 3'd3, line_b);
    if ($bits(dut.g_bank[3].u_data_sram.addr) != 14 || $bits(dut.g_bank[3].u_data_sram.rdata) != 64)
      $fatal(1, "BOOM four-bank geometry mismatch");

    for (int chunk = 0; chunk < 8; chunk++) begin
      read_word(0, 3, 3'(chunk), line_a[chunk*64+:64]);
      read_word(1, 3, 3'(chunk), line_b[chunk*64+:64]);
    end
    read_line(0, 3, line_a);
    read_line(1, 3, line_b);

    // SourceC may read a different line while SourceD waits for its second
    // row. The first row must already be saved before SourceC replaces the
    // shared SRAM read output.
    @(negedge clock);
    read_valid = 1;
    read_all_chunks = 1;
    read_set = 0;
    read_way = 3;
    @(negedge clock);
    source_c_read_valid = 1;
    source_c_read_set = 1;
    source_c_read_way = 3;
    source_c_read_chunk = 0;
    #1;
    if (!source_c_read_ready || read_ready)
      $fatal(1, "SourceC did not pre-empt the second SourceD row");
    @(negedge clock);
    source_c_read_valid = 0;
    #1;
    if (!source_c_result_valid || source_c_read_data !== line_b[0+:64] || !read_ready)
      $fatal(1, "SourceC data or delayed SourceD row was incorrect");
    @(negedge clock);
    read_valid = 0;
    read_all_chunks = 0;
    if (!read_result_valid || read_line_data !== line_a)
      $fatal(1, "SourceC read corrupted the pending SourceD first row");

    // A write between the two row reads delays completion without losing
    // the first row that was already fetched.
    @(negedge clock);
    read_valid = 1;
    read_all_chunks = 1;
    read_set = 0;
    read_way = 3;
    @(negedge clock);
    write_word_valid = 1;
    write_word_set   = 1;
    write_word_way   = 3;
    write_word_chunk = 0;
    write_word_data  = line_b[0+:64];
    write_word_mask  = 8'hff;
    #1;
    if (read_ready) $fatal(1, "second row read bypassed a competing write");
    @(negedge clock);
    write_word_valid = 0;
    #1;
    if (!read_ready) $fatal(1, "second row read did not resume");
    @(negedge clock);
    read_valid = 0;
    read_all_chunks = 0;
    if (!read_result_valid || read_line_data !== line_a)
      $fatal(1, "stalled whole-line read lost its first row");

    // Different sets still collide on the same bank number.
    @(negedge clock);
    write_word_valid = 1;
    write_word_set = 0;
    write_word_way = 3;
    write_word_chunk = 4;
    write_word_data = 64'h1122_3344_5566_7788;
    write_word_mask = 8'h0f;
    read_valid = 1;
    read_set = 1;
    read_way = 3;
    read_chunk = 0;
    #1;
    if (read_ready) $fatal(1, "same bank with different set was not blocked");
    @(negedge clock);
    write_word_valid = 0;
    read_valid = 0;
    if (read_result_valid) $fatal(1, "blocked read returned a result");
    expected_a = line_a;
    expected_a[4*64+:32] = 32'h5566_7788;
    read_word(0, 3, 4, expected_a[4*64+:64]);

    // Different banks can be accessed together, even within the same set.
    @(negedge clock);
    write_word_valid = 1;
    write_word_chunk = 4;
    write_word_mask = 8'hf0;
    read_valid = 1;
    read_set = 0;
    read_chunk = 3;
    #1;
    if (!read_ready) $fatal(1, "independent bank read was blocked");
    @(negedge clock);
    write_word_valid = 0;
    read_valid = 0;
    if (!read_result_valid || read_line_data[3*64+:64] !== expected_a[3*64+:64])
      $fatal(1, "independent bank read mismatch");
    expected_a[4*64+32+:32] = 32'h1122_3344;
    read_line(0, 3, expected_a);

    // Both rows of an adjacent way have independent addresses.
    install_line(0, 4, line_b);
    read_line(0, 3, expected_a);
    read_line(0, 4, line_b);

    // SinkC wins a same-bank collision with a resident SourceD store.
    @(negedge clock);
    priority_write_valid = 1;
    priority_write_set = 0;
    priority_write_way = 3;
    priority_write_chunk = 4;
    priority_write_data = 64'hface_cafe_1122_3344;
    priority_write_mask = 8'hff;
    write_word_valid = 1;
    write_word_set = 0;
    write_word_way = 3;
    write_word_chunk = 4;
    write_word_data = 64'hdead_beef_5566_7788;
    write_word_mask = 8'hff;
    #1;
    if (write_word_ready) $fatal(1, "same-bank SourceD write bypassed SinkC priority");
    @(negedge clock);
    priority_write_valid = 0;
    write_word_valid = 0;
    expected_a[4*64+:64] = 64'hface_cafe_1122_3344;
    read_word(0, 3, 4, expected_a[4*64+:64]);

    // Separate banks accept both writers in the same cycle.
    @(negedge clock);
    priority_write_valid = 1;
    priority_write_chunk = 0;
    priority_write_data = 64'h0123_4567_89ab_cdef;
    write_word_valid = 1;
    write_word_chunk = 1;
    write_word_data = 64'hfedc_ba98_7654_3210;
    #1;
    if (!write_word_ready) $fatal(1, "independent SourceD bank was blocked by SinkC");
    @(negedge clock);
    priority_write_valid = 0;
    write_word_valid = 0;
    expected_a[0+:64] = 64'h0123_4567_89ab_cdef;
    expected_a[64+:64] = 64'hfedc_ba98_7654_3210;
    read_line(0, 3, expected_a);

    // SinkC takes bank 0 on the first SinkD beat. SinkD retries that beat,
    // while a resident store and a scalar read use independent banks.
    @(negedge clock);
    write_line_valid = 1;
    write_line_set = 2;
    write_line_way = 5;
    write_line_data = line_a;
    priority_write_valid = 1;
    priority_write_set = 0;
    priority_write_way = 3;
    priority_write_chunk = 0;
    priority_write_data = 64'hc001_cafe_0123_4567;
    priority_write_mask = 8'hff;
    @(negedge clock);
    write_line_valid = 0;
    priority_write_valid = 0;
    if (!write_line_busy || dut.line_chunk_q != 0)
      $fatal(1, "SinkC did not pre-empt the conflicting first SinkD beat");
    write_word_valid = 1;
    write_word_set = 0;
    write_word_way = 3;
    write_word_chunk = 1;
    write_word_data = 64'hd00d_cafe_89ab_cdef;
    write_word_mask = 8'hff;
    read_valid = 1;
    read_all_chunks = 0;
    read_set = 0;
    read_way = 3;
    read_chunk = 2;
    #1;
    if (!write_word_ready || !read_ready)
      $fatal(1, "independent store or read stalled behind the SinkD retry");
    @(negedge clock);
    write_word_valid = 0;
    read_valid = 0;
    if (!read_result_valid || read_line_data[2*64+:64] !== expected_a[2*64+:64])
      $fatal(1, "independent scalar read failed during SinkD retry");
    if (!write_line_busy || dut.line_chunk_q != 1)
      $fatal(1, "SinkD did not advance after the displaced beat retried");
    for (int cycle = 0; cycle < 16 && write_line_busy; cycle++) @(negedge clock);
    if (write_line_busy) $fatal(1, "first-beat collision left SinkD busy");
    read_line(2, 5, line_a);
    expected_a[0+:64]  = 64'hc001_cafe_0123_4567;
    expected_a[64+:64] = 64'hd00d_cafe_89ab_cdef;
    read_word(0, 3, 0, 64'hc001_cafe_0123_4567);
    read_word(0, 3, 1, 64'hd00d_cafe_89ab_cdef);

    // SinkC can also stall one beat in the second row without restarting
    // the already committed SinkD beats.
    @(negedge clock);
    write_line_valid = 1;
    write_line_set   = 2;
    write_line_way   = 6;
    write_line_data  = line_b;
    @(negedge clock);
    write_line_valid = 0;
    for (int cycle = 0; cycle < 10 && dut.line_chunk_q != 5; cycle++) @(negedge clock);
    if (!write_line_busy || dut.line_chunk_q != 5)
      $fatal(1, "second-row SinkD beat was not pending");
    priority_write_valid = 1;
    priority_write_set   = 0;
    priority_write_way   = 3;
    priority_write_chunk = 5;
    priority_write_data  = 64'hb001_cafe_7654_3210;
    priority_write_mask  = 8'hff;
    @(negedge clock);
    priority_write_valid = 0;
    if (!write_line_busy || dut.line_chunk_q != 5)
      $fatal(1, "SinkC did not pre-empt the conflicting second-row SinkD beat");
    for (int cycle = 0; cycle < 16 && write_line_busy; cycle++) @(negedge clock);
    if (write_line_busy) $fatal(1, "second-row collision left SinkD busy");
    read_line(2, 6, line_b);
    read_word(0, 3, 5, 64'hb001_cafe_7654_3210);

    // An outgoing SourceC read pre-empts a buffered SinkD write on the same
    // bank. SourceD may still read another bank on that cycle.
    @(negedge clock);
    write_line_valid = 1;
    write_line_set = 3;
    write_line_way = 5;
    write_line_data = line_b;
    source_c_read_valid = 1;
    source_c_read_set = 0;
    source_c_read_way = 3;
    source_c_read_chunk = 0;
    read_valid = 1;
    read_all_chunks = 0;
    read_set = 0;
    read_way = 3;
    read_chunk = 0;
    #1;
    if (!source_c_read_ready || read_ready)
      $fatal(1, "SourceC did not take priority over same-bank SourceD read");
    read_chunk = 2;
    #1;
    if (!read_ready) $fatal(1, "independent SourceD read stalled behind SourceC");
    @(negedge clock);
    write_line_valid = 0;
    source_c_read_valid = 0;
    read_valid = 0;
    if (!write_line_busy || dut.line_chunk_q != 0)
      $fatal(1, "SourceC did not pre-empt the first buffered SinkD beat");
    if (!source_c_result_valid || source_c_read_data !== expected_a[0+:64])
      $fatal(1, "SourceC returned the wrong resident word");
    if (!read_result_valid || read_line_data[2*64+:64] !== expected_a[2*64+:64])
      $fatal(1, "independent SourceD read failed beside SourceC");
    for (int cycle = 0; cycle < 16 && write_line_busy; cycle++) @(negedge clock);
    if (write_line_busy) $fatal(1, "SourceC collision left buffered SinkD busy");
    read_line(3, 5, line_b);

    // SinkC outranks SourceC; SourceC outranks a resident SourceD write.
    @(negedge clock);
    priority_write_valid = 1;
    priority_write_set = 0;
    priority_write_way = 3;
    priority_write_chunk = 0;
    priority_write_data = 64'hc0c0_cafe_0123_4567;
    priority_write_mask = 8'hff;
    source_c_read_valid = 1;
    source_c_read_set = 0;
    source_c_read_way = 3;
    source_c_read_chunk = 0;
    #1;
    if (source_c_read_ready) $fatal(1, "same-bank SourceC bypassed SinkC");
    @(negedge clock);
    priority_write_valid = 0;
    if (source_c_result_valid) $fatal(1, "blocked SourceC returned a result");
    write_word_valid = 1;
    write_word_set   = 0;
    write_word_way   = 3;
    write_word_chunk = 0;
    write_word_data  = 64'hdead_beef_0000_0000;
    write_word_mask  = 8'hff;
    #1;
    if (!source_c_read_ready || write_word_ready)
      $fatal(1, "SourceC did not pre-empt same-bank resident store");
    @(negedge clock);
    source_c_read_valid = 0;
    write_word_valid = 0;
    if (!source_c_result_valid || source_c_read_data !== 64'hc0c0_cafe_0123_4567)
      $fatal(1, "SourceC read after SinkC priority was incorrect");
    read_word(0, 3, 0, 64'hc0c0_cafe_0123_4567);

    // A live outer D beat waits for SinkC, then SourceC, on its bank.
    @(negedge clock);
    sink_d_write_valid = 1;
    sink_d_write_set = 4;
    sink_d_write_way = 2;
    sink_d_write_chunk = 0;
    sink_d_write_data = 64'h0123_4567_89ab_cdef;
    sink_d_write_mask = 8'hff;
    priority_write_valid = 1;
    priority_write_chunk = 0;
    priority_write_data = 64'hc0c0_cafe_0123_4567;
    #1;
    if (sink_d_write_ready) $fatal(1, "live SinkD bypassed SinkC");
    @(negedge clock);
    priority_write_valid = 0;
    source_c_read_valid  = 1;
    source_c_read_chunk  = 0;
    #1;
    if (sink_d_write_ready) $fatal(1, "live SinkD bypassed SourceC");
    @(negedge clock);
    source_c_read_valid = 0;
    read_valid = 1;
    read_all_chunks = 0;
    read_set = 0;
    read_way = 3;
    read_chunk = 2;
    #1;
    if (!sink_d_write_ready || !read_ready)
      $fatal(1, "live SinkD and independent SourceD read did not advance");
    @(negedge clock);
    sink_d_write_valid = 0;
    read_valid = 0;
    read_word(4, 2, 0, 64'h0123_4567_89ab_cdef);

    // RV32's two half-word beats use the same physical 64-bit bank row.
    @(negedge clock);
    sink_d_write_valid = 1;
    sink_d_write_chunk = 1;
    sink_d_write_mask  = 8'h0f;
    sink_d_write_data  = 64'hffff_ffff_dead_beef;
    @(negedge clock);
    sink_d_write_mask = 8'hf0;
    sink_d_write_data = 64'hcafe_babe_ffff_ffff;
    @(negedge clock);
    sink_d_write_valid = 0;
    read_word(4, 2, 1, 64'hcafe_babe_dead_beef);
    $display("PASS: four 16384x64 banks, eight SinkD beats and five-port priority");
    $finish;
  end
endmodule
