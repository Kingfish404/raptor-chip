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

#include <setjmp.h>
#include <isa.h>
#include <memory/host.h>
#include <memory/paddr.h>
#include <device/mmio.h>
#include <cpu/difftest.h>

extern jmp_buf exec_jmp_buf;
extern int cause;

char *btb_file = NULL;

#if defined(CONFIG_PMEM_MALLOC)
static uint8_t *pmem = NULL;
#else // CONFIG_PMEM_GARRAY
static uint8_t pmem[CONFIG_MSIZE] PG_ALIGN = {};
#endif
static uint8_t rom[CONFIG_ROM_SIZE] PG_ALIGN = {};
static uint8_t sdram[CONFIG_SDRAM_SIZE] PG_ALIGN = {};
static uint8_t sram[CONFIG_SRAM_SIZE] PG_ALIGN = {};
static uint8_t mrom[CONFIG_MROM_SIZE] PG_ALIGN = {};
static uint8_t flash[CONFIG_FLASH_SIZE] PG_ALIGN = {};

uint8_t *guest_to_host(paddr_t paddr)
{
  if (in_pmem(paddr))
    return pmem + paddr - CONFIG_MBASE;
  // qemu virt peripheral start
  // https://github.com/qemu/qemu/blob/master/hw/riscv/virt.c
  difftest_skip_ref();
  if (in_rom(paddr))
    return rom + paddr - CONFIG_ROM_BASE;
  if (in_sdram(paddr))
    return sdram + paddr - CONFIG_SDRAM_BASE;
  if (in_sram(paddr))
    return sram + paddr - CONFIG_SRAM_BASE;
  if (in_mrom(paddr))
    return mrom + paddr - CONFIG_MROM_BASE;
  if (in_flash(paddr))
    return flash + paddr - CONFIG_FLASH_BASE;
  // soc peripheral end
  Assert(0, "invalid guest physical address = " FMT_PADDR, paddr);
}
paddr_t host_to_guest(uint8_t *haddr)
{
  return haddr - pmem + CONFIG_MBASE;
  Assert(0, "invalid host virtual address = %p", haddr);
}

static word_t pmem_read(paddr_t addr, int len)
{
  word_t ret = host_read(guest_to_host(addr), len);
  return ret;
}

static void pmem_write(paddr_t addr, int len, word_t data)
{
  host_write(guest_to_host(addr), len, data);
}

static void out_of_bound(paddr_t addr)
{
  if (cpu.sr[CSR_MTVEC] != 0 && cpu.priv == PRV_M)
  {
    cause = MCA_LOA_ACC_FAU;
    longjmp(exec_jmp_buf, 10);
  }
  panic("address = " FMT_PADDR " is out of bound of pmem [" FMT_PADDR ", " FMT_PADDR "] at pc = " FMT_WORD,
        addr, PMEM_LEFT, PMEM_RIGHT, cpu.pc);
}

void init_mem()
{
#if defined(CONFIG_PMEM_MALLOC)
  pmem = malloc(CONFIG_MSIZE);
  assert(pmem);
#endif
  IFDEF(CONFIG_MEM_RANDOM, memset(pmem, rand(), CONFIG_MSIZE));
  Log("physical memory area [" FMT_PADDR ", " FMT_PADDR "]", PMEM_LEFT, PMEM_RIGHT);
  memset(sram, 0, sizeof(sram));
  memset(mrom, 0, sizeof(mrom));

#if defined(CONFIG_ROM)
  // refer spike:riscv/sim.cc
  // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/sim.cc
#define RESET_VEC_SIZE 8
  const int reset_vec_size = RESET_VEC_SIZE;
  uint64_t pc = 0x80000000;
  uint32_t reset_vec[RESET_VEC_SIZE] = {
      0x297,                                             // auipc  t0,0x0
      0x28593 + (reset_vec_size * 4 << 20),              // addi   a1, t0, &dtb
      0xf1402573,                                        // csrr   a0, mhartid
      strcmp(CONFIG_ISA, "riscv32") == 0 ? 0x0182a283u : // lw     t0,24(t0)
          0x0182b283u,                                   // ld     t0,24(t0)
      0x28067,                                           // jr     t0
      0,
      (uint32_t)(pc & 0xffffffff),
      (uint32_t)(pc >> 32)};
  for (int i = 0; i < reset_vec_size; i++)
  {
    rom[i * 4 + 0] = (reset_vec[i] >> 0) & 0xff;
    rom[i * 4 + 1] = (reset_vec[i] >> 8) & 0xff;
    rom[i * 4 + 2] = (reset_vec[i] >> 16) & 0xff;
    rom[i * 4 + 3] = (reset_vec[i] >> 24) & 0xff;
  }
#if defined(CONFIG_ROM_DTB)
  char default_filename[] = CONFIG_ROM_DTB_PATH;
  char *filename = default_filename;
  if (btb_file != NULL)
  {
    filename = btb_file;
  }
  FILE *fp = fopen(filename, "rb");
  Assert(fp, "Can not open '%s'", filename);
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  Assert(size < CONFIG_ROM_SIZE - reset_vec_size * 4, "dtb file is too large");
  fseek(fp, 0, SEEK_SET);
  int ret = fread(rom + reset_vec_size * 4, size, 1, fp);
  assert(ret == 1);
  fclose(fp);
  Log("The dtb: %s, size: %ld, loaded to " FMT_PADDR "",
      filename, size, (paddr_t)(CONFIG_ROM_BASE + reset_vec_size * 4));
#endif
#endif
}

word_t paddr_read(paddr_t addr, int len)
{
#ifdef CONFIG_MTRACE
  printf("paddr_r: " FMT_PADDR ", size: %d\n", addr, len);
#endif

  if (likely(
          in_pmem(addr) ||
          in_rom(addr) ||
          in_sdram(addr) ||
          in_sram(addr) ||
          in_mrom(addr) ||
          in_flash(addr)))
    return pmem_read(addr, len);
  IFDEF(CONFIG_DEVICE, return mmio_read(addr, len));
  out_of_bound(addr);
  return 0;
}

void paddr_write(paddr_t addr, int len, word_t data)
{
#ifdef CONFIG_MTRACE
  printf("paddr_w: " FMT_PADDR ", size: %d, data: " FMT_WORD "\n", addr, len, data);
#endif

  if (likely(
          in_pmem(addr) || in_sdram(addr) || in_sram(addr)))
  {
    pmem_write(addr, len, data);
    return;
  }
  IFDEF(CONFIG_DEVICE, mmio_write(addr, len, data); return);
  out_of_bound(addr);
}
