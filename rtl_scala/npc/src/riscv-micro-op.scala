package npc

import chisel3._
import chisel3.util._

trait MicroOP {
  def ALU_ILL_ = "01001"

  def ALU_ADD_ = "00000"
  def ALU_SUB_ = "01000"
  def ALU_EQ__ = "01100"
  def ALU_SLT_ = "00010"
  def ALU_SLE_ = "01010"
  def ALU_SGE_ = "01110"
  def ALU_SLTU = "00011"
  def ALU_SLEU = "01011"
  def ALU_SGEU = "01111"
  def ALU_XOR_ = "00100"
  def ALU_OR__ = "00110"
  def ALU_AND_ = "00111"

  def ALU_SLL_ = "00001"
  def ALU_SRL_ = "00101"
  def ALU_SRA_ = "01101"

  def ALU_MUL_ = "11000"
  def ALU_MULH = "11001"
  def ALU_MULS = "11010"
  def ALU_MULU = "11011"
  def ALU_DIV_ = "11100"
  def ALU_DIVU = "11101"
  def ALU_REM_ = "11110"
  def ALU_REMU = "11111"

  // w: word 32, h: half 16, b: byte 8
  def LSU_LB_ = "00000"
  def LSU_LH_ = "00001"
  def LSU_LW_ = "00010"
  def LSU_LBU = "00100"
  def LSU_LHU = "00101"

  def LSU_SB_ = "00001" // alu_op to axi wstrb
  def LSU_SH_ = "00011" // alu_op to axi wstrb
  def LSU_SW_ = "01111" // alu_op to axi wstrb

  def ATO_LR__ = "00000"
  def ATO_SC__ = "00001"
  def ATO_SWAP = "00010"
  def ATO_ADD_ = "00011"
  def ATO_XOR_ = "00100"
  def ATO_AND_ = "00101"
  def ATO_OR__ = "00110"
  def ATO_MIN_ = "00111"
  def ATO_MAX_ = "01000"
  def ATO_MINU = "01001"
  def ATO_MAXU = "01010"

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
