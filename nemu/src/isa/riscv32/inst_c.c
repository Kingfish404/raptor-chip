#include <stdint.h>
#include <cpu/decode.h>
#include "local-include/rv_c.h"

static void decode_operand(
    uint32_t inst,
    uint32_t *imm, uint32_t *rs1, uint32_t *rs2, uint32_t *rd, int format)
{
  uint32_t nzuimm = 0, offset = 0;
  switch (format)
  {
  case CR:
    *rd = dec_rd(inst);
    *rs1 = dec_rs1(inst);
    *rs2 = dec_rs2(inst);
    break;
  case CI:
    *rd = dec_rd(inst);
    *rs2 = dec_rs2(inst);
    *imm = dec_ci_imm(inst);
    break;
  case CSS:
    offset = dec_css_imm(inst);
    *rs2 = dec_rs2(inst);
    *imm = offset;
    break;
  case CIW:
    nzuimm = dec_ciw_imm(inst);
    *rd = dec_rd_short(inst);
    *imm = nzuimm;
    break;
  case CL:
    *rs1 = dec_rs1_short(inst);
    *rd = dec_rd_short(inst);
    *imm = dec_clw_csw_imm(inst);
    break;
  case CS:
    *rs1 = dec_rs1_short(inst);
    *rs2 = dec_rs2_short(inst);
    *imm = dec_clw_csw_imm(inst);
    break;
  case CA:
    *rs1 = dec_rs1_short(inst);
    *rs2 = dec_rs2_short(inst);
    break;
  case CB:
    offset = dec_branch_imm(inst);
    *rs1 = dec_rs1_short(inst);
    *imm = offset;
    break;
  case CJ:
    *imm = dec_cj_imm(inst);
    break;
  case CN:
    break;
  default:
    break;
  }
}

uint32_t decompress_c(uint32_t inst)
{
  inst &= 0xFFFF; // Clear the upper bits
  uint32_t s = inst, di = 0;

  uint32_t nzimm_addi16sp = dec_ci_nzimm_addi16sp(s);
  uint32_t nzimm_lui = dec_ci_nzimm_lui(s);
  uint32_t offset_lwsp = dec_ci_offset_lwsp(s);
  uint32_t shamt = dec_cs_shamt(s);
  uint32_t imm_candi = dec_cb_imm_candi(s);
#define INSTPAT_INST(s) ((s))
#define INSTPAT_MATCH(s, name, type, ... /* execute body */)   \
  {                                                            \
    uint32_t imm = 0, rs1 = 0, rs2 = 0, rd = 0;                \
    decode_operand(s, &imm, &rs1, &rs2, &rd, concat(C, type)); \
    __VA_ARGS__;                                               \
  }

  INSTPAT_START();
  // Instruction listing for RVC, Quadrant 0
  INSTPAT("000 00000000 000 00", c.inv, N, { di = 0; });
  INSTPAT("000 ???????? ??? 00", c.addi4spn, IW, { di = itype(imm, 2, 0b000, rd, 0b0010011); }); // res, uimm=0
  INSTPAT("001 ???????? ??? 00", c.fld, L, { di = 0; });                                         // rv32/64
  INSTPAT("001 ???????? ??? 00", c.lq, L, { di = 0; });                                          // rv128
  INSTPAT("010 ???????? ??? 00", c.lw, L, { di = itype(imm, rs1, 0b010, rd, 0b0000011); });
  INSTPAT("011 ???????? ??? 00", c.flw, L, { di = 0; }); // rv32
  INSTPAT("011 ???????? ??? 00", c.ld, L, { di = 0; });  // rv64/128
  INSTPAT("100 ???????? ??? 00", c.rev, N, { di = 0; }); // Reserved
  INSTPAT("101 ???????? ??? 00", c.fsd, S, { di = 0; }); // rv32/64
  INSTPAT("101 ???????? ??? 00", c.sq, S, { di = 0; });  // rv128
  INSTPAT("110 ???????? ??? 00", c.sw, S, { di = stype(imm, rs2, rs1, 0b010, 0b0100011); });
  INSTPAT("111 ???????? ??? 00", c.fsw, S, { di = 0; }); // rv32
  INSTPAT("111 ???????? ??? 00", c.sd, S, { di = 0; });  // rv64/128
  // Instruction listing for RVC, Quadrant 1
  INSTPAT("000 ?00000?? ??? 01", c.nop, I, { di = itype(imm, 0, 0b000, 0, 0b0010011); });                                     // hint,imm=0
  INSTPAT("000 ???????? ??? 01", c.addi, I, { di = (rd == 0 || imm == 0) ? nop() : itype(imm, rd, 0b000, rd, 0b0010011); });  // hint,imm=0
  INSTPAT("001 ???????? ??? 01", c.jal, J, { di = jtype(imm, 1, 0b1101111); });                                               // rv32
  INSTPAT("001 ???????? ??? 01", c.addiw, I, { di = (rd == 0 || imm == 0) ? nop() : itype(imm, rd, 0b000, rd, 0b0010011); }); // rv64/128;res,rd=0
  INSTPAT("010 ???????? ??? 01", c.li, I, { di = (rd == 0) ? nop() : itype(imm, 0, 0b000, rd, 0b0010011); });
  INSTPAT("011 ?00010?? ??? 01", c.addi16sp, I, { di = (nzimm_addi16sp == 0) ? nop() : itype(nzimm_addi16sp, 2, 0b000, 2, 0b0010011); }); // res,imm=0
  INSTPAT("011 ???????? ??? 01", c.lui, I, { di = (rd == 0) ? nop() : utype(nzimm_lui, rd, 0b0110111); });                                // res,imm=0;hint,rd=0
  INSTPAT("100 ?00????? ??? 01", c.srli, B, { di = rtype(0b0000000, shamt, rs1, 0b101, rs1, 0b0010011); });                               // rv32 custom,uimm[5]=1
  INSTPAT("100 000???00 000 01", c.srli64, B, { di = 0; });                                                                               // rv128; rv32/64 hint
  INSTPAT("100 ?01????? ??? 01", c.srai, B, { di = rtype(0b0100000, shamt, rs1, 0b101, rs1, 0b0010011); });                               // rv32 custom,uimm[5]=1
  INSTPAT("100 001???00 000 01", c.srai64, B, { di = 0; });                                                                               // rv128;rv32/64 hint
  INSTPAT("100 ?10????? ??? 01", c.andi, B, { di = itype(imm_candi, rs1, 0b111, rs1, 0b0010011); });
  INSTPAT("100 011???00 ??? 01", c.sub, A, { di = rtype(0b0100000, rs2, rs1, 0b000, rs1, 0b0110011); });
  INSTPAT("100 011???01 ??? 01", c.xor, A, { di = rtype(0b0000000, rs2, rs1, 0b100, rs1, 0b0110011); });
  INSTPAT("100 011???10 ??? 01", c.or, A, { di = rtype(0b0000000, rs2, rs1, 0b110, rs1, 0b0110011); });
  INSTPAT("100 011???11 ??? 01", c.and, A, { di = rtype(0b0000000, rs2, rs1, 0b111, rs1, 0b0110011); });
  INSTPAT("100 111???00 ??? 01", c.subw, A, { di = 0; }); // rv64/128;rv32 res
  INSTPAT("100 111???01 ??? 01", c.addw, A, { di = 0; }); // rv64/128;rv32 res
  INSTPAT("100 111???10 ??? 01", c.rev, N, { di = 0; });  // Reserved
  INSTPAT("100 111???11 ??? 01", c.rev, N, { di = 0; });  // Reserved
  INSTPAT("101 ???????? ??? 01", c.j, J, { di = jtype(imm, 0, 0b1101111); });
  INSTPAT("110 ???????? ??? 01", c.beqz, B, { di = btype(imm, 0, rs1, 0b000, 0b1100011); });
  INSTPAT("111 ???????? ??? 01", c.bnez, B, { di = btype(imm, 0, rs1, 0b001, 0b1100011); });
  // Instruction listing for RVC, Quadrant 2
  INSTPAT("000 ???????? ??? 10", c.slli, I, { di = itype(imm, rd, 0b001, rd, 0b0010011); });                                         // hint,rd=0;rv32 custom,uimm[5]=1
  INSTPAT("000 0??????? 000 10", c.slli64, I, { di = 0; });                                                                          // rv128;rv32/64 hint;hint,rd=0
  INSTPAT("001 ???????? ??? 10", c.fldsp, I, { di = 0; });                                                                           // rv32/64
  INSTPAT("001 ???????? ??? 10", c.lqsp, I, { di = 0; });                                                                            // rv128;res,rd=0
  INSTPAT("010 ???????? ??? 10", c.lwsp, I, { di = itype(offset_lwsp, 2, 0b010, rd, 0b0000011); });                                  // res,rd=0
  INSTPAT("011 ???????? ??? 10", c.flwsp, I, { di = 0; });                                                                           // rv32
  INSTPAT("011 ???????? ??? 10", c.ldsp, I, { di = 0; });                                                                            // rv64/128;res,rd=0
  INSTPAT("100 0?????00 000 10", c.jr, R, { di = rtype(0b0000000, 0, rs1, 0b000, 0, 0b1100111); });                                  // res,rs1=0
  INSTPAT("100 0??????? ??? 10", c.mv, R, { di = (rd == 0 || rs2 == 0) ? nop() : rtype(0b0000000, rs2, 0, 0b000, rd, 0b0110011); }); // hint,rd=0
  INSTPAT("100 10000000 000 10", c.ebreak, R, { di = rtype(0b0000000, 1, 0, 0b000, 0, 0b1110011); });
  INSTPAT("100 1?????00 000 10", c.jalr, R, { di = rtype(0b0000000, 0, rs1, 0b000, 1, 0b1100111); });
  INSTPAT("100 1??????? ??? 10", c.add, R, { di = (rd == 0) ? nop() : rtype(0b0000000, rs2, rd, 0b000, rd, 0b0110011); }); // hint,rd=0
  INSTPAT("101 ???????? ??? 10", c.fsdsp, SS, { di = stype(imm, rs2, 2, 0b010, 0b0100011); });                             // rv32/64
  INSTPAT("101 ???????? ??? 10", c.sqsp, SS, { di = stype(imm, rs2, 2, 0b010, 0b0100011); });                              // rv128
  INSTPAT("110 ???????? ??? 10", c.swsp, SS, { di = stype(imm, rs2, 2, 0b010, 0b0100011); });
  INSTPAT("111 ???????? ??? 10", c.fswsp, SS, { di = stype(imm, rs2, 2, 0b010, 0b0100011); }); // rv32
  INSTPAT("111 ???????? ??? 10", c.sdsp, SS, { di = stype(imm, rs2, 2, 0b010, 0b0100011); });  // rv64/128

  INSTPAT("??? ???????? ??? ??", c.inv, N, { di = 0; });
  INSTPAT_END();

  uint32_t decompress_c_ref(uint32_t inst);
  uint32_t di_func = decompress_c_ref(inst);
  if (di_func != di)
  {
    printf("Decompressed mismatch: %04x -> %08x (gt) != %08x\n", s, di_func, di);
  }
  return di;
}
