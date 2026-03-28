/***************************************************************************************
 * Copyright (c) 2014-2022 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#ifndef __CPU_DECODE_H__
#define __CPU_DECODE_H__

#include <isa.h>

typedef struct Decode
{
  vaddr_t pc;
  vaddr_t snpc; // static next pc
  vaddr_t dnpc; // dynamic next pc
  ISADecodeInfo isa;
  IFDEF(CONFIG_ITRACE, char logbuf[128]);
} Decode;

// --- pattern matching mechanism ---
__attribute__((always_inline)) static inline void pattern_decode(const char *str, int len,
                                                                 uint64_t *key, uint64_t *mask, uint64_t *shift)
{
  uint64_t __key = 0, __mask = 0, __shift = 0;
#define macro(i)                                             \
  if ((i) >= len)                                            \
    goto finish;                                             \
  else                                                       \
  {                                                          \
    char c = str[i];                                         \
    if (c != ' ')                                            \
    {                                                        \
      Assert(c == '0' || c == '1' || c == '?',               \
             "invalid character '%c' in pattern string", c); \
      __key = (__key << 1) | (c == '1' ? 1 : 0);             \
      __mask = (__mask << 1) | (c == '?' ? 0 : 1);           \
      __shift = (c == '?' ? __shift + 1 : 0);                \
    }                                                        \
  }

#define macro2(i) \
  macro(i);       \
  macro((i) + 1)
#define macro4(i) \
  macro2(i);      \
  macro2((i) + 2)
#define macro8(i) \
  macro4(i);      \
  macro4((i) + 4)
#define macro16(i) \
  macro8(i);       \
  macro8((i) + 8)
#define macro32(i) \
  macro16(i);      \
  macro16((i) + 16)
#define macro64(i) \
  macro32(i);      \
  macro32((i) + 32)
  macro64(0);
  panic("pattern too long");
#undef macro
finish:
  *key = __key >> __shift;
  *mask = __mask >> __shift;
  *shift = __shift;
}

__attribute__((always_inline)) static inline void pattern_decode_hex(const char *str, int len,
                                                                     uint64_t *key, uint64_t *mask, uint64_t *shift)
{
  uint64_t __key = 0, __mask = 0, __shift = 0;
#define macro(i)                                                                     \
  if ((i) >= len)                                                                    \
    goto finish;                                                                     \
  else                                                                               \
  {                                                                                  \
    char c = str[i];                                                                 \
    if (c != ' ')                                                                    \
    {                                                                                \
      Assert((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c == '?',           \
             "invalid character '%c' in pattern string", c);                         \
      __key = (__key << 4) | (c == '?' ? 0 : (c >= '0' && c <= '9') ? c - '0'        \
                                                                    : c - 'a' + 10); \
      __mask = (__mask << 4) | (c == '?' ? 0 : 0xf);                                 \
      __shift = (c == '?' ? __shift + 4 : 0);                                        \
    }                                                                                \
  }

  macro16(0);
  panic("pattern too long");
#undef macro
finish:
  *key = __key >> __shift;
  *mask = __mask >> __shift;
  *shift = __shift;
}

// --- pattern matching wrappers for decode ---
#define INSTPAT(pattern, ...)                                      \
  do                                                               \
  {                                                                \
    uint64_t key, mask, shift;                                     \
    pattern_decode(pattern, STRLEN(pattern), &key, &mask, &shift); \
    if ((((uint64_t)INSTPAT_INST(s) >> shift) & mask) == key)      \
    {                                                              \
      INSTPAT_MATCH(s, ##__VA_ARGS__);                             \
      goto *(__instpat_end);                                       \
    }                                                              \
  } while (0)

// --- flat linear scan (used by inst_c.c) ---
#define INSTPAT_START(...) \
  {                        \
    const void *__instpat_end = &&__instpat_end_flat
#define INSTPAT_END(...) \
  __instpat_end_flat:;   \
  }

// --- opcode jump-table dispatch (switch on inst[6:2], used by inst.c) ---
// Usage:
//   INSTPAT_SWITCH();
//   INSTPAT_CASE(0b01101, grp_lui)
//     INSTPAT("... 01101 11", lui, U, ...);
//   INSTPAT_CASE_END(grp_lui)
//   ...
//   INSTPAT_DEFAULT()
//     INSTPAT("... ????? ??", inv, N, ...);
//   INSTPAT_SWITCH_END();

#define INSTPAT_SWITCH()                 \
  {                                      \
    switch (BITS(INSTPAT_INST(s), 6, 2)) \
    {

#define INSTPAT_CASE(opcode, name) \
  case opcode:                     \
  {                                \
    const void *__instpat_end = &&concat(__instpat_end_, name);

#define INSTPAT_CASE_END(name)    \
  goto __instpat_inv;             \
  concat(__instpat_end_, name) :; \
  break;                          \
  }

#define INSTPAT_DEFAULT() \
  default:                \
  __instpat_inv:          \
  {                       \
    const void *__instpat_end = &&__instpat_end_inv;

#define INSTPAT_SWITCH_END() \
  __instpat_end_inv:;        \
  }                          \
  } /* switch */             \
  } /* outer block */

#endif
