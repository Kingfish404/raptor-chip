`include "rapt.svh"
// Exercise the actual default I-cache data array and behavioral 1RW SRAM.
module tb_l1i_data_integrity #(
    parameter int SetBits = `RAPT_L1I_LEN,
    parameter int WordBits = `RAPT_L1I_LINE_LEN,
    parameter int Ways = `RAPT_L1I_N_WAYS
);
  localparam int Words   = 2 ** WordBits, Sets = 2 ** SetBits;
  localparam int WayBits = Ways > 1 ? $clog2(Ways) : 1;
  logic clock = 0, reset = 1, write_valid = 0;
  always #5 clock = ~clock;
  logic [SetBits-1:0] read_set, read_next_set, write_set;
  logic [WordBits-1:0] read_focus_word;
  logic read_line = 0;
  logic [WayBits-1:0] read_way = 0;
  logic [WordBits-1:0] write_word;
  logic [WayBits-1:0] write_way;
  logic [31:0] write_data, read_data[Ways][Words];
  logic [SetBits-1:0] read_index[Ways][Words];
  logic read_valid[Ways][Words];
  logic [31:0] expected[Ways][Words][Sets];
  bit known[Ways][Words][Sets];
  int unsigned rng = 1, seed = 1, checks = 0, writes = 0, collisions = 0;
  rapt_l1i_data #(
      .SetBits(SetBits),
      .WordBits(WordBits),
      .Ways(Ways)
  ) dut (
      .*
  );
  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  task automatic step;
    @(posedge clock);
    #1;
    for (int way = 0; way < Ways; way++)
      for (int word_idx = 0; word_idx < Words; word_idx++) begin
        bit requested, write_collision, line_read;
        int expected_set, chunk_distance;
        if (WordBits >= 3) begin
          line_read = read_line && Words / 8 <= Ways;
          chunk_distance = (word_idx / 2 - (int'(read_focus_word) / 4) * 2 + Words / 2)
              % (Words / 2);
          requested = chunk_distance < 4 || (line_read && way == int'(read_way));
          expected_set = line_read || word_idx / 4 == int'(read_focus_word) / 4
              ? int'(read_set) : int'(read_next_set);
        end else begin
          line_read = 0;
          requested = 1;
          expected_set = word_idx == int'(read_focus_word)
              ? int'(read_set) : int'(read_next_set);
        end
        write_collision = write_valid && int'(write_way) == way
            && (WordBits >= 3 ? int'(write_word) / 2 == word_idx / 2
                              : int'(write_word) == word_idx);
        if ((reset || !requested || write_collision) && read_valid[way][word_idx])
          $fatal(1, "unowned/reset/write-blocked data published");
        if (!reset && !write_valid && requested && (!line_read || way == int'(read_way))
            && !read_valid[way][word_idx])
          $fatal(1, "requested read missing without a write conflict");
        if (read_valid[way][word_idx]) begin
          if (read_index[way][word_idx] !== SetBits'(expected_set))
            $fatal(1, "read index ownership lost");
          if (known[way][word_idx][expected_set]) begin
            if (read_data[way][word_idx] !== expected[way][word_idx][expected_set])
              $fatal(
                  1,
                  "torn/stale word way=%0d word=%0d set=%0d got=%h expected=%h",
                  way,
                  word_idx,
                  expected_set,
                  read_data[way][word_idx],
                  expected[way][word_idx][expected_set]
              );
            checks++;
          end
        end
      end
    // SRAM storage is not reset; writes during reset still update its bytes.
    if (write_valid) begin
      expected[write_way][write_word][write_set]=write_data;
      known[write_way][write_word][write_set]=1;
      writes++;
      if (write_set == read_set || write_set == read_next_set) collisions++;
    end
  endtask
  initial begin
    if ($value$plusargs("SEED=%d", seed)) begin
    end
    if (seed == 0) $fatal(1, "zero xorshift seed");
    rng=seed;
    write_way=0;
    write_word=0;
    write_set=0;
    write_data=0;
    read_focus_word=0;
    read_set = 0;
    read_next_set = 0;
    step();
    reset = 0;
    for (int way = 0; way < Ways; way++)
    for (int word_idx = 0; word_idx < Words; word_idx++)
    for (int set_idx = 0; set_idx < Sets; set_idx++) begin
      write_valid=1;
      write_way=WayBits'(way);
      write_word=WordBits'(word_idx);
      write_set=SetBits'(set_idx);
      write_data=random_word()|32'h3;
      read_set = SetBits'(set_idx);
      read_next_set = SetBits'(set_idx);
      step();
    end
    write_valid = 0;
    for (int mode = 0; mode < 2; mode++)
    for (int focus = 0; focus < Words; focus++)
    for (int set_idx = 0; set_idx < Sets; set_idx++) begin
      read_line = 1'(mode);
      read_way = WayBits'((focus + set_idx) % Ways);
      read_focus_word = WordBits'(focus);
      read_set = SetBits'(set_idx);
      read_next_set = SetBits'(set_idx + 1);
      step();
    end
    for (int cycle = 0; cycle < 20000; cycle++) begin
      reset = (cycle % 127) == 0;
      read_set = SetBits'(random_word());
      read_next_set = SetBits'(random_word());
      read_focus_word = WordBits'(random_word());
      read_line = 1'(random_word());
      read_way = WayBits'(random_word() % Ways);
      write_valid=(random_word()&3)!=0;
      write_way=WayBits'(random_word()%Ways);
      write_word=WordBits'(random_word());
      write_set=cycle[0] ? read_set : SetBits'(random_word());
      write_data=random_word()|32'h3;
      step();
    end
    $display(
        "PASS: L1I data integrity ways=%0d words=%0d sets=%0d seed=%0d checks=%0d writes=%0d collisions=%0d",
        Ways, Words, Sets, seed, checks, writes, collisions);
    $finish;
  end
endmodule
