package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._

class ysyx_idu_decoder extends Module with Instr with MicroOP {
  val in      = IO(new Bundle {
    val inst = Input(UInt(32.W))
    val pc   = Input(UInt(32.W))
    val rs1v = Input(UInt(32.W))
    val rs2v = Input(UInt(32.W))
  })
  val out     = IO(new Bundle {
    val wen = Output(UInt(1.W))
    val ren = Output(UInt(1.W))
    val jen = Output(UInt(1.W))
    val ben = Output(UInt(1.W))

    val rd     = Output(UInt(5.W))
    val imm    = Output(UInt(32.W))
    val op1    = Output(UInt(32.W))
    val op2    = Output(UInt(32.W))
    val alu_op = Output(UInt(5.W))

    // U/J-type, and no `rs1` or `rs2` instructions
    val indie = Output(UInt(1.W))
  })
  val out_sys = IO(new Bundle {
    val system  = Output(UInt(1.W))
    var ecall   = Output(UInt(1.W))
    var ebreak  = Output(UInt(1.W))
    val fence_i = Output(UInt(1.W))
    var mret    = Output(UInt(1.W))
    val csr_csw = Output(UInt(3.W))
  })
  val rs1v    = in.rs1v
  val rs2v    = in.rs2v
  val rd      = in.inst(11, 7)
  val opcode  = in.inst(6, 0)
  val funct3  = in.inst(14, 12)
  val funct7  = in.inst(31, 25)

  val imm_i = Cat(Fill(20, in.inst(31)), in.inst(31, 20))
  val imm_s = Cat(Fill(20, in.inst(31)), in.inst(31, 25), in.inst(11, 7))
  val immbv = Cat(in.inst(31), in.inst(7), in.inst(30, 25), in.inst(11, 8))
  val imm_b = Cat(Fill(19, in.inst(31)), immbv, 0.U)
  val imm_u = Cat(in.inst(31, 12), Fill(12, 0.U))
  val immjv = Cat(in.inst(31), in.inst(19, 12), in.inst(20), in.inst(30, 21))
  val imm_j = Cat(Fill(11, in.inst(31)), immjv, 0.U)
  val csr   = in.inst(31, 20)
  val uimm  = in.inst(19, 15)

  val type_table   = TruthTable(
    Map(
      //                  indie rw b j  |  alu op |
      LUI___ -> BitPat("b" + "1 00 0 0" + ALU_ADD_), // U
      AUIPC_ -> BitPat("b" + "1 00 0 0" + ALU_ADD_), // U
      JAL___ -> BitPat("b" + "1 00 0 1" + ALU_ADD_), // J
      JALR__ -> BitPat("b" + "0 00 0 1" + ALU_ADD_), // I

      BEQ___ -> BitPat("b" + "0 00 1 0" + ALU_SUB_), // B
      BNE___ -> BitPat("b" + "0 00 1 0" + ALU_XOR_), // B
      BLT___ -> BitPat("b" + "0 00 1 0" + ALU_SLT_), // B
      BGE___ -> BitPat("b" + "0 00 1 0" + ALU_SLE_), // B
      BLTU__ -> BitPat("b" + "0 00 1 0" + ALU_SLTU), // B
      BGEU__ -> BitPat("b" + "0 00 1 0" + ALU_SLEU), // B

      LB____ -> BitPat("b" + "0 10 0 0" + LSU_LB_), // I
      LH____ -> BitPat("b" + "0 10 0 0" + LSU_LH_), // I
      LW____ -> BitPat("b" + "0 10 0 0" + LSU_LW_), // I
      LBU___ -> BitPat("b" + "0 10 0 0" + LSU_LBU), // I
      LHU___ -> BitPat("b" + "0 10 0 0" + LSU_LHU), // I
      SB____ -> BitPat("b" + "0 01 0 0" + LSU_SB_), // S
      SH____ -> BitPat("b" + "0 01 0 0" + LSU_SH_), // S
      SW____ -> BitPat("b" + "0 01 0 0" + LSU_SW_), // S

      ADDI__ -> BitPat("b" + "0 00 0 0" + ALU_ADD_), // I
      SLTI__ -> BitPat("b" + "0 00 0 0" + ALU_SLT_), // I
      SLTIU_ -> BitPat("b" + "0 00 0 0" + ALU_SLTU), // I
      XORI__ -> BitPat("b" + "0 00 0 0" + ALU_XOR_), // I
      ORI___ -> BitPat("b" + "0 00 0 0" + ALU_OR__), // I
      ANDI__ -> BitPat("b" + "0 00 0 0" + ALU_AND_), // I
      SLLI__ -> BitPat("b" + "0 00 0 0" + ALU_SLL_), // I
      SRLI__ -> BitPat("b" + "0 00 0 0" + ALU_SRL_), // I
      SRAI__ -> BitPat("b" + "0 00 0 0" + ALU_SRA_), // I
      ADD___ -> BitPat("b" + "0 00 0 0" + ALU_ADD_), // R
      SUB___ -> BitPat("b" + "0 00 0 0" + ALU_SUB_), // R
      SLL___ -> BitPat("b" + "0 00 0 0" + ALU_SLL_), // R
      SLT___ -> BitPat("b" + "0 00 0 0" + ALU_SLT_), // R
      SLTU__ -> BitPat("b" + "0 00 0 0" + ALU_SLTU), // R
      XOR___ -> BitPat("b" + "0 00 0 0" + ALU_XOR_), // R
      SRL___ -> BitPat("b" + "0 00 0 0" + ALU_SRL_), // R
      SRA___ -> BitPat("b" + "0 00 0 0" + ALU_SRA_), // R
      OR____ -> BitPat("b" + "0 00 0 0" + ALU_OR__), // R
      AND___ -> BitPat("b" + "0 00 0 0" + ALU_AND_), // R

      FENCE_ -> BitPat("b" + "1 00 0 0" + "0????"), // N
      FENCET -> BitPat("b" + "1 00 0 0" + "0????"), // N
      PAUSE_ -> BitPat("b" + "1 00 0 0" + "0????"), // N
      ECALL_ -> BitPat("b" + "1 00 0 0" + "0????"), // N
      EBREAK -> BitPat("b" + "1 00 0 0" + "0????"), // N

      FENCEI -> BitPat("b" + "1 00 0 0" + "0????"), // N

      CSRRW_ -> BitPat("b" + "0 00 0 0" + "0????"), // CSR
      CSRRS_ -> BitPat("b" + "0 00 0 0" + "0????"), // CSR
      CSRRC_ -> BitPat("b" + "0 00 0 0" + "0????"), // CSR
      CSRRWI -> BitPat("b" + "1 00 0 0" + "0????"), // CSR
      CSRRSI -> BitPat("b" + "1 00 0 0" + "0????"), // CSR
      CSRRCI -> BitPat("b" + "1 00 0 0" + "0????"), // CSR

      MRET__ -> BitPat("b" + "1 00 0 0" + "0????"), // N

      MUL___ -> BitPat("b" + "0 00 0 0" + ALU_MUL_), // R
      MULH__ -> BitPat("b" + "0 00 0 0" + ALU_MULH), // R
      MULHSU -> BitPat("b" + "0 00 0 0" + ALU_MULS), // R
      MULHU_ -> BitPat("b" + "0 00 0 0" + ALU_MULU), // R
      DIV___ -> BitPat("b" + "0 00 0 0" + ALU_DIV_), // R
      DIVU__ -> BitPat("b" + "0 00 0 0" + ALU_DIVU), // R
      REM___ -> BitPat("b" + "0 00 0 0" + ALU_REM_), // R
      REMU__ -> BitPat("b" + "0 00 0 0" + ALU_REMU)  // R
    ),
    BitPat("b" + "1 00 0 0" + ALU_ADD_)
  )
  // val decoded = decoder(in.inst, table)
  val inst_decoded = decoder(in.inst, type_table)
  out.alu_op := inst_decoded(4, 0)
  out.jen    := inst_decoded(5)
  out.ben    := inst_decoded(6)
  out.wen    := inst_decoded(7)
  out.ren    := inst_decoded(8)
  out.indie  := inst_decoded(9)

  val sys_misc_table = TruthTable(
    Map( //                   csw rebc s
      ECALL_ -> BitPat("b" + "000 0001 1"), // N
      EBREAK -> BitPat("b" + "000 0010 1"), // N

      FENCEI -> BitPat("b" + "000 0100 1"), // N

      MRET__ -> BitPat("b" + "000 1000 1"), // N

      CSRRW_ -> BitPat("b" + "001 0000 1"), // CSR
      CSRRS_ -> BitPat("b" + "010 0000 1"), // CSR
      CSRRC_ -> BitPat("b" + "100 0000 1"), // CSR
      CSRRWI -> BitPat("b" + "001 0000 1"), // CSR
      CSRRSI -> BitPat("b" + "010 0000 1"), // CSR
      CSRRCI -> BitPat("b" + "100 0000 1")  // CSR
    ),
    BitPat("b" + "000 0000 0")
  )

  val sys_decoded = decoder(in.inst, sys_misc_table)

  out_sys.system  := sys_decoded(0)
  out_sys.ecall   := sys_decoded(1)
  out_sys.ebreak  := sys_decoded(2)
  out_sys.fence_i := sys_decoded(3)
  out_sys.mret    := sys_decoded(4)
  out_sys.csr_csw := sys_decoded(7, 5)

  val op_table    = Array(
    // format: off
    // inst      |  rd|    imm|   op1|   op2|
    LUI___ -> List( rd,    0.U, imm_u,   0.U), // U
    AUIPC_ -> List( rd,    0.U, in.pc, imm_u), // U
    JAL___ -> List( rd,  imm_j, in.pc,   0.U), // J
    JALR__ -> List( rd,  imm_i,  rs1v,   0.U), // I

    BEQ___ -> List(0.U,  imm_b,  rs1v,  rs2v), // B
    BNE___ -> List(0.U,  imm_b,  rs1v,  rs2v), // B
    BLT___ -> List(0.U,  imm_b,  rs1v,  rs2v), // B
    BGE___ -> List(0.U,  imm_b,  rs2v,  rs1v), // B
    BLTU__ -> List(0.U,  imm_b,  rs1v,  rs2v), // B
    BGEU__ -> List(0.U,  imm_b,  rs2v,  rs1v), // B

    LB____ -> List( rd,  imm_i,  rs1v, imm_i), // I
    LH____ -> List( rd,  imm_i,  rs1v, imm_i), // I
    LW____ -> List( rd,  imm_i,  rs1v, imm_i), // I
    LBU___ -> List( rd,  imm_i,  rs1v, imm_i), // I
    LHU___ -> List( rd,  imm_i,  rs1v, imm_i), // I
    SB____ -> List(0.U,  imm_s,  rs1v,  rs2v), // S
    SH____ -> List(0.U,  imm_s,  rs1v,  rs2v), // S
    SW____ -> List(0.U,  imm_s,  rs1v,  rs2v), // S

    ADDI__ -> List( rd,  imm_i,  rs1v, imm_i), // I
    SLTI__ -> List( rd,  imm_i,  rs1v, imm_i), // I
    SLTIU_ -> List( rd,  imm_i,  rs1v, imm_i), // I
    XORI__ -> List( rd,  imm_i,  rs1v, imm_i), // I
    ORI___ -> List( rd,  imm_i,  rs1v, imm_i), // I
    ANDI__ -> List( rd,  imm_i,  rs1v, imm_i), // I
    SLLI__ -> List( rd,  imm_i,  rs1v, imm_i), // I
    SRLI__ -> List( rd,  imm_i,  rs1v, imm_i), // I
    SRAI__ -> List( rd,  imm_i,  rs1v, imm_i), // I
    ADD___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    SUB___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    SLL___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    SLT___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    SLTU__ -> List( rd,    0.U,  rs1v,  rs2v), // R
    XOR___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    SRL___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    SRA___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    OR____ -> List( rd,    0.U,  rs1v,  rs2v), // R
    AND___ -> List( rd,    0.U,  rs1v,  rs2v), // R

    FENCE_ -> List( rd,    0.U,  rs1v,   0.U), // N
    FENCET -> List( rd,    0.U,  rs1v,   0.U), // N
    PAUSE_ -> List( rd,    0.U,  rs1v,   0.U), // N
    ECALL_ -> List( rd, MCAUSE,  rs1v,   0.U), // N
    EBREAK -> List( rd,    0.U,  rs1v,   0.U), // N
    MRET__ -> List( rd,MSTATUS,  rs1v,   0.U), // N
    FENCEI -> List( rd,    0.U,  rs1v,   0.U), // N

    CSRRW_ -> List( rd,    csr,  rs1v,   0.U), // CSR
    CSRRS_ -> List( rd,    csr,  rs1v,   0.U), // CSR
    CSRRC_ -> List( rd,    csr,  rs1v,   0.U), // CSR
    CSRRWI -> List( rd,    csr,  uimm,   0.U), // CSR
    CSRRSI -> List( rd,    csr,  uimm,   0.U), // CSR
    CSRRCI -> List( rd,    csr,  uimm,   0.U), // CSR

    MUL___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    MULH__ -> List( rd,    0.U,  rs1v,  rs2v), // R
    MULHSU -> List( rd,    0.U,  rs1v,  rs2v), // R
    MULHU_ -> List( rd,    0.U,  rs1v,  rs2v), // R
    DIV___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    DIVU__ -> List( rd,    0.U,  rs1v,  rs2v), // R
    REM___ -> List( rd,    0.U,  rs1v,  rs2v), // R
    REMU__ -> List( rd,    0.U,  rs1v,  rs2v)  // R
  )
  val var_decoder = ListLookup(
     in.inst, List( 0.U,   0.U,   0.U,   0.U), op_table)
  // format: on
  out.rd  := var_decoder(0)
  out.imm := var_decoder(1)
  out.op1 := var_decoder(2)
  out.op2 := var_decoder(3)
}
