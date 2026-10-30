// Independent reference for the registered oldest recovery request. Simulation
// walks the ring entry-by-entry; formal uses an equivalent head-segment order
// comparator so the proof size scales with Ports rather than Entries * Ports.
// Neither model uses the DUT's subtract-and-wrap age calculation.
module formal_recovery_pending #(
    parameter int Entries = 7,
    parameter int Ports = 3,
    parameter int Xlen = 8,
    parameter int GenerationBits = 4,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1,
    parameter logic [Ports-1:0] PortMask = '1
) (
    input logic clock,
    reset,
    flush,
    input logic [Entries-1:0] live,
    input logic [GenerationBits-1:0] owner_generation[Entries],
    input logic [IndexBits-1:0] head,
    input logic candidate_valid[Ports],
    input logic [IndexBits-1:0] candidate_index[Ports],
    input logic [Xlen-1:0] candidate_target[Ports],
    input logic [GenerationBits-1:0] candidate_generation[Ports],
    output logic pending,
    output logic [IndexBits-1:0] owner,
    output logic [Xlen-1:0] target,
    output logic [GenerationBits-1:0] generation,
    output logic correct
);
  rapt_recovery_pending #(
      .Entries(Entries),
      .Ports(Ports),
      .Xlen(Xlen),
      .GenerationBits(GenerationBits),
      .IndexBits(IndexBits),
      .PortMask(PortMask)
  ) dut (
      .*
  );

  logic ref_pending, next_ref_pending;
  (* keep *) logic [6:0] activated;
  logic [IndexBits-1:0] ref_owner, next_ref_owner;
  logic [Xlen-1:0] ref_target, next_ref_target;
  logic [GenerationBits-1:0] ref_generation, next_ref_generation;
  logic selected;

  function automatic logic before_in_ring(input logic [IndexBits-1:0] left,
                                          input logic [IndexBits-1:0] right);
    // [head, Entries) precedes [0, head); inside a segment raw order applies.
    if ((left >= head) == (right >= head)) return left < right;
    return left >= head;
  endfunction

  always_comb begin
    next_ref_pending = 1'b0;
    next_ref_owner = '0;
    next_ref_target = '0;
    next_ref_generation = '0;
    selected = 1'b0;

`ifdef FORMAL
    // The held transaction has tie priority over every new candidate.
    if (ref_pending && int'(ref_owner) < Entries && live[ref_owner]
        && ref_generation == owner_generation[ref_owner]) begin
      next_ref_pending = 1'b1;
      next_ref_owner = ref_owner;
      next_ref_target = ref_target;
      next_ref_generation = ref_generation;
      selected = 1'b1;
    end
    for (int p = 0; p < Ports; p++) begin
      if (PortMask[p] && candidate_valid[p] && int'(candidate_index[p]) < Entries
          && live[candidate_index[p]]
          && candidate_generation[p] == owner_generation[candidate_index[p]]
          && (!selected || before_in_ring(
              candidate_index[p], next_ref_owner
          ))) begin
        next_ref_pending = 1'b1;
        next_ref_owner = candidate_index[p];
        next_ref_target = candidate_target[p];
        next_ref_generation = candidate_generation[p];
        selected = 1'b1;
      end
    end
`else
    // Visit live entries in true ROB order. The held owner wins its age tie;
    // otherwise the first candidate port wins a same-index tie.
    for (int distance = 0; distance < Entries; distance++) begin
      automatic int index = (int'(head) + distance) % Entries;
      if (!selected && live[index]) begin
        if (ref_pending && int'(ref_owner) == index && ref_generation == owner_generation[index]) begin
          next_ref_pending = 1'b1;
          next_ref_owner = ref_owner;
          next_ref_target = ref_target;
          next_ref_generation = ref_generation;
          selected = 1'b1;
        end else begin
          for (int p = 0; p < Ports; p++) begin
            if (!selected && PortMask[p] && candidate_valid[p] && int'(candidate_index[p]) == index
                && candidate_generation[p] == owner_generation[index]) begin
              next_ref_pending = 1'b1;
              next_ref_owner = candidate_index[p];
              next_ref_target = candidate_target[p];
              next_ref_generation = candidate_generation[p];
              selected = 1'b1;
            end
          end
        end
      end
    end
`endif
    if (reset || flush) begin
      next_ref_pending = 1'b0;
      next_ref_owner = '0;
      next_ref_target = '0;
      next_ref_generation = '0;
    end
  end

  always_ff @(posedge clock) begin
    ref_pending <= next_ref_pending;
    ref_owner <= next_ref_owner;
    ref_target <= next_ref_target;
    ref_generation <= next_ref_generation;
  end

  logic past_valid = 0;
  logic prior_pending, prior_reset, prior_flush, prior_tie;
  logic [IndexBits-1:0] prior_owner;
  logic [Xlen-1:0] prior_target;
  logic [GenerationBits-1:0] prior_generation, prior_owner_generation;
  logic enabled_valid, disabled_valid, tie_request;
  always_comb begin
    enabled_valid = 0;
    disabled_valid = 0;
    tie_request = 0;
    for (int p = 0; p < Ports; p++) begin
      enabled_valid |= PortMask[p] && candidate_valid[p];
      disabled_valid |= !PortMask[p] && candidate_valid[p];
      tie_request |= PortMask[p] && candidate_valid[p] && pending
          && int'(owner) < Entries && live[owner]
          && owner_generation[owner] == generation && candidate_index[p] == owner
          && candidate_generation[p] == generation && candidate_target[p] != target;
    end
    correct = !past_valid || pending == ref_pending;
    if (past_valid && (pending || ref_pending))
      correct &= owner == ref_owner && target == ref_target && generation == ref_generation;
  end
  always_ff @(posedge clock) begin
    past_valid <= 1;
    prior_pending <= pending;
    prior_reset <= reset;
    prior_flush <= flush;
    prior_owner <= owner;
    prior_target <= target;
    prior_generation <= generation;
    prior_owner_generation <= owner_generation[owner];
    prior_tie <= tie_request;
  end
  always_comb begin
    activated = '0;
    if (past_valid && !reset && !flush) begin
      activated[0] = !pending;
      activated[1] = pending;
      activated[2] = pending && prior_pending && !enabled_valid && owner == prior_owner
          && generation == prior_generation && target == prior_target;
      activated[3] = prior_pending && prior_flush && !pending;
      activated[4] = prior_pending && !prior_reset && !prior_flush && !pending
          && prior_owner_generation != prior_generation;
      activated[5] = !pending && disabled_valid && !enabled_valid;
      activated[6] = prior_tie && !prior_reset && !prior_flush && pending
          && owner == prior_owner && generation == prior_generation && target == prior_target;
    end
  end

`ifdef FORMAL
  // Non-power-of-two configurations have unused binary head encodings.
  always_comb assume (int'(head) < Entries);
`endif
endmodule

// Synthesis-only pending-output proxy, not the full integrated ROU, which also
// consumes the owner/generation/target for publication and checkpoint restore.
// Leaving them unobserved lets synthesis report the actual fence cone as well
// as the full transaction record reported from rapt_recovery_pending itself.
module recovery_pending_fence_cost #(
    parameter int Entries = 128,
    parameter int Ports = 5,
    parameter int Xlen = 32,
    parameter int GenerationBits = 4,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic clock,
    reset,
    flush,
    input logic [Entries-1:0] live,
    input logic [GenerationBits-1:0] owner_generation[Entries],
    input logic [IndexBits-1:0] head,
    input logic candidate_valid[Ports],
    input logic [IndexBits-1:0] candidate_index[Ports],
    input logic [Xlen-1:0] candidate_target[Ports],
    input logic [GenerationBits-1:0] candidate_generation[Ports],
    output logic pending
);
  logic [IndexBits-1:0] owner;
  logic [Xlen-1:0] target;
  logic [GenerationBits-1:0] generation;
  rapt_recovery_pending #(
      .Entries(Entries),
      .Ports(Ports),
      .Xlen(Xlen),
      .IndexBits(IndexBits),
      .GenerationBits(GenerationBits)
  ) dut (
      .*
  );
endmodule
