package npc

import chisel3._
import chisel3.util._

trait MicroOP {
  def ALU_ILL_ = "001001"

  def ALU_ADD_ = "000000"
  def ALU_SUB_ = "001000"
  def ALU_EQ__ = "001100"
  def ALU_SLT_ = "000010"
  def ALU_SLE_ = "001010"
  def ALU_SGE_ = "001110"
  def ALU_SLTU = "000011"
  def ALU_SLEU = "001011"
  def ALU_SGEU = "001111"
  def ALU_XOR_ = "000100"
  def ALU_OR__ = "000110"
  def ALU_AND_ = "000111"

  def ALU_SLL_ = "000001"
  def ALU_SRL_ = "000101"
  def ALU_SRA_ = "001101"

  def ALU_MUL_ = "011000"
  def ALU_MULH = "011001"
  def ALU_MULS = "011010"
  def ALU_MULU = "011011"
  def ALU_DIV_ = "011100"
  def ALU_DIVU = "011101"
  def ALU_REM_ = "011110"
  def ALU_REMU = "011111"

  // Zba (Address Generation)
  def ALU_SH1ADD = "100000"
  def ALU_SH2ADD = "100001"
  def ALU_SH3ADD = "100010"

  // Zbb (Basic Bit-manipulation)
  def ALU_ANDN  = "100011"
  def ALU_ORN   = "100100"
  def ALU_XNOR  = "100101"
  def ALU_CLZ   = "100110"
  def ALU_CTZ   = "100111"
  def ALU_CPOP  = "101000"
  def ALU_MAX   = "101001"
  def ALU_MAXU  = "101010"
  def ALU_MIN   = "101011"
  def ALU_MINU  = "101100"
  def ALU_SEXTB = "101101"
  def ALU_SEXTH = "101110"
  def ALU_ZEXTH = "101111"
  def ALU_REV8  = "110000"
  def ALU_ORCB  = "110001"
  def ALU_ROL   = "110010"
  def ALU_ROR   = "110011"

  // Zbs (Single-bit Operations)
  def ALU_BCLR = "110100"
  def ALU_BEXT = "110101"
  def ALU_BINV = "110110"
  def ALU_BSET = "110111"

  // Zicond (Conditional Operations)
  def ALU_CZERO_EQZ = "111000"
  def ALU_CZERO_NEZ = "111001"

  // w: word 32, h: half 16, b: byte 8, d: doubleword 64
  def LSU_LB_ = "000000"
  def LSU_LH_ = "000001"
  def LSU_LW_ = "000010"
  def LSU_LBU = "000100"
  def LSU_LHU = "000101"
  def LSU_LWU = "000110"
  def LSU_LD_ = "000011"

  def LSU_SB_ = "000001" // alu_op to axi wstrb
  def LSU_SH_ = "000011" // alu_op to axi wstrb
  def LSU_SW_ = "001111" // alu_op to axi wstrb
  def LSU_SD_ = "011111" // alu_op to axi wstrb (8 bytes)

  def ATO_LR__ = "000000"
  def ATO_SC__ = "000001"
  def ATO_SWAP = "000010"
  def ATO_ADD_ = "000011"
  def ATO_XOR_ = "000100"
  def ATO_AND_ = "000101"
  def ATO_OR__ = "000110"
  def ATO_MIN_ = "000111"
  def ATO_MAX_ = "001000"
  def ATO_MINU = "001100"
  def ATO_MAXU = "001010"

  // Supervisor-level CSR
  def SSTATUS = "h100".U(12.W)
  def SIE___  = "h104".U(12.W)
  def STVEC_  = "h105".U(12.W)

  def SCOUNTEREN = "h106".U(12.W)

  def SSCRATCH = "h140".U(12.W)
  def SEPC__   = "h141".U(12.W)
  def SCAUSE   = "h142".U(12.W)
  def STVAL_   = "h143".U(12.W)
  def SIP___   = "h144".U(12.W)
  def SATP__   = "h180".U(12.W)

  // Machine Trap Settup
  def MSTATUS = "h300".U(12.W)
  def MISA__  = "h301".U(12.W)
  def MEDELEG = "h302".U(12.W)
  def MIDELEG = "h303".U(12.W)
  def MIE___  = "h304".U(12.W)
  def MTVEC_  = "h305".U(12.W)

  def MSTATUSH = "h310".U(12.W)

  // Machine Trap Handling
  def MSCRATCH = "h340".U(12.W)
  def MEPC__   = "h341".U(12.W)
  def MCAUSE   = "h342".U(12.W)
  def MTVAL_   = "h343".U(12.W)
  def MIP___   = "h344".U(12.W)

  def MCYCLE = "hb00".U(12.W)
  def MTIME_ = "hc01".U(12.W)
  def MTIMEH = "hc81".U(12.W)

  // Machine Information Registers
  def MVENDORID  = "hf11".U(12.W)
  def MARCHID    = "hf12".U(12.W)
  def MIMPID     = "hf13".U(12.W)
  def MCONFIGPTR = "hf14".U(12.W)
}
