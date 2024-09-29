package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._
import scala.annotation.switch

trait MicroOP {
  def ALU_ADD_ = "0000"
  def ALU_SUB_ = "1000"
  def ALU_SLT_ = "0010"
  def ALU_SLE_ = "1010"
  def ALU_SLTU = "0011"
  def ALU_SLEU = "1011"
  def ALU_XOR_ = "0100"
  def ALU_OR__ = "0110"
  def ALU_AND_ = "0111"
  def ALU_NAND = "1111"
  def ALU_SLL_ = "0001"
  def ALU_SRL_ = "0101"
  def ALU_SRA_ = "1101"

  // Machine Trap Handling
  def MCAUSE = "h342".U(12.W)
  def MEPC__ = "h341".U(12.W)
  // Machine Trap Settup
  def MTVEC_ = "h305".U(12.W)
  def MSTATUS = "h300".U(12.W)
}

trait Instr {
  def LUI_OPCODE = "b0110111".U(7.W)
  def AUIPC_OPCODE = "b0010111".U(7.W)

  def LUI___ = BitPat("b??????? ????? ????? ??? ????? 0110111")
  def AUIPC_ = BitPat("b??????? ????? ????? ??? ????? 0010111")
  def JAL___ = BitPat("b??????? ????? ????? ??? ????? 1101111")
  def JALR__ = BitPat("b??????? ????? ????? 000 ????? 1100111")

  def BEQ___ = BitPat("b??????? ????? ????? 000 ????? 1100011")
  def BNE___ = BitPat("b??????? ????? ????? 001 ????? 1100011")
  def BLT___ = BitPat("b??????? ????? ????? 100 ????? 1100011")
  def BGE___ = BitPat("b??????? ????? ????? 101 ????? 1100011")
  def BLTU__ = BitPat("b??????? ????? ????? 110 ????? 1100011")
  def BGEU__ = BitPat("b??????? ????? ????? 111 ????? 1100011")

  def LB____ = BitPat("b??????? ????? ????? 000 ????? 0000011")
  def LH____ = BitPat("b??????? ????? ????? 001 ????? 0000011")
  def LW____ = BitPat("b??????? ????? ????? 010 ????? 0000011")

  def LBU___ = BitPat("b??????? ????? ????? 100 ????? 0000011")
  def LHU___ = BitPat("b??????? ????? ????? 101 ????? 0000011")

  def SB____ = BitPat("b??????? ????? ????? 000 ????? 0100011")
  def SH____ = BitPat("b??????? ????? ????? 001 ????? 0100011")
  def SW____ = BitPat("b??????? ????? ????? 010 ????? 0100011")

  def ADDI__ = BitPat("b??????? ????? ????? 000 ????? 0010011")
  def SLTI__ = BitPat("b??????? ????? ????? 010 ????? 0010011")
  def SLTIU_ = BitPat("b??????? ????? ????? 011 ????? 0010011")
  def XORI__ = BitPat("b??????? ????? ????? 100 ????? 0010011")
  def ORI___ = BitPat("b??????? ????? ????? 110 ????? 0010011")
  def ANDI__ = BitPat("b??????? ????? ????? 111 ????? 0010011")

  def SLLI__ = BitPat("b0000000 ????? ????? 001 ????? 0010011")
  def SRLI__ = BitPat("b0000000 ????? ????? 101 ????? 0010011")
  def SRAI__ = BitPat("b0100000 ????? ????? 101 ????? 0010011")

  def ADD___ = BitPat("b0000000 ????? ????? 000 ????? 0110011")
  def SUB___ = BitPat("b0100000 ????? ????? 000 ????? 0110011")
  def SLL___ = BitPat("b0000000 ????? ????? 001 ????? 0110011")
  def SLT___ = BitPat("b0000000 ????? ????? 010 ????? 0110011")
  def SLTU__ = BitPat("b0000000 ????? ????? 011 ????? 0110011")
  def XOR___ = BitPat("b0000000 ????? ????? 100 ????? 0110011")
  def SRL___ = BitPat("b0000000 ????? ????? 101 ????? 0110011")
  def SRA___ = BitPat("b0100000 ????? ????? 101 ????? 0110011")
  def OR____ = BitPat("b0000000 ????? ????? 110 ????? 0110011")
  def AND___ = BitPat("b0000000 ????? ????? 111 ????? 0110011")

  def FENCE_ = BitPat("b0000??? ????? 00000 000 00000 0001111")
  def FENCET = BitPat("b1000001 10011 00000 000 00000 0011111")
  def PAUSE_ = BitPat("b0000000 10000 00000 000 00000 0001111")
  def ECALL_ = BitPat("b0000000 00000 00000 000 00000 1110011")

  def EBREAK = BitPat("b0000000 00001 00000 000 00000 1110011")
  def MRET__ = BitPat("b0011000 00010 00000 000 00000 1110011")

  def FENCEI = BitPat("b??????? ????? ????? 001 ????? 0001111")

  def CSRRW_ = BitPat("b??????? ????? ????? 001 ????? 1110011")
  def CSRRS_ = BitPat("b??????? ????? ????? 010 ????? 1110011")
  def CSRRC_ = BitPat("b??????? ????? ????? 011 ????? 1110011")
  def CSRRWI = BitPat("b??????? ????? ????? 101 ????? 1110011")
  def CSRRSI = BitPat("b??????? ????? ????? 110 ????? 1110011")
  def CSRRCI = BitPat("b??????? ????? ????? 111 ????? 1110011")
}

class ysyx_idu_decoder extends Module with Instr with MicroOP {
  val in = IO(new Bundle {
    val inst = Input(UInt(32.W))
    val pc = Input(UInt(32.W))
    val rs1v = Input(UInt(32.W))
    val rs2v = Input(UInt(32.W))
  })
  val out = IO(new Bundle {
    val wen = Output(UInt(1.W))
    val ren = Output(UInt(1.W))
    val jen = Output(UInt(1.W))
    val ben = Output(UInt(1.W))

    val rd = Output(UInt(4.W))
    val imm = Output(UInt(32.W))
    val op1 = Output(UInt(32.W))
    val op2 = Output(UInt(32.W))
    val alu_op = Output(UInt(4.W))
    val opj = Output(UInt(32.W))
  })
  val out_sys = IO(new Bundle {
    val system = Output(UInt(1.W))
    val func3_zero = Output(UInt(1.W))
    val csr_wen = Output(UInt(1.W))
    var ebreak = Output(UInt(1.W))
    var ecall = Output(UInt(1.W))
    var mret = Output(UInt(1.W))
  })
  val rs1v = in.rs1v
  val rs2v = in.rs2v
  val rd = in.inst(11, 7)
  val opcode = in.inst(6, 0)
  val funct3 = in.inst(14, 12)
  val funct7 = in.inst(31, 25)
  val ALU_F3OP = Cat(0.U(1.W), funct3)
  val ALU_F3_5 = Cat(funct7(5), funct3)

  val imm_i = Cat(Fill(20, in.inst(31)), in.inst(31, 20))
  val imm_s = Cat(Fill(20, in.inst(31)), in.inst(31, 25), in.inst(11, 7))
  val immbv = Cat(in.inst(31), in.inst(7), in.inst(30, 25), in.inst(11, 8))
  val imm_b = Cat(Fill(19, in.inst(31)), immbv, 0.U)
  val imm_u = Cat(in.inst(31, 12), Fill(12, 0.U))
  val immjv = Cat(in.inst(31), in.inst(19, 12), in.inst(20), in.inst(30, 21))
  val imm_j = Cat(Fill(11, in.inst(31)), immjv, 0.U)
  val csr = in.inst(31, 20)
  val uimm = in.inst(19, 15)

  val type_decoder = TruthTable(
    Map(
      // format: off
      //                   |      sys |  rw  |  b  |  j  |  alu op |
      LUI___ -> BitPat("b" + "000000" + "00" + "0" + "0" + ALU_ADD_), // U__
      AUIPC_ -> BitPat("b" + "000000" + "00" + "0" + "0" + ALU_ADD_), // U__
      JAL___ -> BitPat("b" + "000000" + "00" + "0" + "1" + ALU_ADD_), // J__
      JALR__ -> BitPat("b" + "000000" + "00" + "0" + "1" + ALU_ADD_), // I__
      BEQ___ -> BitPat("b" + "000000" + "00" + "1" + "0" + ALU_SUB_), // B__
      BNE___ -> BitPat("b" + "000000" + "00" + "1" + "0" + ALU_XOR_), // B__
      BLT___ -> BitPat("b" + "000000" + "00" + "1" + "0" + ALU_SLT_), // B__
      BGE___ -> BitPat("b" + "000000" + "00" + "1" + "0" + ALU_SLE_), // B__
      BLTU__ -> BitPat("b" + "000000" + "00" + "1" + "0" + ALU_SLTU), // B__
      BGEU__ -> BitPat("b" + "000000" + "00" + "1" + "0" + ALU_SLEU), // B__
      LB____ -> BitPat("b" + "000000" + "10" + "0" + "0" +   "0000"), // I__
      LH____ -> BitPat("b" + "000000" + "10" + "0" + "0" +   "0001"), // I__
      LW____ -> BitPat("b" + "000000" + "10" + "0" + "0" +   "0010"), // I__
      LBU___ -> BitPat("b" + "000000" + "10" + "0" + "0" +   "0100"), // I__
      LHU___ -> BitPat("b" + "000000" + "10" + "0" + "0" +   "0101"), // I__
      SB____ -> BitPat("b" + "000000" + "01" + "0" + "0" +   "0011"), // S__
      SH____ -> BitPat("b" + "000000" + "01" + "0" + "0" +   "1111"), // S__
      SW____ -> BitPat("b" + "000000" + "01" + "0" + "0" +   "0010"), // S__
      ADDI__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0000"), // I__
      SLTI__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0010"), // I__
      SLTIU_ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0011"), // I__
      XORI__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0100"), // I__
      ORI___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0110"), // I__
      ANDI__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0111"), // I__
      SLLI__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0001"), // I__
      SRLI__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0101"), // I__
      SRAI__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "1101"), // I__
      ADD___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0000"), // R__
      SUB___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "1000"), // R__
      SLL___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0001"), // R__
      SLT___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0010"), // R__
      SLTU__ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0011"), // R__
      XOR___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0100"), // R__
      SRL___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0101"), // R__
      SRA___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "1101"), // R__
      OR____ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0110"), // R__
      AND___ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0111"), // R__
      FENCE_ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0000"), // N__
      FENCET -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0000"), // N__
      PAUSE_ -> BitPat("b" + "000000" + "00" + "0" + "0" +   "0000"), // N__
      ECALL_ -> BitPat("b" + "010101" + "00" + "0" + "0" +   "0000"), // N__
      EBREAK -> BitPat("b" + "001101" + "00" + "0" + "0" +   "0000"), // N__
      MRET__ -> BitPat("b" + "100101" + "00" + "0" + "0" +   "0000"), // N__
      FENCEI -> BitPat("b" + "000001" + "00" + "0" + "0" +   "0000"), // N__
      CSRRW_ -> BitPat("b" + "000011" + "00" + "0" + "0" +   "0001"), // CSR
      CSRRS_ -> BitPat("b" + "000011" + "00" + "0" + "0" +   "0010"), // CSR
      CSRRC_ -> BitPat("b" + "000011" + "00" + "0" + "0" +   "0011"), // CSR
      CSRRWI -> BitPat("b" + "000011" + "00" + "0" + "0" +   "0101"), // CSR
      CSRRSI -> BitPat("b" + "000011" + "00" + "0" + "0" +   "0110"), // CSR
      CSRRCI -> BitPat("b" + "000011" + "00" + "0" + "0" +   "0111")  // CSR
    // format: on
    ),
    BitPat("b" + "000000" + "00" + "0" + "0" + ALU_ADD_)
  )
  // val decoded = decoder(in.inst, table)
  val inst_type = decoder(in.inst, type_decoder)
  out.alu_op := inst_type(3, 0)
  out.jen := inst_type(4)
  out.ben := inst_type(5)
  out.wen := inst_type(6)
  out.ren := inst_type(7)

  out_sys.system := inst_type(8)
  out_sys.csr_wen := inst_type(9)
  out_sys.func3_zero := inst_type(10)
  out_sys.ebreak := inst_type(11)
  out_sys.ecall := inst_type(12)
  out_sys.mret := inst_type(13)

  val table1 = Array(
    // format: off
    // inst      | rd |  imm |    op1 |    op2 | opj |
    LUI___ -> List( rd,  imm_u,   0.U, imm_u,    0.U), // U__
    AUIPC_ -> List( rd,  imm_u, in.pc, imm_u,    0.U), // U__
    JAL___ -> List( rd,  imm_j, in.pc,   4.U,  in.pc), // J__
    JALR__ -> List( rd,  imm_i, in.pc,   4.U,   rs1v), // I__
    BEQ___ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B__
    BNE___ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B__
    BLT___ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B__
    BGE___ -> List(0.U,  imm_b,  rs2v,  rs1v,  in.pc), // B__
    BLTU__ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B__
    BGEU__ -> List(0.U,  imm_b,  rs2v,  rs1v,  in.pc), // B__
    LB____ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I__
    LH____ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I__
    LW____ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I__
    LBU___ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I__
    LHU___ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I__
    SB____ -> List(0.U,  imm_s,  rs1v,  rs2v,   rs1v), // S__
    SH____ -> List(0.U,  imm_s,  rs1v,  rs2v,   rs1v), // S__
    SW____ -> List(0.U,  imm_s,  rs1v,  rs2v,   rs1v), // S__
    ADDI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    SLTI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    SLTIU_ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    XORI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    ORI___ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    ANDI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    SLLI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    SRLI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    SRAI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I__
    ADD___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    SUB___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    SLL___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    SLT___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    SLTU__ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    XOR___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    SRL___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    SRA___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    OR____ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    AND___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R__
    FENCE_ -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N__
    FENCET -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N__
    PAUSE_ -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N__
    ECALL_ -> List( rd, MCAUSE,  rs1v,   0.U, MEPC__), // N__
    EBREAK -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N__
    MRET__ -> List( rd,MSTATUS,  rs1v,   0.U,    0.U), // N__
    FENCEI -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N__
    CSRRW_ -> List( rd,    csr,  rs1v,   0.U,    0.U), // CSR
    CSRRS_ -> List( rd,    csr,  rs1v,   0.U,    0.U), // CSR
    CSRRC_ -> List( rd,    csr,  rs1v,   0.U,    0.U), // CSR
    CSRRWI -> List( rd,    csr,  uimm,   0.U,    0.U), // CSR
    CSRRSI -> List( rd,    csr,  uimm,   0.U,    0.U), // CSR
    CSRRCI -> List( rd,    csr,  uimm,   0.U,    0.U)  // CSR
    // format: on
  )
  val var_decoder =
    ListLookup(in.inst, List(0.U, 0.U, 0.U, 0.U, 0.U), table1)

  out.rd := var_decoder(0)
  out.imm := var_decoder(1)
  out.op1 := var_decoder(2)
  out.op2 := var_decoder(3)
  out.opj := var_decoder(4)
}
