`include "rapt.svh"
`include "rapt_if.svh"

// Compare identical resident windows with/without an early cancellation event.
// The producer is modeled here; full ROU integration is a separate check.
module iq_recovery_window_case #(
    parameter bit InOrder = 0,
    parameter int Ports = 2,
    parameter bit Cancel = 0,
    parameter bit CheckDependencyCases = 0,
    parameter bit CheckOperandIndependence = 0
) (
    output bit done
);
  import rapt_pkg::*;
  localparam int Entries = 7;
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
  logic cancel_valid;
  int head, owner, old_dest, young_issued, old_issued;
  rapt_iq #(
      .IQ_SIZE(Entries),
      .NumIssuePorts(Ports),
      .IN_ORDER_ISSUE(InOrder),
      .ReclaimOnIssue(1'b1)
  ) dut (
      .cancel_valid,
      .cancel_head($clog2(ROBEntries)'(head)),
      .cancel_owner($clog2(ROBEntries)'(owner)),
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
  int paired_issues = 0;
  if (CheckOperandIndependence) begin : g_pair
    dispatch_slot_t shadow_dispatch[DispatchWidth];
    completion_t shadow_completion[CompletionPorts];
    issue_packet_t shadow_issue[Ports];
    dpu_iq_if #(.RS_SIZE(Entries)) shadow_disp ();
    load_fast_if shadow_fast ();
    assign shadow_fast.valid = load_fast.valid;
    assign shadow_fast.rebusy = load_fast.rebusy;
    assign shadow_fast.prd = load_fast.prd;
    assign shadow_fast.dest = load_fast.dest;
    assign shadow_fast.generation = load_fast.generation;
    assign shadow_fast.rd = load_fast.rd;
    assign shadow_fast.confirmed = load_fast.confirmed;
    assign shadow_fast.confirmed_prd = load_fast.confirmed_prd;
    assign shadow_fast.confirmed_dest = load_fast.confirmed_dest;
    assign shadow_fast.confirmed_generation = load_fast.confirmed_generation;
    assign shadow_fast.confirmed_rd = load_fast.confirmed_rd;
    assign shadow_fast.result = ~load_fast.result;
    logic [$clog2(Entries):0] shadow_occupancy;
    rapt_iq #(
        .IQ_SIZE(Entries),
        .NumIssuePorts(Ports),
        .IN_ORDER_ISSUE(InOrder),
        .ReclaimOnIssue(1)
    ) shadow (
        .cancel_valid,
        .cancel_head($clog2(ROBEntries)'(head)),
        .cancel_owner($clog2(ROBEntries)'(owner)),
        .clock,
        .reset,
        .dispatch(shadow_dispatch),
        .completion(shadow_completion),
        .disp(shadow_disp),
        .cmu_bcast,
        .load_fast(shadow_fast),
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
  bit measuring;
  always @(posedge clock)
    if (measuring && !reset && !cmu_bcast.flush_pipe)
      foreach (issue[p])
        if (issue[p].valid) begin
          if (int'(issue[p].dest) == old_dest) begin
            old_issued++;
            assert (issue[p].op1 == `RAPT_XLEN'('h55))
            else $fatal(1, "older operand was lost while recovery waited");
          end else begin
            assert ((int'(issue[p].dest) + ROBEntries - head) % ROBEntries
            > (owner + ROBEntries - head) % ROBEntries)
            else $fatal(1, "unexpected resident identity in recovery-window fixture");
            young_issued++;
          end
        end

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic enqueue(input int tag, input bit waiting);
    @(negedge clock);
    dispatch[0] = '0;
    dispatch[0].dest = $bits(dispatch[0].dest)'(tag);
    dispatch[0].uop.pc = `RAPT_XLEN'('h1000 + 4 * tag);
    dispatch[0].uop.schedule.issue_ports = '1;
    dispatch[0].pr1 = waiting ? `RAPT_PHY_LEN'(5) : '0;
    #1;
    assert (disp.free_found[0])
    else $fatal(1, "fixture IQ unexpectedly full");
    disp.rs_idx[0] = disp.free_idx[0];
    disp.accept[0] = 1;
    tick();
    disp.accept[0] = 0;
  endtask

  task automatic measure_window(input int start, input int branch);
    measuring = 0;
    issue_enable = '0;
    cancel_valid = 0;
    head = start;
    owner = branch;
    old_dest = (owner + ROBEntries - 1) % ROBEntries;
    young_issued = 0;
    old_issued = 0;
    cmu_bcast.flush_pipe = 0;
    enqueue(old_dest, 1);
    for (int n = 1; n <= 4; n++) enqueue((owner + n) % ROBEntries, 0);
    assert (occupancy == 5)
    else $fatal(1, "resident setup failed");

    // Marker corresponds to the start of the registered recovery-fence
    // interval. No new dispatch is accepted during the measurement window.
    @(negedge clock);
    measuring = 1;
    issue_enable = '1;
    cancel_valid = Cancel;
    #1;
    if (Cancel)
      foreach (issue[p])
        assert (!issue[p].valid)
        else $fatal(1, "young resident issued in the cancellation cycle");
    tick();
    cancel_valid = 0;
    if (Cancel)
      assert (occupancy == 1)
      else $fatal(1, "cancellation did not retain only the older resident");
    repeat (3) tick();
    assert (old_issued == 0)
    else $fatal(1, "unready older resident issued");
    assert (young_issued == ((InOrder || Cancel) ? 0 : 4))
    else $fatal(1, "current recovery-window behavior changed; review baseline");
    $display(
        "MEASURE: cancel=%0d in_order=%0d ports=%0d head=%0d owner=%0d window=4 younger_issued=%0d",
        Cancel, InOrder, Ports, head, owner, young_issued);

    @(negedge clock);
    completion[0].valid = 1;
    completion[0].prd = `RAPT_PHY_LEN'(5);
    completion[0].result = `RAPT_XLEN'('h55);
    tick();
    completion[0].valid = 0;
    tick();
    assert (old_issued == 1)
    else $fatal(1, "older useful work could not progress");
    cmu_bcast.flush_pipe = 1;
    #1;
    foreach (issue[p])
      assert (!issue[p].valid)
      else $fatal(1, "precise flush did not suppress issue immediately");
    tick();
    assert (occupancy == 0)
    else $fatal(1, "precise flush left a resident alive");
    measuring = 0;
  endtask

  task automatic cancellation_edges;
    measuring = 0;
    issue_enable = '0;
    cmu_bcast.flush_pipe = 0;
    cancel_valid = 0;
    head = ROBEntries - 2;
    owner = 0;
    enqueue(1, 1);  // younger resident, also test delayed wakeup after removal
    enqueue(ROBEntries - 1, 0);  // older resident must survive
    cancel_valid = 1;
    enqueue(2, 1);  // accepted young incoming must also be discarded
    cancel_valid = 0;
    assert (occupancy == 1)
    else $fatal(1, "young incoming escaped cancellation");
    cancel_valid = 1;
    enqueue(ROBEntries - 2, 0);  // older incoming is not a global enqueue flush
    cancel_valid = 0;
    assert (occupancy == 2)
    else $fatal(1, "older incoming was cancelled");
    cancel_valid = 1;
    enqueue(0, 0);  // exact owner is excluded from the strictly-younger set
    cancel_valid = 0;
    assert (occupancy == 3)
    else $fatal(1, "recovery owner was incorrectly cancelled");
    completion[0].valid = 1;
    completion[0].prd = `RAPT_PHY_LEN'(5);
    tick();
    completion[0].valid = 0;
    tick();
    assert (occupancy == 3)
    else $fatal(1, "late wakeup recreated a cancelled resident");
    cmu_bcast.flush_pipe = 1;
    tick();
    assert (occupancy == 0)
    else $fatal(1, "global flush priority failed");
    $display("PASS: cancellation incoming/owner/late-wakeup edges in_order=%0d", InOrder);
  endtask

  task automatic cancellation_fast_paths;
    localparam logic [`RAPT_XLEN-1:0] Value = `RAPT_XLEN'(64'h1234_5678_aa55_55aa);
    measuring = 0;
    for (int mode = 0; mode < 3; mode++) begin
      issue_enable = '0;
      cancel_valid = 0;
      cmu_bcast.flush_pipe = 0;
      head = 4;
      owner = 8;
      enqueue(6, 1);
      enqueue(10, 1);
      // Both consumers wait on one older producer. Its generation is not
      // required to equal either consumer's allocation generation.
      load_fast.valid = 1;
      load_fast.prd = `RAPT_PHY_LEN'(5);
      load_fast.dest = $bits(load_fast.dest)'(4);
      load_fast.generation = rob_generation_t'(3);
      load_fast.rd = arch_reg_t'(5);
      tick();
      load_fast.valid = 0;
      @(negedge clock);
      cancel_valid = 1;
      issue_enable = '1;
      load_fast.confirmed = mode != 2;
      load_fast.confirmed_prd = `RAPT_PHY_LEN'(5);
      load_fast.confirmed_dest = $bits(load_fast.dest)'(4);
      load_fast.confirmed_rd = arch_reg_t'(5);
      load_fast.confirmed_generation = rob_generation_t'(mode == 1 ? 2 : 3);
      load_fast.result = Value;
      load_fast.valid = mode == 2;
      load_fast.rebusy = mode == 2;
      #1;
      assert (issue[0].valid == (mode == 0))
      else $fatal(1, "cancel/confirm/rebusy eligibility mismatch mode=%0d", mode);
      if (mode == 0)
        assert (int'(issue[0].dest) == 6 && issue[0].op1 == Value)
        else $fatal(1, "older fast-confirm bypass lost identity or value");
      for (int p = 1; p < Ports; p++)
      assert (!issue[p].valid)
      else $fatal(1, "younger fast-confirmed consumer escaped cancellation");
      tick();
      cancel_valid = 0;
      load_fast.valid = 0;
      load_fast.rebusy = 0;
      if (mode == 0) begin
        // A repeated confirmation after removal must not recreate either uop.
        repeat (2) tick();
      end else begin
        assert (occupancy == 1)
        else $fatal(1, "older blocked consumer was cancelled");
        load_fast.confirmed = 1;
        load_fast.confirmed_generation = rob_generation_t'(3);
        #1;
        if (mode == 2) begin
          assert (!issue[0].valid)
          else $fatal(1, "confirm resurrected a rebusied fast wake");
          tick();
          load_fast.confirmed = 0;
          completion[0].valid = 1;
          completion[0].prd = `RAPT_PHY_LEN'(5);
          completion[0].result = Value;
          tick();
          completion[0].valid = 0;
        end
        #1;
        assert (issue[0].valid && int'(issue[0].dest) == 6 && issue[0].op1 == Value)
        else $fatal(1, "older consumer failed to recover after stale confirm/rebusy");
        tick();
      end
      load_fast.confirmed = 0;
      assert (occupancy == 0)
      else $fatal(1, "fast-path case left a cancelled resident alive");
      $display("PASS: cancel fast-path mode=%0d in_order=%0d", mode, InOrder);
    end
  endtask

  task automatic cancellation_reclaim;
    int reclaimed;
    int expected_count;
    bit [ROBEntries-1:0] expected;
    measuring = 0;
    // Fill every entry: incoming allocation must use an issuing old slot,
    // not a cancelled slot. Exercise kept and discarded replacement identities.
    for (int discard = 0; discard < 2; discard++) begin
      issue_enable = '0;
      cancel_valid = 0;
      cmu_bcast.flush_pipe = 0;
      head = 7;
      owner = 13;
      for (int tag = 7; tag <= 11; tag++) enqueue(tag, 0);
      enqueue(14, 0);
      enqueue(15, 0);
      assert (int'(occupancy) == Entries)
      else $fatal(1, "reclaim setup did not fill IQ");
      @(negedge clock);
      cancel_valid = 1;
      issue_enable = '1;
      #1;
      for (int p = 0; p < Ports; p++)
      assert (issue[p].valid && int'(issue[p].dest) == 7 + p)
      else $fatal(1, "older selection changed during cancel/reclaim");
      for (int s = 0; s < DispatchWidth; s++)
      assert (disp.free_found[s] == (s < Ports))
      else $fatal(1, "cancelled slots leaked into same-cycle free capacity");
      reclaimed = int'(disp.free_idx[0]);
      assert (int'(dut.iq_dest[reclaimed]) == 7)
      else $fatal(1, "allocation did not reclaim oldest issuing slot");
      dispatch[0] = '0;
      dispatch[0].dest = $bits(dispatch[0].dest)'(discard != 0 ? 16 : 12);
      dispatch[0].generation = rob_generation_t'(3);
      dispatch[0].uop.schedule.issue_ports = '1;
      dispatch[0].op1 = `RAPT_XLEN'('hace);
      disp.rs_idx[0] = $bits(disp.rs_idx[0])'(reclaimed);
      disp.accept[0] = 1;
      tick();
      disp.accept[0] = 0;
      cancel_valid = 0;
      expected_count = Entries - 2 - Ports + (discard != 0 ? 0 : 1);
      assert (int'(occupancy) == expected_count)
      else $fatal(1, "cancel/reclaim allocation priority lost an owner");
      expected = '0;
      for (int tag = 7 + Ports; tag <= 11; tag++) expected[tag] = 1;
      if (discard == 0) expected[12] = 1;
      while (|expected) begin
        @(negedge clock);
        foreach (issue[p])
        if (issue[p].valid) begin
          assert (expected[issue[p].dest])
          else $fatal(1, "unexpected or duplicate reclaimed owner");
          expected[issue[p].dest] = 0;
          if (int'(issue[p].dest) == 12)
            assert (issue[p].generation == rob_generation_t'(3) && issue[p].op1 == `RAPT_XLEN'('hace))
            else $fatal(1, "reclaimed payload/generation was overwritten by old issue clear");
        end
        tick();
      end
      assert (occupancy == 0)
      else $fatal(1, "cancel/reclaim drain left an owner alive");
      $display("PASS: cancel with issue-slot reclaim discard=%0d in_order=%0d", discard, InOrder);
    end
  endtask

  task automatic cancellation_supersession;
    measuring = 0;
    cmu_bcast.flush_pipe = 0;
    issue_enable = '0;
    cancel_valid = 0;
    head = 7;
    owner = 13;
    enqueue(9, 0);
    enqueue(11, 0);
    enqueue(14, 0);
    cancel_valid = 1;
    tick();
    cancel_valid = 0;
    assert (occupancy == 2)
    else $fatal(1, "first recovery boundary was not applied");
    @(negedge clock);
    owner = 10; // validated older recovery supersedes the first request
    cancel_valid = 1;
    issue_enable = '1;
    #1;
    assert (issue[0].valid && int'(issue[0].dest) == 9)
    else $fatal(1, "older supersession blocked surviving useful work");
    for (int p = 1; p < Ports; p++)
      assert (!issue[p].valid)
      else $fatal(1, "newly younger survivor escaped older recovery");
    repeat (2) tick();  // repeated event must not recreate either removed item
    assert (occupancy == 0)
    else $fatal(1, "supersession left a younger survivor");
    issue_enable = '0;
    cancel_valid = 0;
    head = 10;
    owner = 10;
    enqueue(10, 0);
    enqueue(11, 0);
    cancel_valid = 1;
    tick();
    cancel_valid = 0;
    assert (occupancy == 1)
    else $fatal(1, "head-equals-owner boundary failed");
    issue_enable = '1;
    #1;
    assert (issue[0].valid && int'(issue[0].dest) == 10)
    else $fatal(1, "exact recovery owner was not preserved");
    tick();
    assert (occupancy == 0)
    else $fatal(1, "owner drain failed");
    $display("PASS: older recovery supersession and head=owner in_order=%0d", InOrder);
  endtask

  // Exercise every physical dispatch slot, including lanes above the default
  // width. Rotate the age classes to detect accidental slot-zero-only gating.
  task automatic cancellation_batch;
    logic [ROBEntries-1:0] remaining;
    int tags[DispatchWidth];
    for (int rotation = 0; rotation < DispatchWidth; rotation++) begin
      measuring = 0;
      issue_enable = '0;
      cancel_valid = 0;
      head = ROBEntries - 3;
      owner = 0;
      remaining = '0;
      @(negedge clock);
      cmu_bcast.flush_pipe = 1;
      tick();
      @(negedge clock);
      cmu_bcast.flush_pipe = 0;
      cancel_valid = 1;
      for (int s = 0; s < DispatchWidth; s++) begin
        int age_class;
        age_class = (s + rotation) % DispatchWidth;
        tags[s] = age_class == 1 ? owner : (head + 2 * age_class) % ROBEntries;
        dispatch[s] = '0;
        dispatch[s].dest = rob_index_t'(tags[s]);
        dispatch[s].generation = rob_generation_t'(tags[s] + rotation);
        dispatch[s].op1 = `RAPT_XLEN'(64'h7654_3210_0000_0000) + `RAPT_XLEN'(tags[s]);
        dispatch[s].uop.schedule.issue_ports = '1;
        if ((tags[s] + ROBEntries - head) % ROBEntries <= (owner + ROBEntries - head) % ROBEntries)
          remaining[tags[s]] = 1;
      end
      #1;
      for (int s = 0; s < DispatchWidth; s++) begin
        assert (disp.free_found[s])
        else $fatal(1, "batch slot lacks capacity");
        disp.rs_idx[s] = disp.free_idx[s];
        disp.accept[s] = 1;
        for (int older = 0; older < s; older++)
        assert (disp.free_idx[s] != disp.free_idx[older])
        else $fatal(1, "batch allocation aliases another slot");
      end
      tick();
      foreach (disp.accept[s]) disp.accept[s] = 0;
      cancel_valid = 0;
      assert (int'(occupancy) == $countones(remaining))
      else $fatal(1, "batch cancellation retained wrong occupancy");
      @(negedge clock);
      issue_enable = '1;
      for (int cycle = 0; cycle < Entries; cycle++) begin
        #1;
        foreach (issue[p])
        if (issue[p].valid) begin
          int tag;
          tag = int'(issue[p].dest);
          assert (remaining[tag])
          else $fatal(1, "batch issued young/duplicate identity");
          assert (issue[p].generation == rob_generation_t'(tag + rotation)
              && issue[p].op1 == `RAPT_XLEN'(64'h7654_3210_0000_0000) + `RAPT_XLEN'(tag))
          else $fatal(1, "batch survivor payload/identity mismatch");
          remaining[tag] = 0;
        end
        tick();
        @(negedge clock);
      end
      issue_enable = '0;
      assert (remaining == '0 && occupancy == '0)
      else $fatal(1, "batch survivor omitted or queue not drained");
    end
    $display("PASS: all-slot cancellation batches width=%0d in_order=%0d XLEN=%0d", DispatchWidth,
             InOrder, `RAPT_XLEN);
  endtask

  task automatic dependency_cases;
    localparam int Deps = $bits(dispatch[0].dep_valid);
    assert (CompletionPorts >= Deps)
    else $fatal(1, "dependency fixture needs distinct completion ports");
    measuring = 0;
    for (int mode = 0; mode < 4; mode++) begin
      @(negedge clock);
      issue_enable = '0;
      cancel_valid = 0;
      cmu_bcast.flush_pipe = 1;
      foreach (completion[p]) completion[p] = '0;
      tick();
      @(negedge clock);
      cmu_bcast.flush_pipe = 0;
      head = ROBEntries - 4;
      owner = 2;
      dispatch[0] = '0;
      dispatch[0].dest = 3;
      dispatch[0].generation = rob_generation_t'(7);
      dispatch[0].uop.pc = `RAPT_XLEN'('h2000 + mode * 4);
      dispatch[0].uop.schedule.issue_ports = '1;
      dispatch[0].op1 = 'h42;
      dispatch[0].op2 = 'h24;
      dispatch[0].dep_valid = '1;
      for (int d = 0; d < Deps; d++) begin
        dispatch[0].dep_tag[d] = $bits(dispatch[0].dest)'((ROBEntries - 1 + d) % ROBEntries);
        dispatch[0].dep_generation[d] = rob_generation_t'(3 + d);
        if (mode == 1) begin
          completion[d].valid = 1;
          completion[d].dest = dispatch[0].dep_tag[d];
          completion[d].generation = dispatch[0].dep_generation[d];
          completion[d].result = 'h66;
        end
      end
      #1;
      assert (disp.free_found[0])
      else $fatal(1, "dependency allocation unavailable");
      disp.rs_idx[0] = disp.free_idx[0];
      disp.accept[0] = 1;
      tick();
      @(negedge clock);
      disp.accept[0] = 0;
      foreach (completion[p]) completion[p] = '0;
      issue_enable = '1;
      #1;
      assert (issue[0].valid == (mode == 1))
      else $fatal(1, "same-cycle dependency completion eligibility mode=%0d", mode);
      if (mode == 0) begin
        for (int d = 0; d < Deps; d++) begin
          // Wrong generation, wrong tag and invalid identity must not release
          // this dependency, even after earlier dependencies have completed.
          for (int wrong = 0; wrong < 3; wrong++) begin
            @(negedge clock);
            completion[d].valid = wrong != 2;
            completion[d].dest = wrong == 1 ? $bits(completion[d].dest)'(12) : dispatch[0].dep_tag[d];
            completion[d].generation = dispatch[0].dep_generation[d] + rob_generation_t'(wrong == 0);
            completion[d].result = 'h66;
            tick();
            assert (!issue[0].valid)
            else $fatal(1, "stale/invalid dependency released d=%0d wrong=%0d", d, wrong);
          end
          @(negedge clock);
          completion[d].valid = 1;
          completion[d].dest = dispatch[0].dep_tag[d];
          completion[d].generation = dispatch[0].dep_generation[d];
          tick();
          assert (issue[0].valid == (d == Deps - 1))
          else $fatal(1, "partial dependency release eligibility d=%0d", d);
          @(negedge clock);
          completion[d] = '0;
        end
      end else if (mode >= 2) begin
        @(negedge clock);
        cancel_valid = mode == 2;
        cmu_bcast.flush_pipe = mode == 3;
        for (int d = 0; d < Deps; d++) begin
          completion[d].valid = 1;
          completion[d].dest = dispatch[0].dep_tag[d];
          completion[d].generation = dispatch[0].dep_generation[d];
          completion[d].result = 'h66;
        end
        tick();
        @(negedge clock);
        cancel_valid = 0;
        cmu_bcast.flush_pipe = 0;
        // Leave all matching completions asserted after removal.
        repeat (2) begin
          tick();
          assert (occupancy == 0 && !issue[0].valid)
          else $fatal(1, "completion resurrected cancelled/flushed dependency consumer");
        end
      end
      if (mode < 2) begin
        #1;
        assert (issue[0].valid && issue[0].dest == 3 && issue[0].op1 == 'h42 && issue[0].op2 == 'h24)
        else $fatal(1, "dependency survivor payload/identity");
        tick();
        assert (occupancy == 0)
        else $fatal(1, "dependency consumer failed to reclaim");
      end
      @(negedge clock);
      foreach (completion[p]) completion[p] = '0;
      issue_enable = '0;
      $display("PASS: dependency mode=%0d ordered=%0d cancel_fixture=%0d deps=%0d XLEN=%0d", mode,
               InOrder, Cancel, Deps, `RAPT_XLEN);
    end
  endtask

  task automatic capacity_observation;
    measuring = 0;
    issue_enable = '0;
    cancel_valid = 0;
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    for (int n = 0; n < Entries; n++) enqueue(n + 1, 1);
    tick();
    assert (dut.pmu_capacity_reason == 3)
    else $fatal(1, "capacity dependency classification");
    completion[0].valid = 1;
    completion[0].prd = `RAPT_PHY_LEN'(5);
    tick();
    completion[0].valid = 0;
    tick();
    assert (dut.pmu_capacity_reason == 4)
    else $fatal(1, "capacity disabled-port classification");
    issue_enable = '1;
    tick();
    assert (dut.pmu_capacity_reason == 0)
    else $fatal(1, "issuing entry must supply reclaim token");
    issue_enable = '0;
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    for (int n = 0; n < Entries; n++) enqueue(n + 1, 0);
    head = 0;
    owner = 0;
    cancel_valid = 1;
    tick();
    assert (dut.pmu_capacity_reason == 2)
    else $fatal(1, "capacity cancellation classification");
    cancel_valid = 0;
    tick();
    assert (dut.pmu_capacity_reason == 0)
    else $fatal(1, "cancelled entries must become free");
    for (int n = 0; n < Entries; n++) enqueue(n + 1, 0);
    cmu_bcast.flush_pipe = 1;
    tick();
    assert (dut.pmu_capacity_reason == 1)
    else $fatal(1, "capacity flush classification");
    cmu_bcast.flush_pipe = 0;
    $display("PASS: capacity observation in_order=%0d ports=%0d", InOrder, Ports);
  endtask

  initial begin
    done = 0;
    measuring = 0;
    cancel_valid = 0;
    issue_enable = '0;
    cmu_bcast.flush_pipe = 0;
    foreach (dispatch[s]) begin
      dispatch[s] = '0;
      disp.accept[s] = 0;
      disp.rs_idx[s] = '0;
    end
    foreach (completion[p]) completion[p] = '0;
    load_fast.valid = 0;
    load_fast.rebusy = 0;
    load_fast.confirmed = 0;
    load_fast.prd = '0;
    load_fast.dest = '0;
    load_fast.generation = '0;
    load_fast.rd = '0;
    load_fast.confirmed_prd = '0;
    load_fast.confirmed_dest = '0;
    load_fast.confirmed_generation = '0;
    load_fast.confirmed_rd = '0;
    load_fast.result = '0;
    tick();
    reset = 0;
    measure_window(10, 12);
    measure_window(ROBEntries - 2, 0);
    if (Cancel) begin
      cancellation_edges();
      cancellation_fast_paths();
      cancellation_reclaim();
      cancellation_supersession();
      cancellation_batch();
    end
    capacity_observation();
    if (CheckDependencyCases) dependency_cases();
    if (CheckOperandIndependence) begin
      assert (paired_issues > 0)
      else $fatal(1, "no paired recovery issues");
      $display("PASS: paired recovery cancel=%0d ordered=%0d ports=%0d issues=%0d XLEN=%0d",
               Cancel, InOrder, Ports, paired_issues, `RAPT_XLEN);
    end
    done = 1;
  end
endmodule

module tb_iq_recovery_window #(
    parameter bit CheckDependencyCases = 0,
    parameter bit CheckOperandIndependence = 0
);
  wire unordered_done, ordered_done, cancel_unordered_done, cancel_ordered_done;
  iq_recovery_window_case #(
      .CheckDependencyCases(CheckDependencyCases),
      .CheckOperandIndependence(CheckOperandIndependence),
      .InOrder(0),
      .Ports(2)
  ) unordered_case (
      .done(unordered_done)
  );
  iq_recovery_window_case #(
      .CheckDependencyCases(CheckDependencyCases),
      .CheckOperandIndependence(CheckOperandIndependence),
      .InOrder(1),
      .Ports(1)
  ) ordered_case (
      .done(ordered_done)
  );
  iq_recovery_window_case #(
      .CheckDependencyCases(CheckDependencyCases),
      .CheckOperandIndependence(CheckOperandIndependence),
      .InOrder(0),
      .Ports(2),
      .Cancel(1)
  ) cancel_unordered_case (
      .done(cancel_unordered_done)
  );
  iq_recovery_window_case #(
      .CheckDependencyCases(CheckDependencyCases),
      .CheckOperandIndependence(CheckOperandIndependence),
      .InOrder(1),
      .Ports(1),
      .Cancel(1)
  ) cancel_ordered_case (
      .done(cancel_ordered_done)
  );
  initial begin
    wait (unordered_done && ordered_done && cancel_unordered_done && cancel_ordered_done);
    $display("PASS: IQ recovery-window baseline and older-progress checks");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "recovery-window fixture timed out");
  end
endmodule
