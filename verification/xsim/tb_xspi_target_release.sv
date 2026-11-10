`include "rapt_soc_if.svh"

// The target must hold the final byte, then release DQ even if CS stays low
// and the host supplies more clocks. Observe only protocol pins and AXI.
module tb_xspi_target_release;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  logic clock = 0, reset = 1;
  always #5 clock = !clock;

  logic active = 0, valid = 0, write_byte = 0;
  logic [7:0] transmit = 0, received, host_dq, target_dq;
  logic done, sclk, cs_n, host_oe, target_oe;
  wire [7:0] dq = host_oe ? host_dq : (target_oe ? target_dq : 8'h00);
  axi4_if #(.XLEN(XLEN)) board ();

  rapt_xspi_byte host (
      .clock,
      .reset,
      .active_i(active),
      .valid_i(valid),
      .write_i(write_byte),
      .data_i(transmit),
      .half_period_i(4'd4),
      .data_o(received),
      .done_o(done),
      .sclk_o(sclk),
      .cs_n_o(cs_n),
      .dq_o(host_dq),
      .dq_oe_o(host_oe),
      .dq_i(dq)
  );
  rapt_xspi_target #(
      .XLEN(XLEN)
  ) target (
      .clock,
      .reset,
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .status_poll_o(),
      .axi(board)
  );

  int frame_number = 0, requested_beats = 0;
  int response_beat = 0, response_left = 0;
  int ar_count = 0, r_count = 0;
  int frames = 0, checked_bytes = 0, payload_errors = 0, release_errors = 0;
  bit require_release = 0;

  function automatic logic [XLEN-1:0] expected_word(input int frame, input int beat);
    return XLEN'(64'h91a2b3c4d5e6f708 ^ (64'h0101010101010101 * 64'(beat))
                 ^ (64'h1010101010101010 * 64'(frame)));
  endfunction

  assign board.arready = 1'b1;
  assign board.awready = 1'b0;
  assign board.wready = 1'b0;
  assign board.bvalid = 1'b0;
  assign board.bid = '0;
  assign board.bresp = '0;

  always @(posedge clock) begin
    if (reset) begin
      board.rvalid <= 1'b0;
      board.rdata <= '0;
      board.rid <= '0;
      board.rresp <= '0;
      board.rlast <= 1'b0;
      response_beat <= 0;
      response_left <= 0;
      ar_count <= 0;
      r_count <= 0;
    end else begin
      if (board.awvalid || board.wvalid) $fatal(1, "Read frame issued a write request");
      if (board.arvalid && board.arready) begin
        if (board.arlen !== 8'(requested_beats - 1) || board.arid !== 4'h3
            || board.arsize !== 3'($clog2(
                Bytes
            )) || board.arburst !== 2'b01 || board.araddr !== XLEN'(32'h20000000))
          $fatal(1, "Read header did not reach AXI unchanged");
        ar_count <= ar_count + 1;
        response_beat <= 0;
        response_left <= requested_beats - 1;
        board.rvalid <= 1'b1;
        board.rdata <= expected_word(frame_number, 0);
        board.rid <= board.arid;
        board.rresp <= 2'b00;
        board.rlast <= requested_beats == 1;
      end else if (board.rvalid && board.rready) begin
        r_count <= r_count + 1;
        if (response_left == 0) board.rvalid <= 1'b0;
        else begin
          response_beat <= response_beat + 1;
          response_left <= response_left - 1;
          board.rdata <= expected_word(frame_number, response_beat + 1);
          board.rlast <= response_left == 1;
        end
      end
    end
  end

  always @(negedge clock) begin
    if (!reset && host_oe && target_oe) $fatal(1, "Both link ends drive DQ");
    if (require_release && target_oe !== 1'b0) release_errors++;
  end

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic transfer(input bit writing, input logic [7:0] value, output logic [7:0] result);
    int budget;
    @(negedge clock);
    valid = 1;
    write_byte = writing;
    transmit = value;
    budget = 0;
    while (done !== 1'b1 && budget < 40) begin
      tick();
      budget++;
    end
    if (done !== 1'b1) $fatal(1, "Byte transfer timeout");
    result = received;
    tick();
  endtask

  task automatic read_frame(input int beats);
    logic [7:0] value;
    logic [XLEN-1:0] expected;
    int polls, before_ar, before_r, before_release;
    before_ar = ar_count;
    before_r = r_count;
    before_release = release_errors;
    frame_number++;
    requested_beats = beats;
    @(negedge clock);
    active = 1;
    transfer(1, 8'ha1, value);
    transfer(1, 8'h04, value);
    transfer(1, 8'h03, value);
    transfer(1, 8'(beats - 1), value);
    transfer(1, 8'(8 + $clog2(Bytes)), value);
    transfer(1, 8'h03, value);
    for (int lane = 0; lane < Bytes; lane++) transfer(1, 8'(64'h20000000 >> (8 * lane)), value);
    transfer(0, 8'h00, value);  // Turnaround byte precedes status polling.
    polls = 0;
    while (value[7] !== 1'b1 && polls < 16) begin
      transfer(0, 8'h00, value);
      polls++;
    end
    if (value !== 8'h80) $fatal(1, "Read status did not complete successfully");
    for (int beat = 0; beat < beats; beat++) begin
      expected = expected_word(frame_number, beat);
      for (int lane = 0; lane < Bytes; lane++) begin
        transfer(0, 8'h00, value);
        if (value !== expected[8*lane+:8]) payload_errors++;
        // This also covers the last byte: release must not truncate it.
        if (target_oe !== 1'b1) payload_errors++;
        checked_bytes++;
      end
    end
    @(negedge clock);
    valid = 0;
    // Allow the target's SCLK synchronizer to observe the last trailing edge.
    repeat (5) tick();
    if (cs_n !== 1'b0) $fatal(1, "Host ended CS before the release check");
    require_release = 1;
    repeat (12) tick();
    // Extra full byte clocks must not start a new word or re-enable DQ.
    repeat (2) transfer(0, 8'h00, value);
    @(negedge clock);
    valid = 0;
    repeat (5) tick();
    if (release_errors != before_release)
      $display("FAIL: target drives after requested payload frame=%0d LEN=%0d", frames, beats - 1);
    if (ar_count != before_ar + 1 || r_count != before_r + beats)
      $fatal(1, "Frame generated an unexpected AXI transaction count");
    @(negedge clock);
    active = 0;
    repeat (6) tick();
    require_release = 0;
    if (cs_n !== 1'b1 || target_oe !== 1'b0) $fatal(1, "Frame did not return to idle");
    frames++;
  endtask

  initial begin
    repeat (5) tick();
    @(negedge clock);
    reset = 0;
    repeat (6) tick();
    read_frame(1);  // LEN=0 must terminate after one complete word.
    read_frame(3);
    read_frame(1);  // A formerly buffered next word must not leak into this frame.
    read_frame(2);
    $display("TARGET_RELEASE XLEN=%0d frames=%0d bytes=%0d payload_errors=%0d release_errors=%0d",
             XLEN, frames, checked_bytes, payload_errors, release_errors);
    if (payload_errors != 0 || release_errors != 0)
      $fatal(1, "Target response length or last-byte contract failed");
    $display("PASS: xSPI target final byte and release, RV%0d LEN0/multibeat/CS-low clocks", XLEN);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "Target release test timeout");
  end
endmodule
