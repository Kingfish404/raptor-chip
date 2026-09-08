// Independent reference for the registered oldest recovery request. Simulation
// walks the ring entry-by-entry; formal uses an equivalent head-segment order
// comparator so the proof size scales with Ports rather than Entries * Ports.
// Neither model uses the DUT's subtract-and-wrap age calculation.
module formal_recovery_pending #(
    parameter int Entries = 7,
    parameter int Ports = 3,
    parameter int Xlen = 8,
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
      .IndexBits(IndexBits)
  ) dut (
      .*
  );

  logic ref_pending, next_ref_pending;
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
      if (candidate_valid[p] && int'(candidate_index[p]) < Entries
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
            if (!selected && candidate_valid[p] && int'(candidate_index[p]) == index
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

  always_comb begin
    correct = pending == ref_pending;
    if (pending || ref_pending)
      correct &= owner == ref_owner && target == ref_target && generation == ref_generation;
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
