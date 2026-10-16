#ifndef NEMU_DIFFTEST_ISA_H
#define NEMU_DIFFTEST_ISA_H

#include <stdint.h>

#define NEMU_ISA_API_VERSION 1u
#define NEMU_ISA_EXT_SVNAPOT (UINT64_C(1) << 0)
#define NEMU_ISA_EXT_ZAWRS (UINT64_C(1) << 1)
#define NEMU_ISA_EXT_ZFA (UINT64_C(1) << 2)
#define NEMU_ISA_EXT_SSNPM (UINT64_C(1) << 3)
#define NEMU_ISA_EXT_SMNPM (UINT64_C(1) << 4)
#define NEMU_ISA_EXT_SSCOFPMF (UINT64_C(1) << 5)
#define NEMU_ISA_EXT_V128_PREVIEW (UINT64_C(1) << 6)
#define NEMU_ISA_EXT_ZVBB (UINT64_C(1) << 7)
#define NEMU_ISA_EXT_ZVFHMIN (UINT64_C(1) << 8)
#define NEMU_ISA_EXT_SMSTATEEN_PREVIEW (UINT64_C(1) << 9)
#define NEMU_ISA_EXT_H_GSTAGE_PREVIEW (UINT64_C(1) << 10)
#define NEMU_ISA_EXT_MASK (NEMU_ISA_EXT_SVNAPOT | NEMU_ISA_EXT_ZAWRS | NEMU_ISA_EXT_ZFA | \
                         NEMU_ISA_EXT_SSNPM | NEMU_ISA_EXT_SMNPM | NEMU_ISA_EXT_SSCOFPMF | \
                         NEMU_ISA_EXT_V128_PREVIEW | NEMU_ISA_EXT_ZVBB | NEMU_ISA_EXT_ZVFHMIN | \
                         NEMU_ISA_EXT_SMSTATEEN_PREVIEW | NEMU_ISA_EXT_H_GSTAGE_PREVIEW)
#define NEMU_ISA_JOURNAL_SHIFT 8
#define NEMU_ISA_JOURNAL_HIGH_SHIFT 40
#define NEMU_ISA_JOURNAL_LOW_MASK UINT64_C(0xff)
#define NEMU_ISA_JOURNAL_ENCODE(extensions) \
  ((((extensions) & NEMU_ISA_JOURNAL_LOW_MASK) << NEMU_ISA_JOURNAL_SHIFT) | \
   (((extensions) & ~NEMU_ISA_JOURNAL_LOW_MASK) << NEMU_ISA_JOURNAL_HIGH_SHIFT))
#define NEMU_ISA_JOURNAL_DECODE(features) \
  ((((features) >> NEMU_ISA_JOURNAL_SHIFT) & NEMU_ISA_JOURNAL_LOW_MASK) | \
   (((features) >> NEMU_ISA_JOURNAL_HIGH_SHIFT) & ~NEMU_ISA_JOURNAL_LOW_MASK))
#define NEMU_ISA_JOURNAL_MASK NEMU_ISA_JOURNAL_ENCODE(NEMU_ISA_EXT_MASK)

typedef struct {
  uint32_t version;
  uint32_t size;
  uint32_t xlen;
  uint32_t locked;
  uint64_t supported;
  uint64_t enabled;
  int (*configure)(uint64_t extensions);
} NemuISAAPI;

typedef const NemuISAAPI *(*NemuISAQuery)(uint32_t version, uint32_t size);

#endif
