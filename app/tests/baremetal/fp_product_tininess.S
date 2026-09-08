/* FMUL and four fused variants: midpoint tininess, exact controls,
 * static rounding overrides frm; dynamic rounding follows frm. */
.option norvc
.option norelax
.macro probe op, load, store, rm, mode, flags, datum, high, fused
  la s1, \datum
  li t0, ((\mode << 5) | 8)
  csrw fcsr, t0
  \load ft0, 0(s1)
  \load ft1, 8(s1)
  .if \fused
    \load ft3, 16(s1)
    \op ft2, ft0, ft1, ft3, \rm
  .else
    \op ft2, ft0, ft1, \rm
  .endif
  csrr t0, fcsr
  li t1, ((\mode << 5) | \flags)
  bne t0, t1, fail
  \store ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 24(s1)
  bne t0, t1, fail
  .if \high
    lw t0, 4(s0)
    lw t1, 28(s1)
    bne t0, t1, fail
  .endif
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
  probe fmul.s, flw, fsw, rne, 1, 11, case_0, 0, 0
  probe fmul.s, flw, fsw, dyn, 0, 11, case_1, 0, 0
  probe fmul.s, flw, fsw, rtz, 2, 11, case_2, 0, 0
  probe fmul.s, flw, fsw, dyn, 1, 11, case_3, 0, 0
  probe fmul.s, flw, fsw, rdn, 3, 11, case_4, 0, 0
  probe fmul.s, flw, fsw, dyn, 2, 11, case_5, 0, 0
  probe fmul.s, flw, fsw, rup, 4, 11, case_6, 0, 0
  probe fmul.s, flw, fsw, dyn, 3, 11, case_7, 0, 0
  probe fmul.s, flw, fsw, rmm, 0, 11, case_8, 0, 0
  probe fmul.s, flw, fsw, dyn, 4, 11, case_9, 0, 0
  probe fmul.s, flw, fsw, rne, 1, 8, case_10, 0, 0
  probe fmul.s, flw, fsw, dyn, 0, 8, case_11, 0, 0
  probe fmul.s, flw, fsw, rtz, 2, 8, case_12, 0, 0
  probe fmul.s, flw, fsw, dyn, 1, 8, case_13, 0, 0
  probe fmul.s, flw, fsw, rdn, 3, 8, case_14, 0, 0
  probe fmul.s, flw, fsw, dyn, 2, 8, case_15, 0, 0
  probe fmul.s, flw, fsw, rup, 4, 8, case_16, 0, 0
  probe fmul.s, flw, fsw, dyn, 3, 8, case_17, 0, 0
  probe fmul.s, flw, fsw, rmm, 0, 8, case_18, 0, 0
  probe fmul.s, flw, fsw, dyn, 4, 8, case_19, 0, 0
  probe fmul.s, flw, fsw, rne, 1, 11, case_20, 0, 0
  probe fmul.s, flw, fsw, dyn, 0, 11, case_21, 0, 0
  probe fmul.s, flw, fsw, rtz, 2, 11, case_22, 0, 0
  probe fmul.s, flw, fsw, dyn, 1, 11, case_23, 0, 0
  probe fmul.s, flw, fsw, rdn, 3, 11, case_24, 0, 0
  probe fmul.s, flw, fsw, dyn, 2, 11, case_25, 0, 0
  probe fmul.s, flw, fsw, rup, 4, 11, case_26, 0, 0
  probe fmul.s, flw, fsw, dyn, 3, 11, case_27, 0, 0
  probe fmul.s, flw, fsw, rmm, 0, 11, case_28, 0, 0
  probe fmul.s, flw, fsw, dyn, 4, 11, case_29, 0, 0
  probe fmul.s, flw, fsw, rne, 1, 8, case_30, 0, 0
  probe fmul.s, flw, fsw, dyn, 0, 8, case_31, 0, 0
  probe fmul.s, flw, fsw, rtz, 2, 8, case_32, 0, 0
  probe fmul.s, flw, fsw, dyn, 1, 8, case_33, 0, 0
  probe fmul.s, flw, fsw, rdn, 3, 8, case_34, 0, 0
  probe fmul.s, flw, fsw, dyn, 2, 8, case_35, 0, 0
  probe fmul.s, flw, fsw, rup, 4, 8, case_36, 0, 0
  probe fmul.s, flw, fsw, dyn, 3, 8, case_37, 0, 0
  probe fmul.s, flw, fsw, rmm, 0, 8, case_38, 0, 0
  probe fmul.s, flw, fsw, dyn, 4, 8, case_39, 0, 0
  probe fmadd.s, flw, fsw, rne, 1, 11, case_40, 0, 1
  probe fmadd.s, flw, fsw, dyn, 0, 11, case_41, 0, 1
  probe fmadd.s, flw, fsw, rtz, 2, 11, case_42, 0, 1
  probe fmadd.s, flw, fsw, dyn, 1, 11, case_43, 0, 1
  probe fmadd.s, flw, fsw, rdn, 3, 11, case_44, 0, 1
  probe fmadd.s, flw, fsw, dyn, 2, 11, case_45, 0, 1
  probe fmadd.s, flw, fsw, rup, 4, 11, case_46, 0, 1
  probe fmadd.s, flw, fsw, dyn, 3, 11, case_47, 0, 1
  probe fmadd.s, flw, fsw, rmm, 0, 11, case_48, 0, 1
  probe fmadd.s, flw, fsw, dyn, 4, 11, case_49, 0, 1
  probe fmadd.s, flw, fsw, rne, 1, 8, case_50, 0, 1
  probe fmadd.s, flw, fsw, dyn, 0, 8, case_51, 0, 1
  probe fmadd.s, flw, fsw, rtz, 2, 8, case_52, 0, 1
  probe fmadd.s, flw, fsw, dyn, 1, 8, case_53, 0, 1
  probe fmadd.s, flw, fsw, rdn, 3, 8, case_54, 0, 1
  probe fmadd.s, flw, fsw, dyn, 2, 8, case_55, 0, 1
  probe fmadd.s, flw, fsw, rup, 4, 8, case_56, 0, 1
  probe fmadd.s, flw, fsw, dyn, 3, 8, case_57, 0, 1
  probe fmadd.s, flw, fsw, rmm, 0, 8, case_58, 0, 1
  probe fmadd.s, flw, fsw, dyn, 4, 8, case_59, 0, 1
  probe fmadd.s, flw, fsw, rne, 1, 11, case_60, 0, 1
  probe fmadd.s, flw, fsw, dyn, 0, 11, case_61, 0, 1
  probe fmadd.s, flw, fsw, rtz, 2, 11, case_62, 0, 1
  probe fmadd.s, flw, fsw, dyn, 1, 11, case_63, 0, 1
  probe fmadd.s, flw, fsw, rdn, 3, 11, case_64, 0, 1
  probe fmadd.s, flw, fsw, dyn, 2, 11, case_65, 0, 1
  probe fmadd.s, flw, fsw, rup, 4, 11, case_66, 0, 1
  probe fmadd.s, flw, fsw, dyn, 3, 11, case_67, 0, 1
  probe fmadd.s, flw, fsw, rmm, 0, 11, case_68, 0, 1
  probe fmadd.s, flw, fsw, dyn, 4, 11, case_69, 0, 1
  probe fmadd.s, flw, fsw, rne, 1, 8, case_70, 0, 1
  probe fmadd.s, flw, fsw, dyn, 0, 8, case_71, 0, 1
  probe fmadd.s, flw, fsw, rtz, 2, 8, case_72, 0, 1
  probe fmadd.s, flw, fsw, dyn, 1, 8, case_73, 0, 1
  probe fmadd.s, flw, fsw, rdn, 3, 8, case_74, 0, 1
  probe fmadd.s, flw, fsw, dyn, 2, 8, case_75, 0, 1
  probe fmadd.s, flw, fsw, rup, 4, 8, case_76, 0, 1
  probe fmadd.s, flw, fsw, dyn, 3, 8, case_77, 0, 1
  probe fmadd.s, flw, fsw, rmm, 0, 8, case_78, 0, 1
  probe fmadd.s, flw, fsw, dyn, 4, 8, case_79, 0, 1
  probe fmsub.s, flw, fsw, rne, 1, 11, case_80, 0, 1
  probe fmsub.s, flw, fsw, dyn, 0, 11, case_81, 0, 1
  probe fmsub.s, flw, fsw, rtz, 2, 11, case_82, 0, 1
  probe fmsub.s, flw, fsw, dyn, 1, 11, case_83, 0, 1
  probe fmsub.s, flw, fsw, rdn, 3, 11, case_84, 0, 1
  probe fmsub.s, flw, fsw, dyn, 2, 11, case_85, 0, 1
  probe fmsub.s, flw, fsw, rup, 4, 11, case_86, 0, 1
  probe fmsub.s, flw, fsw, dyn, 3, 11, case_87, 0, 1
  probe fmsub.s, flw, fsw, rmm, 0, 11, case_88, 0, 1
  probe fmsub.s, flw, fsw, dyn, 4, 11, case_89, 0, 1
  probe fmsub.s, flw, fsw, rne, 1, 8, case_90, 0, 1
  probe fmsub.s, flw, fsw, dyn, 0, 8, case_91, 0, 1
  probe fmsub.s, flw, fsw, rtz, 2, 8, case_92, 0, 1
  probe fmsub.s, flw, fsw, dyn, 1, 8, case_93, 0, 1
  probe fmsub.s, flw, fsw, rdn, 3, 8, case_94, 0, 1
  probe fmsub.s, flw, fsw, dyn, 2, 8, case_95, 0, 1
  probe fmsub.s, flw, fsw, rup, 4, 8, case_96, 0, 1
  probe fmsub.s, flw, fsw, dyn, 3, 8, case_97, 0, 1
  probe fmsub.s, flw, fsw, rmm, 0, 8, case_98, 0, 1
  probe fmsub.s, flw, fsw, dyn, 4, 8, case_99, 0, 1
  probe fmsub.s, flw, fsw, rne, 1, 11, case_100, 0, 1
  probe fmsub.s, flw, fsw, dyn, 0, 11, case_101, 0, 1
  probe fmsub.s, flw, fsw, rtz, 2, 11, case_102, 0, 1
  probe fmsub.s, flw, fsw, dyn, 1, 11, case_103, 0, 1
  probe fmsub.s, flw, fsw, rdn, 3, 11, case_104, 0, 1
  probe fmsub.s, flw, fsw, dyn, 2, 11, case_105, 0, 1
  probe fmsub.s, flw, fsw, rup, 4, 11, case_106, 0, 1
  probe fmsub.s, flw, fsw, dyn, 3, 11, case_107, 0, 1
  probe fmsub.s, flw, fsw, rmm, 0, 11, case_108, 0, 1
  probe fmsub.s, flw, fsw, dyn, 4, 11, case_109, 0, 1
  probe fmsub.s, flw, fsw, rne, 1, 8, case_110, 0, 1
  probe fmsub.s, flw, fsw, dyn, 0, 8, case_111, 0, 1
  probe fmsub.s, flw, fsw, rtz, 2, 8, case_112, 0, 1
  probe fmsub.s, flw, fsw, dyn, 1, 8, case_113, 0, 1
  probe fmsub.s, flw, fsw, rdn, 3, 8, case_114, 0, 1
  probe fmsub.s, flw, fsw, dyn, 2, 8, case_115, 0, 1
  probe fmsub.s, flw, fsw, rup, 4, 8, case_116, 0, 1
  probe fmsub.s, flw, fsw, dyn, 3, 8, case_117, 0, 1
  probe fmsub.s, flw, fsw, rmm, 0, 8, case_118, 0, 1
  probe fmsub.s, flw, fsw, dyn, 4, 8, case_119, 0, 1
  probe fnmsub.s, flw, fsw, rne, 1, 11, case_120, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 0, 11, case_121, 0, 1
  probe fnmsub.s, flw, fsw, rtz, 2, 11, case_122, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 1, 11, case_123, 0, 1
  probe fnmsub.s, flw, fsw, rdn, 3, 11, case_124, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 2, 11, case_125, 0, 1
  probe fnmsub.s, flw, fsw, rup, 4, 11, case_126, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 3, 11, case_127, 0, 1
  probe fnmsub.s, flw, fsw, rmm, 0, 11, case_128, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 4, 11, case_129, 0, 1
  probe fnmsub.s, flw, fsw, rne, 1, 8, case_130, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 0, 8, case_131, 0, 1
  probe fnmsub.s, flw, fsw, rtz, 2, 8, case_132, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 1, 8, case_133, 0, 1
  probe fnmsub.s, flw, fsw, rdn, 3, 8, case_134, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 2, 8, case_135, 0, 1
  probe fnmsub.s, flw, fsw, rup, 4, 8, case_136, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 3, 8, case_137, 0, 1
  probe fnmsub.s, flw, fsw, rmm, 0, 8, case_138, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 4, 8, case_139, 0, 1
  probe fnmsub.s, flw, fsw, rne, 1, 11, case_140, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 0, 11, case_141, 0, 1
  probe fnmsub.s, flw, fsw, rtz, 2, 11, case_142, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 1, 11, case_143, 0, 1
  probe fnmsub.s, flw, fsw, rdn, 3, 11, case_144, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 2, 11, case_145, 0, 1
  probe fnmsub.s, flw, fsw, rup, 4, 11, case_146, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 3, 11, case_147, 0, 1
  probe fnmsub.s, flw, fsw, rmm, 0, 11, case_148, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 4, 11, case_149, 0, 1
  probe fnmsub.s, flw, fsw, rne, 1, 8, case_150, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 0, 8, case_151, 0, 1
  probe fnmsub.s, flw, fsw, rtz, 2, 8, case_152, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 1, 8, case_153, 0, 1
  probe fnmsub.s, flw, fsw, rdn, 3, 8, case_154, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 2, 8, case_155, 0, 1
  probe fnmsub.s, flw, fsw, rup, 4, 8, case_156, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 3, 8, case_157, 0, 1
  probe fnmsub.s, flw, fsw, rmm, 0, 8, case_158, 0, 1
  probe fnmsub.s, flw, fsw, dyn, 4, 8, case_159, 0, 1
  probe fnmadd.s, flw, fsw, rne, 1, 11, case_160, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 0, 11, case_161, 0, 1
  probe fnmadd.s, flw, fsw, rtz, 2, 11, case_162, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 1, 11, case_163, 0, 1
  probe fnmadd.s, flw, fsw, rdn, 3, 11, case_164, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 2, 11, case_165, 0, 1
  probe fnmadd.s, flw, fsw, rup, 4, 11, case_166, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 3, 11, case_167, 0, 1
  probe fnmadd.s, flw, fsw, rmm, 0, 11, case_168, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 4, 11, case_169, 0, 1
  probe fnmadd.s, flw, fsw, rne, 1, 8, case_170, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 0, 8, case_171, 0, 1
  probe fnmadd.s, flw, fsw, rtz, 2, 8, case_172, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 1, 8, case_173, 0, 1
  probe fnmadd.s, flw, fsw, rdn, 3, 8, case_174, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 2, 8, case_175, 0, 1
  probe fnmadd.s, flw, fsw, rup, 4, 8, case_176, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 3, 8, case_177, 0, 1
  probe fnmadd.s, flw, fsw, rmm, 0, 8, case_178, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 4, 8, case_179, 0, 1
  probe fnmadd.s, flw, fsw, rne, 1, 11, case_180, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 0, 11, case_181, 0, 1
  probe fnmadd.s, flw, fsw, rtz, 2, 11, case_182, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 1, 11, case_183, 0, 1
  probe fnmadd.s, flw, fsw, rdn, 3, 11, case_184, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 2, 11, case_185, 0, 1
  probe fnmadd.s, flw, fsw, rup, 4, 11, case_186, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 3, 11, case_187, 0, 1
  probe fnmadd.s, flw, fsw, rmm, 0, 11, case_188, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 4, 11, case_189, 0, 1
  probe fnmadd.s, flw, fsw, rne, 1, 8, case_190, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 0, 8, case_191, 0, 1
  probe fnmadd.s, flw, fsw, rtz, 2, 8, case_192, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 1, 8, case_193, 0, 1
  probe fnmadd.s, flw, fsw, rdn, 3, 8, case_194, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 2, 8, case_195, 0, 1
  probe fnmadd.s, flw, fsw, rup, 4, 8, case_196, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 3, 8, case_197, 0, 1
  probe fnmadd.s, flw, fsw, rmm, 0, 8, case_198, 0, 1
  probe fnmadd.s, flw, fsw, dyn, 4, 8, case_199, 0, 1
  probe fmul.d, fld, fsd, rne, 1, 11, case_200, 1, 0
  probe fmul.d, fld, fsd, dyn, 0, 11, case_201, 1, 0
  probe fmul.d, fld, fsd, rtz, 2, 11, case_202, 1, 0
  probe fmul.d, fld, fsd, dyn, 1, 11, case_203, 1, 0
  probe fmul.d, fld, fsd, rdn, 3, 11, case_204, 1, 0
  probe fmul.d, fld, fsd, dyn, 2, 11, case_205, 1, 0
  probe fmul.d, fld, fsd, rup, 4, 11, case_206, 1, 0
  probe fmul.d, fld, fsd, dyn, 3, 11, case_207, 1, 0
  probe fmul.d, fld, fsd, rmm, 0, 11, case_208, 1, 0
  probe fmul.d, fld, fsd, dyn, 4, 11, case_209, 1, 0
  probe fmul.d, fld, fsd, rne, 1, 8, case_210, 1, 0
  probe fmul.d, fld, fsd, dyn, 0, 8, case_211, 1, 0
  probe fmul.d, fld, fsd, rtz, 2, 8, case_212, 1, 0
  probe fmul.d, fld, fsd, dyn, 1, 8, case_213, 1, 0
  probe fmul.d, fld, fsd, rdn, 3, 8, case_214, 1, 0
  probe fmul.d, fld, fsd, dyn, 2, 8, case_215, 1, 0
  probe fmul.d, fld, fsd, rup, 4, 8, case_216, 1, 0
  probe fmul.d, fld, fsd, dyn, 3, 8, case_217, 1, 0
  probe fmul.d, fld, fsd, rmm, 0, 8, case_218, 1, 0
  probe fmul.d, fld, fsd, dyn, 4, 8, case_219, 1, 0
  probe fmul.d, fld, fsd, rne, 1, 11, case_220, 1, 0
  probe fmul.d, fld, fsd, dyn, 0, 11, case_221, 1, 0
  probe fmul.d, fld, fsd, rtz, 2, 11, case_222, 1, 0
  probe fmul.d, fld, fsd, dyn, 1, 11, case_223, 1, 0
  probe fmul.d, fld, fsd, rdn, 3, 11, case_224, 1, 0
  probe fmul.d, fld, fsd, dyn, 2, 11, case_225, 1, 0
  probe fmul.d, fld, fsd, rup, 4, 11, case_226, 1, 0
  probe fmul.d, fld, fsd, dyn, 3, 11, case_227, 1, 0
  probe fmul.d, fld, fsd, rmm, 0, 11, case_228, 1, 0
  probe fmul.d, fld, fsd, dyn, 4, 11, case_229, 1, 0
  probe fmul.d, fld, fsd, rne, 1, 8, case_230, 1, 0
  probe fmul.d, fld, fsd, dyn, 0, 8, case_231, 1, 0
  probe fmul.d, fld, fsd, rtz, 2, 8, case_232, 1, 0
  probe fmul.d, fld, fsd, dyn, 1, 8, case_233, 1, 0
  probe fmul.d, fld, fsd, rdn, 3, 8, case_234, 1, 0
  probe fmul.d, fld, fsd, dyn, 2, 8, case_235, 1, 0
  probe fmul.d, fld, fsd, rup, 4, 8, case_236, 1, 0
  probe fmul.d, fld, fsd, dyn, 3, 8, case_237, 1, 0
  probe fmul.d, fld, fsd, rmm, 0, 8, case_238, 1, 0
  probe fmul.d, fld, fsd, dyn, 4, 8, case_239, 1, 0
  probe fmadd.d, fld, fsd, rne, 1, 11, case_240, 1, 1
  probe fmadd.d, fld, fsd, dyn, 0, 11, case_241, 1, 1
  probe fmadd.d, fld, fsd, rtz, 2, 11, case_242, 1, 1
  probe fmadd.d, fld, fsd, dyn, 1, 11, case_243, 1, 1
  probe fmadd.d, fld, fsd, rdn, 3, 11, case_244, 1, 1
  probe fmadd.d, fld, fsd, dyn, 2, 11, case_245, 1, 1
  probe fmadd.d, fld, fsd, rup, 4, 11, case_246, 1, 1
  probe fmadd.d, fld, fsd, dyn, 3, 11, case_247, 1, 1
  probe fmadd.d, fld, fsd, rmm, 0, 11, case_248, 1, 1
  probe fmadd.d, fld, fsd, dyn, 4, 11, case_249, 1, 1
  probe fmadd.d, fld, fsd, rne, 1, 8, case_250, 1, 1
  probe fmadd.d, fld, fsd, dyn, 0, 8, case_251, 1, 1
  probe fmadd.d, fld, fsd, rtz, 2, 8, case_252, 1, 1
  probe fmadd.d, fld, fsd, dyn, 1, 8, case_253, 1, 1
  probe fmadd.d, fld, fsd, rdn, 3, 8, case_254, 1, 1
  probe fmadd.d, fld, fsd, dyn, 2, 8, case_255, 1, 1
  probe fmadd.d, fld, fsd, rup, 4, 8, case_256, 1, 1
  probe fmadd.d, fld, fsd, dyn, 3, 8, case_257, 1, 1
  probe fmadd.d, fld, fsd, rmm, 0, 8, case_258, 1, 1
  probe fmadd.d, fld, fsd, dyn, 4, 8, case_259, 1, 1
  probe fmadd.d, fld, fsd, rne, 1, 11, case_260, 1, 1
  probe fmadd.d, fld, fsd, dyn, 0, 11, case_261, 1, 1
  probe fmadd.d, fld, fsd, rtz, 2, 11, case_262, 1, 1
  probe fmadd.d, fld, fsd, dyn, 1, 11, case_263, 1, 1
  probe fmadd.d, fld, fsd, rdn, 3, 11, case_264, 1, 1
  probe fmadd.d, fld, fsd, dyn, 2, 11, case_265, 1, 1
  probe fmadd.d, fld, fsd, rup, 4, 11, case_266, 1, 1
  probe fmadd.d, fld, fsd, dyn, 3, 11, case_267, 1, 1
  probe fmadd.d, fld, fsd, rmm, 0, 11, case_268, 1, 1
  probe fmadd.d, fld, fsd, dyn, 4, 11, case_269, 1, 1
  probe fmadd.d, fld, fsd, rne, 1, 8, case_270, 1, 1
  probe fmadd.d, fld, fsd, dyn, 0, 8, case_271, 1, 1
  probe fmadd.d, fld, fsd, rtz, 2, 8, case_272, 1, 1
  probe fmadd.d, fld, fsd, dyn, 1, 8, case_273, 1, 1
  probe fmadd.d, fld, fsd, rdn, 3, 8, case_274, 1, 1
  probe fmadd.d, fld, fsd, dyn, 2, 8, case_275, 1, 1
  probe fmadd.d, fld, fsd, rup, 4, 8, case_276, 1, 1
  probe fmadd.d, fld, fsd, dyn, 3, 8, case_277, 1, 1
  probe fmadd.d, fld, fsd, rmm, 0, 8, case_278, 1, 1
  probe fmadd.d, fld, fsd, dyn, 4, 8, case_279, 1, 1
  probe fmsub.d, fld, fsd, rne, 1, 11, case_280, 1, 1
  probe fmsub.d, fld, fsd, dyn, 0, 11, case_281, 1, 1
  probe fmsub.d, fld, fsd, rtz, 2, 11, case_282, 1, 1
  probe fmsub.d, fld, fsd, dyn, 1, 11, case_283, 1, 1
  probe fmsub.d, fld, fsd, rdn, 3, 11, case_284, 1, 1
  probe fmsub.d, fld, fsd, dyn, 2, 11, case_285, 1, 1
  probe fmsub.d, fld, fsd, rup, 4, 11, case_286, 1, 1
  probe fmsub.d, fld, fsd, dyn, 3, 11, case_287, 1, 1
  probe fmsub.d, fld, fsd, rmm, 0, 11, case_288, 1, 1
  probe fmsub.d, fld, fsd, dyn, 4, 11, case_289, 1, 1
  probe fmsub.d, fld, fsd, rne, 1, 8, case_290, 1, 1
  probe fmsub.d, fld, fsd, dyn, 0, 8, case_291, 1, 1
  probe fmsub.d, fld, fsd, rtz, 2, 8, case_292, 1, 1
  probe fmsub.d, fld, fsd, dyn, 1, 8, case_293, 1, 1
  probe fmsub.d, fld, fsd, rdn, 3, 8, case_294, 1, 1
  probe fmsub.d, fld, fsd, dyn, 2, 8, case_295, 1, 1
  probe fmsub.d, fld, fsd, rup, 4, 8, case_296, 1, 1
  probe fmsub.d, fld, fsd, dyn, 3, 8, case_297, 1, 1
  probe fmsub.d, fld, fsd, rmm, 0, 8, case_298, 1, 1
  probe fmsub.d, fld, fsd, dyn, 4, 8, case_299, 1, 1
  probe fmsub.d, fld, fsd, rne, 1, 11, case_300, 1, 1
  probe fmsub.d, fld, fsd, dyn, 0, 11, case_301, 1, 1
  probe fmsub.d, fld, fsd, rtz, 2, 11, case_302, 1, 1
  probe fmsub.d, fld, fsd, dyn, 1, 11, case_303, 1, 1
  probe fmsub.d, fld, fsd, rdn, 3, 11, case_304, 1, 1
  probe fmsub.d, fld, fsd, dyn, 2, 11, case_305, 1, 1
  probe fmsub.d, fld, fsd, rup, 4, 11, case_306, 1, 1
  probe fmsub.d, fld, fsd, dyn, 3, 11, case_307, 1, 1
  probe fmsub.d, fld, fsd, rmm, 0, 11, case_308, 1, 1
  probe fmsub.d, fld, fsd, dyn, 4, 11, case_309, 1, 1
  probe fmsub.d, fld, fsd, rne, 1, 8, case_310, 1, 1
  probe fmsub.d, fld, fsd, dyn, 0, 8, case_311, 1, 1
  probe fmsub.d, fld, fsd, rtz, 2, 8, case_312, 1, 1
  probe fmsub.d, fld, fsd, dyn, 1, 8, case_313, 1, 1
  probe fmsub.d, fld, fsd, rdn, 3, 8, case_314, 1, 1
  probe fmsub.d, fld, fsd, dyn, 2, 8, case_315, 1, 1
  probe fmsub.d, fld, fsd, rup, 4, 8, case_316, 1, 1
  probe fmsub.d, fld, fsd, dyn, 3, 8, case_317, 1, 1
  probe fmsub.d, fld, fsd, rmm, 0, 8, case_318, 1, 1
  probe fmsub.d, fld, fsd, dyn, 4, 8, case_319, 1, 1
  probe fnmsub.d, fld, fsd, rne, 1, 11, case_320, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 0, 11, case_321, 1, 1
  probe fnmsub.d, fld, fsd, rtz, 2, 11, case_322, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 1, 11, case_323, 1, 1
  probe fnmsub.d, fld, fsd, rdn, 3, 11, case_324, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 2, 11, case_325, 1, 1
  probe fnmsub.d, fld, fsd, rup, 4, 11, case_326, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 3, 11, case_327, 1, 1
  probe fnmsub.d, fld, fsd, rmm, 0, 11, case_328, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 4, 11, case_329, 1, 1
  probe fnmsub.d, fld, fsd, rne, 1, 8, case_330, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 0, 8, case_331, 1, 1
  probe fnmsub.d, fld, fsd, rtz, 2, 8, case_332, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 1, 8, case_333, 1, 1
  probe fnmsub.d, fld, fsd, rdn, 3, 8, case_334, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 2, 8, case_335, 1, 1
  probe fnmsub.d, fld, fsd, rup, 4, 8, case_336, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 3, 8, case_337, 1, 1
  probe fnmsub.d, fld, fsd, rmm, 0, 8, case_338, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 4, 8, case_339, 1, 1
  probe fnmsub.d, fld, fsd, rne, 1, 11, case_340, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 0, 11, case_341, 1, 1
  probe fnmsub.d, fld, fsd, rtz, 2, 11, case_342, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 1, 11, case_343, 1, 1
  probe fnmsub.d, fld, fsd, rdn, 3, 11, case_344, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 2, 11, case_345, 1, 1
  probe fnmsub.d, fld, fsd, rup, 4, 11, case_346, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 3, 11, case_347, 1, 1
  probe fnmsub.d, fld, fsd, rmm, 0, 11, case_348, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 4, 11, case_349, 1, 1
  probe fnmsub.d, fld, fsd, rne, 1, 8, case_350, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 0, 8, case_351, 1, 1
  probe fnmsub.d, fld, fsd, rtz, 2, 8, case_352, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 1, 8, case_353, 1, 1
  probe fnmsub.d, fld, fsd, rdn, 3, 8, case_354, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 2, 8, case_355, 1, 1
  probe fnmsub.d, fld, fsd, rup, 4, 8, case_356, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 3, 8, case_357, 1, 1
  probe fnmsub.d, fld, fsd, rmm, 0, 8, case_358, 1, 1
  probe fnmsub.d, fld, fsd, dyn, 4, 8, case_359, 1, 1
  probe fnmadd.d, fld, fsd, rne, 1, 11, case_360, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 0, 11, case_361, 1, 1
  probe fnmadd.d, fld, fsd, rtz, 2, 11, case_362, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 1, 11, case_363, 1, 1
  probe fnmadd.d, fld, fsd, rdn, 3, 11, case_364, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 2, 11, case_365, 1, 1
  probe fnmadd.d, fld, fsd, rup, 4, 11, case_366, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 3, 11, case_367, 1, 1
  probe fnmadd.d, fld, fsd, rmm, 0, 11, case_368, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 4, 11, case_369, 1, 1
  probe fnmadd.d, fld, fsd, rne, 1, 8, case_370, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 0, 8, case_371, 1, 1
  probe fnmadd.d, fld, fsd, rtz, 2, 8, case_372, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 1, 8, case_373, 1, 1
  probe fnmadd.d, fld, fsd, rdn, 3, 8, case_374, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 2, 8, case_375, 1, 1
  probe fnmadd.d, fld, fsd, rup, 4, 8, case_376, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 3, 8, case_377, 1, 1
  probe fnmadd.d, fld, fsd, rmm, 0, 8, case_378, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 4, 8, case_379, 1, 1
  probe fnmadd.d, fld, fsd, rne, 1, 11, case_380, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 0, 11, case_381, 1, 1
  probe fnmadd.d, fld, fsd, rtz, 2, 11, case_382, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 1, 11, case_383, 1, 1
  probe fnmadd.d, fld, fsd, rdn, 3, 11, case_384, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 2, 11, case_385, 1, 1
  probe fnmadd.d, fld, fsd, rup, 4, 11, case_386, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 3, 11, case_387, 1, 1
  probe fnmadd.d, fld, fsd, rmm, 0, 11, case_388, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 4, 11, case_389, 1, 1
  probe fnmadd.d, fld, fsd, rne, 1, 8, case_390, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 0, 8, case_391, 1, 1
  probe fnmadd.d, fld, fsd, rtz, 2, 8, case_392, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 1, 8, case_393, 1, 1
  probe fnmadd.d, fld, fsd, rdn, 3, 8, case_394, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 2, 8, case_395, 1, 1
  probe fnmadd.d, fld, fsd, rup, 4, 8, case_396, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 3, 8, case_397, 1, 1
  probe fnmadd.d, fld, fsd, rmm, 0, 8, case_398, 1, 1
  probe fnmadd.d, fld, fsd, dyn, 4, 8, case_399, 1, 1
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
1: j 1b
.section .data
.balign 8
result: .quad 0
case_0: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_1: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_2: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_3: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_4: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_5: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_6: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_7: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_8: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_9: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_10: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_11: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_12: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_13: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_14: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_15: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_16: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_17: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_18: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_19: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_20: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_21: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_22: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_23: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_24: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_25: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_26: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_27: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_28: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_29: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_30: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_31: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_32: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_33: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_34: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_35: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_36: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_37: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_38: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_39: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_40: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_41: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_42: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_43: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_44: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_45: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_46: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_47: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_48: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_49: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_50: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_51: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_52: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_53: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_54: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_55: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_56: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_57: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_58: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_59: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_60: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_61: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_62: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_63: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_64: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_65: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_66: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_67: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_68: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_69: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_70: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_71: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_72: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_73: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_74: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_75: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_76: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_77: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_78: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_79: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_80: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_81: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_82: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_83: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_84: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_85: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_86: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_87: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_88: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_89: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_90: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_91: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_92: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_93: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_94: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_95: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_96: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_97: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_98: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_99: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000000800000
case_100: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_101: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_102: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_103: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_104: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_105: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_106: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_107: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_108: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_109: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_110: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_111: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_112: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_113: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_114: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_115: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_116: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_117: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_118: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_119: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000080800000
case_120: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_121: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_122: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_123: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_124: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_125: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_126: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_127: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_128: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_129: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_130: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_131: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_132: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_133: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_134: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_135: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_136: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_137: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_138: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_139: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_140: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_141: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_142: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_143: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_144: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_145: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_146: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_147: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_148: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_149: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_150: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_151: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_152: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_153: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_154: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_155: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_156: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_157: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_158: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_159: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_160: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_161: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_162: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_163: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_164: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_165: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_166: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_167: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x00000000807fffff
case_168: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_169: .quad 0x0000000000800000, 0x000000003f7fffff, 0, 0x0000000080800000
case_170: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_171: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_172: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_173: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_174: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_175: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_176: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_177: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_178: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_179: .quad 0x0000000000800000, 0x000000003f800000, 0, 0x0000000080800000
case_180: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_181: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_182: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_183: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_184: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_185: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x00000000007fffff
case_186: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_187: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_188: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_189: .quad 0x0000000080800000, 0x000000003f7fffff, 0, 0x0000000000800000
case_190: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_191: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_192: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_193: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_194: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_195: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_196: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_197: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_198: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_199: .quad 0x0000000080800000, 0x000000003f800000, 0, 0x0000000000800000
case_200: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_201: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_202: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_203: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_204: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_205: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_206: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_207: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_208: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_209: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_210: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_211: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_212: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_213: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_214: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_215: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_216: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_217: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_218: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_219: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_220: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_221: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_222: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_223: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_224: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_225: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_226: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_227: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_228: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_229: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_230: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_231: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_232: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_233: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_234: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_235: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_236: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_237: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_238: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_239: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_240: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_241: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_242: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_243: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_244: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_245: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_246: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_247: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_248: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_249: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_250: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_251: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_252: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_253: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_254: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_255: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_256: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_257: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_258: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_259: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_260: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_261: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_262: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_263: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_264: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_265: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_266: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_267: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_268: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_269: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_270: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_271: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_272: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_273: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_274: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_275: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_276: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_277: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_278: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_279: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_280: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_281: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_282: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_283: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_284: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_285: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_286: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_287: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_288: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_289: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_290: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_291: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_292: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_293: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_294: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_295: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_296: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_297: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_298: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_299: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_300: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_301: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_302: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_303: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_304: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_305: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_306: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_307: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_308: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_309: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_310: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_311: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_312: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_313: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_314: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_315: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_316: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_317: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_318: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_319: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_320: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_321: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_322: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_323: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_324: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_325: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_326: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_327: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_328: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_329: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_330: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_331: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_332: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_333: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_334: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_335: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_336: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_337: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_338: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_339: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_340: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_341: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_342: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_343: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_344: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_345: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_346: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_347: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_348: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_349: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_350: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_351: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_352: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_353: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_354: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_355: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_356: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_357: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_358: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_359: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_360: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_361: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_362: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_363: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_364: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_365: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_366: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_367: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x800fffffffffffff
case_368: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_369: .quad 0x0010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000
case_370: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_371: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_372: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_373: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_374: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_375: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_376: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_377: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_378: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_379: .quad 0x0010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000
case_380: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_381: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_382: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_383: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_384: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_385: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x000fffffffffffff
case_386: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_387: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_388: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_389: .quad 0x8010000000000000, 0x3fefffffffffffff, 0, 0x0010000000000000
case_390: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_391: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_392: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_393: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_394: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_395: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_396: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_397: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_398: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
case_399: .quad 0x8010000000000000, 0x3ff0000000000000, 0, 0x0010000000000000
