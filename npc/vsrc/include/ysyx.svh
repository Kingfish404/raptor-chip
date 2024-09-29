`define YSYX_W_WIDTH 32

`define YSYX_IDLE       0
`define YSYX_WAIT_READY 1

`define YSYX_INST_FENCE_I    32'h0000100f

`define YSYX_OP_LUI           7'b0110111
`define YSYX_OP_AUIPC         7'b0010111
`define YSYX_OP_JAL           7'b1101111
`define YSYX_OP_JALR          7'b1100111
`define YSYX_OP_SYSTEM        7'b1110011
`define YSYX_OP_FENCE_I       7'b0001111

`define YSYX_OP_SYSTEM_FUNC3  'b0000
`define YSYX_OP_SYSTEM_ECALL  'b1110011
`define YSYX_OP_SYSTEM_EBREAK 'b1110011
`define YSYX_OP_SYSTEM_MRET   'b1110011

`define YSYX_OP_SYSTEM_CSRRW  3'b001
`define YSYX_OP_SYSTEM_CSRRS  3'b010
`define YSYX_OP_SYSTEM_CSRRC  3'b011

`define YSYX_OP_SYSTEM_CSRRWI 3'b101
`define YSYX_OP_SYSTEM_CSRRSI 3'b110
`define YSYX_OP_SYSTEM_CSRRCI 3'b111

`define YSYX_OP_R_TYPE  7'b0110011
`define YSYX_OP_I_TYPE  7'b0010011
`define YSYX_OP_IL_TYPE 7'b0000011
`define YSYX_OP_S_TYPE  7'b0100011
`define YSYX_OP_B_TYPE  7'b1100011

`define YSYX_SIGN_EXTEND(x, l, n) ({{n-l{x[l-1]}}, x})
`define YSYX_ZERO_EXTEND(x, l, n) ({{n-l{1'b0}}, x})
`define YSYX_LAMBDA(x) (x)

`define YSYX_ALU_OP_DEF   4'b1111
`define YSYX_ALU_OP_BEQ   4'b0000
`define YSYX_ALU_OP_BNE   4'b0001
`define YSYX_ALU_OP_BLT   4'b0100
`define YSYX_ALU_OP_BGE   4'b0101
`define YSYX_ALU_OP_BLTU  4'b0110
`define YSYX_ALU_OP_BGEU  4'b0111

`define YSYX_ALU_OP_LB    4'b0000
`define YSYX_ALU_OP_LH    4'b0001
`define YSYX_ALU_OP_LW    4'b0010

`define YSYX_ALU_OP_LBU   4'b0100
`define YSYX_ALU_OP_LHU   4'b0101

`define YSYX_ALU_OP_SB    4'b0000
`define YSYX_ALU_OP_SH    4'b0001
`define YSYX_ALU_OP_SW    4'b0010

`define YSYX_ALU_OP_ADD   4'b0000
`define YSYX_ALU_OP_SUB   4'b1000
`define YSYX_ALU_OP_SLT   4'b0010
`define YSYX_ALU_OP_SLE   4'b1010
`define YSYX_ALU_OP_SLTU  4'b0011
`define YSYX_ALU_OP_SLEU  4'b1011
`define YSYX_ALU_OP_XOR   4'b0100
`define YSYX_ALU_OP_OR    4'b0110
`define YSYX_ALU_OP_AND   4'b0111
`define YSYX_ALU_OP_NAND  4'b1111

`define YSYX_ALU_OP_SLL   4'b0001
`define YSYX_ALU_OP_SRL   4'b0101
`define YSYX_ALU_OP_SRA   4'b1101

`define YSYX_BUS_FSM() \
always @(*) begin \
  state = 0; \
  case (state) \
    `YSYX_IDLE:       begin state = ((valid_o ? `YSYX_WAIT_READY : state)); end \
    `YSYX_WAIT_READY: begin state = ((next_ready ? `YSYX_IDLE : state));       end \
  endcase \
end

`define ASSERT(signal, value) \
  if (signal !== value) begin \
    $error("ASSERTION FAILED in %m: signal != value"); \
    $finish; \
  end
