package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._

class rapt_idu_decoder extends RawModule with Instr with MicroOP {
  val in      = IO(new Bundle {
    val inst = Input(UInt(32.W))
    val pc   = Input(UInt(64.W))
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
    val imm = Output(UInt(64.W))
    val op1 = Output(UInt(64.W))
    val op2 = Output(UInt(64.W))
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

  val imm_i = Cat(Fill(52, in.inst(31)), in.inst(31, 20))
  val imm_s = Cat(Fill(52, in.inst(31)), in.inst(31, 25), in.inst(11, 7))
  val immbv = Cat(in.inst(31), in.inst(7), in.inst(30, 25), in.inst(11, 8))
  val imm_b = Cat(Fill(51, in.inst(31)), immbv, 0.U)
  val imm_u = Cat(Fill(32, in.inst(31)), in.inst(31, 12), Fill(12, 0.U))
  val immjv = Cat(in.inst(31), in.inst(19, 12), in.inst(20), in.inst(30, 21))
  val imm_j = Cat(Fill(43, in.inst(31)), immjv, 0.U)
  val csr   = in.inst(31, 20)
  val uimm  = in.inst(19, 15)

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
      SFENCE_VM -> BitPat("b" + "1" + "1")  // N: flush TLBs + I-cache
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
  val fp_half_to_int = fp_op_decoded === fp_zfhmin && funct7 === "b1110010".U
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

    LB____ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I
    LH____ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I
    LW____ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I
    LBU___ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I
    LHU___ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I
    FLW___ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // FP I
    FLD___ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // FP I
    FLH___ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // Zfhmin I
    
    SB____ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // S
    SH____ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // S
    SW____ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // S
    FSW___ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // FP S
    FSD___ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // FP S
    FSH___ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // Zfhmin S

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

    ECALL_ -> List(0.U, MCAUSE,   0.U,   0.U, 0.U, 0.U), // N
    EBREAK -> List(0.U,    0.U,   0.U,   0.U, 0.U, 0.U), // N

    FENCE____ -> List(0.U, 0.U,   0.U,   0.U, 0.U, 0.U), // N (also covers FENCE.TSO)
    FENCE_I__ -> List(0.U, 0.U,   0.U,   0.U, 0.U, 0.U), // N
    CBO_INVAL -> List(0.U, 0.U,   0.U,   0.U, rs1, 0.U), // Zicbom
    CBO_CLEAN -> List(0.U, 0.U,   0.U,   0.U, rs1, 0.U), // Zicbom
    CBO_FLUSH -> List(0.U, 0.U,   0.U,   0.U, rs1, 0.U), // Zicbom
    CBO_ZERO  -> List(0.U, 0.U,   0.U,   0.U, rs1, 0.U), // Zicboz

    SFENCE_VM -> List(0.U,    0.U,   0.U,   0.U, 0.U, 0.U), // N   

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

    // RV64I
    LWU___ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I
    LD____ -> List( rd,  imm_i,   0.U,   0.U, rs1, 0.U), // I
    SD____ -> List(0.U,  imm_s,   0.U,   0.U, rs1, rs2), // S
    ADDIW_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    SLLIW_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    SRLIW_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    SRAIW_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I
    ADDW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SUBW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SLLW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SRLW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SRAW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R

    // RV64M
    MULW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    DIVW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    DIVUW_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    REMW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    REMUW_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R

    // RV64A
    LR_D__ -> List( rd,    0.U,   0.U,  0.U, rs1, 0.U), // N
    SC_D__ -> List( rd,    0.U,   0.U,  0.U, rs1, rs2), // N
 AMOSWAP_D -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOADD_D_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOXOR_D_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOAND_D_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOOR_D__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMIN_D_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMAX_D_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMINU_D -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N
 AMOMAXU_D -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // N

    MRET__ -> List( rd,MSTATUS,   0.U,   0.U, 0.U, 0.U), // N
    SRET__ -> List( rd,SSTATUS,   0.U,   0.U, 0.U, 0.U), // N

    WFI___ -> List(0.U,    0.U,   0.U,   0.U, 0.U, 0.U), // N

    // Zimop: rd <- 0 + 0 (ALU_ADD with zero operands)
    MOP_R_  -> List( rd,    0.U,   0.U,   0.U, 0.U, 0.U), // I-like
    MOP_RR_ -> List( rd,    0.U,   0.U,   0.U, 0.U, 0.U), // R-like

    // Zba (Address Generation): R-type: rd = (rs1 << N) + rs2
    SH1ADD -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SH2ADD -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SH3ADD -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R

    // Zbb (Basic Bit-manipulation)
    ANDN__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    ORN___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    XNOR__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    CLZ___ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary)
    CTZ___ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary)
    CPOP__ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary)
    MAX___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    MAXU__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    MIN___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    MINU__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    SEXTB_ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary)
    SEXTH_ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary)
    ZEXTH_ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // R (PACK rd,rs1,x0)
    REV8_32 -> List(rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary, RV32)
    REV8_64 -> List(rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary, RV64)
    ORC_B_ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (unary)
    ROL___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    ROR___ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    RORI__ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I (shift imm)

    // Zbs (Single-bit Operations)
    BCLR__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    BCLRI_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I (shift imm)
    BEXT__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    BEXTI_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I (shift imm)
    BINV__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    BINVI_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I (shift imm)
    BSET__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    BSETI_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I (shift imm)

    // Zbc (Carry-less Multiplication)
    CLMUL_  -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    CLMULH_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R
    CLMULR_ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R

    // Zicond (Conditional Operations)
    CZERO_EQZ -> List(rd,  0.U,   0.U,   0.U, rs1, rs2), // R
    CZERO_NEZ -> List(rd,  0.U,   0.U,   0.U, rs1, rs2), // R

    // RV64 Zba W-variants
    SH1ADDUW -> List(rd,   0.U,   0.U,   0.U, rs1, rs2), // R (W-variant)
    SH2ADDUW -> List(rd,   0.U,   0.U,   0.U, rs1, rs2), // R (W-variant)
    SH3ADDUW -> List(rd,   0.U,   0.U,   0.U, rs1, rs2), // R (W-variant)
    ADD_UW__ -> List(rd,   0.U,   0.U,   0.U, rs1, rs2), // R (W-variant)
    SLLI_UW_ -> List(rd, imm_i,   0.U, imm_i, rs1, 0.U), // I (W-variant)

    // RV64 Zbb W-variants
    CLZW__ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (W-variant)
    CTZW__ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (W-variant)
    CPOPW_ -> List( rd,    0.U,   0.U,   0.U, rs1, 0.U), // I (W-variant)
    ROLW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R (W-variant)
    RORW__ -> List( rd,    0.U,   0.U,   0.U, rs1, rs2), // R (W-variant)
    RORIW_ -> List( rd,  imm_i,   0.U, imm_i, rs1, 0.U), // I (W-variant)
    ZEXTH64 -> List(rd,    0.U,   0.U,   0.U, rs1, 0.U)  // R (W-variant)
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
