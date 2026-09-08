module ras_case #(
    parameter int Depth = 3
) (
    output bit done
);
  bit clock = 0;
  always #5 clock = ~clock;
  logic reset = 1, clear = 0, flush = 0;
  logic spec_push = 0, spec_pop = 0, commit_push = 0, commit_pop = 0;
  logic [31:0] spec_addr = 0, commit_addr = 0, top_addr;
  logic top_valid;
  bit [31:0] spec_model[$], commit_model[$];
  int unsigned rng;
  int seed;
  rapt_ras #(.Depth(Depth)) dut (.*);

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  // Independent ordered list model: no DUT circular pointers/index arithmetic.
  task automatic advance_model(ref bit [31:0] stack[$], input bit push, pop, input bit [31:0] addr);
    if (pop && stack.size() != 0) void'(stack.pop_back());
    if (push) begin
      if (stack.size() == Depth) void'(stack.pop_front());
      stack.push_back(addr);
    end
  endtask

  task automatic step(input bit sp, so, cp, co, fl, cl);
    @(negedge clock);
    spec_push = sp;
    spec_pop = so;
    commit_push = cp;
    commit_pop = co;
    flush = fl;
    clear = cl;
    spec_addr = random_word();
    commit_addr = random_word();
    if (reset || clear) begin
      spec_model.delete();
      commit_model.delete();
    end else begin
      advance_model(commit_model, cp, co, commit_addr);
      if (flush) spec_model = commit_model;
      else advance_model(spec_model, sp, so, spec_addr);
    end
    @(posedge clock);
    #1;
    assert (top_valid == (spec_model.size() != 0))
    else $fatal(1, "depth %0d valid", Depth);
    assert (top_addr == (spec_model.size() == 0 ? 0 : spec_model[$]))
    else $fatal(1, "depth %0d top", Depth);
    assert (int'(dut.speculative.count) == spec_model.size());
    assert (int'(dut.committed.count) == commit_model.size());
  endtask

  initial begin
    done = 0;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rng = 32'(seed) ^ (32'h9e3779b9 * Depth);
    step(0, 0, 0, 0, 0, 0);
    reset = 0;
    repeat (Depth + 2) step(0, 1, 0, 1, 0, 0);  // Empty never wraps valid.
    repeat (Depth) step(0, 0, 1, 0, 1, 0);  // Fill committed + post-commit restore.
    repeat (Depth * 3) step(1, 0, 0, 0, 0, 0);  // Wrong path overwrites every entry.
    step(1, 1, 0, 0, 1, 0);  // Flush wins speculative action and repairs data.
    repeat (Depth + 2) step(0, 1, 0, 1, 1, 0);  // Drain committed + flush/pop.
    step(1, 1, 1, 1, 1, 0);  // Empty coroutine action creates one entry.
    step(1, 1, 1, 1, 1, 1);  // Security clear wins everything.
    for (int i = 0; i < 10000; i++) begin
      automatic int unsigned controls = random_word();
      step(controls[0], controls[1], controls[2], controls[3], controls[6:4] == 0,
           controls[12:7] == 0);
    end
    $display("PASS: RAS depth=%0d seed=%0d 10000 random transitions + boundaries", Depth, seed);
    done = 1;
  end
endmodule

module tb_ras;
  bit [3:0] done;
  ras_case #(.Depth(1)) one (done[0]);
  ras_case #(.Depth(3)) three (done[1]);
  ras_case #(.Depth(4)) four (done[2]);
  ras_case #(.Depth(16)) sixteen (done[3]);
  initial begin
    for (int rd = 0; rd < 32; rd++)
    for (int rs = 0; rs < 32; rs++) begin
      automatic logic [31:0] inst = (32'(rs) << 15) | (32'(rd) << 7) | 32'h67;
      automatic rapt_pkg::ras_action_t action = rapt_pkg::ras_action(inst);
      assert (action.push == (rd inside {1, 5}));
      assert (action.pop == ((rs inside {1, 5}) && rd != rs));
      inst[6:0] = 7'h6f;
      action = rapt_pkg::ras_action(inst);
      assert (action.push == (rd inside {1, 5}) && !action.pop);
      action = rapt_pkg::ras_action(32'h13);
      assert (action == '0);
    end
    wait (&done);
    $display("PASS: RAS family and exhaustive JAL/JALR register hints");
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "RAS timeout");
  end
endmodule
