package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._
import scala.annotation.switch

trait InstrType {
  def N__ = "b0000"
  def R__ = "b0101"
  def I__ = "b0100"
  def S__ = "b0010"
  def B__ = "b0001"
  def U__ = "b0110"
  def J__ = "b0111"
  def A__ = "b1110"

  def CSR = "b1111"
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

class ysyx_idu_decoder extends Module with InstrType with Instr {
  val in = IO(new Bundle {
    val inst = Input(UInt(32.W))
    val pc = Input(UInt(32.W))
    val rs1v = Input(UInt(32.W))
    val rs2v = Input(UInt(32.W))
  })
  val out = IO(new Bundle {
    val inst_type = Output(UInt(4.W))
    val rd = Output(UInt(4.W))
    val imm = Output(UInt(32.W))
    val op1 = Output(UInt(32.W))
    val op2 = Output(UInt(32.W))
    val wen = Output(UInt(1.W))
    val ren = Output(UInt(1.W))
  })
  val out_sys = IO(new Bundle {
    var ebreak = Output(UInt(1.W))
    val system_func3_zero = Output(UInt(1.W))
    val csr_wen = Output(UInt(1.W))
    val system = Output(UInt(1.W))
  })
  val rd = in.inst(11, 7)
  val opcode = in.inst(6, 0)
  val funct3 = in.inst(14, 12)
  val imm_i = Cat(Fill(20, in.inst(31)), in.inst(31, 20))
  val imm_s = Cat(Fill(20, in.inst(31)), in.inst(31, 25), in.inst(11, 7))
  val immbv = Cat(in.inst(31), in.inst(7), in.inst(30, 25), in.inst(11, 8))
  val imm_b = Cat(Fill(19, in.inst(31)), immbv, 0.U)
  val imm_u = Cat(in.inst(31, 12), Fill(12, 0.U))
  val immjv = Cat(in.inst(31), in.inst(19, 12), in.inst(20), in.inst(30, 21))
  val imm_j = Cat(Fill(11, in.inst(31)), immjv, 0.U)

  val imm = in.inst(31, 20)
  val csr = in.inst(31, 20)
  val table = TruthTable(
    Map(
      ECALL_ -> BitPat("b0111"),
      EBREAK -> BitPat("b1111"),
      MRET__ -> BitPat("b0111"),
      FENCEI -> BitPat("b0001"),
      CSRRW_ -> BitPat("b0011"),
      CSRRS_ -> BitPat("b0011"),
      CSRRC_ -> BitPat("b0011"),
      CSRRWI -> BitPat("b0011"),
      CSRRSI -> BitPat("b0011"),
      CSRRCI -> BitPat("b0011")
    ),
    BitPat("b0000")
  )
  val type_decoder = TruthTable(
    Map(
      LUI___ -> BitPat(U__),
      AUIPC_ -> BitPat(U__),
      JAL___ -> BitPat(J__),
      JALR__ -> BitPat(I__),
      BEQ___ -> BitPat(B__),
      BNE___ -> BitPat(B__),
      BLT___ -> BitPat(B__),
      BGE___ -> BitPat(B__),
      BLTU__ -> BitPat(B__),
      BGEU__ -> BitPat(B__),
      LB____ -> BitPat(I__),
      LH____ -> BitPat(I__),
      LW____ -> BitPat(I__),
      LBU___ -> BitPat(I__),
      LHU___ -> BitPat(I__),
      SB____ -> BitPat(S__),
      SH____ -> BitPat(S__),
      SW____ -> BitPat(S__),
      ADDI__ -> BitPat(I__),
      SLTI__ -> BitPat(I__),
      SLTIU_ -> BitPat(I__),
      XORI__ -> BitPat(I__),
      ORI___ -> BitPat(I__),
      ANDI__ -> BitPat(I__),
      SLLI__ -> BitPat(I__),
      SRLI__ -> BitPat(I__),
      SRAI__ -> BitPat(I__),
      ADD___ -> BitPat(R__),
      SUB___ -> BitPat(R__),
      SLL___ -> BitPat(R__),
      SLT___ -> BitPat(R__),
      SLTU__ -> BitPat(R__),
      XOR___ -> BitPat(R__),
      SRL___ -> BitPat(R__),
      SRA___ -> BitPat(R__),
      OR____ -> BitPat(R__),
      AND___ -> BitPat(R__),
      FENCE_ -> BitPat(N__),
      FENCET -> BitPat(N__),
      PAUSE_ -> BitPat(N__),
      ECALL_ -> BitPat(N__),
      EBREAK -> BitPat(N__),
      MRET__ -> BitPat(N__),
      FENCEI -> BitPat(N__),
      CSRRW_ -> BitPat(CSR),
      CSRRS_ -> BitPat(CSR),
      CSRRC_ -> BitPat(CSR),
      CSRRWI -> BitPat(CSR),
      CSRRSI -> BitPat(CSR),
      CSRRCI -> BitPat(CSR)
    ),
    BitPat(N__)
  )
  val table1 = Array(
    LUI___ -> List(U__.U(4.W), rd, imm_u),
    AUIPC_ -> List(U__.U(4.W), rd, imm_u),
    JAL___ -> List(J__.U(4.W), rd, imm_j),
    JALR__ -> List(I__.U(4.W), rd, imm_i),
    BEQ___ -> List(B__.U(4.W), 0.U, imm_b),
    BNE___ -> List(B__.U(4.W), 0.U, imm_b),
    BLT___ -> List(B__.U(4.W), 0.U, imm_b),
    BGE___ -> List(B__.U(4.W), 0.U, imm_b),
    BLTU__ -> List(B__.U(4.W), 0.U, imm_b),
    BGEU__ -> List(B__.U(4.W), 0.U, imm_b),
    LB____ -> List(I__.U(4.W), rd, imm_i),
    LH____ -> List(I__.U(4.W), rd, imm_i),
    LW____ -> List(I__.U(4.W), rd, imm_i),
    LBU___ -> List(I__.U(4.W), rd, imm_i),
    LHU___ -> List(I__.U(4.W), rd, imm_i),
    SB____ -> List(S__.U(4.W), 0.U, imm_s),
    SH____ -> List(S__.U(4.W), 0.U, imm_s),
    SW____ -> List(S__.U(4.W), 0.U, imm_s),
    ADDI__ -> List(I__.U(4.W), rd, imm_i),
    SLTI__ -> List(I__.U(4.W), rd, imm_i),
    SLTIU_ -> List(I__.U(4.W), rd, imm_i),
    XORI__ -> List(I__.U(4.W), rd, imm_i),
    ORI___ -> List(I__.U(4.W), rd, imm_i),
    ANDI__ -> List(I__.U(4.W), rd, imm_i),
    SLLI__ -> List(I__.U(4.W), rd, imm_i),
    SRLI__ -> List(I__.U(4.W), rd, imm_i),
    SRAI__ -> List(I__.U(4.W), rd, imm_i),
    ADD___ -> List(R__.U(4.W), rd, 0.U),
    SUB___ -> List(R__.U(4.W), rd, 0.U),
    SLL___ -> List(R__.U(4.W), rd, 0.U),
    SLT___ -> List(R__.U(4.W), rd, 0.U),
    SLTU__ -> List(R__.U(4.W), rd, 0.U),
    XOR___ -> List(R__.U(4.W), rd, 0.U),
    SRL___ -> List(R__.U(4.W), rd, 0.U),
    SRA___ -> List(R__.U(4.W), rd, 0.U),
    OR____ -> List(R__.U(4.W), rd, 0.U),
    AND___ -> List(R__.U(4.W), rd, 0.U),
    FENCE_ -> List(N__.U(4.W), rd, imm),
    FENCET -> List(N__.U(4.W), rd, imm),
    PAUSE_ -> List(N__.U(4.W), rd, imm),
    ECALL_ -> List(N__.U(4.W), rd, imm),
    EBREAK -> List(N__.U(4.W), rd, imm),
    MRET__ -> List(N__.U(4.W), rd, imm),
    FENCEI -> List(N__.U(4.W), rd, imm),
    CSRRW_ -> List(CSR.U(4.W), rd, csr),
    CSRRS_ -> List(CSR.U(4.W), rd, csr),
    CSRRC_ -> List(CSR.U(4.W), rd, csr),
    CSRRWI -> List(CSR.U(4.W), rd, csr),
    CSRRSI -> List(CSR.U(4.W), rd, csr),
    CSRRCI -> List(CSR.U(4.W), rd, csr)
  )
  val var_decoder = ListLookup(in.inst, List(N__.U(4.W), 0.U, 0.U), table1)

  val decoded = decoder(in.inst, table)
  out_sys.ebreak := decoded(3)
  out_sys.system_func3_zero := decoded(2)
  out_sys.csr_wen := decoded(1)
  out_sys.system := decoded(0)

  val inst_type = decoder(in.inst, type_decoder)
  val wire = Wire(UInt(4.W))
  wire := inst_type
  out.inst_type := inst_type
  out.rd := var_decoder(1)
  out.imm := var_decoder(2)
  out.op1 := 0.U
  out.op2 := 0.U
  out.wen := 0.U
  out.ren := 0.U
  switch(wire) {
    is(R__.U(4.W)) {
      out.rd := rd; out.op1 := in.rs1v; out.op2 := in.rs2v;
    }
    is(I__.U(4.W)) {
      out.rd := rd;
      // out.imm := imm_i;
      when(opcode === "b1100111".U) {
        out.op1 := in.pc; out.op2 := 4.U;
      }.otherwise {
        out.op1 := in.rs1v; out.op2 := imm_i;
      }
      when(opcode === "b0000011".U) { out.ren := 1.U; }
    }
    is(S__.U(4.W)) {
      // out.imm := imm_s;
      out.op1 := in.rs1v; out.op2 := in.rs2v;
      out.wen := 1.U;
    }
    is(B__.U(4.W)) {
      // out.imm := imm_b;
      switch(funct3) {
        is("b000".U) { out.op1 := in.rs1v; out.op2 := in.rs2v; }
        is("b001".U) { out.op1 := in.rs1v; out.op2 := in.rs2v; }
        is("b100".U) { out.op1 := in.rs1v; out.op2 := in.rs2v; }
        is("b101".U) { out.op1 := in.rs2v; out.op2 := in.rs1v; }
        is("b110".U) { out.op1 := in.rs1v; out.op2 := in.rs2v; }
        is("b111".U) { out.op1 := in.rs2v; out.op2 := in.rs1v; }
      }
    }
    is(U__.U(4.W)) {
      // out.imm := imm_u;
      out.rd := rd;
      switch(opcode) {
        is(LUI_OPCODE) { out.op1 := 0.U; out.op2 := imm_u; }
        is(AUIPC_OPCODE) { out.op1 := in.pc; out.op2 := imm_u; }
      }
    }
    is(J__.U(4.W)) {
      // out.imm := imm_j;
      out.rd := rd; out.op1 := in.pc; out.op2 := 4.U;
    }
    is(N__.U(4.W)) {
      // out.imm := imm;
      out.rd := rd; out.op1 := in.rs1v;
    }
    is(CSR.U(4.W)) {
      // out.imm := csr;
      out.rd := rd;
    }
  }
}
