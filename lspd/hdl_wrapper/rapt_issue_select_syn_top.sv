// Isolated combinational selector timing. Clock is only the IO timing reference;
// no pipeline registers or legal-age constraints are inserted by this wrapper.
module rapt_issue_select_syn_top #(
    parameter int Entries = 16,
    parameter int Ports = 4,
    parameter bit InOrder = 0,
    parameter bit Rebalance = 1
) (
    input logic clock,
    input logic [Entries-1:0] valid,
    ready,
    input logic [Entries-1:0] older[Entries],
    input logic [Ports-1:0] compatible[Entries],
    input logic [Ports-1:0] enabled,
    output logic [Entries-1:0] selected[Ports],
    output logic [Entries-1:0] claimed,
    baseline_claimed
);
  rapt_issue_select #(
      .Entries(Entries),
      .Ports(Ports),
      .InOrder(InOrder),
      .Rebalance(Rebalance)
  ) dut (
      .valid,
      .ready,
      .older,
      .compatible,
      .enabled,
      .selected,
      .claimed,
      .baseline_claimed
  );
endmodule
