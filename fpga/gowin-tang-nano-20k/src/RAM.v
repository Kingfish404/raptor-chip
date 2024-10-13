//
// instructions and data RAM
// port A: read or input 32 bit data
// port W: write 32 bit data
//

`default_nettype none
//`define DBG

module RAM #(
    parameter bit [  31:0] ADDR_WIDTH = 12,  // 2**12 = RAM depth
    parameter bit [1023:0] DATA_FILE  = ""
) (
    input wire clk,
    input wire rst,
    input wire [ADDR_WIDTH-1:0] addrA,
    output reg [DataWidth-1:0] doutA,

    input wire [ADDR_WIDTH-1:0] addrW,
    input wire [1:0] addrW_lo,
    input wire [NumCol-1:0] weA,
    input wire [DataWidth-1:0] dinA
);

  localparam unsigned AddrDepth = 2 ** ADDR_WIDTH;
  localparam unsigned ColWidth = 8;  // byte
  localparam unsigned NumCol = 4;  // 4 x 8 = 32 B
  localparam unsigned DataWidth = NumCol * ColWidth;  // data width in bits

  reg [DataWidth-1:0] data[AddrDepth];
  // note: synthesizes to SP (single port block ram)

  initial begin
    if (DATA_FILE != "") begin
      $readmemh(DATA_FILE, data, 0, AddrDepth - 1);
    end
  end

  // Port-A Operation
  always @(posedge clk) begin
    if (rst) begin
    end else begin
      if (weA != 0) begin
        // for debugging
        // $display("RAM: write %s addrW=%h, dinA=%h, weA=%b",
        // ({addrW, addrW_lo} == 16'hffff) ? "leds" :
        // ({addrW, addrW_lo} == 16'hfffe) ? "rt o" :
        // ({addrW, addrW_lo} == 16'hfffd) ? "rt i" :
        // "data",
        // {addrW, addrW_lo}, dinA, weA);
      end
      for (integer i = 0; i < NumCol; i = i + 1) begin
        if (weA[i]) begin
          data[addrW][i*ColWidth+:ColWidth] <= dinA[i*ColWidth+:ColWidth];
        end
      end
      doutA <= data[addrA];
    end
  end

endmodule

`undef DBG
`default_nettype wire
