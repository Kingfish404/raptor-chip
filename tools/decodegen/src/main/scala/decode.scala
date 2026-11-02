package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._

class rapt_idu_decoder extends RawModule with Instr with MicroOP {
  val in      = IO(new Bundle {
    val inst = Input(UInt(32.W))
  })
  val out     = IO(new Bundle {
    val alu  = Output(UInt(6.W))
    val word = Output(UInt(1.W))
    val ben  = Output(UInt(1.W))
    val jen  = Output(UInt(1.W))
    val jren = Output(UInt(1.W))
    val ren  = Output(UInt(1.W))
    val wen  = Output(UInt(1.W))

    val atom = Output(UInt(1.W))

    val rd  = Output(UInt(5.W))
    // U immediates carry their signed high 20 bits; all other formats fit 21 bits.
    val imm = Output(UInt(21.W))
    val imm_u = Output(Bool())
    val op1_sel = Output(UInt(2.W))
    val op2_sel = Output(Bool())
    val rs1 = Output(UInt(5.W))
    val rs2 = Output(UInt(5.W))
    val csr = Output(UInt(12.W))
  })
  val out_sys = IO(new Bundle {
    val system  = Output(UInt(1.W))
    var ecall   = Output(UInt(1.W))
    var ebreak  = Output(UInt(1.W))
    var mret    = Output(UInt(1.W))
    var sret    = Output(UInt(1.W))
    val csr_csw = Output(UInt(3.W))
  })

  val out_fence = IO(new Bundle {
    val i    = Output(UInt(1.W))
    val time = Output(UInt(1.W))
  })

  val out_fp = IO(new Bundle {
    val valid     = Output(UInt(1.W))
    val op        = Output(UInt(6.W))
    val rm        = Output(UInt(3.W))
    val rs1       = Output(UInt(5.W))
    val rs2       = Output(UInt(5.W))
    val rs3       = Output(UInt(5.W))
    val rd        = Output(UInt(5.W))
    val load      = Output(UInt(1.W))
    val store     = Output(UInt(1.W))
    val width_d   = Output(UInt(1.W))
    val to_int    = Output(UInt(1.W))
    val writes_fpr = Output(UInt(1.W))
  })

  val rs1    = in.inst(19, 15)
  val rs2    = in.inst(24, 20)
  val rs3    = in.inst(31, 27)
  val rd     = in.inst(11, 7)
  val opcode = in.inst(6, 0)
  val funct3 = in.inst(14, 12)
  val funct7 = in.inst(31, 25)

  val imm_i = Cat(Fill(9, in.inst(31)), in.inst(31, 20))
  val imm_s = Cat(Fill(9, in.inst(31)), in.inst(31, 25), in.inst(11, 7))
  val immbv = Cat(in.inst(31), in.inst(7), in.inst(30, 25), in.inst(11, 8))
  val imm_b = Cat(Fill(8, in.inst(31)), immbv, 0.U(1.W))
  val imm_u = Cat(in.inst(31), in.inst(31, 12))
  val immjv = Cat(in.inst(31), in.inst(19, 12), in.inst(20), in.inst(30, 21))
  val imm_j = Cat(immjv, 0.U(1.W))
  val csr = in.inst(31, 20)

  val type_table   = TruthTable(
    Map(
      //                      rw  |  alu op |
      LUI___ -> BitPat("b" + "00" + ALU_ADD_), // U
      AUIPC_ -> BitPat("b" + "00" + ALU_ADD_), // U

      JAL___ -> BitPat("b" + "00" + ALU_ADD_), // J

      JALR__ -> BitPat("b" + "00" + ALU_ADD_), // I

      BEQ___ -> BitPat("b" + "00" + ALU_EQ__), // B
      BNE___ -> BitPat("b" + "00" + ALU_XOR_), // B
      BLT___ -> BitPat("b" + "00" + ALU_SLT_), // B
      BGE___ -> BitPat("b" + "00" + ALU_SGE_), // B
      BLTU__ -> BitPat("b" + "00" + ALU_SLTU), // B
      BGEU__ -> BitPat("b" + "00" + ALU_SGEU), // B

      LB____ -> BitPat("b" + "10" + LSU_LB_), // I
      LH____ -> BitPat("b" + "10" + LSU_LH_), // I
      LW____ -> BitPat("b" + "10" + LSU_LW_), // I
      LBU___ -> BitPat("b" + "10" + LSU_LBU), // I
      LHU___ -> BitPat("b" + "10" + LSU_LHU), // I

      SB____ -> BitPat("b" + "01" + LSU_SB_), // S
      SH____ -> BitPat("b" + "01" + LSU_SH_), // S
      SW____ -> BitPat("b" + "01" + LSU_SW_), // S

      ADDI__ -> BitPat("b" + "00" + ALU_ADD_), // I
      SLTI__ -> BitPat("b" + "00" + ALU_SLT_), // I
      SLTIU_ -> BitPat("b" + "00" + ALU_SLTU), // I
      XORI__ -> BitPat("b" + "00" + ALU_XOR_), // I
      ORI___ -> BitPat("b" + "00" + ALU_OR__), // I
      ANDI__ -> BitPat("b" + "00" + ALU_AND_), // I

      SLLI__ -> BitPat("b" + "00" + ALU_SLL_), // I
      SRLI__ -> BitPat("b" + "00" + ALU_SRL_), // I
      SRAI__ -> BitPat("b" + "00" + ALU_SRA_), // I

      ADD___ -> BitPat("b" + "00" + ALU_ADD_), // R
      SUB___ -> BitPat("b" + "00" + ALU_SUB_), // R
      SLL___ -> BitPat("b" + "00" + ALU_SLL_), // R
      SLT___ -> BitPat("b" + "00" + ALU_SLT_), // R
      SLTU__ -> BitPat("b" + "00" + ALU_SLTU), // R
      XOR___ -> BitPat("b" + "00" + ALU_XOR_), // R
      SRL___ -> BitPat("b" + "00" + ALU_SRL_), // R
      SRA___ -> BitPat("b" + "00" + ALU_SRA_), // R
      OR____ -> BitPat("b" + "00" + ALU_OR__), // R
      AND___ -> BitPat("b" + "00" + ALU_AND_), // R

      ECALL_ -> BitPat("b" + "00" + ALU_ADD_), // N
      EBREAK -> BitPat("b" + "00" + ALU_ADD_), // N

    // format: off
   FENCE____ -> BitPat("b" + "00" + ALU_ADD_), // N (also covers FENCE.TSO)
   FENCE_I__ -> BitPat("b" + "00" + ALU_ADD_), // N
  CBO_INVAL -> BitPat("b" + "01" + LSU_CBO_MGMT), // Zicbom: checked CMO access
  CBO_CLEAN -> BitPat("b" + "01" + LSU_CBO_MGMT), // Zicbom: checked CMO access
  CBO_FLUSH -> BitPat("b" + "01" + LSU_CBO_MGMT), // Zicbom: checked CMO access
  CBO_ZERO  -> BitPat("b" + "01" + LSU_CBO_ZERO), // Zicboz: SQ block-zero expansion
  PREFETCH_I -> BitPat("b" + "00" + ALU_ADD_), // Zicbop HINT
  PREFETCH_R -> BitPat("b" + "00" + ALU_ADD_), // Zicbop HINT
  PREFETCH_W -> BitPat("b" + "00" + ALU_ADD_), // Zicbop HINT

   SFENCE_VM -> BitPat("b" + "00" + ALU_ADD_), // N
   SINVAL_VM -> BitPat("b" + "00" + ALU_ADD_), // N
   SFENCE_W_INVAL -> BitPat("b" + "00" + ALU_ADD_), // N
   SFENCE_INVAL_IR -> BitPat("b" + "00" + ALU_ADD_), // N
    // format: on

      CSRRW_ -> BitPat("b" + "00" + ALU_ADD_), // CSR
      CSRRS_ -> BitPat("b" + "00" + ALU_ADD_), // CSR
      CSRRC_ -> BitPat("b" + "00" + ALU_ADD_), // CSR
      CSRRWI -> BitPat("b" + "00" + ALU_ADD_), // CSR
      CSRRSI -> BitPat("b" + "00" + ALU_ADD_), // CSR
      CSRRCI -> BitPat("b" + "00" + ALU_ADD_), // CSR

      MUL___ -> BitPat("b" + "00" + ALU_MUL_), // R
      MULH__ -> BitPat("b" + "00" + ALU_MULH), // R
      MULHSU -> BitPat("b" + "00" + ALU_MULS), // R
      MULHU_ -> BitPat("b" + "00" + ALU_MULU), // R
      DIV___ -> BitPat("b" + "00" + ALU_DIV_), // R
      DIVU__ -> BitPat("b" + "00" + ALU_DIVU), // R
      REM___ -> BitPat("b" + "00" + ALU_REM_), // R
      REMU__ -> BitPat("b" + "00" + ALU_REMU), // R

      // RV64I
      LWU___ -> BitPat("b" + "10" + LSU_LWU), // I
      LD____ -> BitPat("b" + "10" + LSU_LD_), // I
      SD____ -> BitPat("b" + "01" + LSU_SD_), // S

      ADDIW_ -> BitPat("b" + "00" + ALU_ADD_), // I (W-variant)
      SLLIW_ -> BitPat("b" + "00" + ALU_SLL_), // I (W-variant)
      SRLIW_ -> BitPat("b" + "00" + ALU_SRL_), // I (W-variant)
      SRAIW_ -> BitPat("b" + "00" + ALU_SRA_), // I (W-variant)
      ADDW__ -> BitPat("b" + "00" + ALU_ADD_), // R (W-variant)
      SUBW__ -> BitPat("b" + "00" + ALU_SUB_), // R (W-variant)
      SLLW__ -> BitPat("b" + "00" + ALU_SLL_), // R (W-variant)
      SRLW__ -> BitPat("b" + "00" + ALU_SRL_), // R (W-variant)
      SRAW__ -> BitPat("b" + "00" + ALU_SRA_), // R (W-variant)

      // RV64M
      MULW__ -> BitPat("b" + "00" + ALU_MUL_), // R (W-variant)
      DIVW__ -> BitPat("b" + "00" + ALU_DIV_), // R (W-variant)
      DIVUW_ -> BitPat("b" + "00" + ALU_DIVU), // R (W-variant)
      REMW__ -> BitPat("b" + "00" + ALU_REM_), // R (W-variant)
      REMUW_ -> BitPat("b" + "00" + ALU_REMU), // R (W-variant)

      // RV64A
      LR_D__    -> BitPat("b" + "10" + ATO_LR__), // R
      SC_D__    -> BitPat("b" + "01" + ATO_SC__), // R
      AMOSWAP_D -> BitPat("b" + "11" + ATO_SWAP), // R
      AMOADD_D_ -> BitPat("b" + "11" + ATO_ADD_), // R
      AMOXOR_D_ -> BitPat("b" + "11" + ATO_XOR_), // R
      AMOAND_D_ -> BitPat("b" + "11" + ATO_AND_), // R
      AMOOR_D__ -> BitPat("b" + "11" + ATO_OR__), // R
      AMOMIN_D_ -> BitPat("b" + "11" + ATO_MIN_), // R
      AMOMAX_D_ -> BitPat("b" + "11" + ATO_MAX_), // R
      AMOMINU_D -> BitPat("b" + "11" + ATO_MINU), // R
      AMOMAXU_D -> BitPat("b" + "11" + ATO_MAXU), // R

      // TODO: add reservation for lr/sc
      // format: off
      LR_W__ -> BitPat("b" + "10" + ATO_LR__), // R
      SC_W__ -> BitPat("b" + "01" + ATO_SC__), // R
   AMOSWAP_W -> BitPat("b" + "11" + ATO_SWAP), // R
   AMOADD_W_ -> BitPat("b" + "11" + ATO_ADD_), // R
   AMOXOR_W_ -> BitPat("b" + "11" + ATO_XOR_), // R
   AMOAND_W_ -> BitPat("b" + "11" + ATO_AND_), // R
   AMOOR_W__ -> BitPat("b" + "11" + ATO_OR__), // R
   AMOMIN_W_ -> BitPat("b" + "11" + ATO_MIN_), // R
   AMOMAX_W_ -> BitPat("b" + "11" + ATO_MAX_), // R
   AMOMINU_W -> BitPat("b" + "11" + ATO_MINU), // R
   AMOMAXU_W -> BitPat("b" + "11" + ATO_MAXU), // R
      // format: on

      MRET__ -> BitPat("b" + "00" + ALU_ADD_), // N
      SRET__ -> BitPat("b" + "00" + ALU_ADD_), // N

      WFI___ -> BitPat("b" + "00" + ALU_ADD_), // N

      // Zimop: MOP.r.n / MOP.rr.n — architecturally rd <- 0
      MOP_R_  -> BitPat("b" + "00" + ALU_ADD_), // I-like
      MOP_RR_ -> BitPat("b" + "00" + ALU_ADD_), // R-like

      // Zba (Address Generation)
      SH1ADD -> BitPat("b" + "00" + ALU_SH1ADD), // R
      SH2ADD -> BitPat("b" + "00" + ALU_SH2ADD), // R
      SH3ADD -> BitPat("b" + "00" + ALU_SH3ADD), // R

      // Zbb (Basic Bit-manipulation)
      ANDN__  -> BitPat("b" + "00" + ALU_ANDN),  // R
      ORN___  -> BitPat("b" + "00" + ALU_ORN),   // R
      XNOR__  -> BitPat("b" + "00" + ALU_XNOR),  // R
      CLZ___  -> BitPat("b" + "00" + ALU_CLZ),   // I (unary)
      CTZ___  -> BitPat("b" + "00" + ALU_CTZ),   // I (unary)
      CPOP__  -> BitPat("b" + "00" + ALU_CPOP),  // I (unary)
      MAX___  -> BitPat("b" + "00" + ALU_MAX),   // R
      MAXU__  -> BitPat("b" + "00" + ALU_MAXU),  // R
      MIN___  -> BitPat("b" + "00" + ALU_MIN),   // R
      MINU__  -> BitPat("b" + "00" + ALU_MINU),  // R
      SEXTB_  -> BitPat("b" + "00" + ALU_SEXTB), // I (unary)
      SEXTH_  -> BitPat("b" + "00" + ALU_SEXTH), // I (unary)
      ZEXTH_  -> BitPat("b" + "00" + ALU_ZEXTH), // R (PACK rd,rs1,x0)
      REV8_32 -> BitPat("b" + "00" + ALU_REV8),  // I (unary, RV32)
      REV8_64 -> BitPat("b" + "00" + ALU_REV8),  // I (unary, RV64)
      ORC_B_  -> BitPat("b" + "00" + ALU_ORCB),  // I (unary)
      ROL___  -> BitPat("b" + "00" + ALU_ROL),   // R
      ROR___  -> BitPat("b" + "00" + ALU_ROR),   // R
      RORI__  -> BitPat("b" + "00" + ALU_ROR),   // I (shift imm)

      // Zbs (Single-bit Operations)
      BCLR__ -> BitPat("b" + "00" + ALU_BCLR), // R
      BCLRI_ -> BitPat("b" + "00" + ALU_BCLR), // I (shift imm)
      BEXT__ -> BitPat("b" + "00" + ALU_BEXT), // R
      BEXTI_ -> BitPat("b" + "00" + ALU_BEXT), // I (shift imm)
      BINV__ -> BitPat("b" + "00" + ALU_BINV), // R
      BINVI_ -> BitPat("b" + "00" + ALU_BINV), // I (shift imm)
      BSET__ -> BitPat("b" + "00" + ALU_BSET), // R
      BSETI_ -> BitPat("b" + "00" + ALU_BSET), // I (shift imm)

      // Zbc (Carry-less Multiplication)
      CLMUL_  -> BitPat("b" + "00" + ALU_CLMUL),  // R
      CLMULH_ -> BitPat("b" + "00" + ALU_CLMULH), // R
      CLMULR_ -> BitPat("b" + "00" + ALU_CLMULR), // R

      // Zicond (Conditional Operations)
      CZERO_EQZ -> BitPat("b" + "00" + ALU_CZERO_EQZ), // R
      CZERO_NEZ -> BitPat("b" + "00" + ALU_CZERO_NEZ), // R

      // RV64 Zba
      SH1ADDUW -> BitPat("b" + "00" + ALU_SH1ADD),  // R (W-variant)
      SH2ADDUW -> BitPat("b" + "00" + ALU_SH2ADD),  // R (W-variant)
      SH3ADDUW -> BitPat("b" + "00" + ALU_SH3ADD),  // R (W-variant)
      ADD_UW__ -> BitPat("b" + "00" + ALU_ADD_UW),  // R (RV64 Zba .UW: zext.w(rs1)+rs2)
      SLLI_UW_ -> BitPat("b" + "00" + ALU_SLLI_UW), // I (RV64 Zba .UW: zext.w(rs1)<<shamt)

      // RV64 Zbb W-variants
      CLZW__  -> BitPat("b" + "00" + ALU_CLZ),  // I (W-variant)
      CTZW__  -> BitPat("b" + "00" + ALU_CTZ),  // I (W-variant)
      CPOPW_  -> BitPat("b" + "00" + ALU_CPOP), // I (W-variant)
      ROLW__  -> BitPat("b" + "00" + ALU_ROL),  // R (W-variant)
      RORW__  -> BitPat("b" + "00" + ALU_ROR),  // R (W-variant)
      RORIW_  -> BitPat("b" + "00" + ALU_ROR),  // I (W-variant)
      ZEXTH64 -> BitPat("b" + "00" + ALU_ZEXTH) // R (W-variant)
      //                      rw  |  alu op |
    ),
    BitPat("b" + "00" + ALU_ILL_)
  )
  val inst_decoded = decoder(in.inst, type_table)
  out.alu := inst_decoded(5, 0)
  out.wen := inst_decoded(6)
  out.ren := inst_decoded(7)

  val branch_table   = TruthTable(
    Map( //                retu,indi,dire,cond
      JAL___ -> BitPat("b" + "0    0   1    0"), // J

      JALR__ -> BitPat("b" + "0    1   0    0"), // I

      BEQ___ -> BitPat("b" + "0    0   0    1"), // B
      BNE___ -> BitPat("b" + "0    0   0    1"), // B
      BLT___ -> BitPat("b" + "0    0   0    1"), // B
      BGE___ -> BitPat("b" + "0    0   0    1"), // B
      BLTU__ -> BitPat("b" + "0    0   0    1"), // B
      BGEU__ -> BitPat("b" + "0    0   0    1")  // B
    ),
    BitPat("b" + "0000")
  )
  val branch_decoded = decoder(in.inst, branch_table)
  out.ben  := branch_decoded(0)
  out.jen  := branch_decoded(1) || branch_decoded(2)
  out.jren := branch_decoded(2)

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
        AMOMAXU_W -> BitPat("b" + "1"), // N
        LR_D__    -> BitPat("b" + "1"), // N
        SC_D__    -> BitPat("b" + "1"), // N
        AMOSWAP_D -> BitPat("b" + "1"), // N
        AMOADD_D_ -> BitPat("b" + "1"), // N
        AMOXOR_D_ -> BitPat("b" + "1"), // N
        AMOAND_D_ -> BitPat("b" + "1"), // N
        AMOOR_D__ -> BitPat("b" + "1"), // N
        AMOMIN_D_ -> BitPat("b" + "1"), // N
        AMOMAX_D_ -> BitPat("b" + "1"), // N
        AMOMINU_D -> BitPat("b" + "1"), // N
        AMOMAXU_D -> BitPat("b" + "1")  // N
      ),
      BitPat("b" + "0")
    )
  );
  out.atom := atom_decoded(0)

  // RV64 W-variant (word) flag decode table
  val word_table   = TruthTable(
    Map(
      ADDIW_   -> BitPat("b" + "1"), // W
      SLLIW_   -> BitPat("b" + "1"), // W
      SRLIW_   -> BitPat("b" + "1"), // W
      SRAIW_   -> BitPat("b" + "1"), // W
      ADDW__   -> BitPat("b" + "1"), // W
      SUBW__   -> BitPat("b" + "1"), // W
      SLLW__   -> BitPat("b" + "1"), // W
      SRLW__   -> BitPat("b" + "1"), // W
      SRAW__   -> BitPat("b" + "1"), // W
      MULW__   -> BitPat("b" + "1"), // W
      DIVW__   -> BitPat("b" + "1"), // W
      DIVUW_   -> BitPat("b" + "1"), // W
      REMW__   -> BitPat("b" + "1"), // W
      REMUW_   -> BitPat("b" + "1"), // W
      // RV64 Zba W-variants
      SH1ADDUW -> BitPat("b" + "1"), // W (uses ALU_SH1ADD + word=1 -> zext.w(rs1))
      SH2ADDUW -> BitPat("b" + "1"), // W
      SH3ADDUW -> BitPat("b" + "1"), // W
      // ADD_UW and SLLI_UW use dedicated ALU ops (ALU_ADD_UW / ALU_SLLI_UW);
      // they do NOT set word=1 because their result is full 64-bit (no trunc+sext).
      // RV64 Zbb W-variants
      CLZW__   -> BitPat("b" + "1"), // W
      CTZW__   -> BitPat("b" + "1"), // W
      CPOPW_   -> BitPat("b" + "1"), // W
      ROLW__   -> BitPat("b" + "1"), // W
      RORW__   -> BitPat("b" + "1"), // W
      RORIW_   -> BitPat("b" + "1"), // W
      ZEXTH64  -> BitPat("b" + "1")  // W
    ),
    BitPat("b" + "0")
  )
  val word_decoded = decoder(in.inst, word_table)
  out.word := word_decoded(0)

  val sys_misc_table = TruthTable(
    Map( //                   csw sr mr eb ec sys
      ECALL_ -> BitPat("b" + "000 0  0  0  1  1"), // N
      EBREAK -> BitPat("b" + "000 0  0  1  0  1"), // N

    // format: off
   FENCE____ -> BitPat("b" + "000 0  0  0  0  1"), // N (also covers FENCE.TSO)
   FENCE_I__ -> BitPat("b" + "000 0  0  0  0  1"), // N
  CBO_INVAL -> BitPat("b" + "000 0  0  0  0  1"), // Zicbom
  CBO_CLEAN -> BitPat("b" + "000 0  0  0  0  1"), // Zicbom
  CBO_FLUSH -> BitPat("b" + "000 0  0  0  0  1"), // Zicbom
  CBO_ZERO -> BitPat("b" + "000 0  0  0  0  1"), // Zicboz

   SFENCE_VM -> BitPat("b" + "000 0  0  0  0  1"), // N
   SINVAL_VM -> BitPat("b" + "000 0  0  0  0  1"), // N
    // format: on

      MRET__ -> BitPat("b" + "000 0  1  0  0  1"), // N
      SRET__ -> BitPat("b" + "000 1  0  0  0  1"), // N

      CSRRW_ -> BitPat("b" + "001 0  0  0  0  1"), // CSR
      CSRRS_ -> BitPat("b" + "010 0  0  0  0  1"), // CSR
      CSRRC_ -> BitPat("b" + "100 0  0  0  0  1"), // CSR
      CSRRWI -> BitPat("b" + "001 0  0  0  0  1"), // CSR
      CSRRSI -> BitPat("b" + "010 0  0  0  0  1"), // CSR
      CSRRCI -> BitPat("b" + "100 0  0  0  0  1"), // CSR

      WFI___ -> BitPat("b" + "000 0  0  0  0  1") // N
    ),
    BitPat("b" + "000 0 0 0 0 0")
  )

  val sys_decoded = decoder(in.inst, sys_misc_table)

  out_sys.system := sys_decoded(0)
  out_sys.ecall  := sys_decoded(1)
  out_sys.ebreak := sys_decoded(2)
  out_sys.mret   := sys_decoded(3)
  out_sys.sret   := sys_decoded(4)
  val csr_csw = sys_decoded(7, 5)
  out_sys.csr_csw := csr_csw

  val fence_table   = TruthTable(
    Map( //                      ftime iflush
      FENCE____ -> BitPat("b" + "0" + "0"), // N (also covers FENCE.TSO)
      FENCE_I__ -> BitPat("b" + "0" + "1"), // N
      CBO_INVAL -> BitPat("b" + "1" + "0"), // Zicbom: conservative whole-L1 maintenance
      CBO_CLEAN -> BitPat("b" + "1" + "0"), // Zicbom: write-through clean is ordering-only
      CBO_FLUSH -> BitPat("b" + "1" + "0"), // Zicbom: conservative whole-L1 maintenance
      CBO_ZERO -> BitPat("b" + "1" + "0"), // Zicboz: serialize block stores
      SFENCE_VM -> BitPat("b" + "1" + "1"), // N: flush TLBs + I-cache
      SINVAL_VM -> BitPat("b" + "1" + "1") // full SFENCE.VMA implementation
    ),
    BitPat("b" + "0" + "0")
  )
  val fence_decoded = decoder(in.inst, fence_table)
  out_fence.i    := fence_decoded(0)
  out_fence.time := fence_decoded(1)

  val fp_op_table = TruthTable(
    Map(
      FMV_W_X  -> BitPat("b" + FP_FMV_W_X),
      FMV_X_W  -> BitPat("b" + FP_FMV_X_W),
      FSGNJ_S  -> BitPat("b" + FP_FSGNJ_S),
      FSGNJN_S -> BitPat("b" + FP_FSGNJN_S),
      FSGNJX_S -> BitPat("b" + FP_FSGNJX_S),
      FMV_D_X  -> BitPat("b" + FP_FMV_D_X),
      FMV_X_D  -> BitPat("b" + FP_FMV_X_D),
      FSGNJ_D  -> BitPat("b" + FP_FSGNJ_D),
      FSGNJN_D -> BitPat("b" + FP_FSGNJN_D),
      FSGNJX_D -> BitPat("b" + FP_FSGNJX_D),
      FLW___   -> BitPat("b" + FP_FLW),
      FSW___   -> BitPat("b" + FP_FSW),
      FLD___   -> BitPat("b" + FP_FLD),
      FSD___   -> BitPat("b" + FP_FSD),
      FLH___   -> BitPat("b" + FP_ZFHMIN),
      FSH___   -> BitPat("b" + FP_ZFHMIN),
      FMV_H_X  -> BitPat("b" + FP_ZFHMIN),
      FMV_X_H  -> BitPat("b" + FP_ZFHMIN),
      FCVT_S_H -> BitPat("b" + FP_ZFHMIN),
      FCVT_H_S -> BitPat("b" + FP_ZFHMIN),
      FCVT_D_H -> BitPat("b" + FP_ZFHMIN),
      FCVT_H_D -> BitPat("b" + FP_ZFHMIN),
      FMADD_S  -> BitPat("b" + FP_FMADD_S),
      FMADD_D  -> BitPat("b" + FP_FMADD_D),
      FMSUB_S  -> BitPat("b" + FP_FMSUB_S),
      FMSUB_D  -> BitPat("b" + FP_FMSUB_D),
      FNMSUB_S -> BitPat("b" + FP_FNMSUB_S),
      FNMSUB_D -> BitPat("b" + FP_FNMSUB_D),
      FNMADD_S -> BitPat("b" + FP_FNMADD_S),
      FNMADD_D -> BitPat("b" + FP_FNMADD_D),
      FADD_S   -> BitPat("b" + FP_FADD_S),
      FSUB_S   -> BitPat("b" + FP_FSUB_S),
      FMUL_S   -> BitPat("b" + FP_FMUL_S),
      FDIV_S   -> BitPat("b" + FP_FDIV_S),
      FSQRT_S  -> BitPat("b" + FP_FSQRT_S),
      FADD_D   -> BitPat("b" + FP_FADD_D),
      FSUB_D   -> BitPat("b" + FP_FSUB_D),
      FMUL_D   -> BitPat("b" + FP_FMUL_D),
      FDIV_D   -> BitPat("b" + FP_FDIV_D),
      FSQRT_D  -> BitPat("b" + FP_FSQRT_D),
      FMIN_S   -> BitPat("b" + FP_FMIN_S),
      FMAX_S   -> BitPat("b" + FP_FMAX_S),
      FMIN_D   -> BitPat("b" + FP_FMIN_D),
      FMAX_D   -> BitPat("b" + FP_FMAX_D),
      FLE_S    -> BitPat("b" + FP_FLE_S),
      FLT_S    -> BitPat("b" + FP_FLT_S),
      FEQ_S    -> BitPat("b" + FP_FEQ_S),
      FCLASS_S -> BitPat("b" + FP_FCLASS_S),
      FLE_D    -> BitPat("b" + FP_FLE_D),
      FLT_D    -> BitPat("b" + FP_FLT_D),
      FEQ_D    -> BitPat("b" + FP_FEQ_D),
      FCLASS_D -> BitPat("b" + FP_FCLASS_D),
      FCVT_W_S -> BitPat("b" + FP_FCVT_W_S),
      FCVT_WU_S -> BitPat("b" + FP_FCVT_WU_S),
      FCVT_L_S -> BitPat("b" + FP_FCVT_L_S),
      FCVT_LU_S -> BitPat("b" + FP_FCVT_LU_S),
      FCVT_S_W -> BitPat("b" + FP_FCVT_S_W),
      FCVT_S_WU -> BitPat("b" + FP_FCVT_S_WU),
      FCVT_S_L -> BitPat("b" + FP_FCVT_S_L),
      FCVT_S_LU -> BitPat("b" + FP_FCVT_S_LU),
      FCVT_W_D -> BitPat("b" + FP_FCVT_W_D),
      FCVT_WU_D -> BitPat("b" + FP_FCVT_WU_D),
      FCVT_L_D -> BitPat("b" + FP_FCVT_L_D),
      FCVT_LU_D -> BitPat("b" + FP_FCVT_LU_D),
      FCVT_D_W -> BitPat("b" + FP_FCVT_D_W),
      FCVT_D_WU -> BitPat("b" + FP_FCVT_D_WU),
      FCVT_D_L -> BitPat("b" + FP_FCVT_D_L),
      FCVT_D_LU -> BitPat("b" + FP_FCVT_D_LU),
      FCVT_S_D -> BitPat("b" + FP_FCVT_S_D),
      FCVT_D_S -> BitPat("b" + FP_FCVT_D_S)
    ),
    BitPat("b" + FP_NONE)
  )
  val fp_op_decoded = decoder(in.inst, fp_op_table)
  val fp_fmv_x_w = ("b" + FP_FMV_X_W).U(6.W)
  val fp_fmv_x_d = ("b" + FP_FMV_X_D).U(6.W)
  val fp_flw = ("b" + FP_FLW).U(6.W)
  val fp_fsw = ("b" + FP_FSW).U(6.W)
  val fp_fld = ("b" + FP_FLD).U(6.W)
  val fp_fsd = ("b" + FP_FSD).U(6.W)
  val fp_zfhmin = ("b" + FP_ZFHMIN).U(6.W)
  val fp_half_load = fp_op_decoded === fp_zfhmin && opcode === "b0000111".U
  val fp_half_store = fp_op_decoded === fp_zfhmin && opcode === "b0100111".U
  val fp_half_to_int = fp_op_decoded === fp_zfhmin && opcode === "b1010011".U && funct7 === "b1110010".U
  val fp_fmv_d_x = ("b" + FP_FMV_D_X).U(6.W)
  val fp_fsgnj_d = ("b" + FP_FSGNJ_D).U(6.W)
  val fp_fsgnjn_d = ("b" + FP_FSGNJN_D).U(6.W)
  val fp_fsgnjx_d = ("b" + FP_FSGNJX_D).U(6.W)
  val fp_fadd_d = ("b" + FP_FADD_D).U(6.W)
  val fp_fsub_d = ("b" + FP_FSUB_D).U(6.W)
  val fp_fmul_d = ("b" + FP_FMUL_D).U(6.W)
  val fp_fdiv_d = ("b" + FP_FDIV_D).U(6.W)
  val fp_fsqrt_d = ("b" + FP_FSQRT_D).U(6.W)
  val fp_fmadd_d = ("b" + FP_FMADD_D).U(6.W)
  val fp_fmsub_d = ("b" + FP_FMSUB_D).U(6.W)
  val fp_fnmsub_d = ("b" + FP_FNMSUB_D).U(6.W)
  val fp_fnmadd_d = ("b" + FP_FNMADD_D).U(6.W)
  val fp_fmin_d = ("b" + FP_FMIN_D).U(6.W)
  val fp_fmax_d = ("b" + FP_FMAX_D).U(6.W)
  val fp_fle_s = ("b" + FP_FLE_S).U(6.W)
  val fp_flt_s = ("b" + FP_FLT_S).U(6.W)
  val fp_feq_s = ("b" + FP_FEQ_S).U(6.W)
  val fp_fclass_s = ("b" + FP_FCLASS_S).U(6.W)
  val fp_fle_d = ("b" + FP_FLE_D).U(6.W)
  val fp_flt_d = ("b" + FP_FLT_D).U(6.W)
  val fp_feq_d = ("b" + FP_FEQ_D).U(6.W)
  val fp_fclass_d = ("b" + FP_FCLASS_D).U(6.W)
  val fp_fcvt_w_s = ("b" + FP_FCVT_W_S).U(6.W)
  val fp_fcvt_wu_s = ("b" + FP_FCVT_WU_S).U(6.W)
  val fp_fcvt_l_s = ("b" + FP_FCVT_L_S).U(6.W)
  val fp_fcvt_lu_s = ("b" + FP_FCVT_LU_S).U(6.W)
  val fp_fcvt_s_w = ("b" + FP_FCVT_S_W).U(6.W)
  val fp_fcvt_s_wu = ("b" + FP_FCVT_S_WU).U(6.W)
  val fp_fcvt_s_l = ("b" + FP_FCVT_S_L).U(6.W)
  val fp_fcvt_s_lu = ("b" + FP_FCVT_S_LU).U(6.W)
  val fp_fcvt_w_d = ("b" + FP_FCVT_W_D).U(6.W)
  val fp_fcvt_wu_d = ("b" + FP_FCVT_WU_D).U(6.W)
  val fp_fcvt_l_d = ("b" + FP_FCVT_L_D).U(6.W)
  val fp_fcvt_lu_d = ("b" + FP_FCVT_LU_D).U(6.W)
  val fp_fcvt_d_w = ("b" + FP_FCVT_D_W).U(6.W)
  val fp_fcvt_d_wu = ("b" + FP_FCVT_D_WU).U(6.W)
  val fp_fcvt_d_l = ("b" + FP_FCVT_D_L).U(6.W)
  val fp_fcvt_d_lu = ("b" + FP_FCVT_D_LU).U(6.W)
  val fp_fcvt_s_d = ("b" + FP_FCVT_S_D).U(6.W)
  val fp_fcvt_d_s = ("b" + FP_FCVT_D_S).U(6.W)
  val fp_valid_decoded = fp_op_decoded =/= 0.U
  val fp_to_int_decoded = (
    (fp_op_decoded === fp_fmv_x_w) || (fp_op_decoded === fp_fmv_x_d) ||
    (fp_op_decoded === fp_fle_s) || (fp_op_decoded === fp_flt_s) ||
    (fp_op_decoded === fp_feq_s) || (fp_op_decoded === fp_fclass_s) ||
    (fp_op_decoded === fp_fle_d) || (fp_op_decoded === fp_flt_d) ||
    (fp_op_decoded === fp_feq_d) || (fp_op_decoded === fp_fclass_d) ||
    (fp_op_decoded === fp_fcvt_w_s) || (fp_op_decoded === fp_fcvt_wu_s) ||
    (fp_op_decoded === fp_fcvt_l_s) || (fp_op_decoded === fp_fcvt_lu_s) ||
    (fp_op_decoded === fp_fcvt_w_d) || (fp_op_decoded === fp_fcvt_wu_d) ||
    (fp_op_decoded === fp_fcvt_l_d) || (fp_op_decoded === fp_fcvt_lu_d) ||
    fp_half_to_int
  )
  val fp_store_decoded = (fp_op_decoded === fp_fsw) || (fp_op_decoded === fp_fsd) || fp_half_store
  out_fp.valid := fp_valid_decoded.asUInt
  out_fp.op := fp_op_decoded
  out_fp.rm := funct3
  out_fp.rs1 := rs1
  out_fp.rs2 := rs2
  out_fp.rs3 := rs3
  out_fp.rd := rd
  out_fp.load := ((fp_op_decoded === fp_flw) || (fp_op_decoded === fp_fld) || fp_half_load).asUInt
  out_fp.store := fp_store_decoded.asUInt
  out_fp.width_d := (
    (fp_op_decoded === fp_fmv_d_x) || (fp_op_decoded === fp_fmv_x_d) ||
    (fp_op_decoded === fp_fsgnj_d) || (fp_op_decoded === fp_fsgnjn_d) ||
    (fp_op_decoded === fp_fsgnjx_d) || (fp_op_decoded === fp_fld) ||
    (fp_op_decoded === fp_fsd) || (fp_op_decoded === fp_fadd_d) ||
    (fp_op_decoded === fp_fsub_d) || (fp_op_decoded === fp_fmul_d) ||
    (fp_op_decoded === fp_fdiv_d) || (fp_op_decoded === fp_fsqrt_d) ||
    (fp_op_decoded === fp_fmadd_d) || (fp_op_decoded === fp_fmsub_d) ||
    (fp_op_decoded === fp_fnmsub_d) || (fp_op_decoded === fp_fnmadd_d) ||
    (fp_op_decoded === fp_fmin_d) || (fp_op_decoded === fp_fmax_d) ||
    (fp_op_decoded === fp_fle_d) || (fp_op_decoded === fp_flt_d) ||
    (fp_op_decoded === fp_feq_d) || (fp_op_decoded === fp_fclass_d) ||
    (fp_op_decoded === fp_fcvt_w_d) || (fp_op_decoded === fp_fcvt_wu_d) ||
    (fp_op_decoded === fp_fcvt_l_d) || (fp_op_decoded === fp_fcvt_lu_d) ||
    (fp_op_decoded === fp_fcvt_d_w) || (fp_op_decoded === fp_fcvt_d_wu) ||
    (fp_op_decoded === fp_fcvt_d_l) || (fp_op_decoded === fp_fcvt_d_lu) ||
    (fp_op_decoded === fp_fcvt_s_d) || (fp_op_decoded === fp_fcvt_d_s)
  ).asUInt
  out_fp.to_int := fp_to_int_decoded.asUInt
  out_fp.writes_fpr := (fp_valid_decoded && !fp_to_int_decoded && !fp_store_decoded).asUInt

  // Keep table outputs independent of operand values and the PC. The frontend
  // transports these selectors; dispatch expands the constants once at use.
  val ImmZero = 0.U(4.W)
  val ImmI = 1.U(4.W)
  val ImmS = 2.U(4.W)
  val ImmB = 3.U(4.W)
  val ImmU = 4.U(4.W)
  val ImmJ = 5.U(4.W)
  val ImmCsr = 6.U(4.W)
  val ImmMcause = 7.U(4.W)
  val ImmMstatus = 8.U(4.W)
  val ImmSstatus = 9.U(4.W)

  val op_table    = Array(
    // format: off
    // Register enables, immediate format, and constant operand selectors.
    // op1: zero/PC/immediate/CSR uimm; op2: zero/immediate.
    LUI___ -> List(1.U, ImmU, 2.U, 0.U, 0.U, 0.U), // U
    AUIPC_ -> List(1.U, ImmU, 1.U, 1.U, 0.U, 0.U), // U

    JAL___ -> List(1.U, ImmJ, 1.U, 0.U, 0.U, 0.U), // J

    JALR__ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I

    BEQ___ -> List(0.U, ImmB, 0.U, 0.U, 1.U, 1.U), // B
    BNE___ -> List(0.U, ImmB, 0.U, 0.U, 1.U, 1.U), // B
    BLT___ -> List(0.U, ImmB, 0.U, 0.U, 1.U, 1.U), // B
    BGE___ -> List(0.U, ImmB, 0.U, 0.U, 1.U, 1.U), // B
    BLTU__ -> List(0.U, ImmB, 0.U, 0.U, 1.U, 1.U), // B
    BGEU__ -> List(0.U, ImmB, 0.U, 0.U, 1.U, 1.U), // B

    LB____ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I
    LH____ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I
    LW____ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I
    LBU___ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I
    LHU___ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I
    FLW___ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // FP I
    FLD___ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // FP I
    FLH___ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // Zfhmin I

    SB____ -> List(0.U, ImmS, 0.U, 0.U, 1.U, 1.U), // S
    SH____ -> List(0.U, ImmS, 0.U, 0.U, 1.U, 1.U), // S
    SW____ -> List(0.U, ImmS, 0.U, 0.U, 1.U, 1.U), // S
    FSW___ -> List(0.U, ImmS, 0.U, 0.U, 1.U, 1.U), // FP S
    FSD___ -> List(0.U, ImmS, 0.U, 0.U, 1.U, 1.U), // FP S
    FSH___ -> List(0.U, ImmS, 0.U, 0.U, 1.U, 1.U), // Zfhmin S

    ADDI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    SLTI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    SLTIU_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    XORI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    ORI___ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    ANDI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I

    SLLI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    SRLI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    SRAI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I

    ADD___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SUB___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SLL___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SLT___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SLTU__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    XOR___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SRL___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SRA___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    OR____ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    AND___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R

    ECALL_ -> List(0.U, ImmMcause, 0.U, 0.U, 0.U, 0.U), // N
    EBREAK -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N

    FENCE____ -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N (also covers FENCE.TSO)
    FENCE_I__ -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N
    CBO_INVAL -> List(0.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // Zicbom
    CBO_CLEAN -> List(0.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // Zicbom
    CBO_FLUSH -> List(0.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // Zicbom
    CBO_ZERO  -> List(0.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // Zicboz

    SFENCE_VM -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N
    SINVAL_VM -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N
    SFENCE_W_INVAL -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N
    SFENCE_INVAL_IR -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N

    CSRRW_ -> List(1.U, ImmCsr, 0.U, 0.U, 1.U, 0.U), // CSR
    CSRRS_ -> List(1.U, ImmCsr, 0.U, 0.U, 1.U, 0.U), // CSR
    CSRRC_ -> List(1.U, ImmCsr, 0.U, 0.U, 1.U, 0.U), // CSR
    CSRRWI -> List(1.U, ImmCsr, 3.U, 0.U, 0.U, 0.U), // CSR
    CSRRSI -> List(1.U, ImmCsr, 3.U, 0.U, 0.U, 0.U), // CSR
    CSRRCI -> List(1.U, ImmCsr, 3.U, 0.U, 0.U, 0.U), // CSR

    MUL___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    MULH__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    MULHSU -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    MULHU_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    DIV___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    DIVU__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    REM___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    REMU__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R

    LR_W__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // N
    SC_W__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N

 AMOSWAP_W -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOADD_W_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOXOR_W_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOAND_W_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOOR_W__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMIN_W_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMAX_W_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMINU_W -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMAXU_W -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N

    // RV64I
    LWU___ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I
    LD____ -> List(1.U, ImmI, 0.U, 0.U, 1.U, 0.U), // I
    SD____ -> List(0.U, ImmS, 0.U, 0.U, 1.U, 1.U), // S
    ADDIW_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    SLLIW_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    SRLIW_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    SRAIW_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I
    ADDW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SUBW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SLLW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SRLW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SRAW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R

    // RV64M
    MULW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    DIVW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    DIVUW_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    REMW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    REMUW_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R

    // RV64A
    LR_D__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // N
    SC_D__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOSWAP_D -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOADD_D_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOXOR_D_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOAND_D_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOOR_D__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMIN_D_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMAX_D_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMINU_D -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N
 AMOMAXU_D -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // N

    MRET__ -> List(1.U, ImmMstatus, 0.U, 0.U, 0.U, 0.U), // N
    SRET__ -> List(1.U, ImmSstatus, 0.U, 0.U, 0.U, 0.U), // N

    WFI___ -> List(0.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // N

    // Zimop: rd <- 0 + 0 (ALU_ADD with zero operands)
    MOP_R_  -> List(1.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // I-like
    MOP_RR_ -> List(1.U, ImmZero, 0.U, 0.U, 0.U, 0.U), // R-like

    // Zba (Address Generation): R-type: rd = (rs1 << N) + rs2
    SH1ADD -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SH2ADD -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SH3ADD -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R

    // Zbb (Basic Bit-manipulation)
    ANDN__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    ORN___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    XNOR__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    CLZ___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary)
    CTZ___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary)
    CPOP__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary)
    MAX___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    MAXU__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    MIN___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    MINU__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    SEXTB_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary)
    SEXTH_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary)
    ZEXTH_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // R (PACK rd,rs1,x0)
    REV8_32 -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary, RV32)
    REV8_64 -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary, RV64)
    ORC_B_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (unary)
    ROL___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    ROR___ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    RORI__ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I (shift imm)

    // Zbs (Single-bit Operations)
    BCLR__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    BCLRI_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I (shift imm)
    BEXT__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    BEXTI_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I (shift imm)
    BINV__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    BINVI_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I (shift imm)
    BSET__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    BSETI_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I (shift imm)

    // Zbc (Carry-less Multiplication)
    CLMUL_  -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    CLMULH_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    CLMULR_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R

    // Zicond (Conditional Operations)
    CZERO_EQZ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R
    CZERO_NEZ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R

    // RV64 Zba W-variants
    SH1ADDUW -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R (W-variant)
    SH2ADDUW -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R (W-variant)
    SH3ADDUW -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R (W-variant)
    ADD_UW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R (W-variant)
    SLLI_UW_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I (W-variant)

    // RV64 Zbb W-variants
    CLZW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (W-variant)
    CTZW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (W-variant)
    CPOPW_ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U), // I (W-variant)
    ROLW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R (W-variant)
    RORW__ -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 1.U), // R (W-variant)
    RORIW_ -> List(1.U, ImmI, 0.U, 1.U, 1.U, 0.U), // I (W-variant)
    ZEXTH64 -> List(1.U, ImmZero, 0.U, 0.U, 1.U, 0.U)  // R (W-variant)
  )
  val var_decoder = ListLookup(in.inst,
    List(0.U, ImmZero, 0.U(2.W), 0.U, 0.U, 0.U), op_table)
  // format: on
  val immediate_format = var_decoder(1)
  val immediate_values = Seq(
    ImmI -> imm_i, ImmS -> imm_s, ImmB -> imm_b, ImmU -> imm_u, ImmJ -> imm_j,
    ImmCsr -> csr, ImmMcause -> MCAUSE, ImmMstatus -> MSTATUS, ImmSstatus -> SSTATUS
  )
  out.rd := Mux(var_decoder(0).asBool, rd, 0.U)
  out.imm := MuxLookup(immediate_format, 0.U(21.W))(immediate_values)
  out.imm_u := immediate_format === ImmU
  out.op1_sel := var_decoder(2)
  out.op2_sel := var_decoder(3).asBool
  out.rs1 := Mux(var_decoder(4).asBool, rs1, 0.U)
  out.rs2 := Mux(var_decoder(5).asBool, rs2, 0.U)
  out.csr := csr
}
