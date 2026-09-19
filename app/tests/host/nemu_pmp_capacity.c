#include <isa.h>
#include <isa-def.h>
#include <assert.h>
#include <stdio.h>

CPU_state cpu;
void soft_tlb_flush(void) {}
void pmp_restore_checkpoint(const uint8_t *, const word_t *);
int pmp_csr_write(uint16_t, word_t);
bool pmp_check(paddr_t, int, uint32_t, bool, bool, bool);

static void config(unsigned entry, unsigned cfg) {
  unsigned bank = XLEN == 64 ? (entry / 8) * 2 : entry / 4;
  assert(pmp_csr_write(0x3a0 + bank, (word_t)cfg << ((entry % (XLEN / 8)) * 8)));
}

int main(void) {
  uint8_t cfg[16] = {0};
  word_t addr[16] = {0};
  // Checkpoint restore must also discard unavailable state.
  for (unsigned i = 8; i < 16; ++i) { cfg[i] = 0x9f; addr[i] = ~(word_t)0; }
  pmp_restore_checkpoint(cfg, addr);
  assert(pmp_check(0x80000000, 4, PRV_S, true, false, false));
  for (unsigned i = 8; i < 16; ++i) {
    config(i, 0x89); // An unavailable locked TOR must not lock its predecessor.
    assert(pmp_csr_write(0x3b0 + i, ~(word_t)0));
    assert(cpu.sr[0x3b0 + i] == 0);
    assert(pmp_csr_write(0x3b7, 0x20000000));
    assert(cpu.sr[0x3b7] == 0x20000000);
  }
  assert(cpu.sr[0x3a2] == 0 && cpu.sr[0x3a3] == 0);
  config(7, 0x1f); // Last usable entry remains functional.
  assert(!pmp_check(0x80000000, 4, PRV_S, true, false, false));
  config(7, 0x9f);
  assert(pmp_csr_write(0x3b7, 0));
  assert(cpu.sr[0x3b7] == 0x20000000);
  config(7, 0);
  assert(!pmp_check(0x80000000, 4, PRV_S, true, false, false));
  printf("PASS: RV%d PMP 8 usable / 16 CSR slots, restore, upper writes and entry 7 lock\n", XLEN);
  return 0;
}
