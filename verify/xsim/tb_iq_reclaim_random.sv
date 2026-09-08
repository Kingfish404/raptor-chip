`include "rapt.svh"
`include "rapt_if.svh"
module tb_iq_reclaim_random #(
    parameter int Entries = 7,
    parameter bit Rebalance = 0,
    parameter bit InOrder = 0,
    parameter bit CheckOperandIndependence = 0,
    parameter int Ports = rapt_pkg::IntegerIssuePorts
);
  import rapt_pkg::*;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  dispatch_slot_t dispatch[DispatchWidth];
  completion_t completion[CompletionPorts];
  issue_packet_t issue[Ports];
  dpu_iq_if #(.RS_SIZE(Entries)) disp ();
  cmu_bcast_if cmu_bcast ();
  load_fast_if load_fast ();
  logic [Ports-1:0] issue_enable;
  logic [$clog2(Entries):0] occupancy;
  rapt_iq #(
      .IQ_SIZE(Entries),
      .NumIssuePorts(Ports),
      .IN_ORDER_ISSUE(InOrder),
      .RebalancePorts(Rebalance),
      .ReclaimOnIssue(1)
  ) dut (
      .cancel_valid(1'b0),
      .cancel_head('0),
      .cancel_owner('0),
      .clock,
      .reset,
      .dispatch,
      .completion,
      .disp,
      .cmu_bcast,
      .load_fast,
      .issue_enable,
      .issue,
      .occ_o(occupancy),
      .pmu_iq_full()
  );
  for (genvar s = 0; s < DispatchWidth; s++) assign disp.rs_idx[s] = disp.free_idx[s];
  int paired_issues = 0;
  if (CheckOperandIndependence) begin : g_pair
    dispatch_slot_t shadow_dispatch[DispatchWidth];
    completion_t shadow_completion[CompletionPorts];
    issue_packet_t shadow_issue[Ports];
    dpu_iq_if #(.RS_SIZE(Entries)) shadow_disp ();
    logic [$clog2(Entries):0] shadow_occupancy;
    rapt_iq #(
        .IQ_SIZE(Entries),
        .NumIssuePorts(Ports),
        .IN_ORDER_ISSUE(InOrder),
        .RebalancePorts(Rebalance),
        .ReclaimOnIssue(1)
    ) shadow (
        .cancel_valid(1'b0),
        .cancel_head('0),
        .cancel_owner('0),
        .clock,
        .reset,
        .dispatch(shadow_dispatch),
        .completion(shadow_completion),
        .disp(shadow_disp),
        .cmu_bcast,
        .load_fast,
        .issue_enable,
        .issue(shadow_issue),
        .occ_o(shadow_occupancy),
        .pmu_iq_full()
    );
    for (genvar s = 0; s < DispatchWidth; s++) begin
      assign shadow_disp.accept[s] = disp.accept[s];
      assign shadow_disp.rs_idx[s] = disp.rs_idx[s];
      always_comb begin
        shadow_dispatch[s] = dispatch[s];
        shadow_dispatch[s].op1 = ~dispatch[s].op1;
        shadow_dispatch[s].op2 = ~dispatch[s].op2;
      end
    end
    for (genvar p = 0; p < CompletionPorts; p++)
    always_comb begin
      shadow_completion[p] = completion[p];
      shadow_completion[p].result = ~completion[p].result;
    end
    always @(posedge clock)
      if (!reset) begin
        assert (occupancy == shadow_occupancy)
        else $fatal(1, "operand-dependent IQ occupancy");
        for (int s = 0; s < DispatchWidth; s++) begin
          assert (disp.free_found[s] == shadow_disp.free_found[s]
            && disp.free_idx[s] == shadow_disp.free_idx[s])
          else $fatal(1, "operand-dependent IQ allocation");
        end
        for (int p = 0; p < Ports; p++) begin
          assert (issue[p].valid == shadow_issue[p].valid)
          else $fatal(1, "operand-dependent IQ issue timing");
          if (issue[p].valid) begin
            automatic issue_packet_t a = issue[p], b = shadow_issue[p];
            assert (a.op1 == ~b.op1 && a.op2 == ~b.op2)
            else $fatal(1, "shadow data capture/wakeup did not preserve differing operands");
            a.op1 = '0;
            a.op2 = '0;
            b.op1 = '0;
            b.op2 = '0;
            assert (a == b)
            else $fatal(1, "operand-dependent IQ issue identity");
            paired_issues++;
          end
        end
      end
  end
  typedef struct packed {
    bit valid, ready;
    int age;
    phys_reg_t source;
    issue_packet_t packet;
  } entry_t;
  entry_t model[Entries];
  int issued_per_port[Ports];
  int repair_count = 0, repair_reclaim_cycles = 0;
  int waiting_head_reads = 0, waiting_nonzero_head_reads = 0;
  int flush_head_reads = 0, reset_head_checks = 0;
  logic [31:0] rng = 32'h695f32b1;
  int
      next_id = 0,
      issued_count = 0,
      reclaimed_count = 0,
      multi_reclaimed = 0,
      flush_count = 0,
      wake_count = 0;
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic xlen_t source_value(input phys_reg_t tag);
    return xlen_t'(64'hcdef_1234_0000_0000) | (xlen_t'(tag) * 13);
  endfunction
  always @(posedge clock)
    if (!reset) begin
      automatic logic [Entries-1:0] selected = '0, available = '0, reusable = '0;
      automatic int best = -1, free_index = -1, reclaims = 0;
      automatic int choice[Ports];
      automatic bit repaired = 0;
      for (int e = 0; e < Entries; e++) available[e] = !model[e].valid;
      // Check the pre-read contract even when no transfer is permitted. An
      // issued-packet-only scoreboard would also pass the old late-ready mux.
      if (InOrder && Ports == 1) begin
        automatic int head = -1;
        for (int e = 0; e < Entries; e++)
        if (model[e].valid && (head < 0 || model[e].age < model[head].age)) head = e;
        if (head >= 0) begin
          assert (issue[0].uop == model[head].packet.uop
              && issue[0].dest == model[head].packet.dest
              && issue[0].generation == model[head].packet.generation
              && issue[0].prd == model[head].packet.prd)
          else $fatal(1, "ordered head identity depends on issue readiness");
          if (cmu_bcast.flush_pipe) flush_head_reads++;
          if (!issue[0].valid) begin
            waiting_head_reads++;
            if (head != 0) waiting_nonzero_head_reads++;
          end
        end
      end
      // Independent age-number scheduler; no DUT age/selected state is read.
      for (int p = 0; p < Ports; p++) begin
        best = -1;
        for (int e = 0; e < Entries; e++)
        if(!cmu_bcast.flush_pipe && model[e].valid && !selected[e]
            && (InOrder || (model[e].ready && issue_enable[p]
                && model[e].packet.uop.schedule.issue_ports[p]))
            && (best<0 || model[e].age<model[best].age))
          best = e;
        if (InOrder && best >= 0)
          if (!model[best].ready || !issue_enable[p]
              || !model[best].packet.uop.schedule.issue_ports[p])
            best = -1;
        choice[p] = best;
        if (best >= 0) selected[best] = 1;
      end
      // Model bounded augmentation using integer entry identities and ages,
      // not the DUT's age matrix, candidate vectors or generated stages.
      if (Rebalance && !InOrder && !cmu_bcast.flush_pipe)
        for (int p = 0; p < Ports; p++)
        if (issue_enable[p] && choice[p] < 0) begin
          automatic int replacement = -1, donor = -1;
          for (int e = 0; e < Entries; e++)
          if (model[e].valid && model[e].ready && !selected[e]) begin
            automatic int candidate_donor = -1;
            for (int d = 0; d < Ports; d++)
            if (candidate_donor < 0 && d != p && choice[d] >= 0)
              if (model[choice[d]].packet.uop.schedule.issue_ports[p] &&
                        model[e].packet.uop.schedule.issue_ports[d])
                candidate_donor = d;
            if (candidate_donor >= 0 &&
                    (replacement < 0 || model[e].age < model[replacement].age)) begin
              replacement = e;
              donor = candidate_donor;
            end
          end
          if (replacement >= 0) begin
            choice[p] = choice[donor];
            choice[donor] = replacement;
            selected[replacement] = 1;
            repair_count++;
            repaired = 1;
          end
        end
      for (int p = 0; p < Ports; p++) begin
        best = choice[p];
        assert (issue[p].valid == (best >= 0))
        else $fatal(1, "issue eligibility/order mismatch");
        if (best >= 0) begin
          assert (issue[p] == model[best].packet)
          else $fatal(1, "issued payload/value mismatch");
          selected[best] = 1;
          issued_count++;
          issued_per_port[p]++;
        end
      end
      reusable = selected;
      // The free identity contract prefers old free entries over issuing ones.
      for (int s = 0; s < DispatchWidth; s++) begin
        free_index = -1;
        for (int e = Entries - 1; e >= 0; e--) if (available[e]) free_index = e;
        if (free_index >= 0) available[free_index] = 0;
        else begin
          for (int e = Entries - 1; e >= 0; e--) if (reusable[e]) free_index = e;
          if (free_index >= 0) reusable[free_index] = 0;
        end
        assert (disp.free_found[s] == (free_index >= 0))
        else $fatal(1, "free/reclaim capacity mismatch");
        if (free_index >= 0)
          assert (int'(disp.free_idx[s]) == free_index)
          else $fatal(1, "free/reclaim rank mismatch");
      end
      if (cmu_bcast.flush_pipe) begin
        foreach (model[e]) model[e] = '0;
        flush_count++;
      end else begin
        for (int s = 0; s < DispatchWidth; s++)
        if (disp.accept[s] && model[disp.rs_idx[s]].valid) begin
          assert (selected[disp.rs_idx[s]])
          else $fatal(1, "overwrote non-issuing resident");
          reclaims++;
        end
        reclaimed_count += reclaims;
        if (repaired && reclaims > 0) repair_reclaim_cycles++;
        if (reclaims > 1) multi_reclaimed++;
        for (int e = 0; e < Entries; e++) begin
          if (selected[e]) model[e].valid = 0;
          if (model[e].valid && !model[e].ready)
            foreach (completion[p])
            if (completion[p].valid && completion[p].prd == model[e].source) begin
              model[e].packet.op1 = completion[p].result;
              model[e].ready = 1;
              wake_count++;
            end
        end
        for (int s = 0; s < DispatchWidth; s++)
        if (disp.accept[s]) begin
          automatic int e = int'(disp.rs_idx[s]);
          assert (!model[e].valid)
          else $fatal(1, "allocation collided with live entry");
          model[e] = '0;
          model[e].valid = 1;
          model[e].ready = dispatch[s].pr1 == 0;
          model[e].age = int'(dispatch[s].uop.pc);
          model[e].source = dispatch[s].pr1;
          model[e].packet.valid = 1;
          model[e].packet.uop = dispatch[s].uop;
          model[e].packet.op1 = dispatch[s].op1;
          model[e].packet.op2 = dispatch[s].op2;
          model[e].packet.prd = dispatch[s].prd;
          model[e].packet.dest = dispatch[s].dest;
          model[e].packet.generation = dispatch[s].generation;
        end
      end
      #1;
      best = 0;
      foreach (model[e]) best += int'(model[e].valid);
      assert (int'(occupancy) == best)
      else $fatal(1, "allocation/issue occupancy mismatch");
    end
  initial begin
    assert (Entries > 0 && Ports > 0 && Ports <= 16)
    else $fatal(1, "unsupported random harness dimensions");
    void'($value$plusargs("SEED=%d", rng));
    assert (rng != 0)
    else $fatal(1, "SEED must be nonzero");
    foreach (model[e]) model[e] = '0;
    disp.accept = '{default: 0};
    dispatch = '{default: '0};
    completion = '{default: '0};
    issue_enable = 0;
    cmu_bcast.flush_pipe = 0;
    load_fast.valid = 0;
    load_fast.prd = 0;
    load_fast.rebusy = 0;
    load_fast.confirmed = 0;
    load_fast.confirmed_prd = 0;
    load_fast.confirmed_rd = 0;
    load_fast.dest = 0;
    load_fast.generation = 0;
    load_fast.confirmed_dest = 0;
    load_fast.confirmed_generation = 0;
    load_fast.result = 0;
    repeat (3) @(negedge clock);
    reset = 0;
    for (int cycle = 0; cycle < 5000; cycle++) begin
      @(negedge clock);
      cmu_bcast.flush_pipe = cycle % 97 == 96;
      issue_enable = Ports'(random_word());
      completion = '{default: '0};
      // Wake a random waiting source; simultaneous allocation sees the same
      // forwarding that UOQ performs before passing a packet to the real IQ.
      begin
        automatic int e = int'(random_word() % Entries);
        if (model[e].valid && !model[e].ready) begin
          completion[0].valid = 1;
          completion[0].prd = model[e].source;
          completion[0].result = source_value(model[e].source);
        end
      end
      disp.accept = '{default: 0};
      #1;
      for (int s = 0; s < DispatchWidth; s++) begin
        dispatch[s] = '0;
        if (!cmu_bcast.flush_pipe && disp.free_found[s] && random_word() % 5 != 0) begin
          dispatch[s].uop.pc = xlen_t'(64'h1234_5678_0000_0000) | xlen_t'(next_id++);
          dispatch[s].uop.schedule.issue_ports = $bits(dispatch[s].uop.schedule.issue_ports)'(
              1 + random_word() % (2**Ports - 1));
          dispatch[s].op1 = xlen_t'(64'h1357_9bdf_0000_0000) | (xlen_t'(next_id) * xlen_t'(3));
          dispatch[s].op2 = xlen_t'(64'h2468_ace0_0000_0000) | (xlen_t'(next_id) + xlen_t'(1));
          dispatch[s].prd = phys_reg_t'(next_id % 97 + 1);
          dispatch[s].dest = rob_index_t'(next_id);
          dispatch[s].generation = $bits(dispatch[s].generation)'(next_id);
          dispatch[s].pr1 = random_word() % 3 == 0 ? phys_reg_t'(next_id % 97 + 1) : '0;
          if(dispatch[s].pr1!=0 && completion[0].valid && completion[0].prd==dispatch[s].pr1) begin
            dispatch[s].op1 = completion[0].result;
            dispatch[s].pr1 = 0;
          end
          disp.accept[s] = 1;
        end
      end
      if (InOrder && Ports == 1) begin
        // Pulse reset entirely between clock edges. It must suppress valid
        // immediately without steering the unqualified payload back to slot 0.
        automatic issue_packet_t before_reset = issue[0];
        reset = 1;
        #1;
        assert (!issue[0].valid && issue[0].uop == before_reset.uop
            && issue[0].dest == before_reset.dest
            && issue[0].generation == before_reset.generation
            && issue[0].prd == before_reset.prd)
        else $fatal(1, "reset steered ordered pre-read payload or allowed issue");
        if (occupancy != 0) reset_head_checks++;
        reset = 0;
        #1;
      end
      @(posedge clock);
      #2;
    end
    @(negedge clock);
    cmu_bcast.flush_pipe = 1;
    disp.accept = '{default: 0};
    @(posedge clock);
    #2;
    assert(issued_count>1000 && reclaimed_count>100 &&
        ((Ports == 1 || Entries == 1 || DispatchWidth == 1) || multi_reclaimed>10) &&
        wake_count>100 && flush_count>20)
    else $fatal(1, "insufficient random lifecycle coverage");
    foreach (issued_per_port[p]) begin
      assert (issued_per_port[p] > 10)
      else $fatal(1, "issue port %0d was not sufficiently exercised", p);
      $display("COVER: issue port %0d issued=%0d", p, issued_per_port[p]);
    end
    if (Rebalance && !InOrder && Ports > 1) begin
      assert (repair_count > 10 && repair_reclaim_cycles > 10)
      else $fatal(1, "insufficient repair/reclaim overlap coverage");
    end
    if (InOrder && Ports == 1) begin
      assert (waiting_head_reads > 100 && (Entries == 1 || waiting_nonzero_head_reads > 100))
      else $fatal(1, "insufficient waiting-head pre-read coverage");
      $display("COVER: waiting-head reads=%0d nonzero-slot=%0d", waiting_head_reads,
               waiting_nonzero_head_reads);
      assert (flush_head_reads > 20 && reset_head_checks > 1000)
      else $fatal(1, "insufficient reset/flush pre-read coverage");
      $display("COVER: flush-head reads=%0d reset-head checks=%0d", flush_head_reads,
               reset_head_checks);
    end
    $display("COVER: repairs=%0d repair-with-reclaim-cycles=%0d", repair_count,
             repair_reclaim_cycles);
    $display(
        "CONFIG: XLEN=%0d entries=%0d ports=%0d dispatch=%0d rebalance=%0d ordered=%0d cycles=5000",
        XLENPkg, Entries, Ports, DispatchWidth, Rebalance, InOrder);
    if (CheckOperandIndependence) begin
      assert (paired_issues > 100)
      else $fatal(1, "insufficient paired issue coverage");
      $display("PASS: IQ operand-independence paired issues=%0d", paired_issues);
    end
    $display("PASS: IQ reclaim random issued=%0d reused=%0d multi-reuse=%0d wakes=%0d flushes=%0d",
             issued_count, reclaimed_count, multi_reclaimed, wake_count, flush_count);
    $finish;
  end
  initial begin
    #60000;
    $fatal(1, "IQ random timeout");
  end
endmodule
