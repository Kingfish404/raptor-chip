// Tool-flow regression fixture, not production RTL.
module synthesis_driver_good (
    input logic clock, reset, data,
    output logic result
);
  always_ff @(posedge clock)
    if (reset) result <= 1'b0;
    else result <= data;
endmodule

module synthesis_driver_missing (
    input logic clock, reset, data,
    output wire result
);
  // Deliberately missing a functional output driver. The production synthesis
  // flow must reject this before opt -undriven / setundef can turn it into zero.
endmodule
