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

#include <utils.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <memory/paddr.h>

NEMUState nemu_state = {.state = NEMU_STOP};

int is_exit_status_bad()
{
  int good = (nemu_state.state == NEMU_END && nemu_state.halt_ret == 0) ||
             (nemu_state.state == NEMU_QUIT);
  return !good;
}

/* ===== RISC-V signature dump (for RISCOF compliance testing) =====
 * Configured via --sig=<hex_begin>-<hex_end>:<path> option.  Dumps
 * memory[sig_begin, sig_end) as 4-byte little-endian words, one word
 * per line as 8 lowercase hex chars, matching the RISCOF signature
 * format produced by the sail reference model.  Mirrors the sim
 * implementation in sim/csrc/utils/state.cc so the two DUT flows
 * produce byte-identical signatures. */

static paddr_t sig_begin = 0;
static paddr_t sig_end = 0;
static char *sig_file = NULL;
static int sig_enabled = 0;

int sig_is_enabled(void) { return sig_enabled; }

int sig_set_range(const char *spec)
{
  if (spec == NULL)
    return -1;
  const char *dash = strchr(spec, '-');
  const char *colon = strchr(spec, ':');
  if (dash == NULL || colon == NULL || dash >= colon)
    return -1;

  unsigned long long begin = 0, end = 0;
  if (sscanf(spec, "%llx-%llx", &begin, &end) != 2)
    return -1;

  sig_begin = (paddr_t)begin;
  sig_end = (paddr_t)end;
  if (sig_end <= sig_begin)
    return -1;

  const char *path = colon + 1;
  if (*path == '\0')
    return -1;
  if (sig_file != NULL)
    free(sig_file);
  sig_file = strdup(path);
  sig_enabled = 1;
  return 0;
}

int sig_dump_if_enabled(void)
{
  if (!sig_enabled)
    return 0;

  FILE *fp = fopen(sig_file, "w");
  if (fp == NULL)
  {
    printf("[sig] ERROR: cannot open signature file: %s\n", sig_file);
    return -1;
  }

  /* Align to 4 bytes defensively; RISCOF already guarantees alignment. */
  paddr_t addr = sig_begin & ~((paddr_t)0x3);
  paddr_t end = (sig_end + 3) & ~((paddr_t)0x3);
  size_t words = 0;

  for (; addr < end; addr += 4)
  {
    uint8_t *host = guest_to_host(addr);
    uint32_t w = 0;
    if (host != NULL)
    {
      w = ((uint32_t)host[0]) |
          ((uint32_t)host[1] << 8) |
          ((uint32_t)host[2] << 16) |
          ((uint32_t)host[3] << 24);
    }
    fprintf(fp, "%08x\n", w);
    words++;
  }

  fclose(fp);
  printf("[sig] dumped %zu words [0x%lx, 0x%lx) -> %s\n",
         words, (unsigned long)sig_begin, (unsigned long)sig_end, sig_file);
  return 0;
}
