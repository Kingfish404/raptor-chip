`define ysyx_23060087_W_WIDTH 32
`define ysyx_23060087_PC_INIT `ysyx_23060087_W_WIDTH'h80000000


`define ysyx_23060087_OP_R_TYPE 7'b0110011
`define ysyx_23060087_OP_I_TYPE 7'b0010011
`define ysyx_23060087_OP_S_TYPE 7'b0100011
`define ysyx_23060087_OP_B_TYPE 7'b1100011
`define ysyx_23060087_OP_LUI    7'b0110111
`define ysyx_23060087_OP_AUIPC  7'b0010111
`define ysyx_23060087_OP_JAL    7'b1101111
`define ysyx_23060087_OP_JALR   7'b1100111

`define ysyx_23060087_SIGN_EXTEND(x, l, n) ({{n-l{x[l-1]}}, x})
`define ysyx_23060087_ZERO_EXTEND(x, l, n) ({{n-l{1'b0}}, x})
`define ysyx_23060087_LAMBDA(x) (x)


`define ysyx_23060087_ALU_OP_ADD 3'b001
