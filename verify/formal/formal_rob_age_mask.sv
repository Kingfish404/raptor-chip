// Exact arithmetic expression formerly used by ROU, also available as the
// matched baseline for standalone combinational mapping (no technology lib).
module rob_age_mask_reference #(
    parameter int Entries = 128,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] pending,
    input logic fence,
    input logic [IndexBits-1:0] head,
    owner,
    output logic [Entries-1:0] eligible
);
  always_comb begin
    for (int e = 0; e < Entries; e++) begin
      automatic int unsigned entry_age;
      automatic int unsigned recovery_age;
      entry_age = (e + Entries - int'(head)) % Entries;
      recovery_age = (int'(owner) + Entries - int'(head)) % Entries;
      eligible[e] = pending[e] && (!fence || entry_age < recovery_age);
    end
  end
endmodule

module formal_rob_age_mask #(
    parameter int Entries = 128,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] pending,
    input logic fence,
    input logic [IndexBits-1:0] head,
    owner,
    output logic correct
);
  wire [Entries-1:0] eligible, reference;
  rapt_rob_age_mask #(
      .Entries(Entries),
      .IndexBits(IndexBits)
  ) dut (
      .*
  );
  rob_age_mask_reference #(
      .Entries(Entries),
      .IndexBits(IndexBits)
  ) oracle (
      .pending,
      .fence,
      .head,
      .owner,
      .eligible(reference)
  );
  // Legal ring pointers. Non-power-of-two encodings outside the ring are not
  // architectural states; pending/fence are otherwise unconstrained.
  always_comb begin
    assume (int'(head) < Entries && int'(owner) < Entries);
    correct = eligible == reference;
  end
endmodule
