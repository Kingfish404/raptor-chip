`include "rapt.svh"

module tb_btb_storage;
  logic [2:0] done;
  btb_storage_case #(.Sets(3)) non_power_two (done[0]);
  btb_storage_case #(.Sets(8)) small_table (done[1]);
  btb_storage_case #(.Sets(`RAPT_BTB_SIZE / 2)) default_table (done[2]);
  initial begin
    wait (&done);
    $display("PASS: BTB storage, three depths, collisions, held reads, LRU and init/reset");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "BTB test timeout");
  end
endmodule

module btb_storage_case #(
    parameter int Sets = 64,
    parameter int Xlen = `RAPT_XLEN,
    parameter int IndexBits = $clog2(Sets)
) (
    output logic done = 0
);
  logic clock = 0, reset = 1, init = 0, ren = 0;
  logic [IndexBits-1:0] raddr = 0, waddr = 0;
  logic [6:0] rtag = 0, wd_tag = 0;
  logic [Xlen-1:1] rd_target, wd_target = 0;
  logic [1:0] rd_type, wd_type = 0;
  logic rd_tag_match, wen_entry = 0, wen_type = 0;
  rapt_bpu_btb #(
      .DEPTH(Sets),
      .XLEN(Xlen)
  ) dut (
      .*
  );

  // Transaction-level reference. Payload survives invalidation and type-only
  // writes require a tag match. Entry writes choose from PRE-edge contents.
  logic model_valid[Sets][2], type_known[Sets][2];
  logic [6:0] model_tag[Sets][2];
  logic [Xlen-1:1] model_target[Sets][2];
  logic [1:0] model_type[Sets][2];
  int victim[Sets], read_set = 0;
  logic [6:0] read_tag = 0;
  logic sampled = 0;
  logic [31:0] rng = 32'h731b80a5;
  int checks = 0, read_hits = 0, collisions = 0, held_writes = 0, rejected_types = 0;
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic int lookup(input int idx, input logic [6:0] tag_value);
    int found;
    found = -1;
    for (int way = 0; way < 2; way++)
    if (model_valid[idx][way] && model_tag[idx][way] == tag_value) found = way;
    return found;
  endfunction
  task automatic step;
    int old_hit, write_hit, selected, new_hit;
    clock = 0;
    #1;
    old_hit = sampled ? lookup(read_set, read_tag) : -1;
    write_hit = lookup(int'(waddr), wd_tag);
    selected = write_hit >= 0 ? write_hit : victim[waddr];
    if (reset || init) begin
      for (int idx = 0; idx < Sets; idx++) begin
        victim[idx] = 0;
        for (int way = 0; way < 2; way++) model_valid[idx][way] = 0;
      end
    end else begin
      if (wen_entry) begin
        model_valid[waddr][selected] = 1;
        model_tag[waddr][selected] = wd_tag;
        model_target[waddr][selected] = wd_target;
        victim[waddr] = 1 - selected;
        if (ren && raddr == waddr) collisions++;
        if (!ren && sampled && int'(waddr) == read_set) held_writes++;
      end else if (old_hit >= 0) victim[read_set] = 1 - old_hit;
      if (wen_type && (wen_entry || write_hit >= 0)) begin
        model_type[waddr][selected] = wd_type;
        type_known[waddr][selected] = 1;
      end else if (wen_type) rejected_types++;
      if (ren) begin
        read_set = int'(raddr);
        read_tag = rtag;
        sampled = 1;
      end
    end
    clock = 1;
    #1;
    if (sampled) begin
      new_hit = lookup(read_set, read_tag);
      if (rd_tag_match !== (new_hit >= 0))
        $fatal(1, "hit mismatch sets=%0d step=%0d", Sets, checks);
      if (new_hit >= 0) begin
        read_hits++;
        if (rd_target !== model_target[read_set][new_hit])
          $fatal(1, "target mismatch sets=%0d step=%0d", Sets, checks);
        if (type_known[read_set][new_hit] && rd_type !== model_type[read_set][new_hit])
          $fatal(1, "type mismatch sets=%0d step=%0d", Sets, checks);
      end
    end
    checks++;
    clock = 0;
    #1;
  endtask
  initial begin
    for (int idx = 0; idx < Sets; idx++) begin
      victim[idx] = 0;
      for (int way = 0; way < 2; way++) begin
        model_valid[idx][way] = 0;
        type_known[idx][way] = 0;
      end
    end
    step();
    reset = 0;
    // Two ways filled, read-hit LRU update, replacement, held-address update,
    // and a type-only miss. This also initializes every target payload.
    for (int idx = 0; idx < Sets; idx++) begin
      waddr = IndexBits'(idx);
      raddr = IndexBits'(idx);
      ren = 1;
      for (int tag_value = 1; tag_value <= 2; tag_value++) begin
        wd_tag = 7'(tag_value);
        rtag = wd_tag;
        wd_target = (Xlen-1)'({random_word(), random_word()});
        wd_type = 2'(tag_value);
        wen_entry = 1;
        wen_type = 1;
        step();
      end
      wen_entry = 0;
      wen_type = 0;
      rtag = 1;
      step();
      step();  // read-hit LRU uses the previous registered read
      ren = 0;
      wen_entry = 1;
      wen_type = 0;
      wd_tag = 3;
      wd_target = (Xlen-1)'({random_word(), random_word()});
      step();
      wd_tag = 1;
      step();  // update the target of the held hit, without ren
      wen_entry = 0;
      wen_type = 1;
      wd_type = 3;
      step();  // matching type-only update
      wd_tag = 4;
      wd_type = 0;
      step();  // unmatched type-only update must not corrupt a victim
    end
    for (int cycle = 0; cycle < 20000; cycle++) begin
      reset = cycle % 997 == 996;
      init = cycle % 251 == 250;
      ren = (random_word() & 3) != 0;
      wen_entry = (random_word() & 3) != 0;
      wen_type = (random_word() & 1) != 0;
      raddr = IndexBits'(random_word() % Sets);
      waddr = (cycle % 3 == 0) ? raddr : IndexBits'(random_word() % Sets);
      rtag = 7'(random_word() & 7);
      wd_tag = cycle % 2 == 0 ? rtag : 7'(random_word() & 7);
      wd_type = 2'(random_word());
      wd_target = (Xlen-1)'({random_word(), random_word()});
      step();
    end
    if (read_hits == 0 || collisions == 0 || held_writes == 0 || rejected_types == 0)
      $fatal(1, "vacuous BTB coverage");
    $display("PASS: BTB XLEN=%0d sets=%0d checks=%0d hits=%0d rw=%0d held=%0d type_miss=%0d", Xlen,
             Sets, checks, read_hits, collisions, held_writes, rejected_types);
    done = 1;
  end
endmodule
