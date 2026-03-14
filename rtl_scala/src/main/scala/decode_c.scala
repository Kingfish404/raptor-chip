package npc

import chisel3._
import chisel3.util._
import chisel3.util.experimental.decode._

object RVCUtil {
  def decRd(inst:       UInt): UInt = inst(11, 7)
  def decRs1(inst:      UInt): UInt = inst(11, 7)
  def decRs2(inst:      UInt): UInt = inst(6, 2)
  def decRdShort(inst:  UInt): UInt = Cat("b01".U(2.W), inst(4, 2))
  def decRs1Short(inst: UInt): UInt = Cat("b01".U(2.W), inst(9, 7))
  def decRs2Short(inst: UInt): UInt = Cat("b01".U(2.W), inst(4, 2))

  /** Sign‑extend `x` *up to* 64 bits where `signPos` is the MSB of the value. */
  def signExtend(x: UInt, signPos: Int): UInt = {
    val sign = x(signPos)
    Cat(Fill(64 - (signPos + 1), sign), x)
  }

  /** CI‑format immediate (general‑purpose) – sign‑extended, scaled by 4. */
  def decCiImm(inst: UInt): UInt = {
    val raw = Cat(inst(12), inst(6, 4), inst(3, 2))
    signExtend(raw, 5)
  }

  /** CSS‑format imm (C.SWSP) – zero‑extended, scaled by 4. */
  def decCssImm(inst: UInt): UInt = {
    Cat(Cat(0.U(24.W), inst(8, 7), inst(12, 9), 0.U(2.W)))
  }

  /** CIW‑format imm (C.ADDI4SPN) – zero‑extended, scaled by 4. */
  def decCiwImm(inst: UInt): UInt = {
    // nzuimm[9:6|5:4|3|2|1:0] = inst[10:7|12:11|5|6|"00"]
    Cat(
      0.U(22.W), // upper zeros
      inst(10,7),  // 9:6
      inst(12,11), // 5:4
      inst(5),   // 3
      inst(6),   // 2
      0.U(2.W)
    )            // 1:0 (00)
  }

  /** CL/CS imm (C.LW/C.SW) – zero‑extended, scaled by 4. */
  def decClwCswImm(inst: UInt): UInt = {
    Cat(
      0.U(25.W),    // upper zeros
      inst(5, 5),   // 6
      inst(12, 10), // 5:3
      inst(6, 6),   // 2
      0.U(2.W)      // 1:0
    )
  }

  /** CL/CS imm for doubleword (C.LD/C.SD) – zero-extended, scaled by 8. */
  def decCldCsdImm(inst: UInt): UInt = {
    Cat(
      0.U(24.W),    // upper zeros
      inst(6, 5),   // 7:6
      inst(12, 10), // 5:3
      0.U(3.W)      // 2:0
    )
  }

  /** CSS‑format imm for doubleword (C.SDSP) – zero-extended, scaled by 8. */
  def decCssdImm(inst: UInt): UInt = {
    Cat(0.U(23.W), inst(9, 7), inst(12, 10), 0.U(3.W))
  }

  /** CI‑format offset for doubleword (C.LDSP) – zero-extended, scaled by 8. */
  def decCiOffsetLdsp(inst: UInt): UInt = {
    Cat(
      0.U(24.W),    // upper zeros
      inst(4, 2),   // 8:6
      inst(12, 12), // 5:5
      inst(6, 5),   // 4:3
      0.U(3.W)      // 2:0
    )
  }

  /** CB‑format branch imm (C.BEQZ/BNEZ) – sign‑extended, scaled by 2. */
  def decBranchImm(inst: UInt): UInt = {
    // imm[8]  = inst[12]
    // imm[7]  = inst[6]
    // imm[6]  = inst[5]
    // imm[5]  = inst[2]
    // imm[4]  = inst[11]
    // imm[3]  = inst[10]
    // imm[2]  = inst[4]
    // imm[1]  = inst[3]
    // imm[0]  = 0
    val raw = Cat(inst(12), inst(6), inst(5), inst(2), inst(11), inst(10), inst(4), inst(3), 0.U(1.W))
    signExtend(raw, 8)
  }

  /** CJ‑format jump imm (C.J/C.JAL) – sign‑extended, scaled by 2. */
  def decCjImm(inst: UInt): UInt = {
    // imm[11] = inst[12]
    // imm[10] = inst[8]
    // imm[9:8] = inst[10:9]
    // imm[7]  = inst[6]
    // imm[6]  = inst[7]
    // imm[5]  = inst[2]
    // imm[4]  = inst[11]
    // imm[3:1] = inst[5:3]
    // imm[0]  = 0
    val raw =
      Cat(inst(12), inst(8), inst(10, 9), inst(6), inst(7), inst(2), inst(11), inst(5,3), 0.U(1.W))
    signExtend(raw, 11)
  }

  /** CI‑format non‑zero immediate (C.ADDI16SP) – sign‑extended, scaled by 4. */
  def decCiNzimmAddi16sp(inst: UInt): UInt = {
    signExtend(Cat(
      inst(12, 12),// 9
      inst(4, 3),  // 8:7
      inst(5, 5),    // 6
      inst(2, 2),    // 5
      inst(6, 6),    // 4
      0.U(4.W)    // 3:0
    ), 9) // sign position
  }

  /** CI‑format immediate (C.LUI) – sign‑extended, scaled by 4. */
  def decCiNzimmLui(inst: UInt): UInt = {
    signExtend(Cat(
      inst(12, 12), // 17  -> 6:6
      inst(6, 2), // 16:12 -> 5:0
    ), 5)
  }

  /** CI‑format offset (C.LWSP) – zero‑extended, scaled by 4. */
  def decCiOffsetLwsp(inst: UInt): UInt = {
    Cat(
      0.U(25.W),    // upper zeros
      inst(3, 2),   // 7:6
      inst(12, 12), // 5:5
      inst(6, 4),   // 4:2
      0.U(2.W)      // 1:0
    )
  }

  /** C.SLLI‑format immediate (C.SLLI) – sign‑extended, scaled by 4. */
  def decCshamt(inst: UInt): UInt = {
    Cat(
      inst(12,12),// 5:5
      inst(6, 2), // 4:0
    )(4, 0)
  }

  /** Full 6-bit shift amount for RV64 C.SLLI/C.SRLI/C.SRAI: {inst[12], inst[6:2]} */
  def decCshamtFull(inst: UInt): UInt = {
    Cat(inst(12), inst(6, 2))
  }

  /** CBANDI‑format immediate (C.ANDI) – sign‑extended, scaled by 4. */
  def decCBAndi(inst: UInt): UInt = {
    val raw = Cat(inst(12), inst(6, 4), inst(3, 2))
    signExtend(raw, 5)
  }

  // 32‑bit instruction encoders (match the base ISA encoding)
  def rtype(funct7: UInt, rs2: UInt, rs1: UInt, funct3: UInt, rd: UInt, opcode: UInt): UInt =
    Cat(funct7, rs2, rs1, funct3, rd, opcode)

  def itype(imm: UInt, rs1: UInt, funct3: UInt, rd: UInt, opcode: UInt): UInt =
    Cat(imm(11, 0), rs1, funct3, rd, opcode)

  def stype(imm: UInt, rs2: UInt, rs1: UInt, funct3: UInt, opcode: UInt): UInt =
    Cat(imm(11, 5), rs2, rs1, funct3, imm(4, 0), opcode)

  def btype(imm: UInt, rs2: UInt, rs1: UInt, funct3: UInt, opcode: UInt): UInt =
    Cat(imm(12), imm(10, 5), rs2, rs1, funct3, imm(4, 1), imm(11), opcode)

  def utype(imm: UInt, rd: UInt, opcode: UInt): UInt = Cat(imm, rd, opcode)

  def jtype(imm: UInt, rd: UInt, opcode: UInt): UInt =
    Cat(imm(20), imm(10, 1), imm(11), imm(19, 12), rd, opcode)

  def cNop:    UInt = itype(0.U, 0.U(5.W), "b000".U(3.W), 0.U(5.W), "b0010011".U) // addi x0,x0,0
}

class ysyx_idu_decoder_c extends Module with Instr {
  import RVCUtil._

  val io = IO(new Bundle {
    val cinst   = Input(UInt(16.W))
    val is_rv64 = Input(UInt(1.W))
    val inst    = Output(UInt(32.W)) 
  })

  var cinst = io.cinst
  val is_rv64 = io.is_rv64.asBool

  // RV64C: C.LD  → ld  rd', offset(rs1')  (opcode=0000011, funct3=011)
  // RV64C: C.SD  → sd  rs2', offset(rs1') (opcode=0100011, funct3=011)
  // RV64C: C.LDSP → ld rd, offset(x2)
  // RV64C: C.SDSP → sd rs2, offset(x2)
  // RV64C: C.ADDIW → addiw rd, rd, imm   (opcode=0011011, funct3=000)
  // RV64C: C.SUBW  → subw  rd', rd', rs2' (opcode=0111011, funct7=0100000, funct3=000)
  // RV64C: C.ADDW  → addw  rd', rd', rs2' (opcode=0111011, funct7=0000000, funct3=000)
  val c_ld_inst   = itype(decCldCsdImm(cinst), decRs1Short(cinst), "b011".U(3.W), decRdShort(cinst), "b0000011".U(7.W))
  val c_sd_inst   = stype(decCldCsdImm(cinst), decRs2Short(cinst), decRs1Short(cinst), "b011".U(3.W), "b0100011".U(7.W))
  val c_ldsp_inst = itype(decCiOffsetLdsp(cinst), 2.U(5.W), "b011".U(3.W), decRd(cinst), "b0000011".U(7.W))
  val c_sdsp_inst = stype(decCssdImm(cinst), decRs2(cinst), 2.U(5.W), "b011".U(3.W), "b0100011".U(7.W))
  val c_addiw_inst = itype(decCiImm(cinst), decRd(cinst), "b000".U(3.W), decRd(cinst), "b0011011".U(7.W))
  val c_subw_inst = rtype(0b0100000.U(7.W), decRs2Short(cinst), decRs1Short(cinst), "b000".U(3.W), decRs1Short(cinst), "b0111011".U(7.W))
  val c_addw_inst = rtype(0b0000000.U(7.W), decRs2Short(cinst), decRs1Short(cinst), "b000".U(3.W), decRs1Short(cinst), "b0111011".U(7.W))

  val op_table    = Array(
    // Instruction listing for RVC, Quadrant 0
    C_INV_     -> List(0.U),
    C_ADDI4SPN -> List(itype(decCiwImm(cinst), 2.U(5.W), "b000".U(3.W), decRdShort(cinst), "b0010011".U(7.W))),
    C_FLD_     -> List(0.U),
    C_LQ__     -> List(0.U),
    C_LW__     -> List(itype(decClwCswImm(cinst), decRs1Short(cinst), "b010".U(3.W), decRdShort(cinst), "b0000011".U(7.W))),
    C_FLW_     -> List(0.U),           // RV32: C.FLW (F ext, unsupported); RV64: handled via C_LD__
    C_LD__     -> List(c_ld_inst),     // RV64: C.LD
    C_REV_     -> List(0.U),
    C_FSD_     -> List(0.U),
    C_SQ__     -> List(0.U),
    C_SW__     -> List(stype(decClwCswImm(cinst), decRs2Short(cinst), decRs1Short(cinst), "b010".U(3.W), "b0100011".U(7.W))),
    C_FSW_     -> List(0.U),           // RV32: C.FSW (F ext, unsupported); RV64: handled via C_SD__
    C_SD__     -> List(c_sd_inst),     // RV64: C.SD
    // Instruction listing for RVC, Quadrant 1
    C_NOP_     -> List(itype(decCiImm(cinst), 0.U(5.W), "b000".U(3.W), 0.U(5.W), "b0010011".U(7.W))),
    C_ADDI     -> List(Mux(decRd(cinst) === 0.U || decCiImm(cinst) === 0.U, cNop,
                     itype(decCiImm(cinst), decRd(cinst), "b000".U(3.W), decRd(cinst), "b0010011".U(7.W)))),
    C_JAL_     -> List(jtype(decCjImm(cinst), 1.U(5.W), "b1101111".U(7.W))), // rv32 only; rv64 uses C_ADDIW
    C_ADDIW    -> List(c_addiw_inst), // rv64: C.ADDIW → addiw rd, rd, imm
    C_LI__     -> List(Mux(decRdShort(cinst) === 0.U, cNop, itype(decCiImm(cinst), 0.U(5.W), "b000".U(3.W), decRd(cinst), "b0010011".U(7.W)))),
    
    C_ADDI16sp -> List(Mux(decCiNzimmAddi16sp(cinst) === 0.U, cNop,
                     itype(decCiNzimmAddi16sp(cinst), 2.U(5.W), "b000".U(3.W), 2.U(5.W), "b0010011".U(7.W)))), // res,imm=0
    C_LUI_   -> List(Mux(decRd(cinst) === 0.U, cNop, utype(decCiNzimmLui(cinst), decRd(cinst), "b0110111".U(7.W)))),
    C_SRLI   -> List(itype(Cat(0.U(6.W), decCshamtFull(cinst)), decRs1Short(cinst), "b101".U(3.W), decRs1Short(cinst), "b0010011".U(7.W))), // hint,rd=0;rv32 custom,uimm[5]=1
    C_SRLI64 -> List(0.U), // rv128; rv32/64 hint;hint,rd=0
    C_SRAI   -> List(itype(Cat("b010000".U(6.W), decCshamtFull(cinst)), decRs1Short(cinst), "b101".U(3.W), decRs1Short(cinst), "b0010011".U(7.W))), // rv32 custom,uimm[5]=1
    C_SRAI64 -> List(0.U), // rv128;rv32/64 hint
    C_ANDI   -> List(itype(decCBAndi(cinst), decRs1Short(cinst), "b111".U(3.W), decRs1Short(cinst), "b0010011".U(7.W))),
    C_SUB_   -> List(rtype(0b0100000.U(7.W), decRs2Short(cinst), decRs1Short(cinst), "b000".U(3.W), decRs1Short(cinst), "b0110011".U(7.W))),
    C_XOR_   -> List(rtype(0b0000000.U(7.W), decRs2Short(cinst), decRs1Short(cinst), "b100".U(3.W), decRs1Short(cinst), "b0110011".U(7.W))),
    C_OR__   -> List(rtype(0b0000000.U(7.W), decRs2Short(cinst), decRs1Short(cinst), "b110".U(3.W), decRs1Short(cinst), "b0110011".U(7.W))),
    C_AND_   -> List(rtype(0b0000000.U(7.W), decRs2Short(cinst), decRs1Short(cinst), "b111".U(3.W), decRs1Short(cinst), "b0110011".U(7.W))),
    C_SUBW   -> List(c_subw_inst), // rv64: C.SUBW → subw
    C_ADDW   -> List(c_addw_inst), // rv64: C.ADDW → addw
    C_REV0   -> List(0.U),
    C_REV1   -> List(0.U),
    C_J___   -> List(jtype(decCjImm(cinst), 0.U(5.W), "b1101111".U(7.W))),
    C_BEQZ   -> List(btype(decBranchImm(cinst), 0.U(5.W), decRs1Short(cinst), "b000".U(3.W), "b1100011".U(7.W))),
    C_BNEZ   -> List(btype(decBranchImm(cinst), 0.U(5.W), decRs1Short(cinst), "b001".U(3.W), "b1100011".U(7.W))),
    // Instruction listing for RVC, Quadrant 2
    C_SLLI   -> List(itype(Cat(0.U(6.W), decCshamtFull(cinst)), decRd(cinst), "b001".U(3.W), decRd(cinst), "b0010011".U(7.W))), // hint,rd=0
    C_SLLI64 -> List(0.U),
    C_FLDSP  -> List(0.U),
    C_LQSP   -> List(0.U),
    C_LWSP   -> List(itype(decCiOffsetLwsp(cinst), 2.U(5.W), "b010".U(3.W), decRd(cinst), "b0000011".U(7.W))), // res,rd=0
    C_FLWSP  -> List(0.U),         // RV32: C.FLWSP (F ext); RV64: handled via C_LDSP
    C_LDSP   -> List(c_ldsp_inst), // RV64: C.LDSP → ld rd, offset(x2)
    C_JR__   -> List(itype(0.U, decRs1(cinst), "b000".U(3.W), 0.U(5.W), "b1100111".U(7.W))), // res,rs1=0
    C_MV__   -> List(Mux(decRd(cinst) === 0.U || decRs2(cinst) === 0.U, cNop,
                     rtype(0b0000000.U(7.W), decRs2(cinst), 0.U(5.W), "b000".U(3.W), decRd(cinst), "b0110011".U(7.W)))), // hint,rd=0
    C_EBREAK -> List(rtype(0b0000000.U(7.W), 1.U(5.W), 0.U(5.W), "b000".U(3.W), 0.U(5.W), "b1110011".U(7.W))),
    C_JALR   -> List(rtype(0b0000000.U(7.W), 0.U(5.W), decRs1(cinst), "b000".U(3.W), 1.U(5.W), "b1100111".U(7.W))),
    C_ADD_   -> List(Mux(decRd(cinst) === 0.U, cNop,
                     rtype(0b0000000.U(7.W), decRs2(cinst), decRd(cinst), "b000".U(3.W), decRd(cinst), "b0110011".U(7.W)))), // hint,rd=0
    C_FSDSP  -> List(stype(decCssImm(cinst), decRs2(cinst), 2.U(5.W), "b010".U(3.W), "b0100011".U(7.W))), // rv32/64
    C_SQSP   -> List(stype(decCssImm(cinst), decRs2(cinst), 2.U(5.W), "b010".U(3.W), "b0100011".U(7.W))), // rv128
    C_SWSP   -> List(stype(decCssImm(cinst), decRs2(cinst), 2.U(5.W), "b010".U(3.W), "b0100011".U(7.W))),
    C_FSWSP  -> List(stype(decCssImm(cinst), decRs2(cinst), 2.U(5.W), "b010".U(3.W), "b0100011".U(7.W))), // rv32
    C_SDSP   -> List(c_sdsp_inst) // rv64: C.SDSP → sd rs2, offset(x2)
  )
  val var_decoder = ListLookup(io.cinst, List(0.U), op_table)

  // Handle conflicting RV32/RV64 opcodes via is_rv64 mux:
  // Q0: C.FLW(RV32)/C.LD(RV64) share 011...00; C.FSW(RV32)/C.SD(RV64) share 111...00
  // Q1: C.JAL(RV32)/C.ADDIW(RV64) share 001...01
  // Q2: C.FLWSP(RV32)/C.LDSP(RV64) share 011...10; C.FSWSP(RV32)/C.SDSP(RV64) share 111...10
  // Since these pairs share identical bit patterns, ListLookup picks one.
  // We fix up with Mux based on is_rv64 and the opcode quadrant/funct.
  val raw_inst = var_decoder(0)
  val quadrant = cinst(1, 0)
  val funct3   = cinst(15, 13)

  val fixed_inst = MuxCase(raw_inst, Seq(
    // Q0, funct3=011: RV32→C.FLW(unsupported), RV64→C.LD
    (quadrant === "b00".U && funct3 === "b011".U) ->
      Mux(is_rv64, c_ld_inst, 0.U(32.W)),
    // Q0, funct3=111: RV32→C.FSW(unsupported), RV64→C.SD
    (quadrant === "b00".U && funct3 === "b111".U) ->
      Mux(is_rv64, c_sd_inst, 0.U(32.W)),
    // Q1, funct3=001: RV32→C.JAL, RV64→C.ADDIW
    (quadrant === "b01".U && funct3 === "b001".U) ->
      Mux(is_rv64, c_addiw_inst,
        jtype(decCjImm(cinst), 1.U(5.W), "b1101111".U(7.W))),
    // Q2, funct3=011: RV32→C.FLWSP(unsupported), RV64→C.LDSP
    (quadrant === "b10".U && funct3 === "b011".U) ->
      Mux(is_rv64, c_ldsp_inst, 0.U(32.W)),
    // Q2, funct3=111: RV32→C.FSWSP(sw), RV64→C.SDSP
    (quadrant === "b10".U && funct3 === "b111".U) ->
      Mux(is_rv64, c_sdsp_inst,
        stype(decCssImm(cinst), decRs2(cinst), 2.U(5.W), "b010".U(3.W), "b0100011".U(7.W)))
  ))

  io.inst := fixed_inst
}
