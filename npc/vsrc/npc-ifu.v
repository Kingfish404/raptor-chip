module ysyx_23060087_IFU #(ADDR_WIDTH = 64, DATA_WIDTH = 32)(
    input clk,
    input [ADDR_WIDTH-1:0] pc,
    input [DATA_WIDTH-1:0] inst_in,
    output [DATA_WIDTH-1:0] inst
);
    assign inst = inst_in;
endmodule //ysyx_23060087_IFU
