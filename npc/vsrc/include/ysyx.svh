`ifndef YSYX_SVH
`define YSYX_SVH
`include "ysyx_config.svh"

// Instruction Set Opcodes
`define YSYX_INST_FENCE_I 32'h0000100f

`define YSYX_OP_LUI___ 7'b0110111
`define YSYX_OP_AUIPC_ 7'b0010111
`define YSYX_OP_JAL___ 7'b1101111
`define YSYX_OP_JALR__ 7'b1100111
`define YSYX_OP_SYSTEM 7'b1110011
`define YSYX_OP_FENCE_ 7'b0001111

`define YSYX_F3_CSRRW_ 3'b001
`define YSYX_F3_CSRRS_ 3'b010
`define YSYX_F3_CSRRC_ 3'b011

`define YSYX_F3_CSRRWI 3'b101
`define YSYX_F3_CSRRSI 3'b110
`define YSYX_F3_CSRRCI 3'b111

`define YSYX_OP_R_TYPE_ 7'b0110011
`define YSYX_OP_I_TYPE_ 7'b0010011
`define YSYX_OP_IL_TYPE 7'b0000011
`define YSYX_OP_S_TYPE_ 7'b0100011
`define YSYX_OP_B_TYPE_ 7'b1100011

`define YSYX_SIGN_EXTEND(x, l, n) ({{n-l{x[l-1]}}, x})
`define YSYX_ZERO_EXTEND(x, l, n) ({{n-l{1'b0}}, x})
`define YSYX_LAMBDA(x) (x)

`define YSYX_ALU_ILL_ 'b01001

`define YSYX_ALU_ADD_ 'b00000
`define YSYX_ALU_SUB_ 'b01000
`define YSYX_ALU_EQ__ 'b01100
`define YSYX_ALU_SLT_ 'b00010
`define YSYX_ALU_SLE_ 'b01010
`define YSYX_ALU_SGE_ 'b01110
`define YSYX_ALU_SLTU 'b00011
`define YSYX_ALU_SLEU 'b01011
`define YSYX_ALU_SGEU 'b01111
`define YSYX_ALU_XOR_ 'b00100
`define YSYX_ALU_OR__ 'b00110
`define YSYX_ALU_AND_ 'b00111

`define YSYX_ALU_SLL_ 'b00001
`define YSYX_ALU_SRL_ 'b00101
`define YSYX_ALU_SRA_ 'b01101

`define YSYX_ALU_MUL___ 'b11000
`define YSYX_ALU_MULH__ 'b11001
`define YSYX_ALU_MULHSU 'b11010
`define YSYX_ALU_MULHU_ 'b11011
`define YSYX_ALU_DIV___ 'b11100
`define YSYX_ALU_DIVU__ 'b11101
`define YSYX_ALU_REM___ 'b11110
`define YSYX_ALU_REMU__ 'b11111

`define YSYX_ALU_LB__ 'b00000
`define YSYX_ALU_LH__ 'b00001
`define YSYX_ALU_LW__ 'b00010
`define YSYX_ALU_LBU_ 'b00100
`define YSYX_ALU_LHU_ 'b00101

`define YSYX_ALU_SB__ 'b00000
`define YSYX_ALU_SH__ 'b00001
`define YSYX_ALU_SW__ 'b00010

`define YSYX_SB_WSTRB 'b00001
`define YSYX_SH_WSTRB 'b00011
`define YSYX_SW_WSTRB 'b01111

`define YSYX_ATO_LR__ 'b00000
`define YSYX_ATO_SC__ 'b00001
`define YSYX_ATO_SWAP 'b00010
`define YSYX_ATO_ADD_ 'b00011
`define YSYX_ATO_XOR_ 'b00100
`define YSYX_ATO_AND_ 'b00101
`define YSYX_ATO_OR__ 'b00110
`define YSYX_ATO_MIN_ 'b00111
`define YSYX_ATO_MAX_ 'b01000
`define YSYX_ATO_MINU 'b01001
`define YSYX_ATO_MAXU 'b01010

`define YSYX_WSTRB_SB 'b00001
`define YSYX_WSTRB_SH 'b00011
`define YSYX_WSTRB_SW 'b11111

// Privilege Levels
`define YSYX_PRIV_U 2'h0
`define YSYX_PRIV_S 2'h1
`define YSYX_PRIV_M 2'h3

// Supervisor-level CSR
`define YSYX_CSR_SSTATUS 'h100
`define YSYX_CSR_SIE____ 'h104
`define YSYX_CSR_STVEC__ 'h105

`define YSYX_CSR_SCOUNTE 'h106

`define YSYX_CSR_SSCRATC 'h140
`define YSYX_CSR_SEPC___ 'h141
`define YSYX_CSR_SCAUSE_ 'h142
`define YSYX_CSR_STVAL__ 'h143
`define YSYX_CSR_SIP____ 'h144
`define YSYX_CSR_SATP___ 'h180

// Machine Trap Settup
`define YSYX_CSR_MSTATUS 'h300
`define YSYX_CSR_MISA___ 'h301
`define YSYX_CSR_MEDELEG 'h302
`define YSYX_CSR_MIDELEG 'h303
`define YSYX_CSR_MIE____ 'h304
`define YSYX_CSR_MTVEC__ 'h305

`define YSYX_CSR_MSTATUSH 'h310

// Machine Trap Handling
`define YSYX_CSR_MSCRATCH 'h340
`define YSYX_CSR_MEPC___ 'h341
`define YSYX_CSR_MCAUSE_ 'h342
`define YSYX_CSR_MTVAL__ 'h343
`define YSYX_CSR_MIP____ 'h344

`define YSYX_CSR_MCYCLE_ 'hb00
`define YSYX_CSR_TIME___ 'hc01
`define YSYX_CSR_TIMEH__ 'hc81

// Machine Information Registers
`define YSYX_CSR_MVENDORID 'hf11
`define YSYX_CSR_MARCHID__ 'hf12
`define YSYX_CSR_IMPID____ 'hf13
`define YSYX_CSR_MHARTID__ 'hf14

// CSR_MSTATUS FLAGS
`define YSYX_CSR_MSTATUS_MPP_ 12:11
`define YSYX_CSR_MSTATUS_MPIE 7
`define YSYX_CSR_MSTATUS_MIE_ 3

// Macros
`define ASSERT(signal, str) \
  if (signal == 'h0) begin \
    $write("ASSERTION FAILED in %m, %s\n", str); \
    $finish; \
  end

`endif
