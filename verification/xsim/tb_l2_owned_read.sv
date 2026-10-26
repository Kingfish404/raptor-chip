// A Get from another client must probe a Trunk owner before returning data.
`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_l2_owned_read;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int WordBytes = XLEN / 8;
  localparam int LineBeats = 64 / WordBytes;
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000100);
  localparam logic [XLEN-1:0] DirtyAddr = LineAddr + XLEN'(2 * WordBytes);
  localparam logic [XLEN-1:0] DirtyWord = XLEN'('hfe123456);
  logic clock = 1'b0, reset = 1'b1;
  logic probe_valid, probe_ready = 1'b0;
  logic [XLEN-1:0] probe_addr;
  logic probe_release_valid = 1'b0, probe_release_ready;
  logic [XLEN-1:0] probe_release_addr = '0, probe_release_data = '0;
  logic release_valid = 1'b0, release_ready, release_ack;
  logic [XLEN-1:0] release_addr = '0, release_data = '0;
  logic release_has_data = 1'b0, release_mask = 1'b0, release_last = 1'b0;
  int directory_reads = 0;
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_s ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_m ();
  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) dut (
      .clock,
      .reset,
      .probe_valid_o(probe_valid),
      .probe_addr_o(probe_addr),
      .probe_ready_i(probe_ready),
      .probe_release_valid_i(probe_release_valid),
      .probe_release_addr_i(probe_release_addr),
      .probe_release_data_i(probe_release_data),
      .probe_release_ready_o(probe_release_ready),
      .release_valid_i(release_valid),
      .release_addr_i(release_addr),
      .release_data_i(release_data),
      .release_has_data_i(release_has_data),
      .release_mask_i(release_mask),
      .release_last_i(release_last),
      .release_ready_o(release_ready),
      .release_ack_o(release_ack),
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  always @(posedge clock)
    if (!reset && dut.dir_demand_read_valid && dut.dir_read_ready)
      directory_reads <= directory_reads + 1;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  task automatic start_case;
    reset = 1'b1;
    probe_ready = 1'b0;
    probe_release_valid = 1'b0;
    release_valid = 1'b0;
    init_l2_axi(1'b1);
    tick(5);
    reset = 1'b0;
    for (int cycle = 0; cycle < 1100 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "directory wipe timed out");
  endtask

  task automatic finish_context;
    axi_s.rready = 1'b1;
    for (int cycle = 0; cycle < 128 && (dut.ms_busy || dut.rs != 0 || axi_s.rvalid); cycle++)
      tick(1);
    check(!dut.ms_busy && dut.rs == 0 && !axi_s.rvalid, "read context did not retire");
    axi_s.rready = 1'b0;
  endtask

  task automatic fill_owner;
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
    logic [7:0] outer_len;
    send_l2_ar(LineAddr, 4'h2);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h1000 + beat), beat == LineBeats - 1);
    finish_context();
  endtask

  task automatic wait_probe;
    for (int cycle = 0; cycle < 128 && !probe_valid; cycle++) begin
      check(!axi_s.rvalid, "Get returned stale L2 data before probing its Trunk owner");
      check(!axi_m.arvalid && !axi_m.awvalid, "resident Get issued outer traffic");
      tick(1);
    end
    check(probe_valid && probe_addr == LineAddr, "Get did not probe the D-owner");
    check(!axi_s.rvalid, "Get response escaped before Probe Ack");
  endtask

  task automatic finish_probe(input bit with_data, input bit voluntary_release);
    if (voluntary_release) begin
      // C Release must pre-empt the waiting owner Probe. Only word two is dirty.
      for (int beat = 0; beat < LineBeats; beat++) begin
        release_addr = LineAddr + XLEN'(beat * WordBytes);
        release_data = DirtyWord;
        release_has_data = 1'b1;
        release_mask = beat == 2;
        release_last = beat == LineBeats - 1;
        release_valid = 1'b1;
        for (int cycle = 0; cycle < 128 && !release_ready; cycle++) tick(1);
        check(release_ready && !axi_s.rvalid, "C Release blocked behind Get Probe");
        tick(1);
        release_valid = 1'b0;
      end
      for (int cycle = 0; cycle < 128 && !release_ack; cycle++) begin
        check(!axi_s.rvalid, "Get escaped before C metadata commit");
        tick(1);
      end
      check(release_ack, "nested Get ReleaseAck timed out");
      check(!probe_valid, "Get still probed a client after ReleaseAck");
      tick(1);
    end else begin
      if (with_data) begin
        probe_release_addr = DirtyAddr;
        probe_release_data = DirtyWord;
        probe_release_valid = 1'b1;
        for (int cycle = 0; cycle < 64 && !probe_release_ready; cycle++) tick(1);
        check(probe_release_ready, "Get ProbeAckData was blocked");
        tick(1);
        probe_release_valid = 1'b0;
      end
      repeat (3) begin
        check(!axi_s.rvalid, "Get response escaped before the final Probe Ack");
        tick(1);
      end
      probe_ready = 1'b1;
      tick(1);
      probe_ready = 1'b0;
    end
  endtask

  task automatic expect_word(input logic [IdW-1:0] id, input logic [XLEN-1:0] data, input bit last);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == id && axi_s.rdata == data
          && axi_s.rresp == 2'b00 && axi_s.rlast == last,
        "Get data, ID or burst shape mismatch");
    check(!probe_valid && !axi_m.arvalid && !axi_m.awvalid,
          "hit response repeated Probe or refill");
    tick(2);
    check(axi_s.rvalid && axi_s.rdata == data, "Get changed data under backpressure");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
  endtask

  task automatic run_primary(input int shape, input bit with_data,
                             input bit voluntary_release = 1'b0);
    int first_word, length, word_index, reads_before;
    logic [1:0] burst;
    start_case();
    fill_owner();
    // The requesting owner skips Probe, as BOOM's skipProbeN requires.
    send_l2_ar(DirtyAddr, 4'h2);
    expect_word(4'h2, XLEN'('h1002), 1'b1);
    finish_context();
    first_word = shape == 1 ? 1 : shape == 3 ? 3 : 2;
    length = shape == 0 ? 0 : shape == 3 ? 3 : 2;
    burst = shape == 2 ? 2'b00 : shape == 3 ? 2'b10 : 2'b01;
    send_l2_ar_len(LineAddr + XLEN'(first_word * WordBytes), 4'h1, 8'(length), burst);
    reads_before = directory_reads;
    wait_probe();
    finish_probe(with_data, voluntary_release);
    for (int beat = 0; beat <= length; beat++) begin
      word_index = shape == 2 ? first_word : shape == 3 ? (first_word + beat) % 4
                   : first_word + beat;
      expect_word(4'h1,
                  word_index == 2 && (with_data || voluntary_release)
                  ? DirtyWord : XLEN'('h1000 + word_index),
                  beat == length);
    end
    check(directory_reads == reads_before, "line-local Get burst re-read directory metadata");
    finish_context();
    // Granting the line again must re-mark ownership and preserve dirty metadata.
    send_l2_ar(DirtyAddr, 4'h2);
    expect_word(4'h2, with_data || voluntary_release ? DirtyWord : XLEN'('h1002), 1'b1);
    finish_context();
    send_l2_ar(DirtyAddr, 4'h1);
    wait_probe();
    check(dut.victim_dirty_q == (with_data || voluntary_release), "Get lost dirty metadata");
    finish_probe(1'b0, 1'b0);
    expect_word(4'h1, with_data || voluntary_release ? DirtyWord : XLEN'('h1002), 1'b1);
    finish_context();
    $display("PASS: primary Get shape=%0d data=%0d C=%0d, XLEN=%0d", shape, with_data,
             voluntary_release, XLEN);
  endtask

  task automatic run_secondary(input bit voluntary_release, input bit burst_read = 1'b0);
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
    logic [7:0] outer_len;
    int reads_before;
    start_case();
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    send_l2_ar_len(DirtyAddr, 4'h1, burst_read ? 8'd2 : 8'd0, 2'b01);
    // A D secondary after the foreign Get must restore ownership cleared by Probe.
    send_l2_ar(LineAddr + XLEN'(3 * WordBytes), 4'h8);
    check(dut.ms_secondary_queue_valid[0], "secondary did not enter the primary MSHR");
    return_l2_downstream_r(outer_id, XLEN'('h1000), 1'b0);
    expect_word(4'h2, XLEN'('h1000), 1'b1);
    reads_before = directory_reads;
    for (int beat = 1; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h1000 + beat), beat == LineBeats - 1);
    wait_probe();
    finish_probe(1'b1, voluntary_release);
    expect_word(4'h1, DirtyWord, !burst_read);
    if (burst_read) begin
      expect_word(4'h1, XLEN'('h1003), 1'b0);
      expect_word(4'h1, XLEN'('h1004), 1'b1);
    end
    expect_word(4'h8, XLEN'('h1003), 1'b1);
    check(directory_reads == reads_before, "equal-tag secondary re-read directory metadata");
    finish_context();
    send_l2_ar(DirtyAddr, 4'h1);
    wait_probe();
    check(dut.victim_dirty_q, "secondary regrant lost dirty metadata");
    finish_probe(1'b0, 1'b0);
    expect_word(4'h1, DirtyWord, 1'b1);
    finish_context();
    $display("PASS: same-tag secondary Get and regrant, C=%0d burst=%0d XLEN=%0d",
             voluntary_release, burst_read, XLEN);
  endtask

  task automatic run_queued_grants;
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
    logic [7:0] outer_len;
    int reads_before;
    start_case();
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h1);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    send_l2_ar(LineAddr + XLEN'(3 * WordBytes), 4'h2);
    send_l2_ar(DirtyAddr, 4'h4);
    return_l2_downstream_r(outer_id, XLEN'('h1000), 1'b0);
    expect_word(4'h1, XLEN'('h1000), 1'b1);
    reads_before = directory_reads;
    for (int beat = 1; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h1000 + beat), beat == LineBeats - 1);
    // Queuing the future D grant must not make the foreign primary an owner.
    // The first secondary commits ownership; the next foreign secondary probes it.
    expect_word(4'h2, XLEN'('h1003), 1'b1);
    wait_probe();
    finish_probe(1'b1, 1'b0);
    expect_word(4'h4, DirtyWord, 1'b1);
    check(directory_reads == reads_before, "queued equal-tag grants re-read the directory");
    finish_context();
    $display("PASS: queued grants acquire ownership in execution order, XLEN=%0d", XLEN);
  endtask

  task automatic release_beat(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] dirty_data,
                              input int beat);
    release_addr = addr + XLEN'(beat * WordBytes);
    release_data = dirty_data;
    release_has_data = 1'b1;
    release_mask = beat == 2;
    release_last = beat == LineBeats - 1;
    release_valid = 1'b1;
    for (int cycle = 0; cycle < 128 && !release_ready; cycle++) tick(1);
    check(release_ready, "replacement C beat stalled");
    tick(1);
    release_valid = 1'b0;
  endtask

  task automatic wait_release_ack;
    for (int cycle = 0; cycle < 128 && !release_ack; cycle++) tick(1);
    check(release_ack, "replacement ReleaseAck stalled");
    tick(1);
  endtask

  task automatic expect_writeback(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] base_data,
                                  input logic [XLEN-1:0] dirty_data);
    logic [IdW-1:0] write_id;
    logic [XLEN-1:0] write_addr, write_data;
    logic [XLEN/8-1:0] write_mask;
    logic write_last;
    for (int cycle = 0; cycle < 128 && !axi_m.awvalid; cycle++) begin
      check(!axi_m.arvalid, "cached metadata skipped a dirty replacement writeback");
      tick(1);
    end
    check(axi_m.awvalid && axi_m.awaddr == addr, "dirty replacement writeback missing");
    accept_l2_downstream_write(write_id, write_addr, write_data, write_mask, write_last);
    check(write_data == base_data && &write_mask && !write_last, "writeback first beat mismatch");
    axi_m.wready = 1'b1;
    for (int beat = 1; beat < LineBeats; beat++) begin
      for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
      check(
          axi_m.wvalid && axi_m.wdata == (beat == 2 ? dirty_data : base_data + XLEN'(beat))
            && &axi_m.wstrb && axi_m.wlast == (beat == LineBeats - 1),
          "replacement writeback lost dirty data");
      tick(1);
    end
    axi_m.wready = 1'b0;
    return_l2_downstream_b(write_id, 2'b00);
  endtask

  task automatic run_replacement_metadata;
    logic [XLEN-1:0] next_line;
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
    logic [7:0] outer_len;
    next_line = LineAddr + XLEN'('h10000);
    start_case();
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    send_l2_ar(next_line, 4'h8);
    send_l2_ar(DirtyAddr, 4'h4);
    return_l2_downstream_r(outer_id, XLEN'('h1000), 1'b0);
    expect_word(4'h2, XLEN'('h1000), 1'b1);
    // Hold C active while the primary finishes, then install it dirty.
    release_beat(LineAddr, DirtyWord, 0);
    for (int beat = 1; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h1000 + beat), beat == LineBeats - 1);
    for (int beat = 1; beat < LineBeats; beat++) release_beat(LineAddr, DirtyWord, beat);
    wait_release_ack();
    expect_writeback(LineAddr, XLEN'('h1000), DirtyWord);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == next_line, "different-tag secondary did not refill");
    return_l2_downstream_r(outer_id, XLEN'('h2000), 1'b0);
    expect_word(4'h8, XLEN'('h2000), 1'b1);
    // This blocking refill replaces the original MSHR's physical way, but
    // its old primary tag remains until all secondary lists have drained.
    release_beat(next_line, DirtyWord + XLEN'(1), 0);
    for (int beat = 1; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h2000 + beat), beat == LineBeats - 1);
    for (int beat = 1; beat < LineBeats; beat++)
      release_beat(next_line, DirtyWord + XLEN'(1), beat);
    wait_release_ack();
    expect_writeback(next_line, XLEN'('h2000), DirtyWord + XLEN'(1));
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr, "old-tag secondary did not reload after replacement");
    for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, beat == 2 ? DirtyWord : XLEN'('h1000 + beat),
                             beat == LineBeats - 1);
    expect_word(4'h4, DirtyWord, 1'b1);
    finish_context();
    $display("PASS: cached MSHR metadata tracks different-tag dirty replacement, XLEN=%0d", XLEN);
  endtask

  initial begin
    run_primary(0, 1'b1);
    run_primary(0, 1'b0);
    run_primary(1, 1'b1);
    run_primary(2, 1'b1);
    run_primary(3, 1'b1);
    run_primary(0, 1'b1, 1'b1);
    run_secondary(1'b0);
    run_secondary(1'b1);
    run_secondary(1'b0, 1'b1);
    run_secondary(1'b1, 1'b1);
    run_queued_grants();
    run_replacement_metadata();
    $display("PASS: owned Get coherence across primary/secondary/C paths, XLEN=%0d", XLEN);
    $finish;
  end
endmodule
