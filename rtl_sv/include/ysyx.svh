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
`define YSYX_OP_AMO___ 7'b0101111
`define YSYX_OP_FENCE_ 7'b0001111

`define YSYX_OP_C_J___ 7'b0010101
`define YSYX_OP_C_JAL_ 7'b0000101
`define YSYX_OP_C_BEQZ 7'b0011001
`define YSYX_OP_C_BNEZ 7'b0011101

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

// RV64 opcodes
`define YSYX_OP_RW_TYPE 7'b0111011
`define YSYX_OP_IW_TYPE 7'b0011011

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

// Zba (Address Generation)
`define YSYX_ALU_SH1ADD 'b100000
`define YSYX_ALU_SH2ADD 'b100001
`define YSYX_ALU_SH3ADD 'b100010

// Zbb (Basic Bit-manipulation)
`define YSYX_ALU_ANDN 'b100011
`define YSYX_ALU_ORN_ 'b100100
`define YSYX_ALU_XNOR 'b100101
`define YSYX_ALU_CLZ_ 'b100110
`define YSYX_ALU_CTZ_ 'b100111
`define YSYX_ALU_CPOP 'b101000
`define YSYX_ALU_MAX_ 'b101001
`define YSYX_ALU_MAXU 'b101010
`define YSYX_ALU_MIN_ 'b101011
`define YSYX_ALU_MINU 'b101100
`define YSYX_ALU_SEXTB 'b101101
`define YSYX_ALU_SEXTH 'b101110
`define YSYX_ALU_ZEXTH 'b101111
`define YSYX_ALU_REV8 'b110000
`define YSYX_ALU_ORCB 'b110001
`define YSYX_ALU_ROL_ 'b110010
`define YSYX_ALU_ROR_ 'b110011

// Zbs (Single-bit Operations)
`define YSYX_ALU_BCLR 'b110100
`define YSYX_ALU_BEXT 'b110101
`define YSYX_ALU_BINV 'b110110
`define YSYX_ALU_BSET 'b110111

// Zicond (Conditional Operations)
`define YSYX_ALU_CZERO_EQZ 'b111000
`define YSYX_ALU_CZERO_NEZ 'b111001

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
`define YSYX_ALU_LWU_ 'b00110
`define YSYX_ALU_LD__ 'b00011

`define YSYX_ALU_SB__ 'b00000
`define YSYX_ALU_SH__ 'b00001
`define YSYX_ALU_SW__ 'b00010
`define YSYX_ALU_SD__ 'b00011

`define YSYX_SB_WSTRB 'b00001
`define YSYX_SH_WSTRB 'b00011
`define YSYX_SW_WSTRB 'b01111
`define YSYX_SD_WSTRB 'b11111

`define YSYX_ATO_LR__ 'b00000
`define YSYX_ATO_SC__ 'b00001
`define YSYX_ATO_SWAP 'b00010
`define YSYX_ATO_ADD_ 'b00011
`define YSYX_ATO_XOR_ 'b00100
`define YSYX_ATO_AND_ 'b00101
`define YSYX_ATO_OR__ 'b00110
`define YSYX_ATO_MIN_ 'b00111
`define YSYX_ATO_MAX_ 'b01000
`define YSYX_ATO_MINU 'b01100
`define YSYX_ATO_MAXU 'b01010

`define YSYX_WSTRB_SB 'b00000001
`define YSYX_WSTRB_SH 'b00000011
`define YSYX_WSTRB_SW 'b00001111
`define YSYX_WSTRB_SD 'b11111111

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

// SATP mode bit position: RV32 bit 31, RV64 bit 63
`ifdef YSYX_RV64
`define YSYX_CSR_SATP_MODE_ 63
`else
`define YSYX_CSR_SATP_MODE_ 31
`endif
`define YSYX_CSR_MSTATUS_MPRV 17

// Machine Trap Settup
`define YSYX_CSR_MSTATUS 'h300
`define YSYX_CSR_MISA___ 'h301
`define YSYX_CSR_MEDELEG 'h302
`define YSYX_CSR_MIDELEG 'h303
`define YSYX_CSR_MIE____ 'h304
`define YSYX_CSR_MTVEC__ 'h305
`define YSYX_CSR_MCOUNTE 'h306
`define YSYX_CSR_MENVCFG 'h30a

`define YSYX_CSR_MSTATUSH 'h310

// Machine Trap Handling
`define YSYX_CSR_MSCRATCH 'h340
`define YSYX_CSR_MEPC___ 'h341
`define YSYX_CSR_MCAUSE_ 'h342
`define YSYX_CSR_MTVAL__ 'h343
`define YSYX_CSR_MIP____ 'h344

`define YSYX_CSR_MCYCLE_ 'hb00
`define YSYX_CSR_MINSTRET 'hb02
`define YSYX_CSR_MCYCLEH 'hb80
`define YSYX_CSR_MINSTRETH 'hb82

`define YSYX_CSR_CYCLE__ 'hc00
`define YSYX_CSR_TIME___ 'hc01
`define YSYX_CSR_INSTRET_ 'hc02

`define YSYX_CSR_CYCLEH_ 'hc80
`define YSYX_CSR_TIMEH__ 'hc81
`define YSYX_CSR_INSTRETH 'hc82

// Machine Information Registers
`define YSYX_CSR_MVENDORID 'hf11
`define YSYX_CSR_MARCHID__ 'hf12
`define YSYX_CSR_IMPID____ 'hf13
`define YSYX_CSR_MHARTID__ 'hf14

// CSR_MSTATUS FLAGS
`define YSYX_CSR_MSTATUS_MPP_ 12:11
`define YSYX_CSR_MSTATUS_SPP_ 8
`define YSYX_CSR_MSTATUS_MPIE 7
`define YSYX_CSR_MSTATUS_SPIE 5
`define YSYX_CSR_MSTATUS_MIE_ 3
`define YSYX_CSR_MSTATUS_SIE_ 1

// CSR_MIE FLAGS
`define YSYX_CSR_MIE_SSIE 1
`define YSYX_CSR_MIE_MSIE 3
`define YSYX_CSR_MIE_STIE 5
`define YSYX_CSR_MIE_MTIE 7
`define YSYX_CSR_MIE_SEIE 9
`define YSYX_CSR_MIE_MEIE 11

// PMP CSR address ranges
`define YSYX_CSR_PMPCFG0 'h3a0
`define YSYX_CSR_PMPCFG3 'h3a3
`define YSYX_CSR_PMPADDR0 'h3b0
`define YSYX_CSR_PMPADDR15 'h3bf

// Exception Cause Codes (synchronous)
`define YSYX_CAUSE_ILLEGAL_INST 'h2
`define YSYX_CAUSE_BREAKPOINT 'h3
`define YSYX_CAUSE_ECALL_U 'h8
`define YSYX_CAUSE_ECALL_S 'h9
`define YSYX_CAUSE_ECALL_M 'hb

// Interrupt Cause Codes (bit index, without MSB interrupt flag)
`define YSYX_CAUSE_SSI 'h1
`define YSYX_CAUSE_MSI 'h3
`define YSYX_CAUSE_STI 'h5
`define YSYX_CAUSE_MTI 'h7

// CSR Write Masks
`define YSYX_CSR_MEDELEG_WMASK 'hf4bffe
`define YSYX_CSR_MSTATUS_WMASK 32'h007FF9EA
`define YSYX_CSR_MSTATUS_SD 32'h80000000
`define YSYX_CSR_SSTATUS_WMASK 32'h000DE162
`define YSYX_CSR_SSTATUS_CMASK 32'h800DE162

`endif
