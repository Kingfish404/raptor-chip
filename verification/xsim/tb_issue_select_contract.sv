// ---- tb_issue_select ----
module tb_issue_select;
  localparam int Entries = 5, Ports = 3;
  logic [Entries-1:0] valid, ready, older[Entries];
  logic [Ports-1:0] compatible[Entries], enabled;
  logic [Entries-1:0] selected[Ports], legacy[Ports], ordered[Ports];
  logic [Entries-1:0] claimed, baseline, legacy_claimed, ordered_claimed, ordered_base;
  int ranks[Entries];
  int cases = 0, baseline_issues = 0, enhanced_issues = 0, optimal_issues = 0, improvements = 0;
  logic [31:0] rng = 32'h714a19cd;
  rapt_issue_select #(
      .Entries(Entries),
      .Ports  (Ports)
  ) dut (
      .*,
      .baseline_claimed(baseline)
  );
  issue_select_reference #(
      .Entries(Entries),
      .Ports  (Ports)
  ) reference_dut (
      .*,
      .selected(legacy),
      .claimed (legacy_claimed)
  );
  rapt_issue_select #(
      .Entries(Entries),
      .Ports  (Ports),
      .InOrder(1)
  ) inorder_dut (
      .*,
      .selected(ordered),
      .claimed(ordered_claimed),
      .baseline_claimed(ordered_base)
  );
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  task automatic update_age();
    for (int o = 0; o < Entries; o++)
      for (int e = 0; e < Entries; e++) older[o][e] = ranks[o] < ranks[e];
  endtask
  task automatic check();
    logic [Entries-1:0] seen, chosen, remaining;
    bit legal, found;
    int best, code, entry, count, oldest_entry;
    #1;
    seen = '0;
    assert (baseline == legacy_claimed && (baseline & ~claimed) == '0)
    else $fatal(1, "lost baseline selection");
    for (int p = 0; p < Ports; p++) begin
      assert ($onehot0(selected[p]) && (seen & selected[p]) == '0)
      else $fatal(1, "duplicate selection");
      for (int e = 0; e < Entries; e++)
      if (selected[p][e])
        assert (valid[e] && ready[e] && enabled[p] && compatible[e][p])
        else $fatal(1, "ineligible issue");
      seen |= selected[p];
    end
    assert (seen == claimed)
    else $fatal(1, "claimed mismatch");
    // Independent exhaustive matching oracle: at most (Entries+1)^Ports assignments.
    best = 0;
    for (int assignment = 0; assignment < (Entries + 1) ** Ports; assignment++) begin
      code   = assignment;
      chosen = '0;
      legal  = 1;
      count  = 0;
      for (int p = 0; p < Ports; p++) begin
        entry = code % (Entries + 1);
        code /= (Entries + 1);
        if (entry < Entries) begin
          legal &= !chosen[entry] && valid[entry] && ready[entry] && enabled[p] && compatible[entry][p];
          chosen[entry] = 1;
          count++;
        end
      end
      if (legal && count > best) best = count;
    end
    assert ($countones(claimed) <= best)
    else $fatal(1, "invalid cardinality");
    // In-order mode preserves the head barrier even when a port is disabled.
    remaining = valid;
    for (int p = 0; p < Ports; p++) begin
      oldest_entry = 0;
      found = 0;
      for (int e = 0; e < Entries; e++)
      if (remaining[e] && (!found || ranks[e] < ranks[oldest_entry])) begin
        oldest_entry = e;
        found = 1;
      end
      chosen = '0;
      if (found && enabled[p] && ready[oldest_entry] && compatible[oldest_entry][p]) begin
        chosen[oldest_entry] = 1;
        remaining[oldest_entry] = 0;
      end
      assert (ordered[p] == chosen)
      else $fatal(1, "in-order head barrier changed");
    end
    cases++;
    baseline_issues += $countones(baseline);
    enhanced_issues += $countones(claimed);
    optimal_issues += best;
    if (claimed != baseline) improvements++;
  endtask
  initial begin
    void'($value$plusargs("SEED=%d", rng));
    assert (rng != 0)
    else $fatal(1, "SEED must be nonzero");
    valid   = '0;
    ready   = '1;
    enabled = '1;
    for (int e = 0; e < Entries; e++) begin
      ranks[e] = e;
      compatible[e] = '0;
    end
    update_age();
    // Oldest flexible uop takes port 0; younger restricted uop needs port 0.
    valid = 5'b00011;
    compatible[0] = 3'b011;
    compatible[1] = 3'b001;
    check();
    assert ($countones(baseline) == 1 && selected[0][1] && selected[1][0])
    else $fatal(1, "missing port repair");
    // A longer alternating path is deliberately not repaired: document bound.
    valid = 5'b00111;
    compatible[0] = 3'b011;
    compatible[1] = 3'b110;
    compatible[2] = 3'b001;
    check();
    assert ($countones(claimed) == 2)
    else $fatal(1, "unexpected multi-hop policy");
    for (int cycle = 0; cycle < 20000; cycle++) begin
      valid   = Entries'(random_word());
      ready   = Entries'(random_word());
      enabled = Ports'(random_word());
      for (int e = 0; e < Entries; e++) begin
        automatic int swap_index = int'(random_word() % Entries);
        automatic int old_rank = ranks[e];
        ranks[e] = ranks[swap_index];
        ranks[swap_index] = old_rank;
        compatible[e] = Ports'(random_word());
      end
      update_age();
      check();
    end
    assert (improvements > 100)
    else $fatal(1, "insufficient conflict coverage");
    $display("PASS: issue-select %0d cases, greedy=%0d repaired=%0d maximum=%0d, improved=%0d",
             cases, baseline_issues, enhanced_issues, optimal_issues, improvements);
    $finish;
  end
endmodule


// ---- tb_issue_select_large ----
// Large-capacity behavioral scoreboard. The reference uses integer age ranks,
// not the DUT's predecessor-mask reduction or donor-eligibility circuit.
module issue_large_case #(
    parameter int Entries=64,
    Ports=4
) (
    output bit done
);
  logic [Entries-1:0] valid, ready, older[Entries];
  logic [Ports-1:0] compatible[Entries], enabled;
  logic [Entries-1:0] selected[Ports], claimed, baseline_claimed;
  int rank[Entries], model_slot[Ports];
  bit [Entries-1:0] model_used, baseline;
  int best, donor, swaps, repairs = 0, cases = 0;
  bit movable;
  int unsigned rng=32'h9e3779b9 ^ Entries;
  rapt_issue_select #(
      .Entries(Entries),
      .Ports(Ports)
  ) dut (
      .*
  );

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  initial begin
    done = 0;
    for (int cycle = 0; cycle < 1000; cycle++) begin
      for (int e = 0; e < Entries; e++) rank[e] = e;
      for (int e = Entries - 1; e > 0; e--) begin
        automatic int j = int'(random_word() % (e + 1));
        swaps=rank[e];
        rank[e]=rank[j];
        rank[j]=swaps;
      end
      enabled = Ports'(random_word());
      for (int e = 0; e < Entries; e++) begin
        // Sparse readiness keeps port conflicts and augmentations observable
        // even when the queue capacity is much larger than the port count.
        valid[e]=random_word()%3!=0;
        ready[e]=random_word()%16==0;
        compatible[e]=Ports'(random_word());
      end
      for (int e = 0; e < Entries; e++)
      for (int o = 0; o < Entries; o++)
      older[e][o] = (e != o && valid[e] && valid[o]) ? rank[e] < rank[o] : 1'(random_word());

      model_used = '0;
      for (int p = 0; p < Ports; p++) begin
        best = -1;
        for (int e = 0; e < Entries; e++)
        if (enabled[p] && valid[e] && ready[e] && compatible[e][p] && !model_used[e])
          if (best < 0 || rank[e] < rank[best]) best = e;
        model_slot[p] = best;
        if (best >= 0) model_used[best] = 1;
      end
      baseline = model_used;
      for (int p = 0; p < Ports; p++)
      if (enabled[p] && model_slot[p] < 0) begin
        best=-1;
        donor=-1;
        for (int e = 0; e < Entries; e++)
        if (valid[e] && ready[e] && !model_used[e]) begin
          movable = 0;
          for (int d = 0; d < Ports; d++)
          if (d!=p && model_slot[d]>=0 && compatible[model_slot[d]][p] && compatible[e][d]) begin
            if (!movable && (best < 0 || rank[e] < rank[best])) begin
              best=e;
              donor=d;
            end
            movable = 1;
          end
        end
        if (best >= 0) begin
          model_slot[p]=model_slot[donor];
          model_slot[donor]=best;
          model_used[best]=1;
          repairs++;
        end
      end
      #1;
      assert (baseline_claimed == baseline && claimed == model_used)
      else $fatal(1, "claim mismatch Entries=%0d cycle=%0d", Entries, cycle);
      for (int p = 0; p < Ports; p++)
      for (int e = 0; e < Entries; e++)
      assert (selected[p][e] == (model_slot[p] == e))
      else $fatal(1, "selection mismatch Entries=%0d cycle=%0d port=%0d", Entries, cycle, p);
      cases++;
    end
    assert (repairs > 0)
    else $fatal(1, "augmentation coverage missing");
    $display("PASS: large issue Entries=%0d Ports=%0d cases=%0d repairs=%0d", Entries, Ports,
             cases, repairs);
    done = 1;
  end
endmodule

module tb_issue_select_large;
  wire [1:0] done;
  issue_large_case #(.Entries(64)) a (.done(done[0]));
  issue_large_case #(.Entries(128)) b (.done(done[1]));
  initial begin
    wait (&done);
    $finish;
  end
  initial begin
    #2000;
    $fatal(1, "large issue timeout");
  end
endmodule
