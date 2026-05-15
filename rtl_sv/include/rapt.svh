`ifndef RAPT_SVH
`define RAPT_SVH
`include "rapt_config.svh"
`include "rapt_sva.svh"

// Instruction Set Opcodes
`define RAPT_INST_FENCE_I 32'h0000100f

`define RAPT_OP_LUI___ 7'b0110111
`define RAPT_OP_AUIPC_ 7'b0010111
`define RAPT_OP_JAL___ 7'b1101111
`define RAPT_OP_JALR__ 7'b1100111
`define RAPT_OP_SYSTEM 7'b1110011
`define RAPT_OP_AMO___ 7'b0101111
`define RAPT_OP_FENCE_ 7'b0001111

`define RAPT_OP_C_J___ 7'b0010101
`define RAPT_OP_C_JAL_ 7'b0000101
`define RAPT_OP_C_BEQZ 7'b0011001
`define RAPT_OP_C_BNEZ 7'b0011101

`define RAPT_F3_CSRRW_ 3'b001
`define RAPT_F3_CSRRS_ 3'b010
`define RAPT_F3_CSRRC_ 3'b011

`define RAPT_F3_CSRRWI 3'b101
`define RAPT_F3_CSRRSI 3'b110
`define RAPT_F3_CSRRCI 3'b111
`define RAPT_F3_SYS___ 3'b000
`define RAPT_F3_AMO_W_ 3'b010

// AMO funct5 (inst[31:27]) - distinguishes LR/SC from RMW AMOs.
`define RAPT_F5_AMO_LR 5'b00010
`define RAPT_F5_AMO_SC 5'b00011

// SYSTEM funct7 - used to recognize SFENCE.VMA without funct12 match.
`define RAPT_F7_SFENCE_VMA 7'b0001001

// Whole-instruction encodings for system uops decoded by exact match.
`define RAPT_INST_WFI 32'h10500073

// Page-table entry bits (Sv32 / Sv39 share the low-bit layout).
`define RAPT_PTE_V_BIT 0
`define RAPT_PTE_R_BIT 1
`define RAPT_PTE_W_BIT 2
`define RAPT_PTE_X_BIT 3
`define RAPT_PTE_U_BIT 4
`define RAPT_PTE_G_BIT 5
`define RAPT_PTE_A_BIT 6
`define RAPT_PTE_D_BIT 7
`define RAPT_PTE_A_MASK 32'h0000_0040
`define RAPT_PTE_D_MASK 32'h0000_0080

`define RAPT_CSR_CSW_NONE 3'b000
`define RAPT_CTR_SEL_NONE 3'b000
`define RAPT_CTR_SEL_CY__ 3'b001
`define RAPT_CTR_SEL_TM__ 3'b010
`define RAPT_CTR_SEL_IR__ 3'b100

`define RAPT_OP_R_TYPE_ 7'b0110011
`define RAPT_OP_I_TYPE_ 7'b0010011
`define RAPT_OP_IL_TYPE 7'b0000011
`define RAPT_OP_S_TYPE_ 7'b0100011
`define RAPT_OP_B_TYPE_ 7'b1100011

// RV64 opcodes
`define RAPT_OP_RW_TYPE 7'b0111011
`define RAPT_OP_IW_TYPE 7'b0011011

`define RAPT_SIGN_EXTEND(x, l, n) ({{n-l{x[l-1]}}, x})
`define RAPT_ZERO_EXTEND(x, l, n) ({{n-l{1'b0}}, x})
`define RAPT_LAMBDA(x) (x)

`define RAPT_ALU_ILL_ 'b01001

`define RAPT_ALU_ADD_ 'b00000
`define RAPT_ALU_SUB_ 'b01000
`define RAPT_ALU_EQ__ 'b01100
`define RAPT_ALU_SLT_ 'b00010
`define RAPT_ALU_SLE_ 'b01010
`define RAPT_ALU_SGE_ 'b01110
`define RAPT_ALU_SLTU 'b00011
`define RAPT_ALU_SLEU 'b01011
`define RAPT_ALU_SGEU 'b01111
`define RAPT_ALU_XOR_ 'b00100
`define RAPT_ALU_OR__ 'b00110
`define RAPT_ALU_AND_ 'b00111

`define RAPT_ALU_SLL_ 'b00001
`define RAPT_ALU_SRL_ 'b00101
`define RAPT_ALU_SRA_ 'b01101

// Zba (Address Generation)
`define RAPT_ALU_SH1ADD 'b100000
`define RAPT_ALU_SH2ADD 'b100001
`define RAPT_ALU_SH3ADD 'b100010

// Zbb (Basic Bit-manipulation)
`define RAPT_ALU_ANDN 'b100011
`define RAPT_ALU_ORN_ 'b100100
`define RAPT_ALU_XNOR 'b100101
`define RAPT_ALU_CLZ_ 'b100110
`define RAPT_ALU_CTZ_ 'b100111
`define RAPT_ALU_CPOP 'b101000
`define RAPT_ALU_MAX_ 'b101001
`define RAPT_ALU_MAXU 'b101010
`define RAPT_ALU_MIN_ 'b101011
`define RAPT_ALU_MINU 'b101100
`define RAPT_ALU_SEXTB 'b101101
`define RAPT_ALU_SEXTH 'b101110
`define RAPT_ALU_ZEXTH 'b101111
`define RAPT_ALU_REV8 'b110000
`define RAPT_ALU_ORCB 'b110001
`define RAPT_ALU_ROL_ 'b110010
`define RAPT_ALU_ROR_ 'b110011

// Zbs (Single-bit Operations)
`define RAPT_ALU_BCLR 'b110100
`define RAPT_ALU_BEXT 'b110101
`define RAPT_ALU_BINV 'b110110
`define RAPT_ALU_BSET 'b110111

// Zicond (Conditional Operations)
`define RAPT_ALU_CZERO_EQZ 'b111000
`define RAPT_ALU_CZERO_NEZ 'b111001

// Zbc (Carry-less Multiplication)
`define RAPT_ALU_CLMUL 'b111010
`define RAPT_ALU_CLMULH 'b111011
`define RAPT_ALU_CLMULR 'b111100

// RV64 Zba .UW variants (dedicated opcodes; semantics differ from ADDW/SLLW:
// zero-extend rs1[31:0], produce full 64-bit result, no trunc+sext)
`define RAPT_ALU_ADD_UW 'b111101
`define RAPT_ALU_SLLI_UW 'b111110

`define RAPT_ALU_MUL___ 'b11000
`define RAPT_ALU_MULH__ 'b11001
`define RAPT_ALU_MULHSU 'b11010
`define RAPT_ALU_MULHU_ 'b11011
`define RAPT_ALU_DIV___ 'b11100
`define RAPT_ALU_DIVU__ 'b11101
`define RAPT_ALU_REM___ 'b11110
`define RAPT_ALU_REMU__ 'b11111

`define RAPT_ALU_LB__ 'b00000
`define RAPT_ALU_LH__ 'b00001
`define RAPT_ALU_LW__ 'b00010
`define RAPT_ALU_LBU_ 'b00100
`define RAPT_ALU_LHU_ 'b00101
`define RAPT_ALU_LWU_ 'b00110
`define RAPT_ALU_LD__ 'b00011

`define RAPT_ALU_SB__ 'b00000
`define RAPT_ALU_SH__ 'b00001
`define RAPT_ALU_SW__ 'b00010
`define RAPT_ALU_SD__ 'b00011

`define RAPT_SB_WSTRB 'b00001
`define RAPT_SH_WSTRB 'b00011
`define RAPT_SW_WSTRB 'b01111
`define RAPT_SD_WSTRB 'b11111

`define RAPT_ATO_LR__ 'b00000
`define RAPT_ATO_SC__ 'b00001
`define RAPT_ATO_SWAP 'b00010
`define RAPT_ATO_ADD_ 'b00011
`define RAPT_ATO_XOR_ 'b00100
`define RAPT_ATO_AND_ 'b00101
`define RAPT_ATO_OR__ 'b00110
`define RAPT_ATO_MIN_ 'b00111
`define RAPT_ATO_MAX_ 'b01000
`define RAPT_ATO_MINU 'b01100
`define RAPT_ATO_MAXU 'b01010

`define RAPT_WSTRB_SB 'b00000001
`define RAPT_WSTRB_SH 'b00000011
`define RAPT_WSTRB_SW 'b00001111
`define RAPT_WSTRB_SD 'b11111111

// Privilege Levels
`define RAPT_PRIV_U 2'h0
`define RAPT_PRIV_S 2'h1
`define RAPT_PRIV_M 2'h3

// Supervisor-level CSR
`define RAPT_CSR_SSTATUS 'h100
`define RAPT_CSR_SIE____ 'h104
`define RAPT_CSR_STVEC__ 'h105

`define RAPT_CSR_SCOUNTE 'h106

`define RAPT_CSR_SSCRATC 'h140
`define RAPT_CSR_SEPC___ 'h141
`define RAPT_CSR_SCAUSE_ 'h142
`define RAPT_CSR_STVAL__ 'h143
`define RAPT_CSR_SIP____ 'h144
`define RAPT_CSR_STIMECMP 'h14d
`define RAPT_CSR_STIMECMPH 'h15d
`define RAPT_CSR_SATP___ 'h180

// SATP mode bit position: RV32 bit 31, RV64 bit 63
`ifdef RAPT_RV64
`define RAPT_CSR_SATP_MODE_ 63
`define RAPT_CSR_SATP_PPN_W 44
`define RAPT_CSR_SATP_ASID_LSB 44
`else
`define RAPT_CSR_SATP_MODE_ 31
`define RAPT_CSR_SATP_PPN_W 22
`define RAPT_CSR_SATP_ASID_LSB 22
`endif
`define RAPT_CSR_MSTATUS_MPRV 17

// Machine Trap Settup
`define RAPT_CSR_MSTATUS 'h300
`define RAPT_CSR_MISA___ 'h301
`define RAPT_CSR_MEDELEG 'h302
`define RAPT_CSR_MIDELEG 'h303
`define RAPT_CSR_MIE____ 'h304
`define RAPT_CSR_MTVEC__ 'h305
`define RAPT_CSR_MCOUNTE 'h306
`define RAPT_CSR_MENVCFG 'h30a

`define RAPT_CSR_MSTATUSH 'h310

// Machine Trap Handling
`define RAPT_CSR_MSCRATCH 'h340
`define RAPT_CSR_MEPC___ 'h341
`define RAPT_CSR_MCAUSE_ 'h342
`define RAPT_CSR_MTVAL__ 'h343
`define RAPT_CSR_MIP____ 'h344

`define RAPT_CSR_MCYCLE_ 'hb00
`define RAPT_CSR_MINSTRET 'hb02
`define RAPT_CSR_MCYCLEH 'hb80
`define RAPT_CSR_MINSTRETH 'hb82

`define RAPT_CSR_CYCLE__ 'hc00
`define RAPT_CSR_TIME___ 'hc01
`define RAPT_CSR_INSTRET_ 'hc02

`define RAPT_CSR_CYCLEH_ 'hc80
`define RAPT_CSR_TIMEH__ 'hc81
`define RAPT_CSR_INSTRETH 'hc82

// Machine Information Registers
`define RAPT_CSR_MVENDORID 'hf11
`define RAPT_CSR_MARCHID__ 'hf12
`define RAPT_CSR_IMPID____ 'hf13
`define RAPT_CSR_MHARTID__ 'hf14

// CSR_MSTATUS FLAGS
`define RAPT_CSR_MSTATUS_MPP_ 12:11
`define RAPT_CSR_MSTATUS_SPP_ 8
`define RAPT_CSR_MSTATUS_MPIE 7
`define RAPT_CSR_MSTATUS_SPIE 5
`define RAPT_CSR_MSTATUS_MIE_ 3
`define RAPT_CSR_MSTATUS_SIE_ 1
`define RAPT_CSR_MSTATUS_TVM_ 20
`define RAPT_CSR_MSTATUS_TW__ 21
`define RAPT_CSR_MSTATUS_TSR_ 22
`define RAPT_CSR_MSTATUS_SUM_ 18
`define RAPT_CSR_MSTATUS_MXR_ 19
`define RAPT_CSR_MSTATUS_UBE_ 6
`define RAPT_CSR_MSTATUSH_SBE 4
`define RAPT_CSR_MSTATUSH_MBE 5

// CSR_MCOUNTEREN / SCOUNTEREN bit positions (CY/TM/IR are bits 0/1/2).
`define RAPT_CSR_COUNTEREN_CY 0
`define RAPT_CSR_COUNTEREN_TM 1
`define RAPT_CSR_COUNTEREN_IR 2
// WARL write mask: only CY/TM/IR are supported (no HPM counters).
`define RAPT_CSR_COUNTEREN_WMASK 32'h00000007

// mideleg WARL: only SSI(1)/STI(5)/SEI(9) delegatable.
`define RAPT_CSR_MIDELEG_WMASK 32'h00000222

// sip/sie are restricted views of mip/mie (Priv spec §3.1.9). The S-mode
// visible bits are SSIP/STIP/SEIP (and matching mie). Reads return mip/mie
// masked by SIE_RMASK; writes update the underlying mip/mie bits within
// the writable mask (SSIP only on sip; SSIE/STIE/SEIE on sie).
`define RAPT_CSR_SIE_RMASK 32'h00000222
`define RAPT_CSR_SIE_WMASK 32'h00000222
`define RAPT_CSR_SIP_RMASK 32'h00000222
`define RAPT_CSR_SIP_WMASK 32'h00000002
`define RAPT_CSR_MIP_WMASK 32'h00000222

`ifdef RAPT_RV64
`define RAPT_CSR_MENVCFG_STCE 63
`define RAPT_CSR_MENVCFG_WMASK 64'h8000_0000_0000_0000
`else
`define RAPT_CSR_MENVCFG_WMASK 32'h0000_0000
`endif

// tvec MODE field encodings
`define RAPT_TVEC_MODE_DIRECT 2'b00
`define RAPT_TVEC_MODE_VECTORED 2'b01

// CSR_MIE FLAGS
`define RAPT_CSR_MIE_SSIE 1
`define RAPT_CSR_MIE_MSIE 3
`define RAPT_CSR_MIE_STIE 5
`define RAPT_CSR_MIE_MTIE 7
`define RAPT_CSR_MIE_SEIE 9
`define RAPT_CSR_MIE_MEIE 11

// PMP CSR address ranges
`define RAPT_CSR_PMPCFG0 'h3a0
`define RAPT_CSR_PMPCFG1 'h3a1
`define RAPT_CSR_PMPCFG2 'h3a2
`define RAPT_CSR_PMPCFG3 'h3a3
`define RAPT_CSR_PMPADDR0 'h3b0
`define RAPT_CSR_PMPADDR15 'h3bf

// PMP parameters: 16 entries (pmpcfg0/1/2/3 all active).
// pmp_granularity = 4 bytes -> G=0, NA4 legal, all pmpaddr bits writable.
`define RAPT_PMP_NUM 16
// pmpcfg byte field positions
`define RAPT_PMPCFG_R_ 0
`define RAPT_PMPCFG_W_ 1
`define RAPT_PMPCFG_X_ 2
`define RAPT_PMPCFG_A_ 4:3
`define RAPT_PMPCFG_L_ 7
// pmpcfg A encodings
`define RAPT_PMP_A_OFF 2'd0
`define RAPT_PMP_A_TOR 2'd1
`define RAPT_PMP_A_NA4 2'd2
`define RAPT_PMP_A_NAPOT 2'd3

// Exception Cause Codes (synchronous)
`define RAPT_CAUSE_INSTR_ACC_FAULT 'h1
`define RAPT_CAUSE_ILLEGAL_INST 'h2
`define RAPT_CAUSE_BREAKPOINT 'h3
`define RAPT_CAUSE_LOAD_ACC_FAULT 'h5
`define RAPT_CAUSE_STORE_ACC_FAULT 'h7
`define RAPT_CAUSE_ECALL_U 'h8
`define RAPT_CAUSE_ECALL_S 'h9
`define RAPT_CAUSE_ECALL_M 'hb
`define RAPT_CAUSE_INSTR_PAGE_FAULT 'hc
`define RAPT_CAUSE_LOAD_PAGE_FAULT 'hd
`define RAPT_CAUSE_STORE_PAGE_FAULT 'hf

// Interrupt Cause Codes (bit index, without MSB interrupt flag)
`define RAPT_CAUSE_SSI 'h1
`define RAPT_CAUSE_MSI 'h3
`define RAPT_CAUSE_STI 'h5
`define RAPT_CAUSE_MTI 'h7
`define RAPT_CAUSE_SEI 'h9
`define RAPT_CAUSE_MEI 'hb

// CSR Write Masks
`define RAPT_CSR_MEDELEG_WMASK 'hf4bffe
`define RAPT_CSR_MSTATUS_WMASK 32'h007FF9EA
`define RAPT_CSR_MSTATUS_SD 32'h80000000
`define RAPT_CSR_SSTATUS_WMASK 32'h000DE162
`define RAPT_CSR_SSTATUS_CMASK 32'h800DE162

// Hardwired mstatus/sstatus bits per RISC-V Priv §3.1.6: in RV64 the SXL/UXL
// fields are WARL but our implementation only supports XLEN=64 in S/U modes,
// so they are tied to MXL=2. mstatus.SXL[35:34]=2 and mstatus.UXL[33:32]=2
// (=> 64'h0000_000A_0000_0000); sstatus only exposes UXL (=> 64'h0000_0002_0000_0000).
// In RV32 these fields don't exist so the constants are zero.
`ifdef RAPT_RV64
`define RAPT_CSR_MSTATUS_HW 64'h0000_000A_0000_0000
`define RAPT_CSR_SSTATUS_HW 64'h0000_0002_0000_0000
`else
`define RAPT_CSR_MSTATUS_HW 32'h0
`define RAPT_CSR_SSTATUS_HW 32'h0
`endif

`endif
