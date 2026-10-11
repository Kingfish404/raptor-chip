`include "rapt.svh"
module tb_mshr_fill_selection #(
    parameter int Entries = 4
);
  localparam int Xlen  = `RAPT_XLEN;
  localparam int Words = 64 / (Xlen / 8);
  bit clock = 0;
  always #5 clock = ~clock;
  logic reset = 1;
  logic invalidate, invalidate_line;
  logic [Xlen-1:0] invalidate_addr;
  logic fill_ready;
  logic lookup_valid, cache_hit;
  logic [Xlen-1:0] lookup_addr;
  logic [7:0] lookup_version;
  logic req_ready, rsp_valid, rsp_error, rsp_last;
  logic [1:0] rsp_id;
  logic [Xlen-1:0] rsp_data;
  logic fill_valid[2];
  logic [Xlen-1:0] fill_addr[2];
  logic [Words-1:0] fill_mask[2];
  logic [Words*Xlen-1:0] fill_data[2];
  logic lookup_ready[2], lookup_error[2], lookup_wait[2], lookup_buffered[2];
  logic [Xlen-1:0] lookup_data[2];
  logic busy[2], wake[2], req_valid[2];
  logic [1:0] req_id[2];
  logic [Xlen-1:0] req_addr[2];

  `define MSHR_TEST_PORTS(N) \
    .clock, .reset, .invalidate, .invalidate_line, .invalidate_addr, \
    .fill_valid(fill_valid[N]), .fill_ready, .fill_addr(fill_addr[N]), \
    .fill_mask(fill_mask[N]), .fill_data(fill_data[N]), .lookup_valid, \
    .cache_hit, .lookup_addr, .lookup_version, .lookup_ready(lookup_ready[N]), \
    .lookup_error(lookup_error[N]), .lookup_wait(lookup_wait[N]), \
    .lookup_buffered(lookup_buffered[N]), .lookup_data(lookup_data[N]), \
    .busy(busy[N]), .wake(wake[N]), .req_valid(req_valid[N]), \
    .req_id(req_id[N]), .req_addr(req_addr[N]), .req_ready, \
    .rsp_valid, .rsp_id, .rsp_data, .rsp_error, .rsp_last

  rapt_l1d_mshr #(
      .Xlen(Xlen),
      .Entries(Entries),
      .LineBytes(64)
  ) gold (
      `MSHR_TEST_PORTS(0)
  );
  rapt_l1d_mshr #(
      .Xlen(Xlen),
      .Entries(Entries),
      .LineBytes(64),
      .StallFillOnLineInvalidate(1'b1)
  ) dut (
      `MSHR_TEST_PORTS(1)
  );
  `undef MSHR_TEST_PORTS

  logic [Entries-1:0] outstanding = '0;
  int beats[Entries];
  int cycles = 0;
  int accepted_requests = 0;
  int accepted_fills = 0;
  int response_beats = 0;
  int invalidation_cycles = 0;
  int masked_fills = 0;
  int invalidated_selected = 0;
  int killed_drain_beats = 0;
  int simultaneous_last_invalidation = 0;
  int global_live_flushes = 0;
  int unsigned rng = 32'h31415926;
  int run_cycles = 50000;
  string trace_path;

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  always @(posedge clock) begin
    if (reset) begin
      outstanding = '0;
      for (int e = 0; e < Entries; e++) beats[e] = 0;
    end else begin
      cycles++;
      for (int v = 1; v < 2; v++) begin
        if ({lookup_ready[v], lookup_error[v], lookup_wait[v], lookup_buffered[v],
             lookup_data[v], busy[v], wake[v], req_valid[v], req_id[v], req_addr[v]}
            !== {lookup_ready[0], lookup_error[0], lookup_wait[0], lookup_buffered[0],
                 lookup_data[0], busy[0], wake[0], req_valid[0], req_id[0], req_addr[0]})
          $fatal(1, "control/request mismatch variant=%0d cycle=%0d", v, cycles);
        if (!invalidate_line
            && {fill_valid[v], fill_addr[v], fill_mask[v], fill_data[v]}
            !== {fill_valid[0], fill_addr[0], fill_mask[0], fill_data[0]})
          $fatal(1, "fill payload mismatch variant=%0d cycle=%0d", v, cycles);
        if ((fill_valid[v] && fill_ready) !== (fill_valid[0] && fill_ready))
          $fatal(1, "fill transfer mismatch variant=%0d cycle=%0d", v, cycles);
      end
      if (invalidate_line) begin
        invalidation_cycles++;
        if (fill_ready || fill_valid[1]) $fatal(1, "exclusive-fill contract violated");
        if (fill_valid[0]) masked_fills++;
        if (dut.valid[dut.fill_id] && dut.done[dut.fill_id]
            && !dut.installed[dut.fill_id] && !dut.killed[dut.fill_id]
            && fill_addr[1][Xlen-1:6] == invalidate_addr[Xlen-1:6])
          invalidated_selected++;
      end
      if (invalidate && |outstanding) global_live_flushes++;
      if (req_valid[0] && req_ready) begin
        if (int'(req_id[0]) >= Entries || outstanding[req_id[0]])
          $fatal(1, "request reused live ID");
        outstanding[req_id[0]] = 1;
        beats[req_id[0]] = 0;
        accepted_requests++;
      end
      if (rsp_valid) begin
        if (!outstanding[rsp_id] || rsp_last != (beats[rsp_id] == Words - 1))
          $fatal(1, "invalid response stimulus");
        response_beats++;
        if (gold.killed[rsp_id]) killed_drain_beats++;
        if (rsp_last && (invalidate || invalidate_line)) simultaneous_last_invalidation++;
        if (rsp_last) outstanding[rsp_id] = 0;
        else beats[rsp_id]++;
      end
      if (fill_valid[0] && fill_ready) accepted_fills++;
      // Inspect next state after the edge: the alternate payload policy must
      // not change ownership, received data, errors, replacement, or progress.
      #1;
      if ({gold.valid, gold.sent, gold.done, gold.killed, gold.consumed,
           gold.installed, gold.replace_q}
          !== {dut.valid, dut.sent, dut.done, dut.killed, dut.consumed,
               dut.installed, dut.replace_q})
        $fatal(1, "exclusive next-state mismatch cycle=%0d", cycles);
      for (int e = 0; e < Entries; e++) begin
        if ({gold.tag[e], gold.version[e], gold.beat[e], gold.errors[e],
             gold.received[e], gold.waiting[e]}
            !== {dut.tag[e], dut.version[e], dut.beat[e], dut.errors[e],
                 dut.received[e], dut.waiting[e]})
          $fatal(1, "exclusive entry metadata mismatch cycle=%0d entry=%0d", cycles, e);
        for (int w = 0; w < Words; w++) begin
          if (gold.data[e][w] !== dut.data[e][w])
            $fatal(1, "entry data mismatch cycle=%0d entry=%0d word=%0d", cycles, e, w);
        end
      end
    end
  end

  initial begin
    invalidate = 0;
    invalidate_line = 0;
    invalidate_addr = '0;
    fill_ready = 0;
    lookup_valid = 0;
    cache_hit = 0;
    lookup_addr = '0;
    lookup_version = '0;
    req_ready = 0;
    rsp_valid = 0;
    rsp_id = '0;
    rsp_data = '0;
    rsp_error = 0;
    rsp_last = 0;
    rng ^= 32'(Xlen + Entries);
    void'($value$plusargs("SEED=%d", rng));
    void'($value$plusargs("CYCLES=%d", run_cycles));
    if ($value$plusargs("TRACE=%s", trace_path)) begin
      $dumpfile(trace_path);
      $dumpvars(0, tb_mshr_fill_selection);
    end
    repeat (4) @(negedge clock);
    reset = 0;
    for (int n = 0; n < run_cycles; n++) begin
      int selected;
      @(negedge clock);
      // Hold completed fills occasionally to exercise line kills against
      // multiple ready entries, rather than only empty-table invalidation.
      invalidate = random_word() % 251 == 0;
      invalidate_line = random_word() % 5 == 0;
      invalidate_addr = Xlen'('h80000000 + 64 * (random_word() % 16));
      if (random_word() % 3 == 0) invalidate_addr = fill_addr[1];
      fill_ready = !invalidate_line && random_word() % 3 == 0;
      lookup_valid = random_word() % 4 != 0;
      cache_hit = random_word() % 8 == 0;
      lookup_addr = Xlen'('h80000000 + 64 * (random_word() % 16)
                         + (Xlen / 8) * (random_word() % Words));
      lookup_version = 8'(random_word() % 4);
      req_ready = random_word() % 4 != 0;
      rsp_valid = 0;
      rsp_last = 0;
      rsp_error = 0;
      selected = int'(random_word() % Entries);
      for (int e = 0; e < Entries; e++) begin
        int id;
        id = (selected + e) % Entries;
        if (!rsp_valid && outstanding[id] && random_word() % 4 != 0) begin
          rsp_valid = 1;
          rsp_id = 2'(id);
          rsp_last = beats[id] == Words - 1;
          rsp_error = random_word() % 31 == 0;
          rsp_data = Xlen'(random_word());
          if (Xlen == 64) rsp_data = (rsp_data << 32) | Xlen'(random_word());
        end
      end
    end
    @(negedge clock);
    if (accepted_requests < 100 || accepted_fills < 20 || masked_fills < 5
        || invalidated_selected < 5 || killed_drain_beats < 20
        || simultaneous_last_invalidation < 10 || global_live_flushes < 5)
      $fatal(
          1,
          "vacuous coverage: req=%0d fill=%0d masked=%0d selected=%0d killed=%0d last=%0d flush=%0d",
          accepted_requests,
          accepted_fills,
          masked_fills,
          invalidated_selected,
          killed_drain_beats,
          simultaneous_last_invalidation,
          global_live_flushes
      );
    $display(
        "PASS: MSHR fill selection RV%0d entries=%0d cycles=%0d requests=%0d fills=%0d masked=%0d selected_kills=%0d killed_beats=%0d last_invalidate=%0d live_flush=%0d",
        Xlen, Entries, cycles, accepted_requests, accepted_fills, masked_fills,
        invalidated_selected, killed_drain_beats, simultaneous_last_invalidation,
        global_live_flushes);
    $finish;
  end
endmodule
