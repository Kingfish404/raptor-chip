// Functional stand-in for the 8x32 OpenRAM macro used by the wrapper test.
// Synthesis and STA continue to use the separate blackbox and Liberty model.
module rapt_openram_1rw_8x32 (
    input logic clk0,
    input logic csb0,
    input logic web0,
    input logic [3:0] wmask0,
    input logic [2:0] addr0,
    input logic [31:0] din0,
    output logic [31:0] dout0
);
  logic [31:0] mem[8];
  always_ff @(posedge clk0) begin
    if (!csb0) begin
      if (!web0) begin
        for (int b = 0; b < 4; b++) if (wmask0[b]) mem[addr0][8*b+:8] <= din0[8*b+:8];
      end else dout0 <= mem[addr0];
    end
  end
endmodule
