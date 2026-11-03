// Keep only pending owners strictly before the recovery owner in ROB order.
// A circular interval is either [head, owner) or [head, Entries) U [0, owner).
// XOR the two prefix masks, complementing for wrap. No per-entry subtract or
// modulo, and no per-entry mux between AND/OR interval expressions.
module rapt_rob_age_mask #(
    parameter int Entries = 128,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] pending,
    input logic fence,
    input logic [IndexBits-1:0] head,
    owner,
    output wire [Entries-1:0] eligible
);
  wire wraps = owner < head;
  for (genvar e = 0; e < Entries; e++) begin : g_entry
    wire before_head, before_owner;
    if (IndexBits'(e) == {IndexBits{1'b1}}) begin : g_maximum_index
      // No representable pointer is greater than the maximum binary index.
      assign before_head = 1'b0;
      assign before_owner = 1'b0;
    end else begin : g_compare
      assign before_head = IndexBits'(e) < head;
      assign before_owner = IndexBits'(e) < owner;
    end
    wire older = before_head ^ before_owner ^ wraps;
    assign eligible[e] = pending[e] && (!fence || older);
  end
  if (Entries < 1 || IndexBits < (Entries > 1 ? $clog2(Entries) : 1)) begin : g_invalid
    $error("Invalid rapt_rob_age_mask configuration");
  end
endmodule
