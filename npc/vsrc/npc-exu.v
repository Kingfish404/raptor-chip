import "DPI-C" function void npc_exu_ebreak ();

module RegisterFile #(ADDR_WIDTH = 1, DATA_WIDTH = 1) (
  input clk,
  input [DATA_WIDTH-1:0] wdata,
  input [ADDR_WIDTH-1:0] waddr,
  input wen,
  input [ADDR_WIDTH-1:0] raddr,
  output [DATA_WIDTH-1:0] rdata,
  output [DATA_WIDTH-1:0] rfout [31:0]
);
  reg [DATA_WIDTH-1:0] rf [31:0];
  always @(posedge clk) begin
    if (wen) rf[waddr] <= wdata;
  end
  assign rdata = rf[raddr];
  assign rfout = rf;
  assign rf[0] = 0;
  assign rfout[0] = 0;
endmodule

module ysyx_23060087_EXU #(BIT_W = 64)(
    input clk,
    input [11:0] imm_I,
    input [4:0] rs1,
    input [2:0] funct3,
    input [4:0] rd,
    input [6:0] opcode,
    output reg [BIT_W-1:0] rfout [31:0]
);
    reg wen = 0;
    reg [BIT_W-1:0] wdata = 0;
    reg [4:0] waddr = 0;
    reg [BIT_W-1:0] rdata = 0;
    reg [4:0] raddr = 0;
    RegisterFile #(5, BIT_W) regs(clk, wdata, waddr, wen, raddr, rdata, rfout);
    assign waddr = rd;
    assign raddr = rs1;

    always @(posedge clk ) begin
        case ({funct3, opcode})
            10'b000_00100_11: begin
                wen = 1; wdata = rdata + {52'b0, imm_I};  // addi
            end
            10'b000_11100_11: npc_exu_ebreak();                         // ebreak
            default: wen = 0;
        endcase
    end
endmodule //ysyx_23060087_EXU
