`define ysyx_W_WIDTH 32
`define ysyx_PC_INIT `ysyx_W_WIDTH'h80000000

`define ysyx_OP_LUI           7'b0110111
`define ysyx_OP_AUIPC         7'b0010111
`define ysyx_OP_JAL           7'b1101111
`define ysyx_OP_JALR          7'b1100111
`define ysyx_OP_SYSTEM        7'b1110011
`define ysyx_OP_SYSTEM_EBREAK 7'b1110011

`define ysyx_OP_R_TYPE  7'b0110011
`define ysyx_OP_I_TYPE  7'b0010011
`define ysyx_OP_IL_TYPE 7'b0000011
`define ysyx_OP_S_TYPE  7'b0100011
`define ysyx_OP_B_TYPE  7'b1100011

`define ysyx_SIGN_EXTEND(x, l, n) ({{n-l{x[l-1]}}, x})
`define ysyx_ZERO_EXTEND(x, l, n) ({{n-l{1'b0}}, x})
`define ysyx_LAMBDA(x) (x)

`define ysyx_ALU_OP_DEF   4'b1111
`define ysyx_ALU_OP_BEQ   4'b0000
`define ysyx_ALU_OP_BNE   4'b0001
`define ysyx_ALU_OP_BLT   4'b0100
`define ysyx_ALU_OP_BGE   4'b0101
`define ysyx_ALU_OP_BLTU  4'b0110
`define ysyx_ALU_OP_BGEU  4'b0111

`define ysyx_ALU_OP_LB    4'b0000
`define ysyx_ALU_OP_LH    4'b0001
`define ysyx_ALU_OP_LW    4'b0010

`define ysyx_ALU_OP_LBU   4'b0100
`define ysyx_ALU_OP_LHU   4'b0101

`define ysyx_ALU_OP_SB    4'b0000
`define ysyx_ALU_OP_SH    4'b0001
`define ysyx_ALU_OP_SW    4'b0010

`define ysyx_ALU_OP_ADD   4'b0000
`define ysyx_ALU_OP_SUB   4'b1000
`define ysyx_ALU_OP_SLT   4'b0010
`define ysyx_ALU_OP_SLE   4'b1010
`define ysyx_ALU_OP_SLTU  4'b0011
`define ysyx_ALU_OP_SLEU  4'b1011
`define ysyx_ALU_OP_XOR   4'b0100
`define ysyx_ALU_OP_OR    4'b0110
`define ysyx_ALU_OP_AND   4'b0111
`define ysyx_ALU_OP_NAND  4'b1111

`define ysyx_ALU_OP_SLL   4'b0001
`define ysyx_ALU_OP_SRL   4'b0101
`define ysyx_ALU_OP_SRA   4'b1101
