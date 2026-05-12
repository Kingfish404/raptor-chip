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

#ifndef __COMMON_H__
#define __COMMON_H__

#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>

#include <generated/autoconf.h>
#include <macro.h>

#ifdef CONFIG_TARGET_AM
#include <klib.h>
#else
#include <assert.h>
#include <stdlib.h>
#endif

#if CONFIG_MBASE + CONFIG_MSIZE > 0x100000000ul
#define PMEM64 1
#endif

/*
 * Fast non-signal-mask setjmp/longjmp shim used on the inner-loop trap path
 * (every executed instruction calls setjmp twice). Standard setjmp on macOS
 * (BSD libc) is implicitly sigsetjmp(.., 1) which calls sigprocmask /
 * sigaltstack / sigreturn syscalls — these dominate >90% of NEMU runtime in
 * `sample`-based profiling on Apple Silicon. POSIX `_setjmp`/`_longjmp` are
 * defined to NOT save/restore the signal mask and are pure register
 * save/restore on both glibc and Darwin. NEMU does not need the signal mask
 * preserved across its trap unwinds, so this is a safe drop-in replacement.
 *
 * On platforms without `_setjmp` (rare; e.g. some embedded libcs) fall back
 * to the regular setjmp/longjmp. AM target uses klib so just defer to its
 * setjmp/longjmp.
 */
#if !defined(CONFIG_TARGET_AM) && (defined(__APPLE__) || defined(__linux__) || defined(__GLIBC__) || defined(_POSIX_C_SOURCE))
#define nemu_setjmp(buf)         _setjmp(buf)
#define nemu_longjmp(buf, val)   _longjmp((buf), (val))
#else
#define nemu_setjmp(buf)         setjmp(buf)
#define nemu_longjmp(buf, val)   longjmp((buf), (val))
#endif

typedef MUXDEF(CONFIG_ISA64, uint64_t, uint32_t) word_t;
typedef MUXDEF(CONFIG_ISA64, int64_t, int32_t)  sword_t;
#define FMT_WORD MUXDEF(CONFIG_ISA64, "0x%016" PRIx64, "0x%08" PRIx32)
#define FMT_WORD_NO_PREFIX MUXDEF(CONFIG_ISA64, "%016" PRIx64, "%08" PRIx32)

typedef word_t vaddr_t;
typedef MUXDEF(PMEM64, uint64_t, uint32_t) paddr_t;
#define FMT_PADDR MUXDEF(PMEM64, "0x%016" PRIx64, "0x%08" PRIx32)
typedef uint16_t ioaddr_t;

#include <debug.h>

#endif
