// Exercise frontend features used by the real DUT before launching RVFI jobs.
// A continuously driven int must not acquire an implicit init constraint.
module rvfi_tool_probe (
    input logic [15:0] live,
    input logic [2:0] domain,
    output logic [4:0] occupancy,
    output logic [31:0] target_out
);
  int unsigned target;
  assign target = int'(domain);
  assign target_out = target;
  assign occupancy = 5'($countones(live));
endmodule
