module tb_l2_release_buffer;
`ifdef RAPT_RV64
  localparam int Xlen = 64;
`else
  localparam int Xlen = 32;
`endif
  localparam int LineWords = 64 / (Xlen / 8);
  localparam int WordBits  = $clog2(LineWords);
  logic clock = 0;
  logic reset = 1;
  logic push_valid, push_ready, push_has_data, push_mask, push_last;
  logic busy_o;
  logic [Xlen-1:0] push_addr, push_data;
  logic head_valid, head_complete, head_word_valid, head_pop, head_has_data, head_mask;
  logic [Xlen-1:0] head_addr, head_data;
  logic [WordBits-1:0] head_word;
  always #5 clock = ~clock;

  rapt_l2_release_buffer #(.Xlen(Xlen)) dut (.*);

  task automatic push(input logic [Xlen-1:0] addr, input logic [Xlen-1:0] data,
                      input logic has_data, mask, last);
    @(negedge clock);
    push_addr = addr;
    push_data = data;
    push_has_data = has_data;
    push_mask = mask;
    push_last = last;
    push_valid = 1;
    do @(posedge clock); while (!push_ready);
    @(negedge clock);
    push_valid = 0;
  endtask

  task automatic pop;
    @(negedge clock);
    head_pop = 1;
    @(posedge clock);
    @(negedge clock);
    head_pop = 0;
  endtask

  initial begin
    push_valid = 0;
    push_addr = '0;
    push_data = '0;
    push_has_data = 0;
    push_mask = 0;
    push_last = 0;
    head_pop = 0;
    head_word = '0;
    repeat (3) @(negedge clock);
    reset = 0;
    assert (!busy_o)
    else $fatal(1, "release buffer reset busy");

    // Clean release consumes one list but no data beats.
    push(Xlen'('h80000100), '0, 0, 0, 1);
    assert (busy_o && head_valid && !head_has_data && head_addr == Xlen'('h80000100))
    else $fatal(1, "clean release head");

    // The dirty request becomes visible on its first beat, while later
    // words remain unavailable until their C beats arrive.
    push(Xlen'('h80000200), Xlen'('h12340000), 1, 0, 0);
    pop();
    head_word = '0;
    #1;
    assert (head_valid && !head_complete && head_word_valid && head_has_data
            && head_addr == Xlen'('h80000200))
    else $fatal(1, "partial dirty release head");
    head_word = WordBits'(1);
    #1;
    assert (!head_word_valid)
    else $fatal(1, "unreceived dirty beat appeared valid");

    // Sparse dirty words retain their beat position; clean beats have zero
    // write mask. The first list has drained, so the second can complete.
    for (int i = 1; i < LineWords; i++)
    push(Xlen'('h80000200) + (Xlen'(i) * Xlen'(Xlen / 8)), Xlen'('h12340000 + i), 1,
         i == 1 || i == LineWords - 1, i == LineWords - 1);
    assert (busy_o && head_complete && head_valid && head_has_data
            && head_addr == Xlen'('h80000200))
    else $fatal(1, "dirty release head");
    for (int i = 0; i < LineWords; i++) begin
      head_word = WordBits'(i);
      #1;
      assert (head_word_valid && head_mask == (i == 1 || i == LineWords - 1))
      else $fatal(1, "beat mask %0d", i);
      assert (head_data == Xlen'('h12340000 + i))
      else $fatal(1, "beat data %0d", i);
    end
    pop();
    assert (!busy_o && !head_valid && push_ready)
    else $fatal(1, "buffer did not drain");
    push(Xlen'('h80000300), '0, 0, 0, 1);
    push(Xlen'('h80000400), '0, 0, 0, 1);
    assert (busy_o && !push_ready)
    else $fatal(1, "full buffer accepted third release");
    pop();
    pop();
    assert (!busy_o && push_ready)
    else $fatal(1, "two-list buffer did not drain");

    // Two dirty Releases consume the shared pool. Once the first list
    // retires, the next one reuses its lowest-numbered entries while the
    // second list's data stays intact for a possible refill retry.
    for (int list = 0; list < 2; list++) begin
      for (int word = 0; word < LineWords; word++) begin
        push(Xlen'('h80000500 + list * 64 + word * (Xlen / 8)), Xlen'('h5100 + list * 'h100 + word),
             1, 1, word == LineWords - 1);
      end
    end
    assert (&dut.used && !push_ready)
    else $fatal(1, "two dirty Releases did not fill the shared beat pool");
    for (int word = 0; word < LineWords; word++) begin
      assert (dut.entry_index[0][word] == dut.EntryBits'(word)
              && dut.entry_index[1][word] == dut.EntryBits'(LineWords + word))
      else $fatal(1, "Release beat pool did not allocate the lowest free entry");
    end
    pop();
    assert ($countones(dut.used) == LineWords && push_ready)
    else $fatal(1, "retiring a Release did not free its shared beats");
    for (int word = 0; word < LineWords; word++) begin
      head_word = WordBits'(word);
      #1;
      assert (head_word_valid && head_data == Xlen'('h5200 + word))
      else $fatal(1, "second Release changed after first list retired");
    end
    for (int word = 0; word < LineWords; word++) begin
      push(Xlen'('h80000600 + word * (Xlen / 8)), Xlen'('h5300 + word), 1, 1,
           word == LineWords - 1);
    end
    assert (&dut.used)
    else $fatal(1, "new Release did not reuse freed shared beats");
    for (int word = 0; word < LineWords; word++) begin
      assert (dut.entry_index[0][word] == dut.EntryBits'(word))
      else $fatal(1, "reallocated Release used a non-lowest free entry");
    end
    pop();
    for (int word = 0; word < LineWords; word++) begin
      head_word = WordBits'(word);
      #1;
      assert (head_word_valid && head_data == Xlen'('h5300 + word))
      else $fatal(1, "reallocated Release data was lost");
    end
    pop();
    assert (!busy_o && !(|dut.used))
    else $fatal(1, "shared Release beat pool leaked entries");
    $display("PASS: L2 release buffer XLEN=%0d", Xlen);
    $finish;
  end
endmodule
