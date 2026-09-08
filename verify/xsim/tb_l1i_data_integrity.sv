`include "rapt.svh"
// Exercise the actual default I-cache data array and behavioral 1RW SRAM.
module tb_l1i_data_integrity;
  localparam int SetBits = `RAPT_L1I_LEN, WordBits = `RAPT_L1I_LINE_LEN;
  localparam int Ways = `RAPT_L1I_N_WAYS, Words = 2 ** WordBits, Sets = 2 ** SetBits;
  localparam int WayBits = Ways > 1 ? $clog2(Ways) : 1;
  logic clock = 0, reset = 1, write_valid = 0;
  always #5 clock = ~clock;
  logic [SetBits-1:0] read_addr[Words], write_set;
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
        bit bank_write;
        bank_write = write_valid && int'(write_way) == way && int'(write_word) == word_idx;
        if (read_valid[way][word_idx] !== !(reset || bank_write))
          $fatal(
              1,
              "read validity wrong way=%0d word=%0d reset=%b write=%b",
              way,
              word_idx,
              reset,
              bank_write
          );
        if (!reset && !bank_write) begin
          if (read_index[way][word_idx] !== read_addr[word_idx])
            $fatal(1, "read index ownership lost");
          if (known[way][word_idx][read_addr[word_idx]]) begin
            if (read_data[way][word_idx] !== expected[way][word_idx][read_addr[word_idx]])
              $fatal(
                  1,
                  "torn/stale word way=%0d word=%0d set=%0d got=%h expected=%h",
                  way,
                  word_idx,
                  read_addr[word_idx],
                  read_data[way][word_idx],
                  expected[way][word_idx][read_addr[word_idx]]
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
      if (write_set == read_addr[write_word]) collisions++;
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
    foreach (read_addr[i]) read_addr[i] = 0;
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
      foreach (read_addr[i]) read_addr[i] = SetBits'(set_idx);
      step();
    end
    write_valid = 0;
    for (int set_idx = 0; set_idx < Sets; set_idx++) begin
      foreach (read_addr[i]) read_addr[i] = SetBits'(set_idx);
      step();
    end
    for (int cycle = 0; cycle < 20000; cycle++) begin
      reset = (cycle % 127) == 0;
      foreach (read_addr[i]) read_addr[i] = SetBits'(random_word());
      write_valid=(random_word()&3)!=0;
      write_way=WayBits'(random_word()%Ways);
      write_word=WordBits'(random_word());
      write_set=cycle[0] ? read_addr[write_word] : SetBits'(random_word());
      write_data=random_word()|32'h3;
      step();
    end
    $display(
        "PASS: L1I data integrity ways=%0d words=%0d sets=%0d seed=%0d checks=%0d writes=%0d collisions=%0d",
        Ways, Words, Sets, seed, checks, writes, collisions);
    $finish;
  end
endmodule
