/* FCVT tininess: both signs, exact controls, five static/dynamic modes.
 * Store the full FPR to verify NaN boxing and both result words on RV32 too. */
.option norvc
.option norelax
.macro probe op, load, rm, mode, flags, datum
  la s1, \datum
  li t0, ((\mode << 5) | 8)
  csrw fcsr, t0
  \load ft0, 0(s1)
  \op ft2, ft0, \rm
  csrr t0, fcsr
  li t1, ((\mode << 5) | \flags)
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 8(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 12(s1)
  bne t0, t1, fail
.endm
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, 0x6000
  csrs mstatus, t0
  la s0, result
#if CASE_KIND == 0
  probe fcvt.s.d, fld, rne, 1, 11, case_0
  probe fcvt.s.d, fld, dyn, 0, 11, case_1
  probe fcvt.s.d, fld, rtz, 2, 11, case_2
  probe fcvt.s.d, fld, dyn, 1, 11, case_3
  probe fcvt.s.d, fld, rdn, 3, 11, case_4
  probe fcvt.s.d, fld, dyn, 2, 11, case_5
  probe fcvt.s.d, fld, rup, 4, 11, case_6
  probe fcvt.s.d, fld, dyn, 3, 11, case_7
  probe fcvt.s.d, fld, rmm, 0, 11, case_8
  probe fcvt.s.d, fld, dyn, 4, 11, case_9
  probe fcvt.s.d, fld, rne, 1, 8, case_10
  probe fcvt.s.d, fld, dyn, 0, 8, case_11
  probe fcvt.s.d, fld, rtz, 2, 8, case_12
  probe fcvt.s.d, fld, dyn, 1, 8, case_13
  probe fcvt.s.d, fld, rdn, 3, 8, case_14
  probe fcvt.s.d, fld, dyn, 2, 8, case_15
  probe fcvt.s.d, fld, rup, 4, 8, case_16
  probe fcvt.s.d, fld, dyn, 3, 8, case_17
  probe fcvt.s.d, fld, rmm, 0, 8, case_18
  probe fcvt.s.d, fld, dyn, 4, 8, case_19
  probe fcvt.s.d, fld, rne, 1, 11, case_20
  probe fcvt.s.d, fld, dyn, 0, 11, case_21
  probe fcvt.s.d, fld, rtz, 2, 11, case_22
  probe fcvt.s.d, fld, dyn, 1, 11, case_23
  probe fcvt.s.d, fld, rdn, 3, 11, case_24
  probe fcvt.s.d, fld, dyn, 2, 11, case_25
  probe fcvt.s.d, fld, rup, 4, 11, case_26
  probe fcvt.s.d, fld, dyn, 3, 11, case_27
  probe fcvt.s.d, fld, rmm, 0, 11, case_28
  probe fcvt.s.d, fld, dyn, 4, 11, case_29
  probe fcvt.s.d, fld, rne, 1, 8, case_30
  probe fcvt.s.d, fld, dyn, 0, 8, case_31
  probe fcvt.s.d, fld, rtz, 2, 8, case_32
  probe fcvt.s.d, fld, dyn, 1, 8, case_33
  probe fcvt.s.d, fld, rdn, 3, 8, case_34
  probe fcvt.s.d, fld, dyn, 2, 8, case_35
  probe fcvt.s.d, fld, rup, 4, 8, case_36
  probe fcvt.s.d, fld, dyn, 3, 8, case_37
  probe fcvt.s.d, fld, rmm, 0, 8, case_38
  probe fcvt.s.d, fld, dyn, 4, 8, case_39
#endif
#if CASE_KIND == 1
  probe fcvt.h.s, flw, rne, 1, 11, case_40
  probe fcvt.h.s, flw, dyn, 0, 11, case_41
  probe fcvt.h.s, flw, rtz, 2, 11, case_42
  probe fcvt.h.s, flw, dyn, 1, 11, case_43
  probe fcvt.h.s, flw, rdn, 3, 11, case_44
  probe fcvt.h.s, flw, dyn, 2, 11, case_45
  probe fcvt.h.s, flw, rup, 4, 11, case_46
  probe fcvt.h.s, flw, dyn, 3, 11, case_47
  probe fcvt.h.s, flw, rmm, 0, 11, case_48
  probe fcvt.h.s, flw, dyn, 4, 11, case_49
  probe fcvt.h.s, flw, rne, 1, 8, case_50
  probe fcvt.h.s, flw, dyn, 0, 8, case_51
  probe fcvt.h.s, flw, rtz, 2, 8, case_52
  probe fcvt.h.s, flw, dyn, 1, 8, case_53
  probe fcvt.h.s, flw, rdn, 3, 8, case_54
  probe fcvt.h.s, flw, dyn, 2, 8, case_55
  probe fcvt.h.s, flw, rup, 4, 8, case_56
  probe fcvt.h.s, flw, dyn, 3, 8, case_57
  probe fcvt.h.s, flw, rmm, 0, 8, case_58
  probe fcvt.h.s, flw, dyn, 4, 8, case_59
  probe fcvt.h.s, flw, rne, 1, 11, case_60
  probe fcvt.h.s, flw, dyn, 0, 11, case_61
  probe fcvt.h.s, flw, rtz, 2, 11, case_62
  probe fcvt.h.s, flw, dyn, 1, 11, case_63
  probe fcvt.h.s, flw, rdn, 3, 11, case_64
  probe fcvt.h.s, flw, dyn, 2, 11, case_65
  probe fcvt.h.s, flw, rup, 4, 11, case_66
  probe fcvt.h.s, flw, dyn, 3, 11, case_67
  probe fcvt.h.s, flw, rmm, 0, 11, case_68
  probe fcvt.h.s, flw, dyn, 4, 11, case_69
  probe fcvt.h.s, flw, rne, 1, 8, case_70
  probe fcvt.h.s, flw, dyn, 0, 8, case_71
  probe fcvt.h.s, flw, rtz, 2, 8, case_72
  probe fcvt.h.s, flw, dyn, 1, 8, case_73
  probe fcvt.h.s, flw, rdn, 3, 8, case_74
  probe fcvt.h.s, flw, dyn, 2, 8, case_75
  probe fcvt.h.s, flw, rup, 4, 8, case_76
  probe fcvt.h.s, flw, dyn, 3, 8, case_77
  probe fcvt.h.s, flw, rmm, 0, 8, case_78
  probe fcvt.h.s, flw, dyn, 4, 8, case_79
#endif
#if CASE_KIND == 2
  probe fcvt.h.d, fld, rne, 1, 11, case_80
  probe fcvt.h.d, fld, dyn, 0, 11, case_81
  probe fcvt.h.d, fld, rtz, 2, 11, case_82
  probe fcvt.h.d, fld, dyn, 1, 11, case_83
  probe fcvt.h.d, fld, rdn, 3, 11, case_84
  probe fcvt.h.d, fld, dyn, 2, 11, case_85
  probe fcvt.h.d, fld, rup, 4, 11, case_86
  probe fcvt.h.d, fld, dyn, 3, 11, case_87
  probe fcvt.h.d, fld, rmm, 0, 11, case_88
  probe fcvt.h.d, fld, dyn, 4, 11, case_89
  probe fcvt.h.d, fld, rne, 1, 8, case_90
  probe fcvt.h.d, fld, dyn, 0, 8, case_91
  probe fcvt.h.d, fld, rtz, 2, 8, case_92
  probe fcvt.h.d, fld, dyn, 1, 8, case_93
  probe fcvt.h.d, fld, rdn, 3, 8, case_94
  probe fcvt.h.d, fld, dyn, 2, 8, case_95
  probe fcvt.h.d, fld, rup, 4, 8, case_96
  probe fcvt.h.d, fld, dyn, 3, 8, case_97
  probe fcvt.h.d, fld, rmm, 0, 8, case_98
  probe fcvt.h.d, fld, dyn, 4, 8, case_99
  probe fcvt.h.d, fld, rne, 1, 11, case_100
  probe fcvt.h.d, fld, dyn, 0, 11, case_101
  probe fcvt.h.d, fld, rtz, 2, 11, case_102
  probe fcvt.h.d, fld, dyn, 1, 11, case_103
  probe fcvt.h.d, fld, rdn, 3, 11, case_104
  probe fcvt.h.d, fld, dyn, 2, 11, case_105
  probe fcvt.h.d, fld, rup, 4, 11, case_106
  probe fcvt.h.d, fld, dyn, 3, 11, case_107
  probe fcvt.h.d, fld, rmm, 0, 11, case_108
  probe fcvt.h.d, fld, dyn, 4, 11, case_109
  probe fcvt.h.d, fld, rne, 1, 8, case_110
  probe fcvt.h.d, fld, dyn, 0, 8, case_111
  probe fcvt.h.d, fld, rtz, 2, 8, case_112
  probe fcvt.h.d, fld, dyn, 1, 8, case_113
  probe fcvt.h.d, fld, rdn, 3, 8, case_114
  probe fcvt.h.d, fld, dyn, 2, 8, case_115
  probe fcvt.h.d, fld, rup, 4, 8, case_116
  probe fcvt.h.d, fld, dyn, 3, 8, case_117
  probe fcvt.h.d, fld, rmm, 0, 8, case_118
  probe fcvt.h.d, fld, dyn, 4, 8, case_119
#endif
  li a0, 0
  ebreak
1: j 1b
fail:
  li a0, 1
  ebreak
2: j 2b
.section .data
.balign 8
result: .quad 0
case_0: .quad 0x380fffffe0000000, 0xffffffff00800000
case_1: .quad 0x380fffffe0000000, 0xffffffff00800000
case_2: .quad 0x380fffffe0000000, 0xffffffff007fffff
case_3: .quad 0x380fffffe0000000, 0xffffffff007fffff
case_4: .quad 0x380fffffe0000000, 0xffffffff007fffff
case_5: .quad 0x380fffffe0000000, 0xffffffff007fffff
case_6: .quad 0x380fffffe0000000, 0xffffffff00800000
case_7: .quad 0x380fffffe0000000, 0xffffffff00800000
case_8: .quad 0x380fffffe0000000, 0xffffffff00800000
case_9: .quad 0x380fffffe0000000, 0xffffffff00800000
case_10: .quad 0x3810000000000000, 0xffffffff00800000
case_11: .quad 0x3810000000000000, 0xffffffff00800000
case_12: .quad 0x3810000000000000, 0xffffffff00800000
case_13: .quad 0x3810000000000000, 0xffffffff00800000
case_14: .quad 0x3810000000000000, 0xffffffff00800000
case_15: .quad 0x3810000000000000, 0xffffffff00800000
case_16: .quad 0x3810000000000000, 0xffffffff00800000
case_17: .quad 0x3810000000000000, 0xffffffff00800000
case_18: .quad 0x3810000000000000, 0xffffffff00800000
case_19: .quad 0x3810000000000000, 0xffffffff00800000
case_20: .quad 0xb80fffffe0000000, 0xffffffff80800000
case_21: .quad 0xb80fffffe0000000, 0xffffffff80800000
case_22: .quad 0xb80fffffe0000000, 0xffffffff807fffff
case_23: .quad 0xb80fffffe0000000, 0xffffffff807fffff
case_24: .quad 0xb80fffffe0000000, 0xffffffff80800000
case_25: .quad 0xb80fffffe0000000, 0xffffffff80800000
case_26: .quad 0xb80fffffe0000000, 0xffffffff807fffff
case_27: .quad 0xb80fffffe0000000, 0xffffffff807fffff
case_28: .quad 0xb80fffffe0000000, 0xffffffff80800000
case_29: .quad 0xb80fffffe0000000, 0xffffffff80800000
case_30: .quad 0xb810000000000000, 0xffffffff80800000
case_31: .quad 0xb810000000000000, 0xffffffff80800000
case_32: .quad 0xb810000000000000, 0xffffffff80800000
case_33: .quad 0xb810000000000000, 0xffffffff80800000
case_34: .quad 0xb810000000000000, 0xffffffff80800000
case_35: .quad 0xb810000000000000, 0xffffffff80800000
case_36: .quad 0xb810000000000000, 0xffffffff80800000
case_37: .quad 0xb810000000000000, 0xffffffff80800000
case_38: .quad 0xb810000000000000, 0xffffffff80800000
case_39: .quad 0xb810000000000000, 0xffffffff80800000
case_40: .quad 0x00000000387fe000, 0xffffffffffff0400
case_41: .quad 0x00000000387fe000, 0xffffffffffff0400
case_42: .quad 0x00000000387fe000, 0xffffffffffff03ff
case_43: .quad 0x00000000387fe000, 0xffffffffffff03ff
case_44: .quad 0x00000000387fe000, 0xffffffffffff03ff
case_45: .quad 0x00000000387fe000, 0xffffffffffff03ff
case_46: .quad 0x00000000387fe000, 0xffffffffffff0400
case_47: .quad 0x00000000387fe000, 0xffffffffffff0400
case_48: .quad 0x00000000387fe000, 0xffffffffffff0400
case_49: .quad 0x00000000387fe000, 0xffffffffffff0400
case_50: .quad 0x0000000038800000, 0xffffffffffff0400
case_51: .quad 0x0000000038800000, 0xffffffffffff0400
case_52: .quad 0x0000000038800000, 0xffffffffffff0400
case_53: .quad 0x0000000038800000, 0xffffffffffff0400
case_54: .quad 0x0000000038800000, 0xffffffffffff0400
case_55: .quad 0x0000000038800000, 0xffffffffffff0400
case_56: .quad 0x0000000038800000, 0xffffffffffff0400
case_57: .quad 0x0000000038800000, 0xffffffffffff0400
case_58: .quad 0x0000000038800000, 0xffffffffffff0400
case_59: .quad 0x0000000038800000, 0xffffffffffff0400
case_60: .quad 0x00000000b87fe000, 0xffffffffffff8400
case_61: .quad 0x00000000b87fe000, 0xffffffffffff8400
case_62: .quad 0x00000000b87fe000, 0xffffffffffff83ff
case_63: .quad 0x00000000b87fe000, 0xffffffffffff83ff
case_64: .quad 0x00000000b87fe000, 0xffffffffffff8400
case_65: .quad 0x00000000b87fe000, 0xffffffffffff8400
case_66: .quad 0x00000000b87fe000, 0xffffffffffff83ff
case_67: .quad 0x00000000b87fe000, 0xffffffffffff83ff
case_68: .quad 0x00000000b87fe000, 0xffffffffffff8400
case_69: .quad 0x00000000b87fe000, 0xffffffffffff8400
case_70: .quad 0x00000000b8800000, 0xffffffffffff8400
case_71: .quad 0x00000000b8800000, 0xffffffffffff8400
case_72: .quad 0x00000000b8800000, 0xffffffffffff8400
case_73: .quad 0x00000000b8800000, 0xffffffffffff8400
case_74: .quad 0x00000000b8800000, 0xffffffffffff8400
case_75: .quad 0x00000000b8800000, 0xffffffffffff8400
case_76: .quad 0x00000000b8800000, 0xffffffffffff8400
case_77: .quad 0x00000000b8800000, 0xffffffffffff8400
case_78: .quad 0x00000000b8800000, 0xffffffffffff8400
case_79: .quad 0x00000000b8800000, 0xffffffffffff8400
case_80: .quad 0x3f0ffc0000000000, 0xffffffffffff0400
case_81: .quad 0x3f0ffc0000000000, 0xffffffffffff0400
case_82: .quad 0x3f0ffc0000000000, 0xffffffffffff03ff
case_83: .quad 0x3f0ffc0000000000, 0xffffffffffff03ff
case_84: .quad 0x3f0ffc0000000000, 0xffffffffffff03ff
case_85: .quad 0x3f0ffc0000000000, 0xffffffffffff03ff
case_86: .quad 0x3f0ffc0000000000, 0xffffffffffff0400
case_87: .quad 0x3f0ffc0000000000, 0xffffffffffff0400
case_88: .quad 0x3f0ffc0000000000, 0xffffffffffff0400
case_89: .quad 0x3f0ffc0000000000, 0xffffffffffff0400
case_90: .quad 0x3f10000000000000, 0xffffffffffff0400
case_91: .quad 0x3f10000000000000, 0xffffffffffff0400
case_92: .quad 0x3f10000000000000, 0xffffffffffff0400
case_93: .quad 0x3f10000000000000, 0xffffffffffff0400
case_94: .quad 0x3f10000000000000, 0xffffffffffff0400
case_95: .quad 0x3f10000000000000, 0xffffffffffff0400
case_96: .quad 0x3f10000000000000, 0xffffffffffff0400
case_97: .quad 0x3f10000000000000, 0xffffffffffff0400
case_98: .quad 0x3f10000000000000, 0xffffffffffff0400
case_99: .quad 0x3f10000000000000, 0xffffffffffff0400
case_100: .quad 0xbf0ffc0000000000, 0xffffffffffff8400
case_101: .quad 0xbf0ffc0000000000, 0xffffffffffff8400
case_102: .quad 0xbf0ffc0000000000, 0xffffffffffff83ff
case_103: .quad 0xbf0ffc0000000000, 0xffffffffffff83ff
case_104: .quad 0xbf0ffc0000000000, 0xffffffffffff8400
case_105: .quad 0xbf0ffc0000000000, 0xffffffffffff8400
case_106: .quad 0xbf0ffc0000000000, 0xffffffffffff83ff
case_107: .quad 0xbf0ffc0000000000, 0xffffffffffff83ff
case_108: .quad 0xbf0ffc0000000000, 0xffffffffffff8400
case_109: .quad 0xbf0ffc0000000000, 0xffffffffffff8400
case_110: .quad 0xbf10000000000000, 0xffffffffffff8400
case_111: .quad 0xbf10000000000000, 0xffffffffffff8400
case_112: .quad 0xbf10000000000000, 0xffffffffffff8400
case_113: .quad 0xbf10000000000000, 0xffffffffffff8400
case_114: .quad 0xbf10000000000000, 0xffffffffffff8400
case_115: .quad 0xbf10000000000000, 0xffffffffffff8400
case_116: .quad 0xbf10000000000000, 0xffffffffffff8400
case_117: .quad 0xbf10000000000000, 0xffffffffffff8400
case_118: .quad 0xbf10000000000000, 0xffffffffffff8400
case_119: .quad 0xbf10000000000000, 0xffffffffffff8400
