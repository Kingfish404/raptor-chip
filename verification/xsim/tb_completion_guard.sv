module completion_guard_case #(
    parameter int Entries = 7,
    parameter int GenerationBits = 3,
    parameter int PhysBits = 6,
    parameter int ArchBits = 5,
    parameter int Iterations = 10000,
    parameter int Seed = 1,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    output logic done
);
  logic candidate_valid;
  logic [IndexBits-1:0] candidate_index;
  logic [GenerationBits-1:0] candidate_generation;
  logic [PhysBits-1:0] candidate_prd;
  logic [ArchBits-1:0] candidate_rd;
  logic [Entries-1:0] live, executing;
  logic [GenerationBits-1:0] owner_generation[Entries];
  logic [PhysBits-1:0] owner_prd[Entries];
  logic [ArchBits-1:0] owner_rd[Entries];
  logic accept, identity_match, payload_match;
  logic identity_accept, identity_only_match, identity_payload_match;
  int unsigned random_state = Seed;

  rapt_completion_guard #(
      .Entries(Entries),
      .IndexBits(IndexBits),
      .GenerationBits(GenerationBits),
      .PhysBits(PhysBits),
      .ArchBits(ArchBits)
  ) dut (
      .*
  );
  rapt_completion_guard #(
      .Entries(Entries),
      .IndexBits(IndexBits),
      .GenerationBits(GenerationBits),
      .PhysBits(PhysBits),
      .ArchBits(ArchBits),
      .EnforcePayload(1'b0)
  ) identity_dut (
      .*,
      .accept(identity_accept),
      .identity_match(identity_only_match),
      .payload_match(identity_payload_match)
  );

  function automatic int unsigned random_word();
    random_state = random_state * 32'd1664525 + 32'd1013904223;
    return random_state;
  endfunction

  task automatic check_outputs(input string case_name);
    logic exp_identity, exp_payload, exp_accept, exp_identity_accept;
    begin
      exp_identity = 1'b0;
      exp_payload = 1'b0;
      exp_accept = 1'b0;
      exp_identity_accept = 1'b0;
      if (candidate_valid && int'(candidate_index) < Entries) begin
        exp_identity = live[candidate_index]
            && owner_generation[candidate_index] == candidate_generation;
        exp_payload = owner_prd[candidate_index] == candidate_prd
            && owner_rd[candidate_index] == candidate_rd;
        exp_accept = exp_identity && executing[candidate_index] && exp_payload;
        exp_identity_accept = exp_identity && executing[candidate_index];
      end
      #1;
      assert (identity_match == exp_identity && payload_match == exp_payload
              && accept == exp_accept)
      else
        $fatal(
            1,
            "%s: got id=%0b payload=%0b accept=%0b expected %0b/%0b/%0b",
            case_name,
            identity_match,
            payload_match,
            accept,
            exp_identity,
            exp_payload,
            exp_accept
        );
      assert (identity_only_match == exp_identity
              && identity_payload_match == exp_payload
              && identity_accept == exp_identity_accept)
      else $fatal(1, "%s: identity-only mode disagrees with reference", case_name);
    end
  endtask

  initial begin
    done = 1'b0;
    candidate_valid = 1'b0;
    candidate_index = '0;
    candidate_generation = '0;
    candidate_prd = '0;
    candidate_rd = '0;
    live = '0;
    executing = '0;
    for (int e = 0; e < Entries; e++) begin
      owner_generation[e] = GenerationBits'(e + 1);
      owner_prd[e] = PhysBits'(e + 3);
      owner_rd[e] = ArchBits'(e + 5);
    end

    candidate_valid = 1'b1;
    candidate_index = IndexBits'((Entries > 1) ? Entries - 1 : 0);
    live[candidate_index] = 1'b1;
    executing[candidate_index] = 1'b1;
    candidate_generation = owner_generation[candidate_index];
    candidate_prd = owner_prd[candidate_index];
    candidate_rd = owner_rd[candidate_index];
    check_outputs("exact owner");
    candidate_generation ^= GenerationBits'(1);
    check_outputs("stale generation");
    candidate_generation = owner_generation[candidate_index];
    candidate_prd ^= PhysBits'(1);
    check_outputs("wrong physical destination");
    candidate_prd = owner_prd[candidate_index];
    candidate_rd ^= ArchBits'(1);
    check_outputs("wrong architectural destination");
    candidate_rd = owner_rd[candidate_index];
    executing[candidate_index] = 1'b0;
    check_outputs("already completed owner");
    executing[candidate_index] = 1'b1;
    live[candidate_index] = 1'b0;
    check_outputs("dead owner");
    live[candidate_index] = 1'b1;
    candidate_valid = 1'b0;
    check_outputs("invalid candidate");
    if ((1 << IndexBits) > Entries) begin
      candidate_valid = 1'b1;
      candidate_index = IndexBits'(Entries);
      check_outputs("unused index encoding");
    end

    for (int iteration = 0; iteration < Iterations; iteration++) begin
      candidate_valid = random_word() & 1;
      candidate_index = IndexBits'(random_word());
      candidate_generation = GenerationBits'(random_word());
      candidate_prd = PhysBits'(random_word());
      candidate_rd = ArchBits'(random_word());
      live = Entries'(random_word());
      executing = Entries'(random_word());
      for (int e = 0; e < Entries; e++) begin
        owner_generation[e] = GenerationBits'(random_word());
        owner_prd[e] = PhysBits'(random_word());
        owner_rd[e] = ArchBits'(random_word());
      end
      check_outputs("random");
    end
    done = 1'b1;
  end
endmodule

module tb_completion_guard;
  logic done1, done7, done8, done64;
  completion_guard_case #(
      .Entries(1),
      .GenerationBits(1),
      .Iterations(10000),
      .Seed(11)
  ) c1 (
      done1
  );
  completion_guard_case #(
      .Entries(7),
      .GenerationBits(3),
      .Iterations(10000),
      .Seed(17)
  ) c7 (
      done7
  );
  completion_guard_case #(
      .Entries(8),
      .GenerationBits(4),
      .Iterations(10000),
      .Seed(23)
  ) c8 (
      done8
  );
  completion_guard_case #(
      .Entries(64),
      .GenerationBits(4),
      .Iterations(10000),
      .Seed(29)
  ) c64 (
      done64
  );
  initial begin
    wait (done1 && done7 && done8 && done64);
    $display(
        "PASS: completion ownership guard exact/stale/dead/payload/non-power-of-two randomized checks");
    $finish;
  end
endmodule
