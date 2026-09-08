/* Execute the production walker with deterministic physical PTE memory.
 * Environment inputs are injected directly: this does not claim CSR PBMTE
 * software enablement or cache/ordering coverage. */
#include <isa.h>
#include <memory/paddr.h>
#include <setjmp.h>
#include <stdio.h>
CPU_state cpu;
jmp_buf exec_jmp_buf;
int cause;
static uint8_t memory[16384];
static unsigned reads, writes, checked;
static uint8_t expected_pbmt, observed_pbmt;
static uint64_t denied;
uint32_t pmp_effective_priv_ls(void) { return cpu.priv; }
bool pmp_check(paddr_t addr, int size, uint32_t priv, bool r, bool w, bool x) {
  (void)size; (void)priv; (void)r; (void)w; (void)x;
  return addr == denied;
}
word_t paddr_read(paddr_t addr, int len) {
  assert(addr >= 0x80000000ull && addr + len <= 0x80004000ull);
  uint64_t value = 0; memcpy(&value, memory + addr - 0x80000000ull, len);
  reads++; return value;
}
void paddr_write(paddr_t addr, int len, word_t data) {
  (void)addr; (void)len; (void)data; writes++;
}
static void put(uint64_t addr, uint64_t value) {
  memcpy(memory + addr - 0x80000000ull, &value, 8);
}
static uint64_t slot(int level) {
  return level == 2 ? 0x80000008ull : level == 1 ? 0x80001000ull : 0x80002018ull;
}
static void setup(int level, unsigned pbmt, bool enabled) {
  memset(&cpu, 0, sizeof(cpu)); memset(memory, 0, sizeof(memory));
  cpu.priv = PRV_S; cpu.sr[CSR_SATP] = (8ull << 60) | 0x80000;
  cpu.sr[CSR_MENVCFG] = enabled ? 1ull << 62 : 0;
  put(slot(2), (0x80001ull << 10) | 1);
  put(slot(1), (0x80002ull << 10) | 1);
  put(slot(level), (0x80000ull << 10) | 0xcf | ((uint64_t)pbmt << 61));
  reads = writes = 0; denied = UINT64_MAX;
  expected_pbmt = pbmt;
}
static void check(int type, int fault, unsigned max_reads) {
  cause = 0; observed_pbmt = 0xff;
  int trapped = nemu_setjmp(exec_jmp_buf);
  if (!trapped) {
    uint64_t pa = isa_mmu_translate_attrs(0x40003000ull, 4, type, &observed_pbmt);
    assert(observed_pbmt == expected_pbmt);
    if (fault || pa != 0x80003000ull) {
      fprintf(stderr, "walk type=%d expected cause=%d got PA=%llx\n", type, fault, (unsigned long long)pa);
      assert(!fault && pa == 0x80003000ull);
    }
  } else {
    if (cause != fault || !fault) fprintf(stderr, "walk type=%d expected cause=%d got cause=%d\n",type,fault,cause);
    assert(fault && cause == fault);
    assert(observed_pbmt == 0);
  }
  assert(reads <= max_reads && writes == 0); checked++;
}
int main(void) {
  /* All legal and reserved types, enable states, leaf sizes and access kinds. */
  for (int level = 0; level < 3; level++)
    for (int type = 0; type < 4; type++)
      for (int en = 0; en < 2; en++)
        for (unsigned pbmt = 0; pbmt < 4; pbmt++) {
          setup(level,pbmt,en);
          // A level-zero leaf maps exactly PA 0x80000000 + page offset.
          if (level == 0) put(slot(0),(0x80003ull << 10) | 0xcf | ((uint64_t)pbmt << 61));
          int pf = type == MEM_TYPE_IFETCH ? 12 : type == MEM_TYPE_READ ? 13 : 15;
          check(type, pbmt == 3 || (pbmt && !en) ? pf : 0, 3-level);
        }
  for (int level = 1; level < 3; level++)
    for (int type = 0; type < 4; type++)
      for (unsigned pbmt = 1; pbmt < 4; pbmt++) {
        setup(0,0,true);
        put(slot(level), ((level == 2 ? 0x80001ull : 0x80002ull) << 10) | 1 | ((uint64_t)pbmt << 61));
        check(type,type==0?12:type==1?13:15,3-level);
      }
  for (int bit = 54; bit < 64; bit++) {
    if (bit == 61 || bit == 62) continue;
    for (int level = 0; level < 3; level++) {
      setup(level,1,true);
      put(slot(level),(0x80000ull << 10)|0xcf|(1ull<<61)|(1ull<<bit));
      check(MEM_TYPE_READ,13,3-level);
    }
  }
  // Svade and leaf permission faults remain faults with PBMTE enabled.
  for (int type = 0; type < 4; type++) {
    setup(0,2,true);put(slot(0),(0x80003ull<<10)|0x0f|(2ull<<61));
    check(type,type==0?12:type==1?13:15,3);
    setup(0,2,true);denied=slot(1);
    check(type,type==0?1:type==1?5:7,1);
  }
  setup(0,2,true); cpu.sr[CSR_SATP] = 0; observed_pbmt = 0xff;
  assert(isa_mmu_translate_attrs(0x40003000ull,4,MEM_TYPE_READ,&observed_pbmt) == 0x40003000ull);
  assert(observed_pbmt == 0 && reads == 0);
  setup(0,0,false);put(slot(0),(0x80003ull<<10)|0xcf);
  assert(isa_mmu_translate(0x40003000ull,4,MEM_TYPE_READ) == 0x80003000ull);
  printf("PASS: %u production Sv39 walker PBMT cases, zero PTE writes\n",checked);
}
