`ifndef RAPT_SVH
`define RAPT_SVH
`include "rapt_config.svh"
`include "rapt_sva.svh"

// Implemented physical-address width. RV64 does not imply a 64-bit physical
// address space; Sv39-capable systems conventionally implement up to 48 bits.
`ifndef RAPT_PADDR_BITS
`ifdef RAPT_RV64
`define RAPT_PADDR_BITS 48
`else
`define RAPT_PADDR_BITS 32
`endif
`endif

// Architectural pmpaddr CSR width. RV64 reserves bits 63:54, independently
// of the narrower physical address width implemented by the checker.
`ifndef RAPT_PMPADDR_BITS
`ifdef RAPT_RV64
`define RAPT_PMPADDR_BITS 54
`else
`define RAPT_PMPADDR_BITS 32
`endif
`endif

// Cache lines are specified in bytes, not XLEN words. A configuration may
// select a smaller line for formal/FPGA capacity, but RV32 and RV64 use the
// same byte line size within that configuration. L1D/L2 derive their
// XLEN-word counts from this value; L1I always uses 32-bit instruction words.
`ifndef RAPT_CACHE_LINE_BYTES
`define RAPT_CACHE_LINE_BYTES 64
`endif

// Translation-cache sizing. Presets may override these before including this
// file; the fallbacks preserve the original small implementation for external
// configurations that have not selected explicit TLB depths yet.
`ifndef RAPT_ITLB_ENTRIES
`define RAPT_ITLB_ENTRIES 4
`endif
`ifndef RAPT_DTLB_ENTRIES
`define RAPT_DTLB_ENTRIES 4
`endif

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

// Serializing scalar-FP bring-up operation identifiers.
`define RAPT_FP_OP_FMV_W_X 6'd1
`define RAPT_FP_OP_FMV_X_W 6'd2
`define RAPT_FP_OP_FSGNJ_S 6'd3
`define RAPT_FP_OP_FSGNJN_S 6'd4
`define RAPT_FP_OP_FSGNJX_S 6'd5
`define RAPT_FP_OP_FLW 6'd6
`define RAPT_FP_OP_FSW 6'd7
`define RAPT_FP_OP_FMV_D_X 6'd8
`define RAPT_FP_OP_FMV_X_D 6'd9
`define RAPT_FP_OP_FSGNJ_D 6'd10
`define RAPT_FP_OP_FSGNJN_D 6'd11
`define RAPT_FP_OP_FSGNJX_D 6'd12
`define RAPT_FP_OP_FLD 6'd13
`define RAPT_FP_OP_FSD 6'd14
`define RAPT_FP_OP_FADD_S 6'd15
`define RAPT_FP_OP_FSUB_S 6'd16
`define RAPT_FP_OP_FADD_D 6'd17
`define RAPT_FP_OP_FSUB_D 6'd18
`define RAPT_FP_OP_FMUL_S 6'd19
`define RAPT_FP_OP_FMUL_D 6'd20
`define RAPT_FP_OP_FMIN_S 6'd21
`define RAPT_FP_OP_FMAX_S 6'd22
`define RAPT_FP_OP_FMIN_D 6'd23
`define RAPT_FP_OP_FMAX_D 6'd24
`define RAPT_FP_OP_FLE_S 6'd25
`define RAPT_FP_OP_FLT_S 6'd26
`define RAPT_FP_OP_FEQ_S 6'd27
`define RAPT_FP_OP_FCLASS_S 6'd28
`define RAPT_FP_OP_FLE_D 6'd29
`define RAPT_FP_OP_FLT_D 6'd30
`define RAPT_FP_OP_FEQ_D 6'd31
`define RAPT_FP_OP_FCLASS_D 6'd32
`define RAPT_FP_OP_FCVT_W_S 6'd33
`define RAPT_FP_OP_FCVT_WU_S 6'd34
`define RAPT_FP_OP_FCVT_L_S 6'd35
`define RAPT_FP_OP_FCVT_LU_S 6'd36
`define RAPT_FP_OP_FCVT_S_W 6'd37
`define RAPT_FP_OP_FCVT_S_WU 6'd38
`define RAPT_FP_OP_FCVT_S_L 6'd39
`define RAPT_FP_OP_FCVT_S_LU 6'd40
`define RAPT_FP_OP_FCVT_W_D 6'd41
`define RAPT_FP_OP_FCVT_WU_D 6'd42
`define RAPT_FP_OP_FCVT_L_D 6'd43
`define RAPT_FP_OP_FCVT_LU_D 6'd44
`define RAPT_FP_OP_FCVT_D_W 6'd45
`define RAPT_FP_OP_FCVT_D_WU 6'd46
`define RAPT_FP_OP_FCVT_D_L 6'd47
`define RAPT_FP_OP_FCVT_D_LU 6'd48
`define RAPT_FP_OP_FCVT_S_D 6'd49
`define RAPT_FP_OP_FCVT_D_S 6'd50
`define RAPT_FP_OP_FMADD_S 6'd51
`define RAPT_FP_OP_FMADD_D 6'd52
`define RAPT_FP_OP_FMSUB_S 6'd53
`define RAPT_FP_OP_FMSUB_D 6'd54
`define RAPT_FP_OP_FNMSUB_S 6'd55
`define RAPT_FP_OP_FNMSUB_D 6'd56
`define RAPT_FP_OP_FNMADD_S 6'd57
`define RAPT_FP_OP_FNMADD_D 6'd58
`define RAPT_FP_OP_FDIV_S 6'd59
`define RAPT_FP_OP_FDIV_D 6'd60
`define RAPT_FP_OP_FSQRT_S 6'd61
`define RAPT_FP_OP_FSQRT_D 6'd62
// Zfhmin instructions share the final 6-bit FP operation tag.  The FEU and
// IOQ distinguish the individual operation from the architected instruction
// retained in the ROB payload (or from the memory-operation width).
`define RAPT_FP_OP_ZFHMIN 6'd63

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
`define RAPT_CSR_FFLAGS 'h001
`define RAPT_CSR_FRM 'h002
`define RAPT_CSR_FCSR 'h003
`define RAPT_CSR_SSTATUS 'h100
`define RAPT_CSR_SIE____ 'h104
`define RAPT_CSR_STVEC__ 'h105

`define RAPT_CSR_SCOUNTE 'h106
`define RAPT_CSR_SENVCFG 'h10a

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

// Zihpm permits any individual HPM counter to be hardwired read-only zero.
// Raptor exposes the complete architectural CSR ranges in that form.
`define RAPT_CSR_MHPMCOUNTER3 'hb03
`define RAPT_CSR_MHPMCOUNTER31 'hb1f
`define RAPT_CSR_MHPMCOUNTER3H 'hb83
`define RAPT_CSR_MHPMCOUNTER31H 'hb9f
`define RAPT_CSR_MHPMEVENT3 'h323
`define RAPT_CSR_MHPMEVENT31 'h33f

`define RAPT_CSR_CYCLE__ 'hc00
`define RAPT_CSR_TIME___ 'hc01
`define RAPT_CSR_INSTRET_ 'hc02

`define RAPT_CSR_CYCLEH_ 'hc80
`define RAPT_CSR_TIMEH__ 'hc81
`define RAPT_CSR_INSTRETH 'hc82
`define RAPT_CSR_HPMCOUNTER3 'hc03
`define RAPT_CSR_HPMCOUNTER31 'hc1f
`define RAPT_CSR_HPMCOUNTER3H 'hc83
`define RAPT_CSR_HPMCOUNTER31H 'hc9f

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
// CY/TM/IR are implemented.  HPM counters and their event selectors are
// architecturally present but hardwired zero, so their enable bits are zero.
`define RAPT_CSR_COUNTEREN_WMASK 32'h00000007

// mideleg WARL: only SSI(1)/STI(5)/SEI(9) delegatable.
`define RAPT_CSR_MIDELEG_WMASK 32'h00000222

// sip/sie are restricted views of mip/mie (Priv spec Sec.3.1.9). The S-mode
// visible bits are SSIP/STIP/SEIP (and matching mie). Reads return mip/mie
// masked by SIE_RMASK; writes update the underlying mip/mie bits within
// the writable mask (SSIP only on sip; SSIE/STIE/SEIE on sie).
`define RAPT_CSR_SIE_RMASK 32'h00000222
`define RAPT_CSR_SIE_WMASK 32'h00000222
`define RAPT_CSR_SIP_RMASK 32'h00000222
`define RAPT_CSR_SIP_WMASK 32'h00000002
`define RAPT_CSR_MIP_WMASK 32'h00000222

// RVA22 CMO environment controls: CBIE[5:4], CBCFE[6], and CBZE[7].
`define RAPT_CSR_SENVCFG_WMASK 32'h000000f0
`ifdef RAPT_RV64
`define RAPT_CSR_MENVCFG_STCE 63
`define RAPT_CSR_MENVCFG_WMASK 64'h8000_0000_0000_00f0
`else
`define RAPT_CSR_MENVCFG_WMASK 32'h0000_00f0
`endif

// Internal LSU operation tags used only between decode/IOQ/SQ.  They do not
// escape as AXI byte strobes.
`define RAPT_CBO_ZERO_WALU 5'b10000
`define RAPT_CBO_MGMT_WALU 5'b10001

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
// medeleg (WARL): delegable synchronous exceptions only, matching the Spike
// reference for this extension set (RV32IMAC+S, Zicntr, no Zicfiss/Zicfilp/H):
//   bits 1-9   fetch-access/illegal/breakpoint/misaligned-LS/LS-access/ecall-U/S
//   bits 12/13/15  page faults
//   bit  19    hardware-error fault (Zicntr)
// Hardwired 0: bit 0 (misaligned fetch; C ext), bit 11 (ecall-M, per spec),
// bit 18 (software check; needs Zicfiss/Zicfilp), reserved/hypervisor bits.
// Bit 18 leak caused a Spike-difftest ABORT on the OpenSBI medeleg write.
`define RAPT_CSR_MEDELEG_WMASK 'h8b3fe
`define RAPT_CSR_MSTATUS_WMASK 32'h007FF9EA
`define RAPT_CSR_SSTATUS_WMASK 32'h000DE162

// Hardwired mstatus/sstatus bits per RISC-V Priv Sec.3.1.6: in RV64 the SXL/UXL
// fields are WARL but our implementation only supports XLEN=64 in S/U modes,
// so they are tied to MXL=2. mstatus.SXL[35:34]=2 and mstatus.UXL[33:32]=2
// (=> 64'h0000_000A_0000_0000); sstatus only exposes UXL (=> 64'h0000_0002_0000_0000).
// In RV32 these fields don't exist so the constants are zero.
`ifdef RAPT_RV64
`define RAPT_CSR_MSTATUS_SD 64'h8000_0000_0000_0000
`define RAPT_CSR_SSTATUS_CMASK 64'h8000_0000_000D_E162
`define RAPT_CSR_MSTATUS_HW 64'h0000_000A_0000_0000
`define RAPT_CSR_SSTATUS_HW 64'h0000_0002_0000_0000
`else
`define RAPT_CSR_MSTATUS_SD 32'h80000000
`define RAPT_CSR_SSTATUS_CMASK 32'h800DE162
`define RAPT_CSR_MSTATUS_HW 32'h0
`define RAPT_CSR_SSTATUS_HW 32'h0
`endif

`endif
