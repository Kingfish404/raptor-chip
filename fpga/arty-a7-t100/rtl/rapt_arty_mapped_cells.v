// Bind Yosys's legacy falling-edge cells to the 7-series primitives.
// These adapters belong only to the FPGA implementation flow.
module FDCE_1 #(
    parameter INIT = 1'b0
) (
    input  wire C,
    input  wire CE,
    input  wire CLR,
    input  wire D,
    output wire Q
);
  FDCE #(
      .INIT(INIT),
      .IS_C_INVERTED(1'b1)
  ) u_ff (
      .C  (C),
      .CE (CE),
      .CLR(CLR),
      .D  (D),
      .Q  (Q)
  );
endmodule

module FDRE_1 #(
    parameter INIT = 1'b0
) (
    input  wire C,
    input  wire CE,
    input  wire R,
    input  wire D,
    output wire Q
);
  FDRE #(
      .INIT(INIT),
      .IS_C_INVERTED(1'b1)
  ) u_ff (
      .C (C),
      .CE(CE),
      .R (R),
      .D (D),
      .Q (Q)
  );
endmodule

module \$_TBUF_ (
    input  wire A,
    input  wire E,
    output wire Y
);
  assign Y = E ? A : 1'bz;
endmodule
