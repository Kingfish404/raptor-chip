package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._

class ysyx_idu_decoder extends Module with Instr with MicroOP {
  val in       = IO(new Bundle {
    val inst = Input(UInt(32.W))
    val pc   = Input(UInt(32.W))
    val rs1v = Input(UInt(32.W))
    val rs2v = Input(UInt(32.W))
  })
  val out      = IO(new Bundle {
    val wen = Output(UInt(1.W))
    val ren = Output(UInt(1.W))
    val jen = Output(UInt(1.W))
    val ben = Output(UInt(1.W))

    val rd     = Output(UInt(5.W))
    val imm    = Output(UInt(32.W))
    val op1    = Output(UInt(32.W))
    val op2    = Output(UInt(32.W))
    val alu_op = Output(UInt(5.W))
    val opj    = Output(UInt(32.W))

    // U/J-type, and no `rs1` or `rs2` instructions
    val indie = Output(UInt(1.W))
  })
  val out_sys  = IO(new Bundle {
    val system     = Output(UInt(1.W))
    val func3_zero = Output(UInt(1.W))
    val csr_wen    = Output(UInt(1.W))
    var ebreak     = Output(UInt(1.W))
    var ecall      = Output(UInt(1.W))
    var mret       = Output(UInt(1.W))
  })
  val rs1v     = in.rs1v
  val rs2v     = in.rs2v
  val rd       = in.inst(11, 7)
  val opcode   = in.inst(6, 0)
  val funct3   = in.inst(14, 12)
  val funct7   = in.inst(31, 25)
  val ALU_F3OP = Cat(0.U(1.W), funct3)
  val ALU_F3_5 = Cat(funct7(5), funct3)

  val imm_i = Cat(Fill(20, in.inst(31)), in.inst(31, 20))
  val imm_s = Cat(Fill(20, in.inst(31)), in.inst(31, 25), in.inst(11, 7))
  val immbv = Cat(in.inst(31), in.inst(7), in.inst(30, 25), in.inst(11, 8))
  val imm_b = Cat(Fill(19, in.inst(31)), immbv, 0.U)
  val imm_u = Cat(in.inst(31, 12), Fill(12, 0.U))
  val immjv = Cat(in.inst(31), in.inst(19, 12), in.inst(20), in.inst(30, 21))
  val imm_j = Cat(Fill(11, in.inst(31)), immjv, 0.U)
  val csr   = in.inst(31, 20)
  val uimm  = in.inst(19, 15)

  val type_decoder = TruthTable(
    Map(
      //                  | indie |    sys  |  rw  |  b  |  j  |  alu op |
      LUI___ -> BitPat("b" + "1" + "000000" + "00" + "0" + "0" + ALU_ADD_), // U
      AUIPC_ -> BitPat("b" + "1" + "000000" + "00" + "0" + "0" + ALU_ADD_), // U
      JAL___ -> BitPat("b" + "1" + "000000" + "00" + "0" + "1" + ALU_ADD_), // J
      JALR__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "1" + ALU_ADD_), // I

      BEQ___ -> BitPat("b" + "0" + "000000" + "00" + "1" + "0" + ALU_SUB_), // B
      BNE___ -> BitPat("b" + "0" + "000000" + "00" + "1" + "0" + ALU_XOR_), // B
      BLT___ -> BitPat("b" + "0" + "000000" + "00" + "1" + "0" + ALU_SLT_), // B
      BGE___ -> BitPat("b" + "0" + "000000" + "00" + "1" + "0" + ALU_SLE_), // B
      BLTU__ -> BitPat("b" + "0" + "000000" + "00" + "1" + "0" + ALU_SLTU), // B
      BGEU__ -> BitPat("b" + "0" + "000000" + "00" + "1" + "0" + ALU_SLEU), // B

      LB____ -> BitPat("b" + "0" + "000000" + "10" + "0" + "0" + LSU_LB_), // I
      LH____ -> BitPat("b" + "0" + "000000" + "10" + "0" + "0" + LSU_LH_), // I
      LW____ -> BitPat("b" + "0" + "000000" + "10" + "0" + "0" + LSU_LW_), // I
      LBU___ -> BitPat("b" + "0" + "000000" + "10" + "0" + "0" + LSU_LBU), // I
      LHU___ -> BitPat("b" + "0" + "000000" + "10" + "0" + "0" + LSU_LHU), // I
      SB____ -> BitPat("b" + "0" + "000000" + "01" + "0" + "0" + LSU_SB_), // S
      SH____ -> BitPat("b" + "0" + "000000" + "01" + "0" + "0" + LSU_SH_), // S
      SW____ -> BitPat("b" + "0" + "000000" + "01" + "0" + "0" + LSU_SW_), // S

      ADDI__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_ADD_), // I
      SLTI__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SLT_), // I
      SLTIU_ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SLTU), // I
      XORI__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_XOR_), // I
      ORI___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_OR__), // I
      ANDI__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_AND_), // I
      SLLI__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SLL_), // I
      SRLI__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SRL_), // I
      SRAI__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SRA_), // I
      ADD___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_ADD_), // R
      SUB___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SUB_), // R
      SLL___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SLL_), // R
      SLT___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SLT_), // R
      SLTU__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SLTU), // R
      XOR___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_XOR_), // R
      SRL___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SRL_), // R
      SRA___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_SRA_), // R
      OR____ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_OR__), // R
      AND___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_AND_), // R

      FENCE_ -> BitPat("b" + "1" + "000000" + "00" + "0" + "0" + "0????"), // N
      FENCET -> BitPat("b" + "1" + "000000" + "00" + "0" + "0" + "0????"), // N
      PAUSE_ -> BitPat("b" + "1" + "000000" + "00" + "0" + "0" + "0????"), // N
      ECALL_ -> BitPat("b" + "1" + "010101" + "00" + "0" + "0" + "0????"), // N
      EBREAK -> BitPat("b" + "1" + "001101" + "00" + "0" + "0" + "0????"), // N
      MRET__ -> BitPat("b" + "1" + "100101" + "00" + "0" + "0" + "0????"), // N
      FENCEI -> BitPat("b" + "1" + "000001" + "00" + "0" + "0" + "0????"), // N

      CSRRW_ -> BitPat("b" + "0" + "000011" + "00" + "0" + "0" + "0????"), // CSR
      CSRRS_ -> BitPat("b" + "0" + "000011" + "00" + "0" + "0" + "0????"), // CSR
      CSRRC_ -> BitPat("b" + "0" + "000011" + "00" + "0" + "0" + "0????"), // CSR
      CSRRWI -> BitPat("b" + "1" + "000011" + "00" + "0" + "0" + "0????"), // CSR
      CSRRSI -> BitPat("b" + "1" + "000011" + "00" + "0" + "0" + "0????"), // CSR
      CSRRCI -> BitPat("b" + "1" + "000011" + "00" + "0" + "0" + "0????"), // CSR

      MUL___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_MUL_), // R
      MULH__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_MULH), // R
      MULHSU -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_MULS), // R
      MULHU_ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_MULU), // R
      DIV___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_DIV_), // R
      DIVU__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_DIVU), // R
      REM___ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_REM_), // R
      REMU__ -> BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_REMU)  // R
      // format: off
    ),          BitPat("b" + "0" + "000000" + "00" + "0" + "0" + ALU_ADD_)
      // format: on
  )
  // val decoded = decoder(in.inst, table)
  val inst_type    = decoder(in.inst, type_decoder)
  out.alu_op := inst_type(4, 0)
  out.jen    := inst_type(5)
  out.ben    := inst_type(6)
  out.wen    := inst_type(7)
  out.ren    := inst_type(8)

  out_sys.system     := inst_type(9)
  out_sys.csr_wen    := inst_type(10)
  out_sys.func3_zero := inst_type(11)
  out_sys.ebreak     := inst_type(12)
  out_sys.ecall      := inst_type(13)
  out_sys.mret       := inst_type(14)
  out.indie          := inst_type(15)

  val op_table    = Array(
    // format: off
    // inst      | rd |  imm |    op1 |    op2 | opj |
    LUI___ -> List( rd,  imm_u,   0.U, imm_u,    0.U), // U
    AUIPC_ -> List( rd,  imm_u, in.pc, imm_u,    0.U), // U
    JAL___ -> List( rd,  imm_j, in.pc,   4.U,  in.pc), // J
    JALR__ -> List( rd,  imm_i, in.pc,   4.U,   rs1v), // I

    BEQ___ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B
    BNE___ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B
    BLT___ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B
    BGE___ -> List(0.U,  imm_b,  rs2v,  rs1v,  in.pc), // B
    BLTU__ -> List(0.U,  imm_b,  rs1v,  rs2v,  in.pc), // B
    BGEU__ -> List(0.U,  imm_b,  rs2v,  rs1v,  in.pc), // B

    LB____ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I
    LH____ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I
    LW____ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I
    LBU___ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I
    LHU___ -> List( rd,  imm_i,  rs1v, imm_i,   rs1v), // I
    SB____ -> List(0.U,  imm_s,  rs1v,  rs2v,   rs1v), // S
    SH____ -> List(0.U,  imm_s,  rs1v,  rs2v,   rs1v), // S
    SW____ -> List(0.U,  imm_s,  rs1v,  rs2v,   rs1v), // S

    ADDI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    SLTI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    SLTIU_ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    XORI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    ORI___ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    ANDI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    SLLI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    SRLI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    SRAI__ -> List( rd,  imm_i,  rs1v, imm_i,    0.U), // I
    ADD___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    SUB___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    SLL___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    SLT___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    SLTU__ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    XOR___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    SRL___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    SRA___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    OR____ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    AND___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R

    FENCE_ -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N
    FENCET -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N
    PAUSE_ -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N
    ECALL_ -> List( rd, MCAUSE,  rs1v,   0.U, MEPC__), // N
    EBREAK -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N
    MRET__ -> List( rd,MSTATUS,  rs1v,   0.U,    0.U), // N
    FENCEI -> List( rd,    0.U,  rs1v,   0.U,    0.U), // N

    CSRRW_ -> List( rd,    csr,  rs1v,   0.U,    0.U), // CSR
    CSRRS_ -> List( rd,    csr,  rs1v,   0.U,    0.U), // CSR
    CSRRC_ -> List( rd,    csr,  rs1v,   0.U,    0.U), // CSR
    CSRRWI -> List( rd,    csr,  uimm,   0.U,    0.U), // CSR
    CSRRSI -> List( rd,    csr,  uimm,   0.U,    0.U), // CSR
    CSRRCI -> List( rd,    csr,  uimm,   0.U,    0.U), // CSR

    MUL___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    MULH__ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    MULHSU -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    MULHU_ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    DIV___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    DIVU__ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    REM___ -> List( rd,    0.U,  rs1v,  rs2v,    0.U), // R
    REMU__ -> List( rd,    0.U,  rs1v,  rs2v,    0.U)  // R
  )
  val var_decoder = ListLookup(
     in.inst, List( 0.U,   0.U,   0.U,   0.U,    0.U), op_table)
  // format: on
  out.rd  := var_decoder(0)
  out.imm := var_decoder(1)
  out.op1 := var_decoder(2)
  out.op2 := var_decoder(3)
  out.opj := var_decoder(4)
}
