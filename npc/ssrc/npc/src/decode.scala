package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._

class ysyx_idu_decoder extends Module with Instr with MicroOP {
  val in      = IO(new Bundle {
    val inst = Input(UInt(32.W))
    val pc   = Input(UInt(32.W))
  })
  val out     = IO(new Bundle {
    val alu = Output(UInt(5.W))
    val jen = Output(UInt(1.W))
    val ben = Output(UInt(1.W))
    val wen = Output(UInt(1.W))
    val ren = Output(UInt(1.W))

    val atom = Output(UInt(1.W))

    val rd  = Output(UInt(5.W))
    val imm = Output(UInt(32.W))
    val op1 = Output(UInt(32.W))
    val op2 = Output(UInt(32.W))
    val rs1 = Output(UInt(5.W))
    val rs2 = Output(UInt(5.W))
    val csr = Output(UInt(12.W))
  })
  val out_sys = IO(new Bundle {
    val system  = Output(UInt(1.W))
    var ecall   = Output(UInt(1.W))
    var ebreak  = Output(UInt(1.W))
    var mret    = Output(UInt(1.W))
    val csr_csw = Output(UInt(3.W))
  })

  val out_fence = IO(new Bundle {
    val i    = Output(UInt(1.W))
    val time = Output(UInt(1.W))
  })

  val rs1    = in.inst(19, 15)
  val rs2    = in.inst(24, 20)
  val rd     = in.inst(11, 7)
  val opcode = in.inst(6, 0)
  val funct3 = in.inst(14, 12)
  val funct7 = in.inst(31, 25)

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
      //                      rw b j  |  alu op |
      LUI___ -> BitPat("b" + "00 0 0" + ALU_ADD_), // U
      AUIPC_ -> BitPat("b" + "00 0 0" + ALU_ADD_), // U

      JAL___ -> BitPat("b" + "00 0 1" + ALU_ADD_), // J

      JALR__ -> BitPat("b" + "00 0 1" + ALU_ADD_), // I

      BEQ___ -> BitPat("b" + "00 1 0" + ALU_EQ__), // B
      BNE___ -> BitPat("b" + "00 1 0" + ALU_XOR_), // B
      BLT___ -> BitPat("b" + "00 1 0" + ALU_SLT_), // B
      BGE___ -> BitPat("b" + "00 1 0" + ALU_SGE_), // B
      BLTU__ -> BitPat("b" + "00 1 0" + ALU_SLTU), // B
      BGEU__ -> BitPat("b" + "00 1 0" + ALU_SGEU), // B

      LB____ -> BitPat("b" + "10 0 0" + LSU_LB_), // I
      LH____ -> BitPat("b" + "10 0 0" + LSU_LH_), // I
      LW____ -> BitPat("b" + "10 0 0" + LSU_LW_), // I
      LBU___ -> BitPat("b" + "10 0 0" + LSU_LBU), // I
      LHU___ -> BitPat("b" + "10 0 0" + LSU_LHU), // I

      SB____ -> BitPat("b" + "01 0 0" + LSU_SB_), // S
      SH____ -> BitPat("b" + "01 0 0" + LSU_SH_), // S
      SW____ -> BitPat("b" + "01 0 0" + LSU_SW_), // S

      ADDI__ -> BitPat("b" + "00 0 0" + ALU_ADD_), // I
      SLTI__ -> BitPat("b" + "00 0 0" + ALU_SLT_), // I
      SLTIU_ -> BitPat("b" + "00 0 0" + ALU_SLTU), // I
      XORI__ -> BitPat("b" + "00 0 0" + ALU_XOR_), // I
      ORI___ -> BitPat("b" + "00 0 0" + ALU_OR__), // I
      ANDI__ -> BitPat("b" + "00 0 0" + ALU_AND_), // I

      SLLI__ -> BitPat("b" + "00 0 0" + ALU_SLL_), // I
      SRLI__ -> BitPat("b" + "00 0 0" + ALU_SRL_), // I
      SRAI__ -> BitPat("b" + "00 0 0" + ALU_SRA_), // I

      ADD___ -> BitPat("b" + "00 0 0" + ALU_ADD_), // R
      SUB___ -> BitPat("b" + "00 0 0" + ALU_SUB_), // R
      SLL___ -> BitPat("b" + "00 0 0" + ALU_SLL_), // R
      SLT___ -> BitPat("b" + "00 0 0" + ALU_SLT_), // R
      SLTU__ -> BitPat("b" + "00 0 0" + ALU_SLTU), // R
      XOR___ -> BitPat("b" + "00 0 0" + ALU_XOR_), // R
      SRL___ -> BitPat("b" + "00 0 0" + ALU_SRL_), // R
      SRA___ -> BitPat("b" + "00 0 0" + ALU_SRA_), // R
      OR____ -> BitPat("b" + "00 0 0" + ALU_OR__), // R
      AND___ -> BitPat("b" + "00 0 0" + ALU_AND_), // R

      ECALL_ -> BitPat("b" + "00 0 0" + "0???0"), // N
      EBREAK -> BitPat("b" + "00 0 0" + "0???0"), // N

    // format: off
   FENCE____ -> BitPat("b" + "00 0 0" + "0???0"), // N
   FENCE_TSO -> BitPat("b" + "00 0 0" + "0???0"), // N
   FENCE_I__ -> BitPat("b" + "00 0 0" + "0???0"), // N
   FENCE_TIM -> BitPat("b" + "00 0 0" + "0???0"), // N

   SFENCE_VM -> BitPat("b" + "00 0 0" + "0???0"), // N
    // format: on

      CSRRW_ -> BitPat("b" + "00 0 0" + "0???0"), // CSR
      CSRRS_ -> BitPat("b" + "00 0 0" + "0???0"), // CSR
      CSRRC_ -> BitPat("b" + "00 0 0" + "0???0"), // CSR
      CSRRWI -> BitPat("b" + "00 0 0" + "0???0"), // CSR
      CSRRSI -> BitPat("b" + "00 0 0" + "0???0"), // CSR
      CSRRCI -> BitPat("b" + "00 0 0" + "0???0"), // CSR

      MUL___ -> BitPat("b" + "00 0 0" + ALU_MUL_), // R
      MULH__ -> BitPat("b" + "00 0 0" + ALU_MULH), // R
      MULHSU -> BitPat("b" + "00 0 0" + ALU_MULS), // R
      MULHU_ -> BitPat("b" + "00 0 0" + ALU_MULU), // R
      DIV___ -> BitPat("b" + "00 0 0" + ALU_DIV_), // R
      DIVU__ -> BitPat("b" + "00 0 0" + ALU_DIVU), // R
      REM___ -> BitPat("b" + "00 0 0" + ALU_REM_), // R
      REMU__ -> BitPat("b" + "00 0 0" + ALU_REMU), // R

      // TODO: add reservation for lr/sc
      // format: off
      LR_W__ -> BitPat("b" + "10 0 0" + ATO_LR__), // R
      SC_W__ -> BitPat("b" + "01 0 0" + ATO_SC__), // R
   AMOSWAP_W -> BitPat("b" + "11 0 0" + ATO_SWAP), // R
   AMOADD_W_ -> BitPat("b" + "11 0 0" + ATO_ADD_), // R
   AMOXOR_W_ -> BitPat("b" + "11 0 0" + ATO_XOR_), // R
   AMOAND_W_ -> BitPat("b" + "11 0 0" + ATO_AND_), // R
   AMOOR_W__ -> BitPat("b" + "11 0 0" + ATO_OR__), // R
   AMOMIN_W_ -> BitPat("b" + "11 0 0" + ATO_MIN_), // R
   AMOMAX_W_ -> BitPat("b" + "11 0 0" + ATO_MAX_), // R
   AMOMINU_W -> BitPat("b" + "11 0 0" + ATO_MINU), // R
   AMOMAXU_W -> BitPat("b" + "11 0 0" + ATO_MAXU), // R
      // format: on

      MRET__ -> BitPat("b" + "00 0 0" + "0???0"), // N
      SRET__ -> BitPat("b" + "00 0 0" + "0???0"), // N

      WFI___ -> BitPat("b" + "00 0 0" + ALU_ADD_) // N
      //                      rw b j  |  alu op |
    ),
    BitPat("b" + "00 0 0" + ALU_ILL_)
  )
  val inst_decoded = decoder(in.inst, type_table)
  out.alu := inst_decoded(4, 0)
  out.jen := inst_decoded(5)
  out.ben := inst_decoded(6)
  out.wen := inst_decoded(7)
  out.ren := inst_decoded(8)

  val atom_decoded = decoder(
    in.inst,
    TruthTable(
      Map(
        LR_W__    -> BitPat("b" + "1"), // R
        SC_W__    -> BitPat("b" + "1"), // R
        AMOSWAP_W -> BitPat("b" + "1"), // N
        AMOADD_W_ -> BitPat("b" + "1"), // N
        AMOXOR_W_ -> BitPat("b" + "1"), // N
        AMOAND_W_ -> BitPat("b" + "1"), // N
        AMOOR_W__ -> BitPat("b" + "1"), // N
        AMOMIN_W_ -> BitPat("b" + "1"), // N
        AMOMAX_W_ -> BitPat("b" + "1"), // N
        AMOMINU_W -> BitPat("b" + "1"), // N
        AMOMAXU_W -> BitPat("b" + "1")  // N
      ),
      BitPat("b" + "0")
    )
  );
  out.atom := atom_decoded(0)

  val sys_misc_table = TruthTable(
    Map( //                   csw rbc s
      ECALL_ -> BitPat("b" + "000 001 1"), // N
      EBREAK -> BitPat("b" + "000 010 1"), // N

    // format: off
   FENCE____ -> BitPat("b" + "000 000 1"), // N
   FENCE_TSO -> BitPat("b" + "000 000 1"), // N
   FENCE_I__ -> BitPat("b" + "000 000 1"), // N
   FENCE_TIM -> BitPat("b" + "000 000 1"), // N

   SFENCE_VM -> BitPat("b" + "000 000 1"), // N
    // format: on

      MRET__ -> BitPat("b" + "000 100 1"), // N

      CSRRW_ -> BitPat("b" + "001 000 1"), // CSR
      CSRRS_ -> BitPat("b" + "010 000 1"), // CSR
      CSRRC_ -> BitPat("b" + "100 000 1"), // CSR
      CSRRWI -> BitPat("b" + "001 000 1"), // CSR
      CSRRSI -> BitPat("b" + "010 000 1"), // CSR
      CSRRCI -> BitPat("b" + "100 000 1"), // CSR

      WFI___ -> BitPat("b" + "000 000 1") // N
    ),
    BitPat("b" + "000 000 0")
  )

  val sys_decoded = decoder(in.inst, sys_misc_table)

  out_sys.system := sys_decoded(0)
  out_sys.ecall  := sys_decoded(1)
  out_sys.ebreak := sys_decoded(2)
  out_sys.mret   := sys_decoded(3)
  val csr_csw = sys_decoded(6, 4)
  out_sys.csr_csw := csr_csw

  val fence_table   = TruthTable(
    Map( //                      ftime iflush
      FENCE____ -> BitPat("b" + "0" + "0"), // N
      FENCE_TSO -> BitPat("b" + "0" + "0"), // N
      FENCE_I__ -> BitPat("b" + "0" + "1"), // N
      FENCE_TIM -> BitPat("b" + "1" + "1")  // N
    ),
    BitPat("b" + "0" + "0")
  )
  val fence_decoded = decoder(in.inst, fence_table)
  out_fence.i    := fence_decoded(0)
  out_fence.time := fence_decoded(1)

  val op_table    = Array(
    // format: off
    // inst      |  rd|    imm|   op1|   op2| rs1| rs2|
    LUI___ -> List( rd,  imm_u, imm_u,   0.U, 0.U, 0.U), // U
    AUIPC_ -> List( rd,  imm_u, in.pc, imm_u, 0.U, 0.U), // U
    
    JAL___ -> List( rd,  imm_j, in.pc,   0.U, 0.U, 0.U), // J
    
    JALR__ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I

    BEQ___ -> List(0.U,  imm_b,   0.U,   0.U, rs1, rs2), // B
    BNE___ -> List(0.U,  imm_b,   0.U,   0.U, rs1, rs2), // B
    BLT___ -> List(0.U,  imm_b,   0.U,   0.U, rs1, rs2), // B
    BGE___ -> List(0.U,  imm_b,   0.U,   0.U, rs1, rs2), // B
    BLTU__ -> List(0.U,  imm_b,   0.U,   0.U, rs1, rs2), // B
    BGEU__ -> List(0.U,  imm_b,   0.U,   0.U, rs1, rs2), // B

    LB____ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    LH____ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    LW____ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    LBU___ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    LHU___ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    
    SB____ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // S
    SH____ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // S
    SW____ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // S

    ADDI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    SLTI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    SLTIU_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    XORI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    ORI___ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    ANDI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    
    SLLI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    SRLI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    SRAI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    
    ADD___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SUB___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SLL___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SLT___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SLTU__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    XOR___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SRL___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SRA___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    OR____ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    AND___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R

    ECALL_ -> List( rd, MCAUSE,   0.U,   0.U, 0.U, 0.U), // N
    EBREAK -> List( rd,    0.U,   0.U,   0.U, 0.U, 0.U), // N

    FENCE____ -> List( rd, 0.U,   0.U,   0.U, 0.U, 0.U), // N
    FENCE_TSO -> List( rd, 0.U,   0.U,   0.U, 0.U, 0.U), // N
    FENCE_I__ -> List( rd, 0.U,   0.U,   0.U, 0.U, 0.U), // N
    FENCE_TIM -> List( rd, 0.U,   0.U,   0.U, 0.U, 0.U), // N

    SFENCE_VM -> List( rd,    0.U,   0.U,   0.U, 0.U, 0.U), // N   

    CSRRW_ -> List( rd,    csr,   0.U,   0.U, rs1, 0.U), // CSR
    CSRRS_ -> List( rd,    csr,   0.U,   0.U, rs1, 0.U), // CSR
    CSRRC_ -> List( rd,    csr,   0.U,   0.U, rs1, 0.U), // CSR
    CSRRWI -> List( rd,    csr,  uimm,   0.U, 0.U, 0.U), // CSR
    CSRRSI -> List( rd,    csr,  uimm,   0.U, 0.U, 0.U), // CSR
    CSRRCI -> List( rd,    csr,  uimm,   0.U, 0.U, 0.U), // CSR

    MUL___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    MULH__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    MULHSU -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    MULHU_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    DIV___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    DIVU__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    REM___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    REMU__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R

    LR_W__ -> List( rd,    0.U,   0.U,  0.U, rs1, 0.U), // N
    SC_W__ -> List( rd,    0.U,   0.U,  0.U, rs1, rs2), // N

 AMOSWAP_W -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOADD_W_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOXOR_W_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOAND_W_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOOR_W__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMIN_W_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMAX_W_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMINU_W -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMAXU_W -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N

    MRET__ -> List( rd,MSTATUS,   0.U,   0.U, 0.U, 0.U), // N
    SRET__ -> List( rd,SSTATUS,   0.U,   0.U, 0.U, 0.U), // N

    WFI___ -> List(0.U,    0.U,   0.U,   0.U, 0.U, 0.U) // N
  )
  val var_decoder = ListLookup(in.inst,
              List(0.U, 0.U, 0.U, 0.U, 0.U, 0.U), op_table)
  // format: on
  out.rd  := var_decoder(0)
  out.imm := var_decoder(1)
  out.op1 := var_decoder(2)
  out.op2 := var_decoder(3)
  out.rs1 := var_decoder(4)
  out.rs2 := var_decoder(5)
  out.csr := csr
}
